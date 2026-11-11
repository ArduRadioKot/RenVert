import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision
import CoreImage
import PDFKit

/// Files a converter produced beyond the one it was asked for, such as pages 2…N of a PDF.
/// The engine moves them next to the main result as "Name 2.ext", "Name 3.ext".
public final class ExtraOutputs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    public init() {}

    public func add(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        urls.append(url)
    }

    public var all: [URL] {
        lock.lock(); defer { lock.unlock() }
        return urls
    }
}

public struct ConversionContext: Sendable {
    public var settings: AppSettings
    public var cancellation: CancellationToken
    public var onProgress: (@Sendable (Double) -> Void)?
    /// Nil when the caller can only take one file; converters then produce just the first.
    public var extraOutputs: ExtraOutputs?

    public init(settings: AppSettings, cancellation: CancellationToken, onProgress: (@Sendable (Double) -> Void)? = nil) {
        self.settings = settings
        self.cancellation = cancellation
        self.onProgress = onProgress
    }
}

public protocol Converter: Sendable {
    func convert(from source: URL, detected: FormatID, spec: OutputSpec, to destination: URL, context: ConversionContext) throws
}

enum ImageIOSupport {
    static func utType(for id: FormatID) -> UTType? {
        switch id {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .tiff: return .tiff
        case .bmp: return .bmp
        case .gif: return .gif
        case .ico: return UTType("com.microsoft.ico")
        case .icns: return .icns
        case .webp: return UTType("org.webmproject.webp")
        case .avif: return UTType("public.avif")
        case .pdf: return .pdf
        default: return FormatRegistry.descriptor(for: id).utType
        }
    }
}

enum ImageRaster {
    static func image(from cgImage: CGImage) -> NSImage {
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        let image = NSImage(size: size)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size
        image.addRepresentation(rep)
        return image
    }

    static func pixelSize(of image: NSImage) -> NSSize {
        if let cg = cgImage(from: image) {
            return NSSize(width: cg.width, height: cg.height)
        }
        return image.size
    }

    static func cgImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let raw = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? UInt32)
            ?? (props?[kCGImagePropertyOrientation] as? Int).map(UInt32.init)
            ?? 1
        return applyOrientation(raw, orientation)
    }

    static func applyOrientation(_ image: CGImage, _ orientation: UInt32) -> CGImage {
        guard (2...8).contains(orientation) else { return image }
        let ci = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(ci, from: ci.extent) ?? image
    }

    static func cgImage(from image: NSImage) -> CGImage? {
        let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        if let best = bitmaps.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }),
           let cg = best.cgImage {
            return cg
        }
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let cg = rep.cgImage {
            return cg
        }
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    static func standardized(_ image: CGImage, opaque: Bool) -> CGImage {
        guard image.width > 0, image.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        guard let ctx = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: alpha.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if opaque {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(rect)
        }
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    static func bitmap(pixelSize size: NSSize, draw: (CGRect) -> Void) -> NSImage {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: size)
        }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        let graphics = NSGraphicsContext(bitmapImageRep: rep)
        graphics?.imageInterpolation = .high
        NSGraphicsContext.current = graphics
        draw(rect)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }
}

public struct ImageConverter: Converter {
    public init() {}

    public func convert(from source: URL, detected: FormatID, spec: OutputSpec, to destination: URL, context: ConversionContext) throws {
        try context.cancellation.throwIfCancelled()
        if spec.format == .txt || (spec.hasOCR && spec.format == .pdf) {
            try IntelligenceConverter().convert(from: source, detected: detected, spec: spec, to: destination, context: context)
            return
        }

        var image = try loadImage(source, format: detected, spec: spec)
        image = try applyImageModifiers(image, spec.modifiers, context: context)
        context.onProgress?(0.6)

        if spec.format == .pdf {
            try writePDF(image, to: destination, spec: spec, preserveMeta: shouldPreserveMeta(spec, context.settings))
            return
        }

        guard let uti = ImageIOSupport.utType(for: spec.format) else {
            throw RenvertError.unsupportedConversion(from: detected.rawValue, to: spec.format.rawValue)
        }
        try writeImage(image, to: destination, utType: uti, spec: spec, settings: context.settings)
        context.onProgress?(1)
    }

    /// `format` is what the bytes are. The extension cannot be trusted: after a rename it is
    /// already the target's.
    func loadImage(_ url: URL, format: FormatID, spec: OutputSpec) throws -> NSImage {
        if format == .svg || format == .svgz {
            return try rasterizeSVG(url, compressed: format == .svgz, spec: spec)
        }
        if format != .pdf, let cg = ImageRaster.cgImage(at: url) {
            return ImageRaster.image(from: cg)
        }
        if let data = try? Data(contentsOf: url), let image = NSImage(data: data), image.isValid { return image }
        throw RenvertError.invalidInput(L("Could not decode image."))
    }

    /// An SVG's nominal size is often icon-sized. It is drawn as vectors at the requested
    /// width or height, or large enough to be useful, instead of being enlarged afterwards.
    private func rasterizeSVG(_ url: URL, compressed: Bool, spec: OutputSpec) throws -> NSImage {
        var data = try Data(contentsOf: url)
        if compressed {
            let result = ProcessRunner.run(executable: "/usr/bin/gunzip", arguments: ["-c", url.path])
            guard result.exitCode == 0 else { throw RenvertError.invalidInput(L("Could not decode image.")) }
            data = Data(result.stdout.utf8)
        }
        guard let vector = NSImage(data: data), vector.isValid, vector.size.width > 0, vector.size.height > 0 else {
            throw RenvertError.invalidInput(L("Could not decode image."))
        }
        var requestedWidth: CGFloat?
        var requestedHeight: CGFloat?
        for modifier in spec.modifiers {
            if case .width(let value) = modifier { requestedWidth = CGFloat(value) }
            if case .height(let value) = modifier { requestedHeight = CGFloat(value) }
        }
        let nominal = vector.size
        let scale: CGFloat
        if let requestedWidth {
            scale = requestedWidth / nominal.width
        } else if let requestedHeight {
            scale = requestedHeight / nominal.height
        } else {
            scale = max(1, 2048 / max(nominal.width, nominal.height))
        }
        let size = NSSize(width: nominal.width * scale, height: nominal.height * scale)
        return ImageRaster.bitmap(pixelSize: size) { rect in
            vector.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    func applyImageModifiers(_ image: NSImage, _ modifiers: [Modifier], context: ConversionContext) throws -> NSImage {
        var current = image
        for modifier in modifiers {
            try context.cancellation.throwIfCancelled()
            switch modifier {
            case .width(let w):
                current = resize(current, width: CGFloat(w), height: nil)
            case .height(let h):
                current = resize(current, width: nil, height: CGFloat(h))
            case .crop(let w, let h):
                current = crop(current, ratioW: w, ratioH: h, smart: false)
            case .smartCrop(let w, let h):
                current = crop(current, ratioW: w, ratioH: h, smart: true)
            case .rotate(let degrees):
                current = rotate(current, degrees: CGFloat(degrees))
            case .flipH:
                current = flip(current, horizontal: true)
            case .flipV:
                current = flip(current, horizontal: false)
            case .gray:
                current = grayscale(current)
            case .noBackground:
                current = try removeBackground(current)
            case .min:
                current = resizeIfLarger(current, maxEdge: 1920)
            default:
                continue
            }
        }
        return current
    }

    func writeImage(_ image: NSImage, to url: URL, utType: UTType, spec: OutputSpec, settings: AppSettings) throws {
        guard let base = ImageRaster.cgImage(from: image) else {
            throw RenvertError.converterFailed(L("Could not rasterize image."))
        }
        let forceOpaque = utType == .jpeg || utType == .bmp
        let prepared = ImageRaster.standardized(base, opaque: forceOpaque)
        if writeCGImage(prepared, to: url, utType: utType, spec: spec, settings: settings) {
            if let limit = spec.maxBytes() {
                try fitToSize(ImageRaster.image(from: prepared), url: url, utType: utType, limit: limit, settings: settings)
            }
            return
        }
        if !forceOpaque {
            let flat = ImageRaster.standardized(base, opaque: true)
            if writeCGImage(flat, to: url, utType: utType, spec: spec, settings: settings) {
                if let limit = spec.maxBytes() {
                    try fitToSize(ImageRaster.image(from: flat), url: url, utType: utType, limit: limit, settings: settings)
                }
                return
            }
        }
        try writeWithExternalTool(ImageRaster.image(from: prepared), to: url, spec: spec)
    }

    /// One PDF page that fits the image. A photo is scaled down to the system paper size
    /// (A4 or Letter) and stored as JPEG, so the page is printable and the file stays small.
    /// Small images keep their size at 72 dpi; images with transparency are stored losslessly on white.
    func writePDF(_ image: NSImage, to url: URL, spec: OutputSpec, preserveMeta: Bool) throws {
        guard let cg = ImageRaster.cgImage(from: image) else {
            throw RenvertError.converterFailed(L("Could not rasterize image."))
        }
        let pixels = CGSize(width: cg.width, height: cg.height)
        var paper = NSPrintInfo.shared.paperSize
        if paper.width <= 0 || paper.height <= 0 { paper = NSSize(width: 595, height: 842) }
        if (pixels.width > pixels.height) != (paper.width > paper.height) {
            paper = NSSize(width: paper.height, height: paper.width)
        }
        let fit = min(1, paper.width / pixels.width, paper.height / pixels.height)
        var media = CGRect(x: 0, y: 0, width: (pixels.width * fit).rounded(), height: (pixels.height * fit).rounded())

        let hasAlpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(cg.alphaInfo)
        let flat = ImageRaster.standardized(cg, opaque: true)
        var embedded = flat
        if !hasAlpha && !spec.hasLossless {
            // A JPEG-backed CGImage is written into the PDF as JPEG instead of being inflated.
            let quality = spec.quality().map { Double($0) / 100 } ?? 0.9
            let data = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                if CGImageDestinationFinalize(dest),
                   let provider = CGDataProvider(data: data),
                   let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                    embedded = jpeg
                }
            }
        }

        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            throw RenvertError.converterFailed(L("Could not create PDF."))
        }
        ctx.beginPDFPage(nil)
        ctx.interpolationQuality = .high
        ctx.draw(embedded, in: media)
        ctx.endPDFPage()
        ctx.closePDF()
        _ = preserveMeta
    }

    private func writeCGImage(_ image: CGImage, to url: URL, utType: UTType, spec: OutputSpec, settings: AppSettings) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, utType.identifier as CFString, 1, nil) else {
            return false
        }
        var props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: qualityValue(spec: spec, settings: settings, utType: utType)
        ]
        if spec.hasLossless {
            props[kCGImageDestinationLossyCompressionQuality] = 1.0
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    private func writeWithExternalTool(_ image: NSImage, to url: URL, spec: OutputSpec) throws {
        guard let cg = ImageRaster.cgImage(from: image) else {
            throw RenvertError.converterFailed(L("Could not rasterize image."))
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("renvert-img-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenvertError.converterFailed(L("Could not rasterize image."))
        }
        CGImageDestinationAddImage(dest, ImageRaster.standardized(cg, opaque: false), nil)
        guard CGImageDestinationFinalize(dest) else {
            throw RenvertError.converterFailed(L("Could not rasterize image."))
        }
        if encodeWithFFmpeg(temp, to: url, spec: spec) {
            return
        }
        guard let magick = ExternalToolLocator.magick else {
            throw RenvertError.converterFailed(L("No encoder is available for \(spec.format.rawValue) on this Mac."))
        }
        var args = [temp.path]
        if let quality = spec.quality() {
            args += ["-quality", String(quality)]
        }
        args.append(url.path)
        let result = ProcessRunner.run(executable: magick.path, arguments: args)
        guard result.exitCode == 0 else {
            throw RenvertError.converterFailed(result.stderr.isEmpty ? "ImageMagick failed" : result.stderr)
        }
    }

    private func encodeWithFFmpeg(_ source: URL, to url: URL, spec: OutputSpec) -> Bool {
        guard let ffmpeg = ExternalToolLocator.ffmpeg else { return false }
        var args = ["-y", "-hide_banner", "-loglevel", "error", "-i", source.path]
        switch spec.format {
        case .webp:
            args += ["-c:v", "libwebp"]
            if let quality = spec.quality() { args += ["-quality", String(quality)] }
        case .avif:
            args += ["-c:v", "libaom-av1", "-still-picture", "1"]
        case .jpeg:
            args += ["-q:v", "3"]
        default:
            break
        }
        args.append(url.path)
        let result = ProcessRunner.run(executable: ffmpeg.path, arguments: args)
        return result.exitCode == 0 && FileManager.default.fileExists(atPath: url.path)
    }

    private func qualityValue(spec: OutputSpec, settings: AppSettings, utType: UTType) -> Double {
        if let q = spec.quality() {
            return Double(q) / 100.0
        }
        if spec.modifiers.contains(.min) { return 0.55 }
        if utType == .jpeg { return settings.conversion.jpegQuality }
        if utType.identifier.contains("webp") { return settings.conversion.webpQuality }
        return 0.82
    }

    private func shouldPreserveMeta(_ spec: OutputSpec, _ settings: AppSettings) -> Bool {
        if spec.modifiers.contains(.noMeta) { return false }
        return settings.conversion.preserveMetadata
    }

    private func fitToSize(_ image: NSImage, url: URL, utType: UTType, limit: Int64, settings: AppSettings) throws {
        var low = 0.15
        var high = 0.95
        var best: Data?
        for _ in 0..<8 {
            let mid = (low + high) / 2
            let data = try encode(image, utType: utType, quality: mid)
            if Int64(data.count) <= limit {
                best = data
                low = mid
            } else {
                high = mid
            }
        }
        if let best {
            try best.write(to: url)
        } else {
            throw RenvertError.converterFailed(L("Could not fit output under the requested size."))
        }
    }

    private func encode(_ image: NSImage, utType: UTType, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let cg = ImageRaster.cgImage(from: image),
              let dest = CGImageDestinationCreateWithData(data, utType.identifier as CFString, 1, nil) else {
            throw RenvertError.converterFailed(L("encode failed"))
        }
        let opaque = utType == .jpeg || utType == .bmp
        CGImageDestinationAddImage(
            dest,
            ImageRaster.standardized(cg, opaque: opaque),
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else { throw RenvertError.converterFailed(L("encode failed")) }
        return data as Data
    }

    private func resize(_ image: NSImage, width: CGFloat?, height: CGFloat?) -> NSImage {
        let size = ImageRaster.pixelSize(of: image)
        let ratio = size.width / max(size.height, 1)
        let newSize: NSSize
        if let width, let height {
            newSize = NSSize(width: width, height: height)
        } else if let width {
            newSize = NSSize(width: width, height: width / ratio)
        } else if let height {
            newSize = NSSize(width: height * ratio, height: height)
        } else {
            return image
        }
        return ImageRaster.bitmap(pixelSize: newSize) { rect in
            image.draw(in: rect, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1)
        }
    }

    private func resizeIfLarger(_ image: NSImage, maxEdge: CGFloat) -> NSImage {
        let size = ImageRaster.pixelSize(of: image)
        let edge = max(size.width, size.height)
        guard edge > maxEdge else { return image }
        let scale = maxEdge / edge
        return resize(image, width: size.width * scale, height: size.height * scale)
    }

    private func crop(_ image: NSImage, ratioW: Int, ratioH: Int, smart: Bool) -> NSImage {
        let target = CGFloat(ratioW) / CGFloat(ratioH)
        let size = ImageRaster.pixelSize(of: image)
        let current = size.width / max(size.height, 1)
        var rect = NSRect(origin: .zero, size: size)
        if current > target {
            let width = size.height * target
            var x = (size.width - width) / 2
            if smart, let focus = saliencyPoint(image) {
                x = min(max(focus.x * size.width - width / 2, 0), size.width - width)
            }
            rect = NSRect(x: x, y: 0, width: width, height: size.height)
        } else {
            let height = size.width / target
            var y = (size.height - height) / 2
            if smart, let focus = saliencyPoint(image) {
                y = min(max(focus.y * size.height - height / 2, 0), size.height - height)
            }
            rect = NSRect(x: 0, y: y, width: size.width, height: height)
        }
        return ImageRaster.bitmap(pixelSize: rect.size) { dest in
            image.draw(in: dest, from: rect, operation: .copy, fraction: 1)
        }
    }

    private func saliencyPoint(_ image: NSImage) -> CGPoint? {
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else { return nil }
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(ciImage: ci)
        try? handler.perform([request])
        guard let obs = request.results?.first else { return nil }
        let objects = obs.salientObjects ?? []
        if let first = objects.sorted(by: { $0.confidence > $1.confidence }).first {
            return CGPoint(x: first.boundingBox.midX, y: first.boundingBox.midY)
        }
        return CGPoint(x: 0.5, y: 0.5)
    }

    private func rotate(_ image: NSImage, degrees: CGFloat) -> NSImage {
        let size = ImageRaster.pixelSize(of: image)
        let swapped = Int(degrees) % 180 != 0
        let newSize = swapped ? NSSize(width: size.height, height: size.width) : size
        return ImageRaster.bitmap(pixelSize: newSize) { _ in
            let transform = NSAffineTransform()
            transform.translateX(by: newSize.width / 2, yBy: newSize.height / 2)
            transform.rotate(byDegrees: degrees)
            transform.translateX(by: -size.width / 2, yBy: -size.height / 2)
            transform.concat()
            image.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1)
        }
    }

    private func flip(_ image: NSImage, horizontal: Bool) -> NSImage {
        let size = ImageRaster.pixelSize(of: image)
        return ImageRaster.bitmap(pixelSize: size) { _ in
            var transform = AffineTransform()
            if horizontal {
                transform.scale(x: -1, y: 1)
                transform.translate(x: -size.width, y: 0)
            } else {
                transform.scale(x: 1, y: -1)
                transform.translate(x: 0, y: -size.height)
            }
            (transform as NSAffineTransform).concat()
            image.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1)
        }
    }

    private func grayscale(_ image: NSImage) -> NSImage {
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else { return image }
        let filter = CIFilter(name: "CIColorControls")
        filter?.setValue(ci, forKey: kCIInputImageKey)
        filter?.setValue(0, forKey: kCIInputSaturationKey)
        guard let output = filter?.outputImage else { return image }
        let rep = NSCIImageRep(ciImage: output)
        let out = NSImage(size: rep.size)
        out.addRepresentation(rep)
        return out
    }

    private func removeBackground(_ image: NSImage) throws -> NSImage {
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else {
            throw RenvertError.converterFailed(L("Background removal needs a raster image."))
        }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: ci, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else {
            throw RenvertError.converterFailed(L("No foreground subject was found."))
        }
        let mask = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        let maskImage = CIImage(cvPixelBuffer: mask)
        let filtered = ci.applyingFilter("CIBlendWithMask", parameters: [
            "inputMaskImage": maskImage
        ])
        let rep = NSCIImageRep(ciImage: filtered)
        let out = NSImage(size: image.size)
        out.addRepresentation(rep)
        return out
    }
}

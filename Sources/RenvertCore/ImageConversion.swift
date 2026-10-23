import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision
import CoreImage
import PDFKit

public struct ConversionContext: Sendable {
    public var settings: AppSettings
    public var cancellation: CancellationToken
    public var onProgress: (@Sendable (Double) -> Void)?

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

public struct ImageConverter: Converter {
    public init() {}

    public func convert(from source: URL, detected: FormatID, spec: OutputSpec, to destination: URL, context: ConversionContext) throws {
        try context.cancellation.throwIfCancelled()
        if spec.format == .txt || (spec.hasOCR && spec.format == .pdf) {
            try IntelligenceConverter().convert(from: source, detected: detected, spec: spec, to: destination, context: context)
            return
        }

        var image = try loadImage(source)
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

    func loadImage(_ url: URL) throws -> NSImage {
        if url.pathExtension.lowercased() == "svg" || url.pathExtension.lowercased() == "svgz" {
            if let image = NSImage(contentsOf: url) { return image }
        }
        if let image = NSImage(contentsOf: url), image.isValid { return image }
        throw RenvertError.invalidInput(String(localized: "Could not decode image."))
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
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            throw RenvertError.converterFailed(String(localized: "Could not rasterize image."))
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, utType.identifier as CFString, 1, nil)
        guard let dest, let cg = rep.cgImage else {
            try writeWithExternalTool(image, to: url, spec: spec)
            return
        }
        var props: [CFString: Any] = [:]
        let quality = qualityValue(spec: spec, settings: settings, utType: utType)
        props[kCGImageDestinationLossyCompressionQuality] = quality
        if !shouldPreserveMeta(spec, settings) {
            props[kCGImageDestinationMetadata] = nil
        }
        if spec.hasLossless {
            props[kCGImageDestinationLossyCompressionQuality] = 1.0
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try writeWithExternalTool(image, to: url, spec: spec)
            return
        }

        if let limit = spec.maxBytes() {
            try fitToSize(image, url: url, utType: utType, limit: limit, settings: settings)
        }
    }

    func writePDF(_ image: NSImage, to url: URL, spec: OutputSpec, preserveMeta: Bool) throws {
        let size = image.size
        var media = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            throw RenvertError.converterFailed(String(localized: "Could not create PDF."))
        }
        ctx.beginPDFPage(nil)
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.draw(cg, in: media)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        _ = spec
        _ = preserveMeta
    }

    private func writeWithExternalTool(_ image: NSImage, to url: URL, spec: OutputSpec) throws {
        guard let magick = ExternalToolLocator.magick else {
            throw RenvertError.converterFailed(String(localized: "No encoder is available for \(spec.format.rawValue) on this Mac."))
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("renvert-img-\(UUID().uuidString).png")
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw RenvertError.converterFailed(String(localized: "Could not rasterize for ImageMagick."))
        }
        try png.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
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
            throw RenvertError.converterFailed(String(localized: "Could not fit output under the requested size."))
        }
    }

    private func encode(_ image: NSImage, utType: UTType, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, utType.identifier as CFString, 1, nil),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else {
            throw RenvertError.converterFailed(String(localized: "encode failed"))
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RenvertError.converterFailed(String(localized: "encode failed")) }
        return data as Data
    }

    private func resize(_ image: NSImage, width: CGFloat?, height: CGFloat?) -> NSImage {
        let size = image.size
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
        let out = NSImage(size: newSize)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize), from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    private func resizeIfLarger(_ image: NSImage, maxEdge: CGFloat) -> NSImage {
        let edge = max(image.size.width, image.size.height)
        guard edge > maxEdge else { return image }
        let scale = maxEdge / edge
        return resize(image, width: image.size.width * scale, height: image.size.height * scale)
    }

    private func crop(_ image: NSImage, ratioW: Int, ratioH: Int, smart: Bool) -> NSImage {
        let target = CGFloat(ratioW) / CGFloat(ratioH)
        let size = image.size
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
        let out = NSImage(size: rect.size)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: rect.size), from: rect, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
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
        let size = image.size
        let swapped = Int(degrees) % 180 != 0
        let newSize = swapped ? NSSize(width: size.height, height: size.width) : size
        let out = NSImage(size: newSize)
        out.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: newSize.width / 2, yBy: newSize.height / 2)
        transform.rotate(byDegrees: degrees)
        transform.translateX(by: -size.width / 2, yBy: -size.height / 2)
        transform.concat()
        image.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    private func flip(_ image: NSImage, horizontal: Bool) -> NSImage {
        let out = NSImage(size: image.size)
        out.lockFocus()
        var transform = AffineTransform()
        if horizontal {
            transform.scale(x: -1, y: 1)
            transform.translate(x: -image.size.width, y: 0)
        } else {
            transform.scale(x: 1, y: -1)
            transform.translate(x: 0, y: -image.size.height)
        }
        (transform as NSAffineTransform).concat()
        image.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
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
            throw RenvertError.converterFailed(String(localized: "Background removal needs a raster image."))
        }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: ci, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else {
            throw RenvertError.converterFailed(String(localized: "No foreground subject was found."))
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

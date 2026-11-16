import Foundation
import AppKit
import Vision
import Speech
import PDFKit
import AVFoundation

public struct IntelligenceConverter: Converter {
    public init() {}

    public func convert(from source: URL, detected: FormatID, spec: OutputSpec, to destination: URL, context: ConversionContext) throws {
        try context.cancellation.throwIfCancelled()
        if spec.modifiers.contains(.transcribe) || (detected == .wav || detected == .mp3 || detected == .m4a || detected == .mov || detected == .mp4) && subtitleFormats.contains(spec.format) {
            try transcribe(source, spec: spec, to: destination, context: context)
            return
        }
        try ocr(source, spec: spec, to: destination, context: context)
    }

    private func ocr(_ source: URL, spec: OutputSpec, to destination: URL, context: ConversionContext) throws {
        let images = try rasterPages(source, spec: spec)
        var all = ""
        var boxes: [(String, CGRect)] = []
        for image in images {
            try context.cancellation.throwIfCancelled()
            let result = try recognize(image, spec: spec)
            all += result.text
            if !all.hasSuffix("\n") { all += "\n" }
            boxes.append(contentsOf: result.boxes)
        }
        switch spec.format {
        case .txt, .markdown:
            try all.write(to: destination, atomically: true, encoding: .utf8)
        case .pdf:
            try writeSearchablePDF(images: images, boxes: boxes, to: destination)
        case .docx:
            try DocxIO.write(text: all, to: destination)
        default:
            try all.write(to: destination, atomically: true, encoding: .utf8)
        }
        context.onProgress?(1)
    }

    /// Tells a PDF from an image by its bytes: after a rename the extension is the target's.
    private func rasterPages(_ source: URL, spec: OutputSpec) throws -> [NSImage] {
        let head = (try? FileHandle(forReadingFrom: source)).flatMap { handle -> Data? in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 5)
        }
        if head == Data("%PDF-".utf8), let document = PDFDocument(url: source) {
            // 200 dpi on white: small print at 72 dpi is too coarse to recognize.
            let scale: CGFloat = 200.0 / 72.0
            return (0..<document.pageCount).compactMap { index in
                guard let page = document.page(at: index) else { return nil }
                var bounds = page.bounds(for: .cropBox)
                if page.rotation % 180 != 0 { bounds.size = CGSize(width: bounds.height, height: bounds.width) }
                let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
                return ImageRaster.bitmap(pixelSize: size) { rect in
                    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
                    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                    ctx.fill(rect)
                    ctx.scaleBy(x: scale, y: scale)
                    page.draw(with: .cropBox, to: ctx)
                }
            }
        }
        if let cg = ImageRaster.cgImage(at: source) {
            return [ImageRaster.image(from: cg)]
        }
        guard let data = try? Data(contentsOf: source), let image = NSImage(data: data) else {
            throw RenvertError.invalidInput(L("OCR needs an image or PDF."))
        }
        _ = spec
        return [image]
    }

    private func recognize(_ image: NSImage, spec: OutputSpec) throws -> (text: String, boxes: [(String, CGRect)]) {
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else {
            throw RenvertError.converterFailed(L("Could not read image for OCR."))
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let lang = spec.languageCode() {
            request.recognitionLanguages = [lang]
        }
        let handler = VNImageRequestHandler(ciImage: ci)
        try handler.perform([request])
        let observations = request.results ?? []
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        let boxes = observations.compactMap { obs -> (String, CGRect)? in
            guard let string = obs.topCandidates(1).first?.string else { return nil }
            return (string, obs.boundingBox)
        }
        return (text, boxes)
    }

    private func writeSearchablePDF(images: [NSImage], boxes: [(String, CGRect)], to url: URL) throws {
        let data = NSMutableData()
        guard let first = images.first else { throw RenvertError.invalidInput(L("No pages to OCR.")) }
        var media = CGRect(origin: .zero, size: first.size)
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            throw RenvertError.converterFailed(L("Could not write searchable PDF."))
        }
        for image in images {
            var box = CGRect(origin: .zero, size: image.size)
            ctx.beginPage(mediaBox: &box)
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ctx.draw(cg, in: box)
            }
            ctx.setFillColor(NSColor.clear.cgColor)
            ctx.setTextDrawingMode(.invisible)
            for (text, rect) in boxes {
                let mapped = CGRect(
                    x: rect.minX * box.width,
                    y: rect.minY * box.height,
                    width: rect.width * box.width,
                    height: rect.height * box.height
                )
                let line = NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: max(8, mapped.height)),
                    .foregroundColor: NSColor.clear
                ])
                let framesetter = CTFramesetterCreateWithAttributedString(line)
                let path = CGPath(rect: mapped, transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
                CTFrameDraw(frame, ctx)
            }
            ctx.endPage()
        }
        ctx.closePDF()
        try (data as Data).write(to: url)
    }

    private func transcribe(_ source: URL, spec: OutputSpec, to destination: URL, context: ConversionContext) throws {
        let audioURL = try preparedAudio(source)
        let locale = locale(from: spec)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw RenvertError.converterFailed(L("Speech recognizer is not available for \(locale.identifier)."))
        }
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = false

        let semaphore = DispatchSemaphore(value: 0)
        var resultText = ""
        var segments: [SFTranscriptionSegment] = []
        var finishError: Error?
        recognizer.recognitionTask(with: request) { result, error in
            if let result {
                resultText = result.bestTranscription.formattedString
                segments = result.bestTranscription.segments
                if result.isFinal { semaphore.signal() }
            } else if let error {
                finishError = error
                semaphore.signal()
            }
        }
        while semaphore.wait(timeout: .now() + 0.2) == .timedOut {
            if context.cancellation.isCancelled { throw RenvertError.cancelled }
        }
        if let finishError { throw finishError }

        switch spec.format {
        case .srt:
            try SubtitleIO.writeSRT(segments: segments, fallback: resultText, to: destination)
        case .vtt:
            try SubtitleIO.writeVTT(segments: segments, fallback: resultText, to: destination)
        default:
            try resultText.write(to: destination, atomically: true, encoding: .utf8)
        }
        context.onProgress?(1)
    }

    private func preparedAudio(_ source: URL) throws -> URL {
        let values = try? source.resourceValues(forKeys: [.contentTypeKey])
        if values?.contentType?.conforms(to: .audio) == true { return source }
        if let ffmpeg = ExternalToolLocator.ffmpeg {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("renvert-speech-\(UUID().uuidString).m4a")
            let result = ProcessRunner.run(
                executable: ffmpeg.path,
                arguments: ["-y", "-hide_banner", "-loglevel", "error", "-i", source.path, "-vn", "-c:a", "aac", temp.path]
            )
            if result.exitCode == 0 { return temp }
        }
        return source
    }

    private func locale(from spec: OutputSpec) -> Locale {
        if let code = spec.languageCode() {
            return Locale(identifier: code)
        }
        return Locale.current
    }
}

public enum SubtitleIO {
    public static func writeSRT(segments: [SFTranscriptionSegment], fallback: String, to url: URL) throws {
        if segments.isEmpty {
            try "1\n00:00:00,000 --> 00:00:02,000\n\(fallback)\n".write(to: url, atomically: true, encoding: .utf8)
            return
        }
        var lines: [String] = []
        for (index, segment) in segments.enumerated() {
            let start = formatSRT(segment.timestamp)
            let end = formatSRT(segment.timestamp + max(segment.duration, 0.4))
            lines.append("\(index + 1)\n\(start) --> \(end)\n\(segment.substring)\n")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    public static func writeVTT(segments: [SFTranscriptionSegment], fallback: String, to url: URL) throws {
        if segments.isEmpty {
            try "WEBVTT\n\n00:00:00.000 --> 00:00:02.000\n\(fallback)\n".write(to: url, atomically: true, encoding: .utf8)
            return
        }
        var lines = ["WEBVTT", ""]
        for segment in segments {
            let start = formatVTT(segment.timestamp)
            let end = formatVTT(segment.timestamp + max(segment.duration, 0.4))
            lines.append("\(start) --> \(end)\n\(segment.substring)\n")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    public static func convert(from source: URL, to format: FormatID, destination: URL) throws {
        let text = try String(contentsOf: source, encoding: .utf8)
        let arrow = parseCues(text)
        let sami = arrow.isEmpty ? parseSAMI(text) : []
        let sbv = arrow.isEmpty && sami.isEmpty ? parseSBV(text) : []
        let cues = !arrow.isEmpty ? arrow : (!sami.isEmpty ? sami : (!sbv.isEmpty ? sbv : parseLRC(text)))
        switch format {
        case .srt:
            let body = cues.enumerated().map { index, cue in
                "\(index + 1)\n\(formatSRT(cue.0)) --> \(formatSRT(cue.1))\n\(cue.2)\n"
            }.joined(separator: "\n")
            try body.write(to: destination, atomically: true, encoding: .utf8)
        case .vtt:
            let body = "WEBVTT\n\n" + cues.map { cue in
                "\(formatVTT(cue.0)) --> \(formatVTT(cue.1))\n\(cue.2)\n"
            }.joined(separator: "\n")
            try body.write(to: destination, atomically: true, encoding: .utf8)
        case .txt:
            try cues.map(\.2).joined(separator: "\n").write(to: destination, atomically: true, encoding: .utf8)
        case .lrc:
            let body = cues.map { cue in
                let lyric = cue.2.replacingOccurrences(of: "\n", with: " ")
                return "\(formatLRC(cue.0))\(lyric)"
            }.joined(separator: "\n")
            try (body + "\n").write(to: destination, atomically: true, encoding: .utf8)
        case .sbv:
            let body = cues.map { cue in
                "\(formatSBV(cue.0)),\(formatSBV(cue.1))\n\(cue.2.replacingOccurrences(of: "\n", with: " "))\n"
            }.joined(separator: "\n")
            try body.write(to: destination, atomically: true, encoding: .utf8)
        case .smi:
            let body = cues.map { cue in
                "<SYNC Start=\(Int((cue.0 * 1000).rounded()))><P>\(cue.2.replacingOccurrences(of: "<", with: "&lt;"))"
            }.joined(separator: "\n")
            try "<SAMI><BODY>\n\(body)\n</BODY></SAMI>\n".write(to: destination, atomically: true, encoding: .utf8)
        default:
            try text.write(to: destination, atomically: true, encoding: .utf8)
        }
    }

    private static func parseCues(_ text: String) -> [(Double, Double, String)] {
        var cues: [(Double, Double, String)] = []
        let pattern = #"(\d{1,2}:\d{2}:\d{2}[.,]\d{3})\s+-->\s+(\d{1,2}:\d{2}:\d{2}[.,]\d{3})"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        let matches = regex?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []
        for (index, match) in matches.enumerated() {
            let start = parseClock(ns.substring(with: match.range(at: 1)))
            let end = parseClock(ns.substring(with: match.range(at: 2)))
            let from = match.range.location + match.range.length
            let to = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: from, length: max(0, to - from)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            cues.append((start, end, body))
        }
        return cues
    }

    private static func parseSBV(_ text: String) -> [(Double, Double, String)] {
        var cues: [(Double, Double, String)] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(whereSeparator: \.isNewline).map(String.init)
            guard let header = lines.first else { continue }
            let parts = header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let start = parseSBVTime(parts[0]), let end = parseSBVTime(parts[1]) else { continue }
            let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { cues.append((start, end, body)) }
        }
        return cues
    }

    private static func parseSBVTime(_ raw: String) -> Double? {
        let pieces = raw.split(separator: ".")
        let clock = pieces[0].split(separator: ":")
        guard clock.count == 3, let hours = Double(clock[0]), let minutes = Double(clock[1]), let seconds = Double(clock[2]) else { return nil }
        let fraction = pieces.count > 1 ? (Double(pieces[1]) ?? 0) / pow(10, Double(pieces[1].count)) : 0
        return hours * 3600 + minutes * 60 + seconds + fraction
    }

    private static func formatSBV(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let whole = Int(total) % 60
        let millis = Int((total - floor(total)) * 1000)
        return String(format: "%d:%02d:%02d.%03d", hours, minutes, whole, millis)
    }

    private static func parseSAMI(_ text: String) -> [(Double, Double, String)] {
        let pattern = #"<sync\b[^>]*start\s*=\s*["']?(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }
        return matches.enumerated().compactMap { index, match in
            let start = Double(ns.substring(with: match.range(at: 1))) ?? 0
            let from = match.range.location + match.range.length
            let to = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            var body = ns.substring(with: NSRange(location: from, length: max(0, to - from)))
            body = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            body = body.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lt;", with: "<")
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let end = index + 1 < matches.count ? (Double(ns.substring(with: matches[index + 1].range(at: 1))) ?? start + 2000) : start + 2000
            return body.isEmpty ? nil : (start / 1000, end / 1000, body)
        }
    }

    private static func parseLRC(_ text: String) -> [(Double, Double, String)] {
        struct Line { var time: Double; var text: String }
        var lines: [Line] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            var times: [Double] = []
            var index = line.startIndex
            while index < line.endIndex, line[index] == "[" {
                guard let close = line[index...].firstIndex(of: "]") else { break }
                let inside = String(line[line.index(after: index)..<close])
                guard let time = parseLRCTime(inside) else { break }
                times.append(time)
                index = line.index(after: close)
            }
            let lyric = line[index...].trimmingCharacters(in: .whitespaces)
            guard !lyric.isEmpty else { continue }
            for time in times { lines.append(Line(time: time, text: String(lyric))) }
        }
        lines.sort { $0.time < $1.time }
        return lines.enumerated().map { offset, line in
            let end = offset + 1 < lines.count ? lines[offset + 1].time : line.time + 2
            return (line.time, max(end, line.time + 0.2), line.text)
        }
    }

    private static func parseLRCTime(_ raw: String) -> Double? {
        let parts = raw.split { $0 == ":" || $0 == "." }
        guard parts.count >= 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
        var fraction = 0.0
        if parts.count >= 3, let piece = Double(parts[2]) {
            fraction = piece / pow(10, Double(parts[2].count))
        }
        return minutes * 60 + seconds + fraction
    }

    private static func formatLRC(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let whole = Int(total) % 60
        let centiseconds = Int((total - floor(total)) * 100)
        return String(format: "[%02d:%02d.%02d]", minutes, whole, centiseconds)
    }

    private static func parseClock(_ raw: String) -> Double {
        let cleaned = raw.replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return 0 }
        return h * 3600 + m * 60 + s
    }

    private static func formatSRT(_ seconds: TimeInterval) -> String { format(seconds, fraction: ",") }
    private static func formatVTT(_ seconds: TimeInterval) -> String { format(seconds, fraction: ".") }

    private static func format(_ seconds: TimeInterval, fraction: String) -> String {
        let total = max(0, seconds)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        let ms = Int((total - floor(total)) * 1000)
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, fraction, ms)
    }
}

public struct MiscConverter: Converter {
    public init() {}

    public func convert(from source: URL, detected: FormatID, spec: OutputSpec, to destination: URL, context: ConversionContext) throws {
        if subtitleFormats.contains(detected) && subtitleFormats.contains(spec.format) || spec.format == .txt && subtitleFormats.contains(detected) {
            try SubtitleIO.convert(from: source, to: spec.format, destination: destination)
            return
        }
        if (detected == .der && spec.format == .pem) || (detected == .pem && spec.format == .der) {
            try convertCertificate(from: source, to: spec.format, destination: destination)
            return
        }
        throw RenvertError.unsupportedConversion(from: detected.rawValue, to: spec.format.rawValue)
    }

    private func convertCertificate(from source: URL, to format: FormatID, destination: URL) throws {
        let data = try Data(contentsOf: source)
        if format == .pem {
            let b64 = data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            let pem = "-----BEGIN CERTIFICATE-----\n\(b64)\n-----END CERTIFICATE-----\n"
            try pem.write(to: destination, atomically: true, encoding: .utf8)
        } else {
            let text = String(data: data, encoding: .utf8) ?? ""
            let body = text
                .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
                .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
                .filter { !$0.isWhitespace }
            guard let der = Data(base64Encoded: body) else {
                throw RenvertError.invalidInput(L("PEM body is not valid Base64."))
            }
            try der.write(to: destination)
        }
    }
}

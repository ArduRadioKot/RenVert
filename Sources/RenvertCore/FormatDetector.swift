import Foundation
import UniformTypeIdentifiers

public struct DetectedFormat: Equatable, Sendable {
    public var id: FormatID
    public var confidence: Double
    public var via: String

    public init(id: FormatID, confidence: Double, via: String) {
        self.id = id
        self.confidence = confidence
        self.via = via
    }
}

public enum FormatDetector {
    public static func detect(at url: URL) throws -> DetectedFormat {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw RenvertError.fileNotFound(url.path)
        }
        if isDir.boolValue {
            return DetectedFormat(id: .folder, confidence: 1, via: "directory")
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 128) ?? Data()

        if let magic = matchMagic(prefix) {
            if magic == .zip || magic == .docx {
                if let container = inspectZipContainer(url) {
                    return DetectedFormat(id: container, confidence: 0.95, via: "zip-container")
                }
                return DetectedFormat(id: .zip, confidence: 0.7, via: "zip-magic")
            }
            return DetectedFormat(id: magic, confidence: 0.95, via: "magic")
        }

        if let ftyp = matchFtyp(prefix) {
            return DetectedFormat(id: ftyp, confidence: 0.9, via: "ftyp")
        }

        if let text = sniffText(url, prefix: prefix) {
            return text
        }

        if let ut = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           let mapped = mapUTType(ut) {
            return DetectedFormat(id: mapped, confidence: 0.4, via: "uttype")
        }

        throw RenvertError.invalidInput(String(localized: "Could not detect a known format."))
    }

    public static func matches(_ url: URL, expected: FormatID) -> Bool {
        (try? detect(at: url).id) == expected
    }

    private static func matchMagic(_ data: Data) -> FormatID? {
        let bytes = [UInt8](data)
        func has(_ sig: [UInt8], at offset: Int = 0) -> Bool {
            guard bytes.count >= offset + sig.count else { return false }
            return Array(bytes[offset..<(offset + sig.count)]) == sig
        }
        if has([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if has([0x89, 0x50, 0x4E, 0x47]) { return .png }
        if has([0x47, 0x49, 0x46, 0x38]) { return .gif }
        if has([0x42, 0x4D]) { return .bmp }
        if has([0x49, 0x49, 0x2A, 0x00]) || has([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if has([0x25, 0x50, 0x44, 0x46]) { return .pdf }
        if has([0x50, 0x4B, 0x03, 0x04]) || has([0x50, 0x4B, 0x05, 0x06]) { return .zip }
        if has([0x52, 0x49, 0x46, 0x46]) && data.count >= 12 {
            let four = String(bytes: data[8..<12], encoding: .ascii)
            if four == "WAVE" { return .wav }
            if four == "WEBP" { return .webp }
            if four == "AVI " { return .avi }
        }
        if has([0x66, 0x4C, 0x61, 0x43]) { return .flac }
        if has([0x4F, 0x67, 0x67, 0x53]) { return .ogg }
        if has([0x1A, 0x45, 0xDF, 0xA3]) { return .mkv }
        if has([0x49, 0x44, 0x33]) || (bytes.count >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) {
            return .mp3
        }
        if has([0x7B, 0x5C, 0x72, 0x74, 0x66]) { return .rtf }
        if has([0x1F, 0x8B]) { return .gzip }
        if has([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZ }
        if has([0x00, 0x61, 0x73, 0x6D]) { return nil }
        if data.count >= 2 {
            let b0 = bytes[0]
            if b0 == 0x30 && bytes.count > 1 && bytes[1] == 0x82 { return .der }
        }
        if let ascii = String(data: data.prefix(40), encoding: .ascii),
           ascii.contains("-----BEGIN") {
            return .pem
        }
        return nil
    }

    private static func matchFtyp(_ data: Data) -> FormatID? {
        guard data.count >= 12 else { return nil }
        let box = String(bytes: data[4..<8], encoding: .ascii)
        guard box == "ftyp" else { return nil }
        let brand = String(bytes: data[8..<12], encoding: .ascii) ?? ""
        switch brand {
        case "heic", "heix", "hevc", "mif1", "msf1": return .heic
        case "avif", "avis": return .avif
        case "qt  ": return .mov
        case "M4A ", "M4B ": return .m4a
        case "3gp4", "3gp5", "3gp6": return .threeGP
        default:
            if ["isom", "iso2", "mp41", "mp42", "dash"].contains(brand) { return .mp4 }
            return .mp4
        }
    }

    private static func inspectZipContainer(_ url: URL) -> FormatID? {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("renvert-zip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let result = ProcessRunner.run(
                executable: "/usr/bin/unzip",
                arguments: ["-Z", "-1", url.path]
            )
            guard result.exitCode == 0 else { return .zip }
            let names = result.stdout.split(separator: "\n").map(String.init)
            if names.contains("word/document.xml") { return .docx }
            if names.contains("xl/workbook.xml") { return .xlsx }
            if names.contains("ppt/presentation.xml") { return .pptx }
            if names.contains(where: { $0 == "mimetype" }) {
                if let mime = zipStoredFile(url, named: "mimetype"),
                   mime.contains("epub") { return .epub }
            }
            if names.contains("META-INF/container.xml") { return .epub }
            if names.contains("content.opf") { return .epub }
        } catch {
            return .zip
        }
        return .zip
    }

    private static func zipStoredFile(_ url: URL, named: String) -> String? {
        let result = ProcessRunner.run(
            executable: "/usr/bin/unzip",
            arguments: ["-p", url.path, named]
        )
        guard result.exitCode == 0 else { return nil }
        return result.stdout
    }

    private static func sniffText(_ url: URL, prefix: Data) -> DetectedFormat? {
        guard let text = decodeTextSample(prefix) ?? (try? String(contentsOf: url, encoding: .utf8).prefix(4000)).map(String.init) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil {
                return DetectedFormat(id: .json, confidence: 0.85, via: "json")
            }
        }
        if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<") {
            if trimmed.contains("<plist") { return DetectedFormat(id: .plist, confidence: 0.85, via: "plist") }
            return DetectedFormat(id: .xml, confidence: 0.6, via: "xml")
        }
        if trimmed.hasPrefix("---") || yamlLooksLike(trimmed) {
            return DetectedFormat(id: .yaml, confidence: 0.55, via: "yaml")
        }
        if tomlLooksLike(trimmed) {
            return DetectedFormat(id: .toml, confidence: 0.5, via: "toml")
        }
        if trimmed.contains(" --> ") || trimmed.contains("WEBVTT") {
            return DetectedFormat(id: trimmed.hasPrefix("WEBVTT") ? .vtt : .srt, confidence: 0.7, via: "subtitle")
        }
        return DetectedFormat(id: .txt, confidence: 0.3, via: "text")
    }

    private static func decodeTextSample(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8), utf8.utf8.allSatisfy({ $0 >= 9 || $0 == 10 || $0 == 13 }) {
            return utf8
        }
        return String(data: data, encoding: .utf16)
    }

    private static func yamlLooksLike(_ text: String) -> Bool {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.contains(": ") && !line.contains("{")
    }

    private static func tomlLooksLike(_ text: String) -> Bool {
        text.contains(" = ") && (text.contains("[") || text.contains("\""))
    }

    private static func mapUTType(_ type: UTType) -> FormatID? {
        if type.conforms(to: .jpeg) { return .jpeg }
        if type.conforms(to: .png) { return .png }
        if type.conforms(to: .heic) { return .heic }
        if type.conforms(to: .gif) { return .gif }
        if type.identifier.contains("webp") { return .webp }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .mp3) { return .mp3 }
        if type.conforms(to: .wav) { return .wav }
        if type.conforms(to: .mpeg4Movie) { return .mp4 }
        if type.conforms(to: .quickTimeMovie) { return .mov }
        if type.conforms(to: .json) { return .json }
        return nil
    }
}

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
        if url.pathExtension.lowercased() == "clr" {
            return DetectedFormat(id: .clr, confidence: 0.75, via: "extension")
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 8192) ?? Data()

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

        throw RenvertError.invalidInput(L("Could not detect a known format."))
    }

    /// Detects by content, then lets the name the file had before the rename settle what the
    /// bytes cannot: text formats that look alike, and formats that have no signature at all.
    public static func detect(at url: URL, originalFilename: String) throws -> DetectedFormat {
        let hinted = FormatRegistry.resolve(URL(fileURLWithPath: originalFilename).pathExtension)
        do {
            let detected = refine(try detect(at: url), originalFilename: originalFilename)
            if hinted == .svgz, detected.id == .gzip {
                return DetectedFormat(id: .svgz, confidence: 0.8, via: "original-extension")
            }
            // Most camera RAW files are TIFF containers, so the bytes alone say "TIFF".
            if let hinted, rawImageFormats.contains(hinted), detected.id == .tiff {
                return DetectedFormat(id: hinted, confidence: 0.8, via: "original-extension")
            }
            if let hinted, extensionOnlyFormats.contains(hinted), detected.id != hinted,
               detected.confidence <= 0.6 {
                return DetectedFormat(id: hinted, confidence: 0.5, via: "original-extension")
            }
            return detected
        } catch {
            if let hinted, extensionOnlyFormats.contains(hinted) {
                return DetectedFormat(id: hinted, confidence: 0.5, via: "original-extension")
            }
            throw error
        }
    }

    public static func matches(_ url: URL, expected: FormatID) -> Bool {
        (try? detect(at: url).id) == expected
    }

    /// Text formats share the same bytes. When the sniffer only sees "plain text" or "XML",
    /// the name the file had before the rename is the format the user actually meant.
    public static func refine(_ detected: DetectedFormat, originalFilename: String) -> DetectedFormat {
        let ext = URL(fileURLWithPath: originalFilename).pathExtension
        guard let hinted = FormatRegistry.resolve(ext), hinted != detected.id else { return detected }
        if hinted == .webloc, detected.id == .plist || detected.id == .xml || detected.id == .txt {
            return DetectedFormat(id: .webloc, confidence: 0.85, via: "original-extension")
        }
        guard detected.confidence <= 0.6 || detected.id == .txt || detected.id == .xml else { return detected }
        let textish: Set<FormatID> = [
            .txt, .markdown, .html, .xml, .csv, .tsv, .yaml, .toml, .json, .jsonl,
            .srt, .vtt, .lrc, .sbv, .smi, .rtf, .adoc, .rst, .org, .plist, .gpx, .kml, .geojson, .tcx,
            .nmea, .igc, .vcf, .ics, .eml, .opml, .b64, .ini, .env, .properties, .strings, .url, .rss, .atom, .m3u,
            .cue, .bib, .ldif, .gpl, .hex, .css, .clr
        ]
        guard textish.contains(hinted), textish.contains(detected.id) else { return detected }
        if detected.via == "json" || detected.via == "plist" { return detected }
        return DetectedFormat(id: hinted, confidence: max(detected.confidence, 0.75), via: "original-extension")
    }

    private static func matchMagic(_ data: Data) -> FormatID? {
        let bytes = [UInt8](data)
        func has(_ sig: [UInt8], at offset: Int = 0) -> Bool {
            guard bytes.count >= offset + sig.count else { return false }
            return Array(bytes[offset..<(offset + sig.count)]) == sig
        }
        if has([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if has([0x89, 0x50, 0x4E, 0x47]) { return .png }
        if has([0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20]) { return .jp2 }
        if has([0x76, 0x2F, 0x31, 0x01]) { return .exr }
        if has([0x13, 0xAB, 0xA1, 0x5C]) { return .astc }
        if has([0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66, 0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33]) { return .sqlite }
        if has([0x00, 0x01, 0x00, 0x00]) { return .ttf }
        if has([0x4F, 0x54, 0x54, 0x4F]) { return .otf }
        if has([0x47, 0x49, 0x46, 0x38]) { return .gif }
        if has([0x42, 0x4D]) { return .bmp }
        // RAW containers that borrow the TIFF header come first.
        if has([0x49, 0x49, 0x52, 0x4F]) || has([0x49, 0x49, 0x52, 0x53]) || has([0x4D, 0x4D, 0x4F, 0x52]) { return .orf }
        if has([0x49, 0x49, 0x55, 0x00]) { return .rw2 }
        if has(Array("FUJIFILMCCD-RAW".utf8)) { return .raf }
        if has([0x49, 0x49, 0x2A, 0x00]) || has([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if has([0x38, 0x42, 0x50, 0x53]) { return .psd }
        if has([0xFF, 0x0A]) || has([0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20]) { return .jxl }
        if has([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) { return .doc }
        if has([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return .cbr }
        if has([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .txz }
        if has([0x42, 0x5A, 0x68]) { return .tbz2 }
        if has(Array("ustar".utf8), at: 257) { return .tar }
        if has(Array("PXR-USDC".utf8)) { return .usdc }
        if has(Array("#usda".utf8)) { return .usda }
        // Model I/O writes "ply " with a trailing space before the line break.
        if has(Array("ply".utf8)), bytes.count > 3, [0x0A, 0x0D, 0x20].contains(bytes[3]) { return .ply }
        if has([0x25, 0x50, 0x44, 0x46]) { return .pdf }
        if has([0x50, 0x4B, 0x03, 0x04]) || has([0x50, 0x4B, 0x05, 0x06]) { return .zip }
        if has([0x52, 0x49, 0x46, 0x46]) && data.count >= 12 {
            let four = String(bytes: data[8..<12], encoding: .ascii)
            if four == "WAVE" { return .wav }
            if four == "WEBP" { return .webp }
            if four == "AVI " { return .avi }
        }
        if has([0x66, 0x4C, 0x61, 0x43]) { return .flac }
        if has([0x63, 0x61, 0x66, 0x66]) { return .caf }
        if has([0x46, 0x4F, 0x52, 0x4D]) && data.count >= 12 {
            let form = String(bytes: data[8..<12], encoding: .ascii)
            if form == "AIFF" || form == "AIFC" { return .aiff }
        }
        if has([0x69, 0x63, 0x6E, 0x73]) { return .icns }
        if has([0x00, 0x00, 0x01, 0x00]) { return .ico }
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
        // Netpbm is "P3\n" or "P6 32 32". A regex on the newline never matches here.
        if bytes.count >= 3, bytes[0] == 0x50, (0x31...0x36).contains(bytes[1]),
           bytes[2] == 0x0A || bytes[2] == 0x0D || bytes[2] == 0x20 || bytes[2] == 0x09 {
            return .ppm
        }
        return nil
    }

    private static func matchFtyp(_ data: Data) -> FormatID? {
        guard data.count >= 12 else { return nil }
        let box = String(bytes: data[4..<8], encoding: .ascii)
        guard box == "ftyp" else { return nil }
        let brand = String(bytes: data[8..<12], encoding: .ascii) ?? ""
        switch brand {
        case "heic", "heix", "hevc", "heif", "heis", "heim", "hevm", "hevs", "hevx", "mif1", "msf1": return .heic
        case "avif", "avis": return .avif
        case "qt  ": return .mov
        case "M4A ", "M4B ": return .m4a
        case "3gp4", "3gp5", "3gp6": return .threeGP
        case "crx ": return .cr3
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
            if names.contains(where: { $0.lowercased().hasSuffix(".usdc") || $0.lowercased().hasSuffix(".usda") }) { return .usdz }
            if names.contains(where: { $0 == "mimetype" }) {
                if let mime = zipStoredFile(url, named: "mimetype") {
                    if mime.contains("epub") { return .epub }
                    if mime.contains("opendocument.text") { return .odt }
                }
            }
            if names.contains("META-INF/container.xml") { return .epub }
            if names.contains("content.opf") { return .epub }
            let files = names.filter { !$0.hasSuffix("/") && !$0.hasPrefix("__MACOSX") }
            let hasCheckpoint = files.contains { $0 == "data.pkl" || $0.hasSuffix("/data.pkl") }
            let hasByteOrder = files.contains { $0 == "byteorder" || $0.hasSuffix("/byteorder") }
            if hasCheckpoint && hasByteOrder { return .pt }
            if !files.isEmpty, files.allSatisfy({ $0.lowercased().hasSuffix(".npy") }) { return .npz }
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
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\u{feff}") { trimmed.removeFirst() }
        if trimmed.uppercased().hasPrefix("BEGIN:VCARD") {
            return DetectedFormat(id: .vcf, confidence: 0.9, via: "vcard")
        }
        if trimmed.uppercased().contains("BEGIN:VCALENDAR") || trimmed.uppercased().contains("BEGIN:VEVENT") {
            return DetectedFormat(id: .ics, confidence: 0.85, via: "ics")
        }
        if looksLikeEmail(trimmed) {
            return DetectedFormat(id: .eml, confidence: 0.8, via: "email")
        }
        if looksLikeStrings(trimmed) {
            return DetectedFormat(id: .strings, confidence: 0.85, via: "strings")
        }
        if trimmed.hasPrefix("#EXTM3U") {
            return DetectedFormat(id: .m3u, confidence: 0.9, via: "m3u")
        }
        if looksLikeLRC(trimmed) {
            return DetectedFormat(id: .lrc, confidence: 0.8, via: "lrc")
        }
        if trimmed.hasPrefix("GIMP Palette") {
            return DetectedFormat(id: .gpl, confidence: 0.95, via: "gpl")
        }
        if looksLikeLDIF(trimmed) {
            return DetectedFormat(id: .ldif, confidence: 0.85, via: "ldif")
        }
        if looksLikeBib(trimmed) {
            return DetectedFormat(id: .bib, confidence: 0.85, via: "bib")
        }
        if looksLikeCue(trimmed) {
            return DetectedFormat(id: .cue, confidence: 0.85, via: "cue")
        }
        if looksLikeNMEA(trimmed) {
            return DetectedFormat(id: .nmea, confidence: 0.9, via: "nmea")
        }
        if looksLikeIGC(trimmed) {
            return DetectedFormat(id: .igc, confidence: 0.9, via: "igc")
        }
        if looksLikeSBV(trimmed) {
            return DetectedFormat(id: .sbv, confidence: 0.85, via: "sbv")
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) {
                if looksLikeGeoJSON(object) {
                    return DetectedFormat(id: .geojson, confidence: 0.9, via: "geojson")
                }
                return DetectedFormat(id: .json, confidence: 0.85, via: "json")
            }
        }
        if looksLikeJSONL(trimmed) {
            return DetectedFormat(id: .jsonl, confidence: 0.8, via: "jsonl")
        }
        if looksLikeHTML(trimmed) {
            return DetectedFormat(id: .html, confidence: 0.8, via: "html")
        }
        if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<") {
            if trimmed.contains("<plist") { return DetectedFormat(id: .plist, confidence: 0.85, via: "plist") }
            if trimmed.contains("<svg") { return DetectedFormat(id: .svg, confidence: 0.85, via: "svg") }
            let lower = trimmed.lowercased()
            if lower.contains("<gpx") { return DetectedFormat(id: .gpx, confidence: 0.9, via: "gpx") }
            if lower.contains("<kml") { return DetectedFormat(id: .kml, confidence: 0.9, via: "kml") }
            if lower.contains("<opml") { return DetectedFormat(id: .opml, confidence: 0.9, via: "opml") }
            if lower.contains("<rss") { return DetectedFormat(id: .rss, confidence: 0.9, via: "rss") }
            if lower.contains("<feed") { return DetectedFormat(id: .atom, confidence: 0.85, via: "atom") }
            if lower.contains("<trainingcenterdatabase") || lower.contains("<trackpoint") {
                return DetectedFormat(id: .tcx, confidence: 0.9, via: "tcx")
            }
            if lower.contains("<sami") || (lower.contains("<sync") && lower.contains("start")) {
                return DetectedFormat(id: .smi, confidence: 0.85, via: "sami")
            }
            return DetectedFormat(id: .xml, confidence: 0.6, via: "xml")
        }
        if trimmed.lowercased().contains("[internetshortcut]") {
            return DetectedFormat(id: .url, confidence: 0.9, via: "url")
        }
        if looksLikeINI(trimmed) {
            return DetectedFormat(id: .ini, confidence: 0.75, via: "ini")
        }
        if looksLikeEnv(trimmed) {
            return DetectedFormat(id: .env, confidence: 0.7, via: "env")
        }
        if looksLikeProperties(trimmed) {
            return DetectedFormat(id: .properties, confidence: 0.6, via: "properties")
        }
        if looksLikeHex(trimmed) {
            return DetectedFormat(id: .hex, confidence: 0.8, via: "hex")
        }
        if looksLikeCSS(trimmed) {
            return DetectedFormat(id: .css, confidence: 0.75, via: "css")
        }
        let structured = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        if !structured && looksLikeDelimited(trimmed, delimiter: ",") {
            return DetectedFormat(id: .csv, confidence: 0.72, via: "csv")
        }
        if !structured && looksLikeDelimited(trimmed, delimiter: ";") {
            return DetectedFormat(id: .csv, confidence: 0.7, via: "csv")
        }
        if !structured && looksLikeDelimited(trimmed, delimiter: "\t") {
            return DetectedFormat(id: .tsv, confidence: 0.72, via: "tsv")
        }
        if trimmed.contains(" --> ") || trimmed.contains("WEBVTT") {
            return DetectedFormat(id: trimmed.hasPrefix("WEBVTT") ? .vtt : .srt, confidence: 0.7, via: "subtitle")
        }
        if trimmed.hasPrefix("---") || yamlLooksLike(trimmed) {
            return DetectedFormat(id: .yaml, confidence: 0.55, via: "yaml")
        }
        if tomlLooksLike(trimmed) {
            return DetectedFormat(id: .toml, confidence: 0.5, via: "toml")
        }
        if looksLikeMarkdown(trimmed) {
            return DetectedFormat(id: .markdown, confidence: 0.6, via: "markdown")
        }
        return DetectedFormat(id: .txt, confidence: 0.3, via: "text")
    }

    private static func looksLikeEmail(_ text: String) -> Bool {
        let head = text.prefix(800)
        guard let blank = head.range(of: "\n\n") ?? head.range(of: "\r\n\r\n") else { return false }
        let headers = head[..<blank.lowerBound].lowercased()
        let known = ["from:", "subject:", "mime-version:", "received:", "return-path:", "to:", "date:"]
        return known.filter { headers.contains($0) }.count >= 2
    }

    private static func looksLikeGeoJSON(_ object: Any) -> Bool {
        guard let record = object as? [String: Any] else { return false }
        let type = (record["type"] as? String)?.lowercased() ?? ""
        let geo = ["featurecollection", "feature", "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon", "geometrycollection"]
        if geo.contains(type) && (record["coordinates"] != nil || record["features"] != nil || record["geometry"] != nil) {
            return true
        }
        return record["features"] is [Any]
    }

    private static func looksLikeStrings(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let hits = lines.filter { $0.hasPrefix("\"") && $0.contains("=") && $0.hasSuffix(";") }
        return !hits.isEmpty && hits.count * 2 >= lines.count
    }

    private static func looksLikeLRC(_ text: String) -> Bool {
        text.range(of: #"\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\]"#, options: .regularExpression) != nil
    }

    private static func looksLikeINI(_ text: String) -> Bool {
        if text.contains("[[") { return false }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let hasSection = lines.contains { $0.hasPrefix("[") && $0.hasSuffix("]") }
        let hasAssignment = lines.contains { $0.contains("=") && !$0.hasPrefix("[") && !$0.contains("\"") }
        return hasSection && hasAssignment
    }

    private static func looksLikeEnv(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty, !text.contains("[") else { return false }
        return lines.allSatisfy { line in
            var pair = line
            if pair.hasPrefix("export ") { pair.removeFirst("export ".count) }
            guard let eq = pair.firstIndex(of: "=") else { return false }
            let key = pair[..<eq].trimmingCharacters(in: .whitespaces)
            return key.range(of: #"^[A-Z_][A-Z0-9_]*$"#, options: .regularExpression) != nil
        }
    }

    private static func looksLikeProperties(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("!") }
        guard !lines.isEmpty, !text.contains("[") else { return false }
        guard lines.allSatisfy({ $0.contains("=") }) else { return false }
        return lines.contains { line in
            line.split(separator: "=").first?.contains(".") == true
        }
    }

    private static func looksLikeLDIF(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return lines.contains { $0.hasPrefix("dn:") }
    }

    private static func looksLikeBib(_ text: String) -> Bool {
        text.range(of: #"@[A-Za-z]+\{"#, options: .regularExpression) != nil
    }

    private static func looksLikeCue(_ text: String) -> Bool {
        let upper = text.uppercased()
        return upper.contains("FILE ") && upper.contains("TRACK ") && upper.contains("INDEX ")
    }

    private static func looksLikeNMEA(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("$") && (trimmed.contains("GGA") || trimmed.contains("RMC") || trimmed.contains("GLL"))
        }
    }

    private static func looksLikeIGC(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let fixes = lines.contains { $0.count >= 35 && $0.hasPrefix("B") }
        let header = lines.contains { $0.hasPrefix("A") || $0.hasPrefix("HF") }
        return fixes && header
    }

    private static func looksLikeSBV(_ text: String) -> Bool {
        text.range(of: #"\d+:\d{2}:\d{2}\.\d{3},\d+:\d{2}:\d{2}\.\d{3}"#, options: .regularExpression) != nil
    }

    private static func looksLikeHex(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 2 else { return false }
        return lines.allSatisfy { $0.range(of: #"^#?[0-9A-Fa-f]{6}([ \t].*)?$"#, options: .regularExpression) != nil }
    }

    private static func looksLikeCSS(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains(":root") && lower.contains("--") && lower.contains("#")
    }

    private static func looksLikeJSONL(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return false }
        return lines.prefix(20).allSatisfy { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil
        }
    }

    private static func looksLikeHTML(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") { return true }
        return lower.contains("<html") && (lower.contains("<body") || lower.contains("<head"))
    }

    private static func looksLikeDelimited(_ text: String, delimiter: Character) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return false }
        if delimiter == "," {
            let prose = lines.filter { $0.contains(", ") }.count
            if prose * 2 > lines.count { return false }
        }
        let rows = lines.prefix(20).map { splitDelimited($0, delimiter: delimiter) }
        guard let columns = rows.first?.count, columns >= 2 else { return false }
        guard rows.allSatisfy({ $0.count == columns }) else { return false }
        let fields = rows.flatMap { $0 }
        guard fields.allSatisfy({ $0.count <= 80 }) else { return false }
        let numeric = fields.contains { Double($0.trimmingCharacters(in: .whitespaces)) != nil }
        return columns >= 3 || numeric || fields.allSatisfy { !$0.contains(" ") }
    }

    private static func splitDelimited(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        for char in line {
            if char == "\"" {
                quoted.toggle()
            } else if char == delimiter && !quoted {
                fields.append(field)
                field = ""
            } else {
                field.append(char)
            }
        }
        fields.append(field)
        return fields
    }

    private static func looksLikeMarkdown(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).prefix(40).map(String.init)
        let hits = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("# ") || trimmed.hasPrefix("##") || trimmed.hasPrefix("- ")
                || trimmed.hasPrefix("* ") || trimmed.contains("](")
        }
        return hits.count >= 2
    }

    private static func decodeTextSample(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8), !utf8.contains("\u{0}") {
            return utf8
        }
        if data.count > 4, let utf8 = String(data: data.dropLast(3), encoding: .utf8), !utf8.contains("\u{0}") {
            return utf8
        }
        if let utf16 = String(data: data, encoding: .utf16), data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return utf16
        }
        // Legacy single-byte text such as Windows-1251: printable bytes only, no binary noise.
        let binary = data.contains { $0 < 0x09 || ($0 > 0x0D && $0 < 0x20 && $0 != 0x1B) }
        return binary || data.isEmpty ? nil : DelimitedText.decode(data)
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

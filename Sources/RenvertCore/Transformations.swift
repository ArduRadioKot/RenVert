import Foundation

public struct TimeValue: Equatable, Sendable {
    public var seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }

    public static func parse(_ raw: String) throws -> TimeValue {
        if raw.contains(":") {
            let parts = raw.split(separator: ":").map(String.init)
            guard !parts.isEmpty, parts.count <= 3 else { throw RenvertError.invalidModifier(raw) }
            let nums = try parts.map { token -> Double in
                guard let value = Double(token) else { throw RenvertError.invalidModifier(raw) }
                return value
            }
            var total = 0.0
            for num in nums { total = total * 60 + num }
            return TimeValue(seconds: total)
        }
        var remaining = raw.lowercased()
        var hours = 0.0, minutes = 0.0, seconds = 0.0
        if let range = remaining.range(of: "h") {
            guard let parsed = Double(remaining[..<range.lowerBound]) else { throw RenvertError.invalidModifier(raw) }
            hours = parsed
            remaining = String(remaining[range.upperBound...])
        }
        if let range = remaining.range(of: "m") {
            guard let parsed = Double(remaining[..<range.lowerBound]) else { throw RenvertError.invalidModifier(raw) }
            minutes = parsed
            remaining = String(remaining[range.upperBound...])
        }
        if remaining.hasSuffix("s") { remaining.removeLast() }
        if !remaining.isEmpty {
            guard let value = Double(remaining) else { throw RenvertError.invalidModifier(raw) }
            seconds = value
        }
        return TimeValue(seconds: hours * 3600 + minutes * 60 + seconds)
    }
}

public enum PageSelection: Equatable, Sendable {
    case single(Int)
    case closed(ClosedRange<Int>)
    case from(Int)
    case through(Int)
}

public enum AudioCodecChoice: String, Equatable, Sendable {
    case aac, alac, pcm, vorbis, opus, flac
}

public enum VideoCodecChoice: String, Equatable, Sendable {
    case vp9, av1, prores
}

public enum Modifier: Equatable, Sendable {
    case quality(Int)
    case min
    case maxBytes(Int64)
    case noMeta
    case width(Int)
    case height(Int)
    case maxHeight(Int)
    case crop(width: Int, height: Int)
    case smartCrop(width: Int, height: Int)
    case trim(start: TimeValue?, end: TimeValue?)
    case at(TimeValue)
    case speed(Double)
    case mute
    case normalize
    case mono
    case reverse
    case rotate(Int)
    case flipH
    case flipV
    case noBackground
    case lossless
    case bitrate(Int)
    case dpi(Int)
    case pages(PageSelection)
    case audioCodec(AudioCodecChoice)
    case videoCodec(VideoCodecChoice)
    case fps(Int)
    case gray
    case loop(Int)
    case ocr(language: String?)
    case transcribe
    case language(String)

    public var shortLabel: String {
        switch self {
        case .quality(let value): return "q\(value)"
        case .min: return "min"
        case .maxBytes(let bytes):
            if bytes % 1_000_000_000 == 0 { return "\(bytes / 1_000_000_000)gb" }
            if bytes % 1_000_000 == 0 { return "\(bytes / 1_000_000)mb" }
            return "\(bytes / 1_000)kb"
        case .noMeta: return "nometa"
        case .width(let value): return "w\(value)"
        case .height(let value): return "h\(value)"
        case .maxHeight(let value): return "\(value)p"
        case .crop(let w, let h): return "crop\(w)x\(h)"
        case .smartCrop(let w, let h): return "smartcrop\(w)x\(h)"
        case .trim: return "trim"
        case .at: return "at"
        case .speed(let value): return "speed\(value.rounded() == value ? String(Int(value)) : String(value))x"
        case .mute: return "mute"
        case .normalize: return "normalize"
        case .mono: return "mono"
        case .reverse: return "reverse"
        case .rotate(let value): return "rotate\(value)"
        case .flipH: return "fliph"
        case .flipV: return "flipv"
        case .noBackground: return "nobg"
        case .lossless: return "lossless"
        case .bitrate(let value): return "bitrate\(value)"
        case .dpi(let value): return "dpi\(value)"
        case .pages: return "page"
        case .audioCodec(let codec): return codec.rawValue
        case .videoCodec(let codec): return codec.rawValue
        case .fps(let value): return "fps\(value)"
        case .gray: return "gray"
        case .loop(let value): return "loop\(value)"
        case .ocr: return "ocr"
        case .transcribe: return "transcribe"
        case .language(let code): return "lang_\(code)"
        }
    }

    public var transformsContent: Bool {
        switch self {
        case .noMeta: return false
        default: return true
        }
    }
}

public struct OutputSpec: Equatable, Sendable {
    public var format: FormatID
    public var modifiers: [Modifier]
    public var openSettings: Bool

    public init(format: FormatID, modifiers: [Modifier] = [], openSettings: Bool = false) {
        self.format = format
        self.modifiers = modifiers
        self.openSettings = openSettings
    }

    public var isIdentityCandidate: Bool {
        modifiers.filter(\.transformsContent).isEmpty
    }

    public func quality() -> Int? {
        for modifier in modifiers { if case .quality(let value) = modifier { return value } }
        return nil
    }

    public func maxBytes() -> Int64? {
        for modifier in modifiers { if case .maxBytes(let value) = modifier { return value } }
        return nil
    }

    public func pages() -> PageSelection? {
        for modifier in modifiers { if case .pages(let value) = modifier { return value } }
        return nil
    }

    public func dpi() -> Int? {
        for modifier in modifiers { if case .dpi(let value) = modifier { return value } }
        return nil
    }

    public func atTime() -> TimeValue? {
        for modifier in modifiers { if case .at(let value) = modifier { return value } }
        return nil
    }

    public func trimRange() -> (TimeValue?, TimeValue?)? {
        for modifier in modifiers { if case .trim(let start, let end) = modifier { return (start, end) } }
        return nil
    }

    public func maxHeight() -> Int? {
        for modifier in modifiers { if case .maxHeight(let value) = modifier { return value } }
        return nil
    }

    public func bitrate() -> Int? {
        for modifier in modifiers { if case .bitrate(let value) = modifier { return value } }
        return nil
    }

    public func speed() -> Double? {
        for modifier in modifiers { if case .speed(let value) = modifier { return value } }
        return nil
    }

    public func fps() -> Int? {
        for modifier in modifiers { if case .fps(let value) = modifier { return value } }
        return nil
    }

    public func videoCodec() -> VideoCodecChoice? {
        for modifier in modifiers { if case .videoCodec(let value) = modifier { return value } }
        return nil
    }

    public func audioCodec() -> AudioCodecChoice? {
        for modifier in modifiers { if case .audioCodec(let value) = modifier { return value } }
        return nil
    }

    public func languageCode() -> String? {
        for modifier in modifiers {
            if case .language(let code) = modifier { return code }
            if case .ocr(let code) = modifier { return code }
        }
        return nil
    }

    public var hasOCR: Bool {
        modifiers.contains { if case .ocr = $0 { return true }; return false }
    }

    public var hasLossless: Bool {
        modifiers.contains { if case .lossless = $0 { return true }; return false }
    }
}

public struct ConversionCommand: Equatable, Sendable {
    public var stem: String
    public var outputs: [OutputSpec]
    public var skipConfirmation: Bool

    public init(stem: String, outputs: [OutputSpec], skipConfirmation: Bool) {
        self.stem = stem
        self.outputs = outputs
        self.skipConfirmation = skipConfirmation
    }

    public var opensSettings: Bool {
        outputs.contains(where: \.openSettings)
    }

    public var wantsMultipleOutputs: Bool { outputs.count > 1 }
}

public enum TransformationParser {
    public static func parseFilename(_ name: String) throws -> ConversionCommand {
        let filename = URL(fileURLWithPath: name).lastPathComponent
        let scalars = Array(filename)
        var lastError: Error = RenvertError.notAConversion
        for index in scalars.indices.reversed() where scalars[index] == "." {
            let stem = String(scalars[..<index])
            let suffix = String(scalars[(index + 1)...])
            guard !stem.isEmpty else { continue }
            do {
                let parsed = try parseSuffix(suffix)
                if FormatRegistry.knows(firstFormatToken(suffix)) {
                    return ConversionCommand(stem: stem, outputs: parsed.outputs, skipConfirmation: parsed.bang)
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    public static func parseSuffix(_ suffix: String) throws -> (outputs: [OutputSpec], bang: Bool) {
        var scanner = Scanner(suffix)
        var outputs: [OutputSpec] = []
        repeat {
            outputs.append(try parseOutput(&scanner))
        } while scanner.consume(",")
        let bang = scanner.consume("!")
        scanner.skipWhitespace()
        if !scanner.isAtEnd { throw RenvertError.invalidModifier(scanner.remainder) }
        if outputs.isEmpty { throw RenvertError.notAConversion }
        return (outputs, bang)
    }

    public static func isConversionCandidate(oldName: String, newName: String) -> Bool {
        let oldExt = URL(fileURLWithPath: oldName).pathExtension
        guard let command = try? parseFilename(newName) else { return false }
        if command.outputs.contains(where: { !$0.modifiers.isEmpty || $0.openSettings }) {
            return true
        }
        if command.outputs.count > 1 { return true }
        guard let only = command.outputs.first else { return false }
        let oldID = FormatRegistry.resolve(oldExt)
        return oldID != only.format
    }

    private static func parseOutput(_ scanner: inout Scanner) throws -> OutputSpec {
        let token = scanner.take(while: { $0.isLetter || $0.isNumber })
        guard let format = FormatRegistry.resolve(token) else {
            throw RenvertError.unknownFormat(token)
        }
        var modifiers: [Modifier] = []
        var openSettings = false
        while scanner.consume("+") {
            if scanner.startsWith(",") || scanner.startsWith("!") || scanner.isAtEnd {
                openSettings = true
                break
            }
            modifiers.append(try parseModifier(&scanner))
        }
        return OutputSpec(format: format, modifiers: modifiers, openSettings: openSettings)
    }

    private static func parseModifier(_ scanner: inout Scanner) throws -> Modifier {
        let token = scanner.take(while: { $0 != "+" && $0 != "," && $0 != "!" })
        let lower = token.lowercased()
        if lower == "min" { return .min }
        if lower == "nometa" { return .noMeta }
        if lower == "mute" { return .mute }
        if lower == "normalize" { return .normalize }
        if lower == "mono" { return .mono }
        if lower == "reverse" { return .reverse }
        if lower == "fliph" { return .flipH }
        if lower == "flipv" { return .flipV }
        if lower == "nobg" { return .noBackground }
        if lower == "lossless" { return .lossless }
        if lower == "transcribe" { return .transcribe }
        if ["gray", "grey", "grayscale", "greyscale"].contains(lower) { return .gray }
        if lower == "480p" { return .maxHeight(480) }
        if lower == "720p" { return .maxHeight(720) }
        if lower == "1080p" { return .maxHeight(1080) }
        if lower == "4k" { return .maxHeight(2160) }
        if let codec = AudioCodecChoice(rawValue: lower) { return .audioCodec(codec) }
        if let codec = VideoCodecChoice(rawValue: lower) { return .videoCodec(codec) }

        if let value = prefixedInt(lower, "q") ?? prefixedInt(lower, "quality") {
            guard (0...100).contains(value) else { throw RenvertError.invalidModifier(token) }
            return .quality(value)
        }
        if let value = prefixedInt(lower, "w") ?? prefixedInt(lower, "width") {
            guard (1...16384).contains(value) else { throw RenvertError.invalidModifier(token) }
            return .width(value)
        }
        if let value = prefixedInt(lower, "h") ?? prefixedInt(lower, "height") {
            guard (1...16384).contains(value) else { throw RenvertError.invalidModifier(token) }
            return .height(value)
        }
        if let value = prefixedInt(lower, "bitrate") {
            guard (32...512).contains(value) else { throw RenvertError.invalidModifier(token) }
            return .bitrate(value)
        }
        if let value = prefixedInt(lower, "dpi") {
            guard (72...1200).contains(value) else { throw RenvertError.invalidModifier(token) }
            return .dpi(value)
        }
        if let value = prefixedInt(lower, "fps") {
            guard [24, 25, 30, 50, 60].contains(value) else { throw RenvertError.invalidModifier(token) }
            return .fps(value)
        }
        if let value = prefixedInt(lower, "loop") {
            guard (0...1000).contains(value) else { throw RenvertError.invalidModifier(token) }
            return .loop(value)
        }
        if let bytes = parseSize(lower) { return .maxBytes(bytes) }
        if lower.hasPrefix("speed") {
            return .speed(try parseSpeed(String(lower.dropFirst(5))))
        }
        if lower.hasPrefix("rotate") {
            let value = Int(lower.dropFirst(6))
            guard let value, [90, 180, 270].contains(value) else { throw RenvertError.invalidModifier(token) }
            return .rotate(value)
        }
        if lower.hasPrefix("smartcrop") {
            let ratio = try parseRatio(String(lower.dropFirst(9)))
            return .smartCrop(width: ratio.0, height: ratio.1)
        }
        if lower.hasPrefix("crop") {
            let ratio = try parseRatio(String(lower.dropFirst(4)))
            return .crop(width: ratio.0, height: ratio.1)
        }
        if lower.hasPrefix("trim") {
            return try parseTrim(String(lower.dropFirst(4)))
        }
        if lower.hasPrefix("at") {
            return .at(try TimeValue.parse(String(lower.dropFirst(2))))
        }
        if lower.hasPrefix("page") {
            return .pages(try parsePages(String(lower.dropFirst(4))))
        }
        if lower == "ocr" { return .ocr(language: nil) }
        if lower.hasPrefix("ocr_") { return .ocr(language: String(lower.dropFirst(4))) }
        if lower.hasPrefix("lang_") { return .language(String(lower.dropFirst(5))) }
        throw RenvertError.invalidModifier(token)
    }

    private static func firstFormatToken(_ suffix: String) -> String {
        let end = suffix.firstIndex(where: { $0 == "+" || $0 == "," || $0 == "!" }) ?? suffix.endIndex
        return String(suffix[..<end])
    }

    private static func prefixedInt(_ value: String, _ prefix: String) -> Int? {
        guard value.hasPrefix(prefix) else { return nil }
        let rest = value.dropFirst(prefix.count)
        guard !rest.isEmpty, rest.allSatisfy(\.isNumber) else { return nil }
        return Int(rest)
    }

    private static func parseSize(_ value: String) -> Int64? {
        let units: [(String, Int64)] = [("kb", 1_000), ("mb", 1_000_000), ("gb", 1_000_000_000)]
        var body = value
        if body.hasPrefix("size") { body = String(body.dropFirst(4)) }
        for (suffix, multiplier) in units {
            if body.hasSuffix(suffix) {
                let number = body.dropLast(suffix.count)
                guard let count = Int64(number), count > 0 else { return nil }
                return count * multiplier
            }
        }
        return nil
    }

    private static func parseSpeed(_ raw: String) throws -> Double {
        if raw.hasSuffix("x"), let value = Double(raw.dropLast()) {
            guard (1...4).contains(value) else { throw RenvertError.invalidModifier("speed\(raw)") }
            return value
        }
        if let percent = Double(raw) {
            guard (25...400).contains(percent) else { throw RenvertError.invalidModifier("speed\(raw)") }
            return percent / 100.0
        }
        throw RenvertError.invalidModifier("speed\(raw)")
    }

    private static func parseRatio(_ raw: String) throws -> (Int, Int) {
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else {
            throw RenvertError.invalidModifier(raw)
        }
        return (w, h)
    }

    private static func parseTrim(_ raw: String) throws -> Modifier {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { throw RenvertError.invalidModifier("trim\(raw)") }
        let start = parts[0].isEmpty ? nil : try TimeValue.parse(parts[0])
        let end = parts[1].isEmpty ? nil : try TimeValue.parse(parts[1])
        return .trim(start: start, end: end)
    }

    private static func parsePages(_ raw: String) throws -> PageSelection {
        if raw.hasPrefix("-"), let end = Int(raw.dropFirst()) {
            return .through(end)
        }
        if raw.hasSuffix("-"), let start = Int(raw.dropLast()) {
            return .from(start)
        }
        if let range = raw.range(of: "-") {
            guard let start = Int(raw[..<range.lowerBound]), let end = Int(raw[range.upperBound...]), start <= end else {
                throw RenvertError.invalidModifier("page\(raw)")
            }
            return .closed(start...end)
        }
        guard let page = Int(raw), page >= 1 else { throw RenvertError.invalidModifier("page\(raw)") }
        return .single(page)
    }

    private static func trimmed(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private static func byteLabel(_ bytes: Int64) -> String {
        if bytes % 1_000_000_000 == 0 { return "\(bytes / 1_000_000_000)gb" }
        if bytes % 1_000_000 == 0 { return "\(bytes / 1_000_000)mb" }
        return "\(bytes / 1_000)kb"
    }
}

public enum OutputNamer {
    public static func url(
        directory: URL,
        stem: String,
        spec: OutputSpec,
        collidingWith existing: [URL]
    ) -> URL {
        let ext = FormatRegistry.preferredExtension(for: spec.format)
        let descriptor = spec.modifiers.map(\.shortLabel).joined(separator: "+")
        let base = descriptor.isEmpty ? stem : "\(stem) (\(descriptor))"
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var index = 2
        let occupied = Set(existing.map(\.standardizedFileURL.path))
        while occupied.contains(candidate.standardizedFileURL.path) {
            candidate = directory.appendingPathComponent("\(base) \(index).\(ext)")
            index += 1
        }
        return candidate
    }
}

struct Scanner {
    private let chars: [Character]
    private var index = 0

    init(_ text: String) {
        chars = Array(text)
    }

    var isAtEnd: Bool { index >= chars.count }
    var remainder: String { String(chars[index...]) }

    mutating func skipWhitespace() {
        while index < chars.count && chars[index].isWhitespace { index += 1 }
    }

    mutating func consume(_ value: String) -> Bool {
        let slice = value
        guard chars.dropFirst(index).starts(with: slice) else { return false }
        index += slice.count
        return true
    }

    func startsWith(_ value: String) -> Bool {
        chars.dropFirst(index).starts(with: value)
    }

    mutating func take(while predicate: (Character) -> Bool) -> String {
        let start = index
        while index < chars.count && predicate(chars[index]) { index += 1 }
        return String(chars[start..<index])
    }
}

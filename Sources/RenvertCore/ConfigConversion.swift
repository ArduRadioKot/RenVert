import Foundation

public enum ConfigValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ConfigValue])
    case object([String: ConfigValue])

    public var stringScalar: String {
        switch self {
        case .null: return ""
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return value.rounded() == value ? String(Int(value)) : String(value)
        case .string(let value): return value
        case .array, .object: return ""
        }
    }

    public static func load(from url: URL) throws -> ConfigValue {
        let ext = url.pathExtension.lowercased()
        let data = try Data(contentsOf: url)
        switch ext {
        case "json":
            return try fromJSON(JSONSerialization.jsonObject(with: data))
        case "plist":
            return try fromJSON(PropertyListSerialization.propertyList(from: data, options: [], format: nil))
        case "xml":
            if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                return try fromJSON(plist)
            }
            return try XMLBridge.parse(data)
        case "yaml", "yml":
            return try YAMLBridge.parse(String(contentsOf: url, encoding: .utf8))
        case "toml":
            return try TOMLBridge.parse(String(contentsOf: url, encoding: .utf8))
        default:
            if let json = try? JSONSerialization.jsonObject(with: data) {
                return try fromJSON(json)
            }
            throw RenvertError.invalidInput(String(localized: "Unsupported config file."))
        }
    }

    public static func dump(_ value: ConfigValue, format: FormatID) throws -> Data {
        switch format {
        case .json:
            return try JSONSerialization.data(withJSONObject: value.jsonObject(), options: [.prettyPrinted, .sortedKeys])
        case .plist:
            return try PropertyListSerialization.data(fromPropertyList: value.jsonObject(), format: .xml, options: 0)
        case .xml:
            return try XMLBridge.dump(value)
        case .yaml:
            return Data(dumpYAML(value).utf8)
        case .toml:
            return Data(TOMLBridge.dump(value).utf8)
        default:
            throw RenvertError.unsupportedConversion(from: "config", to: format.rawValue)
        }
    }

    public static func dumpYAML(_ value: ConfigValue, indent: Int = 0) -> String {
        let pad = String(repeating: " ", count: indent)
        switch value {
        case .null: return "null"
        case .bool(let v): return v ? "true" : "false"
        case .number(let v): return v.rounded() == v ? String(Int(v)) : String(v)
        case .string(let v): return yamlQuote(v)
        case .array(let items):
            if items.isEmpty { return "[]" }
            return items.map { item in
                switch item {
                case .object, .array:
                    return "\(pad)-\n\(dumpYAML(item, indent: indent + 2))"
                default:
                    return "\(pad)- \(dumpYAML(item, indent: 0))"
                }
            }.joined(separator: "\n")
        case .object(let obj):
            if obj.isEmpty { return "{}" }
            return obj.keys.sorted().map { key in
                let child = obj[key]!
                switch child {
                case .object, .array:
                    return "\(pad)\(key):\n\(dumpYAML(child, indent: indent + 2))"
                default:
                    return "\(pad)\(key): \(dumpYAML(child))"
                }
            }.joined(separator: "\n")
        }
    }

    public static func fromJSON(_ object: Any) throws -> ConfigValue {
        switch object {
        case is NSNull: return .null
        case let value as Bool: return .bool(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        case let value as String: return .string(value)
        case let value as [Any]: return .array(try value.map(fromJSON))
        case let value as [String: Any]:
            var obj: [String: ConfigValue] = [:]
            for (key, raw) in value { obj[key] = try fromJSON(raw) }
            return .object(obj)
        default:
            throw RenvertError.invalidInput(String(localized: "Unsupported JSON value."))
        }
    }

    func jsonObject() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .number(let v): return v
        case .string(let v): return v
        case .array(let items): return items.map { $0.jsonObject() }
        case .object(let obj): return obj.mapValues { $0.jsonObject() }
        }
    }

    private static func yamlQuote(_ value: String) -> String {
        if value.contains(":") || value.contains("#") || value.contains("\n") || value.isEmpty {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return value
    }
}

public struct ConfigConverter: Converter {
    public init() {}

    public func convert(from source: URL, detected: FormatID, spec: OutputSpec, to destination: URL, context: ConversionContext) throws {
        let value = try ConfigValue.load(from: source)
        context.onProgress?(0.5)
        if tableFormats.contains(spec.format) && spec.format != .json && spec.format != .yaml {
            try SpreadsheetConverter().convert(from: source, detected: detected, spec: spec, to: destination, context: context)
            return
        }
        let data = try ConfigValue.dump(value, format: spec.format)
        try data.write(to: destination)
        context.onProgress?(1)
    }
}

enum YAMLBridge {
    static func parse(_ text: String) throws -> ConfigValue {
        let lines = text.replacingOccurrences(of: "\t", with: "  ").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        return try parseBlock(lines, index: &index, indent: 0)
    }

    private static func parseBlock(_ lines: [String], index: inout Int, indent: Int) throws -> ConfigValue {
        skipBlanks(lines, index: &index)
        guard index < lines.count else { return .null }
        let (_, content) = splitIndent(lines[index])
        if content.hasPrefix("- ") || content == "-" {
            return try parseList(lines, index: &index, indent: indent)
        }
        if content.contains(":") {
            return try parseMap(lines, index: &index, indent: indent)
        }
        index += 1
        return parseScalar(content)
    }

    private static func parseMap(_ lines: [String], index: inout Int, indent: Int) throws -> ConfigValue {
        var object: [String: ConfigValue] = [:]
        while index < lines.count {
            skipBlanks(lines, index: &index)
            guard index < lines.count else { break }
            let (pad, content) = splitIndent(lines[index])
            if pad < indent { break }
            if content.hasPrefix("- ") { break }
            guard let colon = content.firstIndex(of: ":") else { break }
            let key = String(content[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            index += 1
            if rest.isEmpty {
                let child = try parseBlock(lines, index: &index, indent: pad + 2)
                object[key] = child
            } else {
                object[key] = parseScalar(rest)
            }
        }
        return .object(object)
    }

    private static func parseList(_ lines: [String], index: inout Int, indent: Int) throws -> ConfigValue {
        var items: [ConfigValue] = []
        while index < lines.count {
            skipBlanks(lines, index: &index)
            guard index < lines.count else { break }
            let (pad, content) = splitIndent(lines[index])
            if pad < indent { break }
            guard content.hasPrefix("-") else { break }
            let rest = String(content.drop(while: { $0 == "-" || $0 == " " }))
            index += 1
            if rest.isEmpty {
                items.append(try parseBlock(lines, index: &index, indent: pad + 2))
            } else if rest.contains(":") {
                var synthetic = [String(repeating: " ", count: pad + 2) + rest]
                while index < lines.count {
                    let (nextPad, next) = splitIndent(lines[index])
                    if nextPad >= pad + 2 && !next.hasPrefix("-") {
                        synthetic.append(lines[index])
                        index += 1
                    } else { break }
                }
                var childIndex = 0
                items.append(try parseBlock(synthetic, index: &childIndex, indent: pad + 2))
            } else {
                items.append(parseScalar(rest))
            }
        }
        return .array(items)
    }

    private static func parseScalar(_ raw: String) -> ConfigValue {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value == "null" || value == "~" { return .null }
        if value == "true" { return .bool(true) }
        if value == "false" { return .bool(false) }
        if let number = Double(value) { return .number(number) }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            return .string(String(value.dropFirst().dropLast()))
        }
        return .string(value)
    }

    private static func splitIndent(_ line: String) -> (Int, String) {
        let trimmed = line.trimmingCharacters(in: .newlines)
        let pad = trimmed.prefix { $0 == " " }.count
        return (pad, String(trimmed.dropFirst(pad)))
    }

    private static func skipBlanks(_ lines: [String], index: inout Int) {
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { index += 1 } else { break }
        }
    }
}

enum TOMLBridge {
    static func parse(_ text: String) throws -> ConfigValue {
        var object: [String: ConfigValue] = [:]
        var current = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast())
                if object[current] == nil { object[current] = .object([:]) }
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let value = scalar(parts[1])
            if current.isEmpty {
                object[parts[0]] = value
            } else if case .object(var nested) = object[current] {
                nested[parts[0]] = value
                object[current] = .object(nested)
            }
        }
        return .object(object)
    }

    static func dump(_ value: ConfigValue) -> String {
        guard case .object(let object) = value else { return "" }
        var lines: [String] = []
        var tables: [(String, [String: ConfigValue])] = []
        for key in object.keys.sorted() {
            switch object[key] {
            case .object(let nested):
                tables.append((key, nested))
            default:
                lines.append("\(key) = \(literal(object[key] ?? .null))")
            }
        }
        for (name, nested) in tables {
            lines.append("")
            lines.append("[\(name)]")
            for key in nested.keys.sorted() {
                lines.append("\(key) = \(literal(nested[key] ?? .null))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func scalar(_ raw: String) -> ConfigValue {
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        if let number = Double(raw) { return .number(number) }
        if raw.hasPrefix("\""), raw.hasSuffix("\"") { return .string(String(raw.dropFirst().dropLast())) }
        return .string(raw)
    }

    private static func literal(_ value: ConfigValue) -> String {
        switch value {
        case .bool(let v): return v ? "true" : "false"
        case .number(let v): return v.rounded() == v ? String(Int(v)) : String(v)
        case .string(let v): return "\"\(v)\""
        default: return "\"\""
        }
    }
}

enum XMLBridge {
    static func parse(_ data: Data) throws -> ConfigValue {
        let parser = SimpleXML()
        return try parser.parse(data)
    }

    static func dump(_ value: ConfigValue) throws -> Data {
        let body = render(value, name: "root", indent: 0)
        return Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\(body)\n".utf8)
    }

    private static func render(_ value: ConfigValue, name: String, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        switch value {
        case .object(let obj):
            let inner = obj.keys.sorted().map { render(obj[$0] ?? .null, name: $0, indent: indent + 2) }.joined(separator: "\n")
            return "\(pad)<\(name)>\n\(inner)\n\(pad)</\(name)>"
        case .array(let items):
            let inner = items.map { render($0, name: "item", indent: indent + 2) }.joined(separator: "\n")
            return "\(pad)<\(name)>\n\(inner)\n\(pad)</\(name)>"
        default:
            return "\(pad)<\(name)>\(DocxIO.xmlEscape(value.stringScalar))</\(name)>"
        }
    }
}

final class SimpleXML: NSObject, XMLParserDelegate {
    private var stack: [(name: String, children: [String: ConfigValue], text: String)] = []
    private var root: ConfigValue = .null

    func parse(_ data: Data) throws -> ConfigValue {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { throw RenvertError.invalidInput(String(localized: "XML parse failed.")) }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        stack.append((elementName, [:], ""))
        _ = attributes
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard let finished = stack.popLast() else { return }
        let value: ConfigValue
        if !finished.children.isEmpty {
            value = .object(finished.children)
        } else {
            value = .string(finished.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if stack.isEmpty {
            root = .object([elementName: value])
        } else {
            stack[stack.count - 1].children[elementName] = value
        }
    }
}

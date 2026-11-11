import Foundation

public struct SpreadsheetConverter: Converter {
    public init() {}

    public func convert(from source: URL, detected: FormatID, spec: OutputSpec, to destination: URL, context: ConversionContext) throws {
        try context.cancellation.throwIfCancelled()
        let table = try loadTable(source, format: detected)
        context.onProgress?(0.5)
        try writeTable(table, format: spec.format, to: destination)
        context.onProgress?(1)
    }

    /// `format` is what the bytes are; the file's extension is already the target's after a rename.
    func loadTable(_ url: URL, format: FormatID) throws -> [[String]] {
        switch format {
        case .csv, .tsv:
            let text = DelimitedText.decode(try Data(contentsOf: url))
            let delimiter = DelimitedText.sniffDelimiter(text, expected: format == .tsv ? "\t" : ",")
            return DelimitedText.parse(text, delimiter: delimiter)
        case .xlsx:
            return try XLSXReader.read(url)
        case .json, .yaml, .xml, .plist, .toml:
            return Self.table(from: try ConfigValue.load(from: url, format: format))
        default:
            throw RenvertError.unsupportedConversion(from: format.rawValue, to: "table")
        }
    }

    private func writeTable(_ rows: [[String]], format: FormatID, to url: URL) throws {
        switch format {
        case .csv:
            try DelimitedText.serialize(rows, delimiter: ",").write(to: url, atomically: true, encoding: .utf8)
        case .tsv:
            try DelimitedText.serialize(rows, delimiter: "\t").write(to: url, atomically: true, encoding: .utf8)
        case .json, .yaml:
            let headers = Self.uniqueHeaders(rows.first ?? [])
            let objects: [ConfigValue] = rows.dropFirst().map { row in
                var dict: [String: ConfigValue] = [:]
                for (index, header) in headers.enumerated() {
                    dict[header] = Self.typed(index < row.count ? row[index] : "")
                }
                return .object(dict)
            }
            try ConfigValue.dump(.array(objects), format: format).write(to: url)
        case .xlsx:
            try XLSXWriter.write(rows, to: url)
        default:
            throw RenvertError.unsupportedConversion(from: "table", to: format.rawValue)
        }
    }

    /// Blank or repeated column titles would collapse into one JSON key.
    private static func uniqueHeaders(_ headers: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return headers.enumerated().map { index, raw in
            let base = raw.trimmingCharacters(in: .whitespaces).isEmpty ? "column\(index + 1)" : raw
            seen[base, default: 0] += 1
            return seen[base] == 1 ? base : "\(base)_\(seen[base]!)"
        }
    }

    /// Numbers and booleans stay numbers and booleans in JSON and YAML.
    private static func typed(_ cell: String) -> ConfigValue {
        if cell == "true" || cell == "false" { return .bool(cell == "true") }
        if XLSXWriter.isPlainNumber(cell), let number = Double(cell) { return .number(number) }
        return .string(cell)
    }

    /// Finds the rows in a config tree: a list of records, however deep it is wrapped.
    static func table(from value: ConfigValue) -> [[String]] {
        switch value {
        case .array(let items):
            let records = items.compactMap { item -> [String: ConfigValue]? in
                if case .object(let object) = item { return object }
                return nil
            }
            if records.isEmpty {
                return [["value"]] + items.map { [cellText($0)] }
            }
            let headers = Array(Set(records.flatMap(\.keys))).sorted()
            return [headers] + records.map { record in headers.map { cellText(record[$0] ?? .null) } }
        case .object(let object):
            // <items><item>…</item><item>…</item></items> and similar single wrappers.
            if object.count == 1, let only = object.values.first {
                switch only {
                case .array, .object: return table(from: only)
                default: break
                }
            }
            let nested = object.values.contains { if case .object = $0 { return true }; return false }
            if nested {
                // A table per key: [section]\nname = …  →  one row per section.
                let records = object.keys.sorted().compactMap { key -> (String, [String: ConfigValue])? in
                    if case .object(let inner) = object[key] { return (key, inner) }
                    return nil
                }
                if records.count == object.count {
                    let headers = Array(Set(records.flatMap { $0.1.keys })).sorted()
                    return [["name"] + headers] + records.map { name, inner in [name] + headers.map { cellText(inner[$0] ?? .null) } }
                }
            }
            let keys = object.keys.sorted()
            return [keys, keys.map { cellText(object[$0] ?? .null) }]
        default:
            return [["value"], [value.stringScalar]]
        }
    }

    private static func cellText(_ value: ConfigValue) -> String {
        switch value {
        case .array, .object:
            let data = try? JSONSerialization.data(withJSONObject: value.jsonObject(), options: [.sortedKeys])
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        default:
            return value.stringScalar
        }
    }
}

/// CSV and TSV as they arrive from Excel, Numbers and exports: any common encoding,
/// comma or semicolon, quoted fields with line breaks and doubled quotes.
enum DelimitedText {
    static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        }
        var converted: NSString?
        let suggested = [String.Encoding.utf16, .windowsCP1251, .windowsCP1252].map { NSNumber(value: $0.rawValue) }
        let guess = NSString.stringEncoding(
            for: data,
            encodingOptions: [.suggestedEncodingsKey: suggested, .useOnlySuggestedEncodingsKey: true],
            convertedString: &converted,
            usedLossyConversion: nil
        )
        if guess != 0, let converted { return converted as String }
        return String(decoding: data, as: UTF8.self)
    }

    /// Excel writes ";" wherever the comma is the decimal separator, Russian locale included.
    static func sniffDelimiter(_ text: String, expected: Character) -> Character {
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        var quoted = false
        var lines = 0
        for char in text {
            if char == "\"" { quoted.toggle(); continue }
            if quoted { continue }
            if char == "\n" { lines += 1; if lines >= 20 { break } }
            if counts[char] != nil { counts[char]! += 1 }
        }
        if (counts[expected] ?? 0) > 0 && expected == "\t" { return expected }
        let best = counts.max { $0.value < $1.value }
        if let best, best.value > 0, best.value > (counts[expected] ?? 0) { return best.key }
        return expected
    }

    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var wasQuoted = false
        let chars = Array(text)
        var index = 0
        func endRow() {
            row.append(field)
            // A trailing line break does not make an extra empty row.
            if !(row.count == 1 && row[0].isEmpty && !wasQuoted) { rows.append(row) }
            row = []
            field = ""
            wasQuoted = false
        }
        while index < chars.count {
            let char = chars[index]
            if quoted {
                if char == "\"" {
                    if index + 1 < chars.count, chars[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(char)
                }
            } else if char == "\"" && field.isEmpty {
                quoted = true
                wasQuoted = true
            } else if char == delimiter {
                row.append(field)
                field = ""
            } else if char == "\r\n" || char == "\n" || char == "\r" {
                endRow()
            } else {
                field.append(char)
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        let width = rows.map(\.count).max() ?? 0
        return rows.map { $0 + Array(repeating: "", count: width - $0.count) }
    }

    static func serialize(_ rows: [[String]], delimiter: Character) -> String {
        rows.map { row in
            row.map { field in
                if field.contains(delimiter) || field.contains("\"") || field.contains("\n") || field.contains("\r") {
                    return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
                }
                return field
            }.joined(separator: String(delimiter))
        }.joined(separator: "\n") + "\n"
    }
}

/// Reads the first worksheet of a real workbook: shared and inline strings, sparse rows,
/// empty cells, cached formula results, booleans and dates.
enum XLSXReader {
    static func read(_ url: URL) throws -> [[String]] {
        func entry(_ name: String) -> Data? {
            let result = ProcessRunner.run(executable: "/usr/bin/unzip", arguments: ["-p", url.path, name])
            return result.exitCode == 0 && !result.stdout.isEmpty ? Data(result.stdout.utf8) : nil
        }
        let strings = entry("xl/sharedStrings.xml").map { SharedStrings().parse($0) } ?? []
        let dateStyles = entry("xl/styles.xml").map { Styles().parse($0) } ?? []
        guard let sheet = entry(firstSheetPath(entry)) ?? entry("xl/worksheets/sheet1.xml") else {
            throw RenvertError.invalidInput(L("XLSX sheet is missing."))
        }
        return Sheet(strings: strings, dateStyles: dateStyles).parse(sheet)
    }

    /// The first sheet in workbook order, which need not be sheet1.xml.
    private static func firstSheetPath(_ entry: (String) -> Data?) -> String {
        guard let workbook = entry("xl/workbook.xml"), let rels = entry("xl/_rels/workbook.xml.rels") else {
            return "xl/worksheets/sheet1.xml"
        }
        let wanted = Attributes(element: "sheet").parse(workbook).first?["r:id"]
        let target = Attributes(element: "Relationship").parse(rels).first { $0["Id"] == wanted }?["Target"]
        guard let target else { return "xl/worksheets/sheet1.xml" }
        return target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
    }

    /// Collects the attributes of every element with the given name.
    private final class Attributes: NSObject, XMLParserDelegate {
        let element: String
        var found: [[String: String]] = []
        init(element: String) { self.element = element }

        func parse(_ data: Data) -> [[String: String]] {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.parse()
            return found
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == element { found.append(attributes) }
        }
    }

    private final class SharedStrings: NSObject, XMLParserDelegate {
        var values: [String] = []
        var current = ""
        var inText = false
        var phonetic = 0

        func parse(_ data: Data) -> [String] {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.parse()
            return values
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "si": current = ""
            case "rPh": phonetic += 1
            case "t": inText = phonetic == 0
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { current += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "si": values.append(current)
            case "rPh": phonetic -= 1
            case "t": inText = false
            default: break
            }
        }
    }

    /// For each cell style index, whether it formats a number as a date or time.
    private final class Styles: NSObject, XMLParserDelegate {
        var custom: [Int: String] = [:]
        var styles: [Bool] = []
        var inCellXfs = false

        func parse(_ data: Data) -> [Bool] {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.parse()
            return styles
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "numFmt", let id = attributes["numFmtId"].flatMap(Int.init) {
                custom[id] = attributes["formatCode"] ?? ""
            } else if name == "cellXfs" {
                inCellXfs = true
            } else if name == "xf", inCellXfs {
                styles.append(isDate(attributes["numFmtId"].flatMap(Int.init) ?? 0))
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "cellXfs" { inCellXfs = false }
        }

        private func isDate(_ id: Int) -> Bool {
            if (14...22).contains(id) || (27...36).contains(id) || (45...47).contains(id) || (50...58).contains(id) { return true }
            guard let code = custom[id] else { return false }
            // Quoted text and [color]/[locale] blocks may hold letters that are not date fields.
            let bare = code
                .replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
                .lowercased()
            return bare.contains("y") || bare.contains("d") || bare.contains("h") || bare.contains("mm") || bare.contains("ss")
        }
    }

    private final class Sheet: NSObject, XMLParserDelegate {
        let strings: [String]
        let dateStyles: [Bool]
        var rows: [[String]] = []
        var row: [String] = []
        var column = 0
        var type = ""
        var style = 0
        var value = ""
        var capture = false

        init(strings: [String], dateStyles: [Bool]) {
            self.strings = strings
            self.dateStyles = dateStyles
        }

        func parse(_ data: Data) -> [[String]] {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.parse()
            while let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }
            let width = rows.map(\.count).max() ?? 0
            return rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "row":
                // Rows that hold nothing are simply absent from the file.
                if let number = attributes["r"].flatMap(Int.init), number <= 1_048_576 {
                    while rows.count < number - 1 { rows.append([]) }
                }
                row = []
            case "c":
                if let ref = attributes["r"] {
                    column = Self.columnIndex(ref)
                } else {
                    column = row.count
                }
                type = attributes["t"] ?? "n"
                style = attributes["s"].flatMap(Int.init) ?? 0
                value = ""
            case "v", "t":
                capture = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capture { value += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v", "t":
                capture = false
            case "c":
                while row.count < column { row.append("") }
                let text = display()
                if column < row.count { row[column] = text } else { row.append(text) }
            case "row":
                rows.append(row)
            default:
                break
            }
        }

        private func display() -> String {
            switch type {
            case "s":
                return Int(value).flatMap { strings.indices.contains($0) ? strings[$0] : nil } ?? ""
            case "b":
                return value == "1" ? "TRUE" : "FALSE"
            case "inlineStr", "str", "e":
                return value
            default:
                guard let number = Double(value) else { return value }
                if dateStyles.indices.contains(style), dateStyles[style] { return Self.date(number) }
                // 0.1 + 0.2 is stored as 0.30000000000000004; show what the user typed.
                return number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(format: "%.15g", number)
            }
        }

        private static func columnIndex(_ ref: String) -> Int {
            var index = 0
            for scalar in ref.unicodeScalars {
                guard scalar.value >= 65, scalar.value <= 90 else { break }
                index = index * 26 + Int(scalar.value - 64)
            }
            return max(index - 1, 0)
        }

        /// Excel counts days from 1899-12-30; the fraction is the time of day.
        private static func date(_ serial: Double) -> String {
            let days = serial.rounded(.down)
            let seconds = ((serial - days) * 86_400).rounded()
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let epoch = calendar.date(from: DateComponents(year: 1899, month: 12, day: 30))!
            let moment = epoch.addingTimeInterval(days * 86_400 + seconds)
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if days == 0 {
                formatter.dateFormat = "HH:mm:ss"
            } else {
                formatter.dateFormat = seconds == 0 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"
            }
            return formatter.string(from: moment)
        }
    }
}

enum XLSXWriter {
    static func write(_ rows: [[String]], to url: URL) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("renvert-xlsx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        </Types>
        """.write(to: temp.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)

        let rels = temp.appendingPathComponent("_rels", isDirectory: true)
        try FileManager.default.createDirectory(at: rels, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """.write(to: rels.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)

        let xl = temp.appendingPathComponent("xl", isDirectory: true)
        try FileManager.default.createDirectory(at: xl, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """.write(to: xl.appendingPathComponent("workbook.xml"), atomically: true, encoding: .utf8)

        let xlRels = xl.appendingPathComponent("_rels", isDirectory: true)
        try FileManager.default.createDirectory(at: xlRels, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        </Relationships>
        """.write(to: xlRels.appendingPathComponent("workbook.xml.rels"), atomically: true, encoding: .utf8)

        let sheets = xl.appendingPathComponent("worksheets", isDirectory: true)
        try FileManager.default.createDirectory(at: sheets, withIntermediateDirectories: true)
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
        for (r, row) in rows.enumerated() {
            xml += "<row r=\"\(r + 1)\">"
            for (c, cell) in row.enumerated() {
                let ref = columnName(c) + "\(r + 1)"
                if cell.isEmpty { continue }
                if isPlainNumber(cell) {
                    // A real number, so the spreadsheet can sum and sort it.
                    xml += "<c r=\"\(ref)\"><v>\(cell)</v></c>"
                } else {
                    xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(DocxIO.xmlEscape(cell))</t></is></c>"
                }
            }
            xml += "</row>"
        }
        xml += "</sheetData></worksheet>"
        try xml.write(to: sheets.appendingPathComponent("sheet1.xml"), atomically: true, encoding: .utf8)

        let zip = ProcessRunner.run(executable: "/usr/bin/ditto", arguments: ["-c", "-k", "--norsrc", "--noextattr", temp.path, url.path])
        guard zip.exitCode == 0 else { throw RenvertError.converterFailed(L("Could not write XLSX.")) }
    }

    /// Digits only, no leading zeros (phone numbers, ZIP codes and IDs stay text), short
    /// enough to survive as a double.
    static func isPlainNumber(_ cell: String) -> Bool {
        guard cell.count <= 15,
              cell.range(of: "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?$", options: .regularExpression) != nil else { return false }
        return true
    }

    private static func columnName(_ index: Int) -> String {
        var n = index
        var name = ""
        repeat {
            name = String(UnicodeScalar(65 + n % 26)!) + name
            n = n / 26 - 1
        } while n >= 0
        return name
    }
}

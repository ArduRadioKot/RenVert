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

    private func loadTable(_ url: URL, format: FormatID) throws -> [[String]] {
        switch format {
        case .csv:
            return try parseDelimited(String(contentsOf: url, encoding: .utf8), delimiter: ",")
        case .tsv:
            return try parseDelimited(String(contentsOf: url, encoding: .utf8), delimiter: "\t")
        case .xlsx:
            return try XLSXReader.read(url)
        case .json:
            return tableFromJSON(try ConfigValue.load(from: url))
        case .yaml:
            return tableFromJSON(try ConfigValue.load(from: url))
        default:
            throw RenvertError.unsupportedConversion(from: format.rawValue, to: "table")
        }
    }

    private func writeTable(_ rows: [[String]], format: FormatID, to url: URL) throws {
        switch format {
        case .csv:
            try serializeDelimited(rows, delimiter: ",").write(to: url, atomically: true, encoding: .utf8)
        case .tsv:
            try serializeDelimited(rows, delimiter: "\t").write(to: url, atomically: true, encoding: .utf8)
        case .json:
            let object = rows.isEmpty ? [] : rows.dropFirst().map { row -> [String: String] in
                let headers = rows[0]
                var dict: [String: String] = [:]
                for (index, header) in headers.enumerated() {
                    dict[header] = index < row.count ? row[index] : ""
                }
                return dict
            }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
        case .yaml:
            let jsonURL = url.deletingPathExtension().appendingPathExtension("json.tmp")
            try writeTable(rows, format: .json, to: jsonURL)
            defer { try? FileManager.default.removeItem(at: jsonURL) }
            let value = try ConfigValue.load(from: jsonURL)
            try ConfigValue.dumpYAML(value).write(to: url, atomically: true, encoding: .utf8)
        case .xlsx:
            try XLSXWriter.write(rows, to: url)
        default:
            throw RenvertError.unsupportedConversion(from: "table", to: format.rawValue)
        }
    }

    private func parseDelimited(_ text: String, delimiter: Character) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        while let char = iterator.next() {
            if char == "\"" {
                quoted.toggle()
            } else if char == delimiter && !quoted {
                row.append(field)
                field = ""
            } else if (char == "\n" || char == "\r") && !quoted {
                if char == "\r" { continue }
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(char)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private func serializeDelimited(_ rows: [[String]], delimiter: Character) -> String {
        rows.map { row in
            row.map { field in
                if field.contains(delimiter) || field.contains("\"") || field.contains("\n") {
                    return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
                }
                return field
            }.joined(separator: String(delimiter))
        }.joined(separator: "\n")
    }

    private func tableFromJSON(_ value: ConfigValue) -> [[String]] {
        switch value {
        case .array(let items):
            let dicts = items.compactMap { item -> [String: String]? in
                if case .object(let obj) = item {
                    return obj.mapValues { $0.stringScalar }
                }
                return nil
            }
            let headers = Array(Set(dicts.flatMap(\.keys))).sorted()
            return [headers] + dicts.map { dict in headers.map { dict[$0] ?? "" } }
        default:
            return [["value"], [value.stringScalar]]
        }
    }
}

enum XLSXReader {
    static func read(_ url: URL) throws -> [[String]] {
        let shared = ProcessRunner.run(executable: "/usr/bin/unzip", arguments: ["-p", url.path, "xl/sharedStrings.xml"])
        let strings = shared.exitCode == 0 ? parseSharedStrings(shared.stdout) : []
        let sheet = ProcessRunner.run(executable: "/usr/bin/unzip", arguments: ["-p", url.path, "xl/worksheets/sheet1.xml"])
        guard sheet.exitCode == 0 else { throw RenvertError.invalidInput(String(localized: "XLSX sheet is missing.")) }
        return parseSheet(sheet.stdout, strings: strings)
    }

    private static func parseSharedStrings(_ xml: String) -> [String] {
        var values: [String] = []
        var current = xml[...]
        while let start = current.range(of: "<si") {
            current = current[start.upperBound...]
            guard let end = current.range(of: "</si>") else { break }
            let chunk = String(current[..<end.lowerBound])
            let text = chunk.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            values.append(text)
            current = current[end.upperBound...]
        }
        return values
    }

    private static func parseSheet(_ xml: String, strings: [String]) -> [[String]] {
        var rows: [[String]] = []
        var current = xml[...]
        while let start = current.range(of: "<row") {
            current = current[start.upperBound...]
            guard let end = current.range(of: "</row>") else { break }
            let rowXML = String(current[..<end.lowerBound])
            rows.append(parseCells(rowXML, strings: strings))
            current = current[end.upperBound...]
        }
        return rows
    }

    private static func parseCells(_ xml: String, strings: [String]) -> [String] {
        var cells: [String] = []
        var current = xml[...]
        while let start = current.range(of: "<c") {
            current = current[start.upperBound...]
            guard let tagEnd = current.range(of: ">") else { break }
            let attrs = String(current[..<tagEnd.lowerBound])
            current = current[tagEnd.upperBound...]
            guard let close = current.range(of: "</c>") else { break }
            let body = String(current[..<close.lowerBound])
            current = current[close.upperBound...]
            let value = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            if attrs.contains("t=\"s\""), let index = Int(value), strings.indices.contains(index) {
                cells.append(strings[index])
            } else {
                cells.append(value)
            }
        }
        return cells
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
                xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(DocxIO.xmlEscape(cell))</t></is></c>"
            }
            xml += "</row>"
        }
        xml += "</sheetData></worksheet>"
        try xml.write(to: sheets.appendingPathComponent("sheet1.xml"), atomically: true, encoding: .utf8)

        let zip = ProcessRunner.run(executable: "/usr/bin/ditto", arguments: ["-c", "-k", "--norsrc", "--noextattr", temp.path, url.path])
        guard zip.exitCode == 0 else { throw RenvertError.converterFailed(String(localized: "Could not write XLSX.")) }
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

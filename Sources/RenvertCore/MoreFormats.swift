import Foundation
import AppKit

// MARK: - Bookmarks

enum Bookmarks {
    static func convert(from source: URL, detected: FormatID, to format: FormatID, destination: URL) throws {
        let link = try read(source, format: detected)
        guard !link.isEmpty else { throw RenvertError.invalidInput(L("No link was found.")) }
        switch format {
        case .txt:
            try (link + "\n").write(to: destination, atomically: true, encoding: .utf8)
        case .json:
            let data = try JSONSerialization.data(withJSONObject: ["url": link], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination)
        case .webloc:
            let data = try PropertyListSerialization.data(fromPropertyList: ["URL": link], format: .xml, options: 0)
            try data.write(to: destination)
        case .url:
            try "[InternetShortcut]\nURL=\(link)\n".write(to: destination, atomically: true, encoding: .utf8)
        default:
            throw RenvertError.unsupportedConversion(from: detected.rawValue, to: format.rawValue)
        }
    }

    private static func read(_ url: URL, format: FormatID) throws -> String {
        switch format {
        case .webloc:
            let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
            let record = object as? [String: Any]
            return (record?["URL"] as? String) ?? (record?["url"] as? String) ?? ""
        case .url:
            let text = DelimitedText.decode(try Data(contentsOf: url))
            for line in text.split(whereSeparator: \.isNewline) {
                let pair = String(line)
                let lower = pair.lowercased()
                guard lower.hasPrefix("url=") else { continue }
                return String(pair.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            }
            return ""
        case .json:
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            if let text = object as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
            let record = object as? [String: Any]
            return (record?["url"] as? String) ?? (record?["URL"] as? String) ?? ""
        default:
            return DelimitedText.decode(try Data(contentsOf: url)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

// MARK: - Feeds

struct FeedItem {
    var title = ""
    var link = ""
    var summary = ""
    var date = ""

    var record: [String: String] {
        var item: [String: String] = [:]
        if !title.isEmpty { item["title"] = title }
        if !link.isEmpty { item["link"] = link }
        if !summary.isEmpty { item["summary"] = summary }
        if !date.isEmpty { item["date"] = date }
        return item
    }
}

enum Feeds {
    static func convert(from source: URL, detected: FormatID, to format: FormatID, destination: URL) throws {
        let items = try read(source, format: detected)
        guard !items.isEmpty else { throw RenvertError.invalidInput(L("No feed items were found.")) }
        switch format {
        case .json:
            let data = try JSONSerialization.data(withJSONObject: items.map(\.record), options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination)
        case .rss:
            try writeRSS(items).write(to: destination, atomically: true, encoding: .utf8)
        case .atom:
            try writeAtom(items).write(to: destination, atomically: true, encoding: .utf8)
        default:
            throw RenvertError.unsupportedConversion(from: detected.rawValue, to: format.rawValue)
        }
    }

    private static func read(_ url: URL, format: FormatID) throws -> [FeedItem] {
        switch format {
        case .rss, .atom:
            let parser = FeedParser()
            let xml = XMLParser(data: try Data(contentsOf: url))
            xml.delegate = parser
            guard xml.parse() else { throw RenvertError.invalidInput(L("The feed could not be read.")) }
            return parser.items
        case .json:
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            let list: [Any]
            if let array = object as? [Any] {
                list = array
            } else if let record = object as? [String: Any], let items = record["items"] as? [Any] {
                list = items
            } else {
                list = []
            }
            return list.compactMap { raw in
                guard let record = raw as? [String: Any] else { return nil }
                var item = FeedItem()
                item.title = text(record["title"])
                item.link = text(record["link"]).isEmpty ? text(record["url"]) : text(record["link"])
                item.summary = text(record["summary"]).isEmpty ? text(record["description"]) : text(record["summary"])
                item.date = text(record["date"]).isEmpty ? text(record["pubDate"]) : text(record["date"])
                return item.title.isEmpty && item.link.isEmpty ? nil : item
            }
        default:
            throw RenvertError.unsupportedConversion(from: format.rawValue, to: "feed")
        }
    }

    private static func writeRSS(_ items: [FeedItem]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rss version=\"2.0\"><channel><title>Renvert</title>\n"
        for item in items {
            xml += "<item><title>\(escape(item.title))</title>"
            if !item.link.isEmpty { xml += "<link>\(escape(item.link))</link>" }
            if !item.summary.isEmpty { xml += "<description>\(escape(item.summary))</description>" }
            if !item.date.isEmpty { xml += "<pubDate>\(escape(item.date))</pubDate>" }
            xml += "</item>\n"
        }
        xml += "</channel></rss>\n"
        return xml
    }

    private static func writeAtom(_ items: [FeedItem]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Renvert</title>\n"
        for item in items {
            xml += "<entry><title>\(escape(item.title))</title>"
            if !item.link.isEmpty { xml += "<link href=\"\(escape(item.link))\"/>" }
            if !item.summary.isEmpty { xml += "<summary>\(escape(item.summary))</summary>" }
            if !item.date.isEmpty { xml += "<updated>\(escape(item.date))</updated>" }
            xml += "</entry>\n"
        }
        xml += "</feed>\n"
        return xml
    }

    private static func text(_ value: Any?) -> String {
        (value as? String) ?? ""
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

final class FeedParser: NSObject, XMLParserDelegate {
    var items: [FeedItem] = []
    private var item: FeedItem?
    private var text = ""
    private var linkHref = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        text = ""
        let name = local(elementName)
        if name == "item" || name == "entry" { item = FeedItem() }
        if name == "link" { linkHref = attributes["href"] ?? "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = local(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var current = item else { return }
        switch name {
        case "title": current.title = value
        case "link": current.link = linkHref.isEmpty ? value : linkHref
        case "description", "summary": if current.summary.isEmpty { current.summary = value }
        case "pubdate", "updated", "published": current.date = value
        case "item", "entry":
            if !current.title.isEmpty || !current.link.isEmpty { items.append(current) }
            item = nil
            return
        default: break
        }
        item = current
    }

    private func local(_ name: String) -> String {
        name.split(separator: ":").last.map { $0.lowercased() } ?? name.lowercased()
    }
}

// MARK: - Playlists

struct PlaylistEntry {
    var title = ""
    var url = ""
    var seconds = ""
}

enum Playlists {
    static func convert(from source: URL, detected: FormatID, to format: FormatID, destination: URL) throws {
        let entries = try read(source, format: detected)
        guard !entries.isEmpty else { throw RenvertError.invalidInput(L("No playlist entries were found.")) }
        switch format {
        case .m3u:
            try write(entries).write(to: destination, atomically: true, encoding: .utf8)
        case .cue:
            try writeCue(entries).write(to: destination, atomically: true, encoding: .utf8)
        case .json:
            let data = try JSONSerialization.data(
                withJSONObject: entries.map { entry -> [String: String] in
                    var item = ["url": entry.url]
                    if !entry.title.isEmpty { item["title"] = entry.title }
                    if !entry.seconds.isEmpty { item["seconds"] = entry.seconds }
                    return item
                },
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: destination)
        case .txt:
            try entries.map(\.url).joined(separator: "\n").appending("\n").write(to: destination, atomically: true, encoding: .utf8)
        default:
            throw RenvertError.unsupportedConversion(from: detected.rawValue, to: format.rawValue)
        }
    }

    private static func read(_ url: URL, format: FormatID) throws -> [PlaylistEntry] {
        switch format {
        case .m3u:
            return parse(DelimitedText.decode(try Data(contentsOf: url)))
        case .cue:
            return parseCue(DelimitedText.decode(try Data(contentsOf: url)))
        case .json:
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            let list = (object as? [Any]) ?? []
            return list.compactMap { raw in
                if let text = raw as? String {
                    let url = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return url.isEmpty ? nil : PlaylistEntry(url: url)
                }
                guard let record = raw as? [String: Any] else { return nil }
                let link = (record["url"] as? String) ?? ""
                guard !link.isEmpty else { return nil }
                return PlaylistEntry(title: record["title"] as? String ?? "", url: link, seconds: record["seconds"].map { "\($0)" } ?? "")
            }
        case .txt:
            return DelimitedText.decode(try Data(contentsOf: url)).split(whereSeparator: \.isNewline).compactMap { line in
                let url = line.trimmingCharacters(in: .whitespaces)
                guard !url.isEmpty, !url.hasPrefix("#") else { return nil }
                return PlaylistEntry(url: url)
            }
        default:
            throw RenvertError.unsupportedConversion(from: format.rawValue, to: "playlist")
        }
    }

    private static func parse(_ text: String) -> [PlaylistEntry] {
        var entries: [PlaylistEntry] = []
        var pending: PlaylistEntry?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.uppercased().hasPrefix("#EXTINF:") {
                let payload = line.dropFirst("#EXTINF:".count)
                let parts = payload.split(separator: ",", maxSplits: 1).map(String.init)
                pending = PlaylistEntry(title: parts.count > 1 ? parts[1] : "", seconds: parts.first ?? "")
                continue
            }
            if line.hasPrefix("#") { continue }
            var entry = pending ?? PlaylistEntry()
            entry.url = line
            entries.append(entry)
            pending = nil
        }
        return entries
    }

    private static func write(_ entries: [PlaylistEntry]) -> String {
        var lines = ["#EXTM3U"]
        for entry in entries {
            if !entry.title.isEmpty || !entry.seconds.isEmpty {
                lines.append("#EXTINF:\(entry.seconds.isEmpty ? "-1" : entry.seconds),\(entry.title)")
            }
            lines.append(entry.url)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func parseCue(_ text: String) -> [PlaylistEntry] {
        var file = ""
        var entries: [PlaylistEntry] = []
        var current: PlaylistEntry?
        func commit() {
            guard var entry = current else { return }
            if entry.url.isEmpty { entry.url = file }
            if !entry.title.isEmpty || !entry.url.isEmpty { entries.append(entry) }
            current = nil
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()
            if upper.hasPrefix("FILE ") {
                commit()
                file = quoted(line) ?? ""
            } else if upper.hasPrefix("TRACK ") {
                commit()
                current = PlaylistEntry(url: file)
            } else if upper.hasPrefix("TITLE ") {
                if current == nil { current = PlaylistEntry(url: file) }
                current?.title = quoted(line) ?? String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if upper.hasPrefix("INDEX ") {
                current?.seconds = line.split(separator: " ").last.map(String.init) ?? ""
            }
        }
        commit()
        return entries
    }

    private static func quoted(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "\""), let close = line[line.index(after: open)...].firstIndex(of: "\"") else { return nil }
        return String(line[line.index(after: open)..<close])
    }

    private static func writeCue(_ entries: [PlaylistEntry]) -> String {
        var lines: [String] = []
        for (index, entry) in entries.enumerated() {
            let file = entry.url.isEmpty ? "audio.wav" : entry.url
            lines.append("FILE \"\(file)\" WAVE")
            lines.append(String(format: "  TRACK %02d AUDIO", index + 1))
            if !entry.title.isEmpty { lines.append("    TITLE \"\(entry.title)\"") }
            lines.append("    INDEX 01 \(cueStamp(entry.seconds))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func cueStamp(_ seconds: String) -> String {
        if seconds.contains(":") { return seconds }
        let total = Int(Double(seconds) ?? 0)
        return String(format: "%02d:%02d:00", total / 60, total % 60)
    }
}

// MARK: - Bibliography

enum Bibliographies {
    struct Entry {
        var type: String
        var citation: String
        var fields: [String: String]
    }

    static func convert(from source: URL, detected: FormatID, to format: FormatID, destination: URL) throws {
        let entries = try read(source, format: detected)
        guard !entries.isEmpty else { throw RenvertError.invalidInput(L("No bibliography entries were found.")) }
        switch format {
        case .json:
            let objects = entries.map { entry -> [String: String] in
                var object = entry.fields
                object["type"] = entry.type
                object["citation"] = entry.citation
                return object
            }
            let data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination)
        case .csv:
            let extras = Set(entries.flatMap { $0.fields.keys }).subtracting(["type", "citation"]).sorted()
            let headers = ["type", "citation"] + extras
            let rows = [headers] + entries.map { entry in
                headers.map { column in
                    if column == "type" { return entry.type }
                    if column == "citation" { return entry.citation }
                    return entry.fields[column] ?? ""
                }
            }
            try DelimitedText.serialize(rows, delimiter: ",").write(to: destination, atomically: true, encoding: .utf8)
        case .bib:
            try write(entries).write(to: destination, atomically: true, encoding: .utf8)
        default:
            throw RenvertError.unsupportedConversion(from: detected.rawValue, to: format.rawValue)
        }
    }

    private static func read(_ url: URL, format: FormatID) throws -> [Entry] {
        switch format {
        case .bib:
            return parse(DelimitedText.decode(try Data(contentsOf: url)))
        case .json:
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            return (object as? [Any] ?? []).compactMap { raw in
                guard let record = raw as? [String: Any] else { return nil }
                var fields: [String: String] = [:]
                for (key, value) in record where key != "type" && key != "citation" {
                    fields[key] = "\(value)"
                }
                let type = (record["type"] as? String) ?? "misc"
                let citation = (record["citation"] as? String) ?? (record["key"] as? String) ?? "item"
                return Entry(type: type, citation: citation, fields: fields)
            }
        case .csv:
            let rows = DelimitedText.parse(DelimitedText.decode(try Data(contentsOf: url)), delimiter: ",")
            guard let headers = rows.first else { return [] }
            return rows.dropFirst().map { row in
                var fields: [String: String] = [:]
                for (index, header) in headers.enumerated() where index < row.count && header != "type" && header != "citation" {
                    fields[header] = row[index]
                }
                let type = column("type", headers: headers, row: row)
                let citation = column("citation", headers: headers, row: row)
                return Entry(type: type.isEmpty ? "misc" : type, citation: citation.isEmpty ? "item" : citation, fields: fields)
            }
        default:
            throw RenvertError.unsupportedConversion(from: format.rawValue, to: "bibliography")
        }
    }

    private static func column(_ name: String, headers: [String], row: [String]) -> String {
        guard let index = headers.firstIndex(of: name), index < row.count else { return "" }
        return row[index]
    }

    private static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        var rest = Substring(text)
        while let at = rest.firstIndex(of: "@") {
            rest = rest[rest.index(after: at)...]
            guard let brace = rest.firstIndex(of: "{") else { break }
            let type = rest[..<brace].filter { !$0.isWhitespace }.lowercased()
            rest = rest[rest.index(after: brace)...]
            guard let comma = rest.firstIndex(of: ",") else { break }
            let citation = rest[..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
            rest = rest[rest.index(after: comma)...]
            var depth = 1
            var body = ""
            var index = rest.startIndex
            while index < rest.endIndex {
                let character = rest[index]
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        index = rest.index(after: index)
                        break
                    }
                }
                body.append(character)
                index = rest.index(after: index)
            }
            rest = rest[index...]
            if !type.isEmpty {
                entries.append(Entry(type: String(type), citation: String(citation), fields: fields(in: body)))
            }
        }
        return entries
    }

    private static func fields(in body: String) -> [String: String] {
        var fields: [String: String] = [:]
        var depth = 0
        var current = ""
        func store() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = piece.firstIndex(of: "=") else { return }
            let name = piece[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, (value.hasPrefix("{") && value.hasSuffix("}")) || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
                value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !name.isEmpty { fields[String(name)] = String(value) }
        }
        for character in body {
            if character == "{" { depth += 1 }
            if character == "}" && depth > 0 { depth -= 1; current.append(character); continue }
            if character == "," && depth == 0 {
                store()
                current = ""
            } else {
                current.append(character)
            }
        }
        store()
        return fields
    }

    private static func write(_ entries: [Entry]) -> String {
        entries.map { entry in
            let body = entry.fields.keys.sorted().map { "  \($0) = {\(entry.fields[$0] ?? "")}" }.joined(separator: ",\n")
            return "@\(entry.type){\(entry.citation),\n\(body)\n}\n"
        }.joined(separator: "\n")
    }
}

// MARK: - Directories

enum Directories {
    static func convert(from source: URL, detected: FormatID, to format: FormatID, destination: URL) throws {
        let records = try read(source, format: detected)
        guard !records.isEmpty else { throw RenvertError.invalidInput(L("No directory entries were found.")) }
        switch format {
        case .json:
            let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination)
        case .csv:
            var headers = records.flatMap(\.keys).reduce(into: [String]()) { list, key in
                if !list.contains(key) { list.append(key) }
            }.sorted()
            if let dn = headers.firstIndex(of: "dn") { headers.remove(at: dn); headers.insert("dn", at: 0) }
            let rows = [headers] + records.map { record in headers.map { record[$0] ?? "" } }
            try DelimitedText.serialize(rows, delimiter: ",").write(to: destination, atomically: true, encoding: .utf8)
        case .ldif:
            let text = records.map { record in
                var keys = record.keys.sorted()
                if let dn = keys.firstIndex(of: "dn") { keys.remove(at: dn); keys.insert("dn", at: 0) }
                return keys.map { "\($0): \(record[$0] ?? "")" }.joined(separator: "\n")
            }.joined(separator: "\n\n")
            try (text + "\n").write(to: destination, atomically: true, encoding: .utf8)
        default:
            throw RenvertError.unsupportedConversion(from: detected.rawValue, to: format.rawValue)
        }
    }

    private static func read(_ url: URL, format: FormatID) throws -> [[String: String]] {
        switch format {
        case .ldif:
            return parse(DelimitedText.decode(try Data(contentsOf: url)))
        case .json:
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            return (object as? [[String: Any]] ?? []).map { record in
                record.mapValues { "\($0)" }
            }
        case .csv:
            let rows = DelimitedText.parse(DelimitedText.decode(try Data(contentsOf: url)), delimiter: ",")
            guard let headers = rows.first else { return [] }
            return rows.dropFirst().map { row in
                var record: [String: String] = [:]
                for (index, header) in headers.enumerated() where index < row.count && !row[index].isEmpty {
                    record[header] = row[index]
                }
                return record
            }.filter { !$0.isEmpty }
        default:
            throw RenvertError.unsupportedConversion(from: format.rawValue, to: "directory")
        }
    }

    private static func parse(_ text: String) -> [[String: String]] {
        var records: [[String: String]] = []
        var current: [String: String] = [:]
        var last = ""
        func commit() {
            if !current.isEmpty { records.append(current) }
            current = [:]
            last = ""
        }
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { commit(); continue }
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !last.isEmpty {
                current[last, default: ""] += line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix(":") { value = "" }
            if let existing = current[key], !existing.isEmpty {
                current[key] = existing + "; " + value
            } else {
                current[key] = value
            }
            last = key
        }
        commit()
        return records
    }
}

// MARK: - Palettes

struct Swatch {
    var name: String
    var red: Double
    var green: Double
    var blue: Double

    var hex: String {
        String(format: "#%02X%02X%02X", channel(red), channel(green), channel(blue))
    }

    func channel(_ value: Double) -> Int {
        min(255, max(0, Int((value * 255).rounded())))
    }
}

enum Palettes {
    static func convert(from source: URL, detected: FormatID, to format: FormatID, destination: URL) throws {
        let colors = try read(source, format: detected)
        guard !colors.isEmpty else { throw RenvertError.invalidInput(L("No colors were found.")) }
        switch format {
        case .gpl:
            try writeGPL(colors).write(to: destination, atomically: true, encoding: .utf8)
        case .hex:
            try colors.map { "\($0.hex) \($0.name)" }.joined(separator: "\n").appending("\n")
                .write(to: destination, atomically: true, encoding: .utf8)
        case .css:
            try writeCSS(colors).write(to: destination, atomically: true, encoding: .utf8)
        case .json:
            let objects = colors.map { ["name": $0.name, "hex": $0.hex] }
            let data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination)
        case .clr:
            try writeCLR(colors, to: destination)
        default:
            throw RenvertError.unsupportedConversion(from: detected.rawValue, to: format.rawValue)
        }
    }

    private static func read(_ url: URL, format: FormatID) throws -> [Swatch] {
        switch format {
        case .gpl:
            return parseGPL(DelimitedText.decode(try Data(contentsOf: url)))
        case .hex:
            return parseHex(DelimitedText.decode(try Data(contentsOf: url)))
        case .css:
            return parseCSS(DelimitedText.decode(try Data(contentsOf: url)))
        case .clr:
            return readCLR(url)
        case .json:
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            return (object as? [Any] ?? []).compactMap { raw in
                guard let record = raw as? [String: Any] else { return nil }
                if let hex = record["hex"] as? String, let color = color(hex) {
                    return Swatch(name: record["name"] as? String ?? "", red: color.0, green: color.1, blue: color.2)
                }
                if let red = record["red"] as? Double, let green = record["green"] as? Double, let blue = record["blue"] as? Double {
                    return Swatch(name: record["name"] as? String ?? "", red: red, green: green, blue: blue)
                }
                return nil
            }
        default:
            throw RenvertError.unsupportedConversion(from: format.rawValue, to: "palette")
        }
    }

    private static func parseGPL(_ text: String) -> [Swatch] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 3, let red = Int(parts[0]), let green = Int(parts[1]), let blue = Int(parts[2]),
                  (0...255).contains(red), (0...255).contains(green), (0...255).contains(blue) else { return nil }
            let name = parts.dropFirst(3).joined(separator: " ")
            return Swatch(name: name, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
        }
    }

    private static func parseHex(_ text: String) -> [Swatch] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = parts.first, let color = color(first) else { return nil }
            return Swatch(name: parts.dropFirst().joined(separator: " "), red: color.0, green: color.1, blue: color.2)
        }
    }

    private static func parseCSS(_ text: String) -> [Swatch] {
        var colors: [Swatch] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let nameStart = line.firstIndex(of: "-"), line[nameStart...].hasPrefix("--") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.index(nameStart, offsetBy: 2)..<colon].trimmingCharacters(in: .whitespaces)
            guard let hex = colorToken(in: String(line[colon...])), let channels = color(hex) else { continue }
            colors.append(Swatch(name: name, red: channels.0, green: channels.1, blue: channels.2))
        }
        return colors
    }

    private static func colorToken(in text: String) -> String? {
        guard let hash = text.firstIndex(of: "#") else { return nil }
        let tail = text[hash...]
        let hex = tail.prefix { $0 == "#" || $0.isHexDigit }
        return String(hex)
    }

    private static func color(_ raw: String) -> (Double, Double, Double)? {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 3, hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let value = Int(hex, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    private static func writeGPL(_ colors: [Swatch]) -> String {
        var lines = ["GIMP Palette", "Name: Renvert", "#"]
        for color in colors {
            lines.append("\(color.channel(color.red)) \(color.channel(color.green)) \(color.channel(color.blue)) \(color.name)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func writeCSS(_ colors: [Swatch]) -> String {
        var used: Set<String> = []
        var lines = [":root {"]
        for color in colors {
            let token = color.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            var name = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if name.isEmpty { name = color.hex.dropFirst().lowercased() }
            var unique = name
            var number = 2
            while used.contains(unique) {
                unique = "\(name)-\(number)"
                number += 1
            }
            used.insert(unique)
            lines.append("  --\(unique): \(color.hex.lowercased());")
        }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func writeCLR(_ colors: [Swatch], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let list = NSColorList(name: "Renvert")
        var used: Set<String> = []
        for (index, swatch) in colors.enumerated() {
            var key = swatch.name.isEmpty ? "Color \(index + 1)" : swatch.name
            if used.contains(key) { key = "\(key) \(index + 1)" }
            used.insert(key)
            let color = NSColor(srgbRed: swatch.red, green: swatch.green, blue: swatch.blue, alpha: 1)
            list.setColor(color, forKey: key)
        }
        try list.write(to: url)
    }

    private static func readCLR(_ url: URL) -> [Swatch] {
        guard let list = NSColorList(name: "RenvertRead", fromFile: url.path) else { return [] }
        return list.allKeys.compactMap { key in
            guard let color = list.color(withKey: key)?.usingColorSpace(.sRGB) else { return nil }
            return Swatch(name: key, red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
        }
    }
}

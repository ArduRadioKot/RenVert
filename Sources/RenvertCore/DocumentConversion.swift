import Foundation
import AppKit
import PDFKit

public struct DocumentConverter: Converter {
    public init() {}

    public func convert(from source: URL, detected: FormatID, spec: OutputSpec, to destination: URL, context: ConversionContext) throws {
        try context.cancellation.throwIfCancelled()
        if detected == .pdf && imageEncodable.contains(spec.format) {
            try renderPDFPage(source, spec: spec, to: destination, context: context)
            return
        }
        if spec.hasOCR {
            try IntelligenceConverter().convert(from: source, detected: detected, spec: spec, to: destination, context: context)
            return
        }

        if [.csv, .tsv, .xlsx].contains(detected), [.txt, .markdown].contains(spec.format) {
            let rows = try SpreadsheetConverter().loadTable(source, format: detected)
            let text = spec.format == .markdown ? Self.markdownTable(rows) : Self.plainTable(rows)
            try text.write(to: destination, atomically: true, encoding: .utf8)
            context.onProgress?(1)
            return
        }
        if detected == .pdf, [.txt, .markdown, .docx, .rtf, .html, .doc, .odt].contains(spec.format),
           try pdfText(source, spec: spec).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A scan has no text layer; recognize the pages instead of writing an empty file.
            var ocrSpec = spec
            ocrSpec.format = [.txt, .markdown, .docx].contains(spec.format) ? spec.format : .txt
            if ocrSpec.format == spec.format {
                try IntelligenceConverter().convert(from: source, detected: detected, spec: spec, to: destination, context: context)
                return
            }
            let recognized = destination.deletingLastPathComponent().appendingPathComponent(".renvert-ocr-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: recognized) }
            try IntelligenceConverter().convert(from: source, detected: detected, spec: ocrSpec, to: recognized, context: context)
            let text = try String(contentsOf: recognized, encoding: .utf8)
            try writeAttributed(NSAttributedString(string: text, attributes: Self.bodyAttributes), spec: spec, to: destination)
            context.onProgress?(1)
            return
        }

        let attributed = try loadAttributed(source, format: detected, spec: spec)
        context.onProgress?(0.4)
        try writeAttributed(attributed, spec: spec, to: destination)
        context.onProgress?(1)
    }

    private func loadAttributed(_ url: URL, format: FormatID, spec: OutputSpec) throws -> NSAttributedString {
        switch format {
        case .txt, .markdown, .rst, .org, .adoc:
            let text = DelimitedText.decode(try Data(contentsOf: url))
            return NSAttributedString(string: text, attributes: Self.bodyAttributes)
        case .csv, .tsv, .xlsx:
            let rows = try SpreadsheetConverter().loadTable(url, format: format)
            return try Self.importHTML(Data(Self.htmlTable(rows).utf8))
        case .html:
            let data = try Data(contentsOf: url)
            return try Self.importHTML(data)
        case .rtf:
            let data = try Data(contentsOf: url)
            return try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
        case .rtfd:
            return try NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.rtfd],
                documentAttributes: nil
            )
        case .doc, .odt:
            return try NSAttributedString(
                url: url,
                options: [.documentType: format == .doc
                    ? NSAttributedString.DocumentType.docFormat
                    : NSAttributedString.DocumentType.openDocument],
                documentAttributes: nil
            )
        case .docx:
            // TextKit keeps headings, bold, lists and tables; the plain reader is the fallback.
            if let rich = try? NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                documentAttributes: nil
            ), rich.length > 0 {
                return rich
            }
            return NSAttributedString(string: try DocxIO.readText(url), attributes: Self.bodyAttributes)
        case .pdf:
            return NSAttributedString(string: try pdfText(url, spec: spec), attributes: Self.bodyAttributes)
        case .eml, .emlx:
            return NSAttributedString(string: try MailMessage.read(url, format: format), attributes: Self.bodyAttributes)
        case .opml:
            return NSAttributedString(string: try Outline.read(url), attributes: Self.bodyAttributes)
        default:
            let text = DelimitedText.decode(try Data(contentsOf: url))
            return NSAttributedString(string: text, attributes: Self.bodyAttributes)
        }
    }

    /// AppKit's HTML importer runs on WebKit and must be used on the main thread;
    /// conversions run on a background queue.
    private static func importHTML(_ data: Data) throws -> NSAttributedString {
        func load() throws -> NSAttributedString {
            // No encoding given: the importer honors the page's own charset declaration.
            try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
            )
        }
        if Thread.isMainThread { return try load() }
        var result: Result<NSAttributedString, Error>!
        DispatchQueue.main.sync { result = Result { try load() } }
        return try result.get()
    }

    private static func htmlTable(_ rows: [[String]]) -> String {
        func cell(_ text: String, _ tag: String) -> String {
            let escaped = DocxIO.xmlEscape(text).replacingOccurrences(of: "\n", with: "<br>")
            // Short values stay on one line; otherwise a narrow column breaks them mid-word.
            let wrap = text.count <= 24 ? " nowrap" : ""
            return "<\(tag)\(wrap) style=\"border:1px solid #999;padding:3px 6px;\">\(escaped)</\(tag)>"
        }
        let body = rows.enumerated().map { index, row in
            "<tr>" + row.map { cell($0, index == 0 ? "th" : "td") }.joined() + "</tr>"
        }.joined(separator: "\n")
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"></head>
        <body style="font-family:-apple-system,Helvetica,sans-serif;font-size:10pt;color:#000;">
        <table width="100%" style="border-collapse:collapse;">
        \(body)
        </table></body></html>
        """
    }

    private static func markdownTable(_ rows: [[String]]) -> String {
        guard let header = rows.first else { return "" }
        func line(_ row: [String]) -> String {
            "| " + row.map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |"
        }
        return ([line(header), "|" + header.map { _ in " --- |" }.joined()] + rows.dropFirst().map(line)).joined(separator: "\n") + "\n"
    }

    /// Columns padded to a common width, so the table reads in any text editor.
    private static func plainTable(_ rows: [[String]]) -> String {
        let width = rows.map(\.count).max() ?? 0
        let widths = (0..<width).map { column in rows.map { $0.count > column ? $0[column].count : 0 }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { column, text in
                column == row.count - 1 ? text : text.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ").replacingOccurrences(of: "\n", with: " ")
        }.joined(separator: "\n") + "\n"
    }

    private func writeAttributed(_ attributed: NSAttributedString, spec: OutputSpec, to url: URL) throws {
        switch spec.format {
        case .txt:
            try attributed.string.write(to: url, atomically: true, encoding: .utf8)
        case .markdown, .rst, .org:
            try attributed.string.write(to: url, atomically: true, encoding: .utf8)
        case .html:
            let data = try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
            )
            try data.write(to: url)
        case .rtf:
            let data = try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            try data.write(to: url)
        case .doc, .odt:
            let data = try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: spec.format == .doc
                    ? NSAttributedString.DocumentType.docFormat
                    : NSAttributedString.DocumentType.openDocument]
            )
            try data.write(to: url)
        case .pdf:
            try writePDF(attributed, to: url)
        case .eml:
            try MailMessage.write(attributed.string).write(to: url, atomically: true, encoding: .utf8)
        case .opml:
            try Outline.write(attributed.string).write(to: url, atomically: true, encoding: .utf8)
        case .docx:
            // TextKit writes styling and tables; the plain writer is the fallback.
            if let data = try? attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
            ) {
                try data.write(to: url)
            } else {
                try DocxIO.write(text: attributed.string, to: url)
            }
        default:
            throw RenvertError.unsupportedConversion(from: "document", to: spec.format.rawValue)
        }
    }

    private func writePDF(_ attributed: NSAttributedString, to url: URL) throws {
        // The system paper size: A4 or Letter, whichever this Mac prints on.
        var paper = NSPrintInfo.shared.paperSize
        if paper.width <= 0 || paper.height <= 0 { paper = NSSize(width: 595, height: 842) }
        let page = CGRect(origin: .zero, size: paper)
        let margin: CGFloat = 54
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var offset = 0
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw RenvertError.converterFailed(L("PDF consumer failed."))
        }
        var media = page
        guard let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            throw RenvertError.converterFailed(L("PDF context failed."))
        }
        // Flipped, so lines run top to bottom and the text starts at the top of the page.
        let nsctx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        // Paper is white whatever the system appearance is. Under Dark Mode dynamic colors
        // would otherwise resolve to white text on a white page.
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            repeat {
                let container = NSTextContainer(size: CGSize(width: page.width - margin * 2, height: page.height - margin * 2))
                layout.addTextContainer(container)
                let range = layout.glyphRange(for: container)
                ctx.beginPDFPage(nil)
                ctx.saveGState()
                ctx.translateBy(x: 0, y: page.height)
                ctx.scaleBy(x: 1, y: -1)
                let origin = CGPoint(x: margin, y: margin)
                layout.drawBackground(forGlyphRange: range, at: origin)
                layout.drawGlyphs(forGlyphRange: range, at: origin)
                ctx.restoreGState()
                ctx.endPDFPage()
                // A container that takes no glyphs (an oversized attachment) must not loop forever.
                if range.length == 0 { break }
                offset = NSMaxRange(range)
            } while offset < layout.numberOfGlyphs
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.closePDF()
        try (data as Data).write(to: url)
    }

    /// Renders pages to images: 200 dpi unless `+dpi` says otherwise, on white, cropped and
    /// rotated the way a PDF viewer shows them. Without `+page` every page is rendered; the
    /// first goes to `destination` and the rest are handed to the engine as extra files.
    private func renderPDFPage(_ url: URL, spec: OutputSpec, to destination: URL, context: ConversionContext) throws {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw RenvertError.invalidInput(L("PDF could not be opened."))
        }
        var indices = spec.pages().map { resolvePages($0, count: document.pageCount) } ?? Array(0..<document.pageCount)
        if indices.isEmpty { indices = [0] }
        if context.extraOutputs == nil { indices = [indices[0]] }
        let utType = ImageIOSupport.utType(for: spec.format) ?? .png
        let scale = CGFloat(spec.dpi() ?? 200) / 72.0

        for (position, index) in indices.enumerated() {
            try context.cancellation.throwIfCancelled()
            guard let page = document.page(at: index) else {
                throw RenvertError.invalidInput(L("PDF page is missing."))
            }
            var bounds = page.bounds(for: .cropBox)
            if page.rotation % 180 != 0 {
                bounds.size = CGSize(width: bounds.height, height: bounds.width)
            }
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = ImageRaster.bitmap(pixelSize: size) { rect in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return }
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(rect)
                ctx.saveGState()
                ctx.scaleBy(x: scale, y: scale)
                // PDFKit applies the page's rotation and crop box origin itself.
                page.draw(with: .cropBox, to: ctx)
                ctx.restoreGState()
            }
            let target: URL
            if position == 0 {
                target = destination
            } else {
                target = destination.deletingLastPathComponent()
                    .appendingPathComponent(".renvert-\(UUID().uuidString).\(destination.pathExtension)")
                context.extraOutputs?.add(target)
            }
            try ImageConverter().writeImage(image, to: target, utType: utType, spec: spec, settings: context.settings)
            context.onProgress?(Double(position + 1) / Double(indices.count))
        }
    }

    private func pdfText(_ url: URL, spec: OutputSpec) throws -> String {
        guard let document = PDFDocument(url: url) else { throw RenvertError.invalidInput(L("PDF could not be opened.")) }
        var indices = Array(0..<document.pageCount)
        if let pages = spec.pages() {
            indices = resolvePages(pages, count: document.pageCount)
        }
        return indices.compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
    }

    private func resolvePages(_ selection: PageSelection, count: Int) -> [Int] {
        switch selection {
        case .single(let page): return [min(max(page - 1, 0), count - 1)]
        case .closed(let range): return range.map { $0 - 1 }.filter { $0 >= 0 && $0 < count }
        case .from(let start): return Array((start - 1)..<count).filter { $0 >= 0 }
        case .through(let end): return Array(0..<min(end, count))
        }
    }

    private static let bodyAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12),
        // Fixed black: documents are written for white paper, not for the app's appearance.
        .foregroundColor: NSColor.black
    ]
}

enum DocxIO {
    static func readText(_ url: URL) throws -> String {
        let result = ProcessRunner.run(executable: "/usr/bin/unzip", arguments: ["-p", url.path, "word/document.xml"])
        guard result.exitCode == 0 else { throw RenvertError.invalidInput(L("Not a readable DOCX file.")) }
        return extractDocxText(result.stdout)
    }

    static func write(text: String, to url: URL) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("renvert-docx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """.write(to: temp.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)

        let rels = temp.appendingPathComponent("_rels", isDirectory: true)
        try FileManager.default.createDirectory(at: rels, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """.write(to: rels.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)

        let word = temp.appendingPathComponent("word", isDirectory: true)
        try FileManager.default.createDirectory(at: word, withIntermediateDirectories: true)
        let paragraphs = text.components(separatedBy: "\n").map { line in
            let escaped = xmlEscape(line)
            return "<w:p><w:r><w:t xml:space=\"preserve\">\(escaped)</w:t></w:r></w:p>"
        }.joined()
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>\(paragraphs)<w:sectPr/></w:body>
        </w:document>
        """.write(to: word.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)

        let zip = ProcessRunner.run(
            executable: "/usr/bin/ditto",
            arguments: ["-c", "-k", "--norsrc", "--noextattr", temp.path, url.path]
        )
        guard zip.exitCode == 0 else { throw RenvertError.converterFailed(L("Could not write DOCX.")) }
    }

    static func extractDocxText(_ xml: String) -> String {
        var text = ""
        var current = xml[...]
        while let start = current.range(of: "<w:t") {
            current = current[start.upperBound...]
            guard let close = current.range(of: ">") else { break }
            current = current[close.upperBound...]
            guard let end = current.range(of: "</w:t>") else { break }
            text += current[..<end.lowerBound]
            current = current[end.upperBound...]
            if current.hasPrefix("<w:p") || current.contains("<w:p") {
                // paragraph breaks are handled below
            }
        }
        return xml
            .replacingOccurrences(of: "</w:p>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func xmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

enum MailMessage {
    static func read(_ url: URL, format: FormatID) throws -> String {
        var data = try Data(contentsOf: url)
        if format == .emlx {
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                throw RenvertError.invalidInput(L("The message could not be read."))
            }
            let rest = text.drop { $0 != "\n" }.dropFirst()
            data = Data(rest.utf8)
        }
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw RenvertError.invalidInput(L("The message could not be read."))
        }
        let parts = splitHeader(raw)
        let headers = headerMap(parts.header)
        let body = decodedBody(parts.body, headers: headers)
        var lines: [String] = []
        for key in ["From", "To", "Subject", "Date"] {
            if let value = headers[key.lowercased()] { lines.append("\(key): \(value)") }
        }
        if !lines.isEmpty { lines.append("") }
        lines.append(body.trimmingCharacters(in: .whitespacesAndNewlines))
        return lines.joined(separator: "\n")
    }

    static func write(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Message"
        return """
        From: Renvert
        Subject: \(subject.prefix(80))
        MIME-Version: 1.0
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: 8bit

        \(trimmed)
        """
    }

    private static func splitHeader(_ raw: String) -> (header: String, body: String) {
        if let range = raw.range(of: "\r\n\r\n") { return (String(raw[..<range.lowerBound]), String(raw[range.upperBound...])) }
        if let range = raw.range(of: "\n\n") { return (String(raw[..<range.lowerBound]), String(raw[range.upperBound...])) }
        return ("", raw)
    }

    private static func headerMap(_ header: String) -> [String: String] {
        var map: [String: String] = [:]
        var current = ""
        var key = ""
        for line in header.split(separator: "\n", omittingEmptySubsequences: false).map({ $0.trimmingCharacters(in: .init(charactersIn: "\r")) }) {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                current += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            if !key.isEmpty { map[key.lowercased()] = current }
            let bits = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard bits.count == 2 else { key = ""; continue }
            key = bits[0]
            current = bits[1].trimmingCharacters(in: .whitespaces)
        }
        if !key.isEmpty { map[key.lowercased()] = current }
        return map
    }

    private static func decodedBody(_ body: String, headers: [String: String]) -> String {
        let type = headers["content-type"]?.lowercased() ?? ""
        if type.contains("multipart/"), let boundary = type.split(separator: "boundary=").last.map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t")) }) {
            let chunks = body.components(separatedBy: "--\(boundary)")
            let plain = chunks.first { $0.lowercased().contains("text/plain") }
            let html = chunks.first { $0.lowercased().contains("text/html") }
            if let part = plain ?? html { return decodedBody(partBody(part), headers: headerMap(part)) }
        }
        let encoding = headers["content-transfer-encoding"]?.lowercased() ?? ""
        if encoding.contains("base64"), let data = Data(base64Encoded: body.filter { !$0.isWhitespace }) {
            return String(data: data, encoding: .utf8) ?? body
        }
        if encoding.contains("quoted-printable") { return quotedPrintable(body) }
        if type.contains("text/html") { return body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
        return body
    }

    private static func partBody(_ part: String) -> String {
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "\n\n") { return String(trimmed[range.upperBound...]) }
        return trimmed
    }

    private static func quotedPrintable(_ text: String) -> String {
        var bytes: [UInt8] = []
        let scalars = Array(text.utf8)
        var index = 0
        while index < scalars.count {
            if scalars[index] == UInt8(ascii: "=") {
                if index + 1 < scalars.count, scalars[index + 1] == 10 {
                    index += 2
                    continue
                }
                if index + 2 < scalars.count, scalars[index + 1] == 13, scalars[index + 2] == 10 {
                    index += 3
                    continue
                }
                if index + 2 < scalars.count,
                   let value = UInt8(String(bytes: scalars[index + 1...index + 2], encoding: .ascii) ?? "", radix: 16) {
                    bytes.append(value)
                    index += 3
                    continue
                }
            }
            bytes.append(scalars[index])
            index += 1
        }
        return String(bytes: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
    }
}

enum Outline {
    static func read(_ url: URL) throws -> String {
        let parser = OutlineParser()
        let xml = XMLParser(data: try Data(contentsOf: url))
        xml.delegate = parser
        guard xml.parse() else { throw RenvertError.invalidInput(L("The outline could not be read.")) }
        return parser.lines.joined(separator: "\n") + (parser.lines.isEmpty ? "" : "\n")
    }

    static func write(_ text: String) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\"><body>\n"
        var open = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count / 2
            let title = raw.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            while open > indent { xml += "</outline>\n"; open -= 1 }
            xml += "<outline text=\"\(DocxIO.xmlEscape(title))\">\n"
            open += 1
        }
        while open > 0 { xml += "</outline>\n"; open -= 1 }
        xml += "</body></opml>\n"
        return xml
    }
}

final class OutlineParser: NSObject, XMLParserDelegate {
    var lines: [String] = []
    private var depth = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? ""
        guard name == "outline" else { return }
        let title = attributes["text"] ?? attributes["title"] ?? ""
        if !title.isEmpty {
            lines.append(String(repeating: "  ", count: depth) + title)
        }
        depth += 1
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? ""
        if name == "outline" { depth = max(0, depth - 1) }
    }
}

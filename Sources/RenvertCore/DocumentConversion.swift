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

        let attributed = try loadAttributed(source, format: detected, spec: spec)
        context.onProgress?(0.4)
        try writeAttributed(attributed, spec: spec, to: destination)
        context.onProgress?(1)
    }

    private func loadAttributed(_ url: URL, format: FormatID, spec: OutputSpec) throws -> NSAttributedString {
        switch format {
        case .txt, .markdown, .rst, .org, .adoc:
            let text = try String(contentsOf: url, encoding: .utf8)
            return NSAttributedString(string: text, attributes: Self.bodyAttributes)
        case .html:
            let data = try Data(contentsOf: url)
            return try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
            )
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
        case .docx:
            return NSAttributedString(string: try DocxIO.readText(url), attributes: Self.bodyAttributes)
        case .pdf:
            return NSAttributedString(string: try pdfText(url, spec: spec), attributes: Self.bodyAttributes)
        default:
            let text = try String(contentsOf: url, encoding: .utf8)
            return NSAttributedString(string: text, attributes: Self.bodyAttributes)
        }
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
        case .pdf:
            try writePDF(attributed, to: url)
        case .docx:
            try DocxIO.write(text: attributed.string, to: url)
        default:
            throw RenvertError.unsupportedConversion(from: "document", to: spec.format.rawValue)
        }
    }

    private func writePDF(_ attributed: NSAttributedString, to url: URL) throws {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var offset = 0
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw RenvertError.converterFailed(String(localized: "PDF consumer failed."))
        }
        var media = page
        guard let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            throw RenvertError.converterFailed(String(localized: "PDF context failed."))
        }
        let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        while offset < layout.numberOfGlyphs {
            let container = NSTextContainer(size: CGSize(width: page.width - 72, height: page.height - 72))
            layout.addTextContainer(container)
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 36, y: 36)
            layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: .zero)
            ctx.restoreGState()
            ctx.endPDFPage()
            offset = NSMaxRange(layout.glyphRange(for: container))
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.closePDF()
        try (data as Data).write(to: url)
    }

    private func renderPDFPage(_ url: URL, spec: OutputSpec, to destination: URL, context: ConversionContext) throws {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw RenvertError.invalidInput(String(localized: "PDF could not be opened."))
        }
        let pageIndex: Int
        if case .single(let page) = spec.pages() {
            pageIndex = max(0, page - 1)
        } else {
            pageIndex = 0
        }
        guard let page = document.page(at: min(pageIndex, document.pageCount - 1)) else {
            throw RenvertError.invalidInput(String(localized: "PDF page is missing."))
        }
        let dpi = spec.dpi() ?? 144
        let bounds = page.bounds(for: .mediaBox)
        let scale = CGFloat(dpi) / 72.0
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }
        image.unlockFocus()
        try ImageConverter().writeImage(
            image,
            to: destination,
            utType: ImageIOSupport.utType(for: spec.format) ?? .png,
            spec: spec,
            settings: context.settings
        )
    }

    private func pdfText(_ url: URL, spec: OutputSpec) throws -> String {
        guard let document = PDFDocument(url: url) else { throw RenvertError.invalidInput(String(localized: "PDF could not be opened.")) }
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
        .foregroundColor: NSColor.textColor
    ]
}

enum DocxIO {
    static func readText(_ url: URL) throws -> String {
        let result = ProcessRunner.run(executable: "/usr/bin/unzip", arguments: ["-p", url.path, "word/document.xml"])
        guard result.exitCode == 0 else { throw RenvertError.invalidInput(String(localized: "Not a readable DOCX file.")) }
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
        guard zip.exitCode == 0 else { throw RenvertError.converterFailed(String(localized: "Could not write DOCX.")) }
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

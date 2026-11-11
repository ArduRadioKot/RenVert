import XCTest
import AppKit
@testable import RenvertCore

/// Drives the real rename flow for every document, table and config pair a user can ask for.
final class MatrixTests: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("renvert-matrix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    static let marker = "Renvertmarker"

    /// Writes a small real file of the given format and returns its URL.
    func makeSource(_ format: FormatID, in dir: URL) throws -> URL {
        let ext = FormatRegistry.preferredExtension(for: format)
        let file = dir.appendingPathComponent("sample.\(ext)")
        let rows = [["name", "qty"], [Self.marker, "3"], ["pears", "5"]]
        let prose = NSAttributedString(string: "Title\n\n\(Self.marker) is in this paragraph.\n")
        func write(_ type: NSAttributedString.DocumentType) throws {
            try prose.data(from: NSRange(location: 0, length: prose.length), documentAttributes: [.documentType: type]).write(to: file)
        }
        switch format {
        case .txt: try prose.string.write(to: file, atomically: true, encoding: .utf8)
        case .markdown: try "# Title\n\n\(Self.marker) is in **this** paragraph.\n".write(to: file, atomically: true, encoding: .utf8)
        case .html: try "<!DOCTYPE html><html><body><h1>Title</h1><p>\(Self.marker) is here.</p></body></html>".write(to: file, atomically: true, encoding: .utf8)
        case .rtf: try write(.rtf)
        case .doc: try write(.docFormat)
        case .odt: try write(.openDocument)
        case .docx: try DocxIO.write(text: prose.string, to: file)
        case .pdf:
            let txt = dir.appendingPathComponent("seed.txt")
            try prose.string.write(to: txt, atomically: true, encoding: .utf8)
            try DocumentConverter().convert(from: txt, detected: .txt, spec: OutputSpec(format: .pdf), to: file,
                                            context: ConversionContext(settings: AppSettings(), cancellation: CancellationToken()))
            try FileManager.default.removeItem(at: txt)
        case .csv: try rows.map { $0.joined(separator: ",") }.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        case .tsv: try rows.map { $0.joined(separator: "\t") }.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        case .xlsx: try XLSXWriter.write(rows, to: file)
        case .json: try "[{\"name\": \"\(Self.marker)\", \"qty\": 3}, {\"name\": \"pears\", \"qty\": 5}]".write(to: file, atomically: true, encoding: .utf8)
        case .yaml: try "- name: \(Self.marker)\n  qty: 3\n- name: pears\n  qty: 5\n".write(to: file, atomically: true, encoding: .utf8)
        case .xml: try "<?xml version=\"1.0\"?><items><item><name>\(Self.marker)</name><qty>3</qty></item></items>".write(to: file, atomically: true, encoding: .utf8)
        case .plist: try PropertyListSerialization.data(fromPropertyList: ["name": Self.marker, "qty": 3], format: .xml, options: 0).write(to: file)
        case .toml: try "name = \"\(Self.marker)\"\nqty = 3\n".write(to: file, atomically: true, encoding: .utf8)
        default: XCTFail("no fixture for \(format)")
        }
        return file
    }

    /// Renames sample.<from> to sample.<to> and lets the engine convert it. Returns nil on success.
    func attempt(_ from: FormatID, _ to: FormatID) -> String? {
        do {
            let dir = temp.appendingPathComponent("\(from.rawValue)-\(to.rawValue)", isDirectory: true)
            let support = dir.appendingPathComponent(".support", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let source = try makeSource(from, in: dir)
            let renamed = dir.appendingPathComponent("sample.\(FormatRegistry.preferredExtension(for: to))")
            try FileManager.default.moveItem(at: source, to: renamed)
            let detected = try FormatDetector.detect(at: renamed, originalFilename: source.lastPathComponent)
            guard detected.id == from else { return "detected as \(detected.id.rawValue)" }
            let outcome = try ConversionEngine().perform(
                PendingConversion(
                    sourceURL: source, commandURL: renamed, detected: detected,
                    command: try TransformationParser.parseFilename(renamed.lastPathComponent),
                    originalName: source.lastPathComponent
                ),
                settings: AppSettings(confirmationMode: .automatic),
                backups: BackupStore(directory: support), journal: OperationJournal(directory: support),
                history: HistoryStore(directory: support), ignore: IgnoreSet(), cancellation: CancellationToken()
            )
            guard let result = outcome.destinations.first else { return "no output" }
            let actual = try FormatDetector.detect(at: result, originalFilename: result.lastPathComponent).id
            if actual != to { return "output is \(actual.rawValue)" }
            // The content has to survive: read the result back as text and look for the marker.
            let back = dir.appendingPathComponent("back.txt")
            let reader: Converter = to == .xlsx ? SpreadsheetConverter() : DocumentConverter()
            var text = ""
            if [.txt, .markdown, .html, .rtf, .csv, .tsv, .json, .yaml, .xml, .plist, .toml].contains(to) {
                text = (try? String(contentsOf: result, encoding: .utf8)) ?? ""
            } else {
                try reader.convert(from: result, detected: to, spec: OutputSpec(format: to == .xlsx ? .csv : .txt), to: back,
                                   context: ConversionContext(settings: AppSettings(), cancellation: CancellationToken()))
                text = try String(contentsOf: back, encoding: .utf8)
            }
            return text.contains(Self.marker) ? nil : "content lost"
        } catch {
            return "\(error)"
        }
    }

    func testDocumentAndTableMatrix() {
        let documents: [FormatID] = [.txt, .markdown, .html, .rtf, .doc, .odt, .docx, .pdf]
        let tables: [FormatID] = [.csv, .tsv, .xlsx]
        let configs: [FormatID] = [.json, .yaml, .xml, .plist, .toml]
        var pairs: [(FormatID, FormatID)] = []
        for from in documents { for to in documents where from != to { pairs.append((from, to)) } }
        for from in tables { for to in tables + [.json, .yaml, .pdf, .html, .txt, .markdown, .rtf, .docx, .doc, .odt] where from != to { pairs.append((from, to)) } }
        for from in configs { for to in configs + [.csv, .tsv, .xlsx] where from != to { pairs.append((from, to)) } }

        var failures: [String] = []
        for (from, to) in pairs {
            if let reason = attempt(from, to) {
                failures.append("\(from.rawValue) → \(to.rawValue): \(reason.prefix(160))")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\n" + failures.joined(separator: "\n"))
    }

    private var context: ConversionContext {
        ConversionContext(settings: AppSettings(), cancellation: CancellationToken())
    }

    /// What Excel saves in a Russian locale: semicolons, Windows-1251, CRLF, doubled quotes.
    func testCSVFromRussianExcel() throws {
        let csv = temp.appendingPathComponent("отчёт.xlsx")
        let text = "Товар;Цена;Комментарий\r\nЯблоки;12,5;\"сорт \"\"Гала\"\"; свежие\"\r\nГруши;7;\r\n"
        try XCTUnwrap(text.data(using: .windowsCP1251)).write(to: csv)
        let detected = try FormatDetector.detect(at: csv, originalFilename: "отчёт.csv")
        XCTAssertEqual(detected.id, .csv)

        let xlsx = temp.appendingPathComponent("out.xlsx")
        try SpreadsheetConverter().convert(from: csv, detected: .csv, spec: OutputSpec(format: .xlsx), to: xlsx, context: context)
        let rows = try XLSXReader.read(xlsx)
        XCTAssertEqual(rows, [
            ["Товар", "Цена", "Комментарий"],
            ["Яблоки", "12,5", "сорт \"Гала\"; свежие"],
            ["Груши", "7", ""]
        ])
    }

    /// A workbook shaped like Excel's own: shared strings, a skipped cell and a skipped row,
    /// self-closing empty cells, a formula with its cached result, a date, a boolean, an
    /// entity, and a first sheet that is not sheet1.xml.
    func testWorkbookWrittenByExcel() throws {
        let book = temp.appendingPathComponent("book", isDirectory: true)
        func write(_ path: String, _ xml: String) throws {
            let file = book.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + xml).write(to: file, atomically: true, encoding: .utf8)
        }
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        try write("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"xml\" ContentType=\"application/xml\"/></Types>")
        try write("xl/workbook.xml", "<workbook xmlns=\"\(main)\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Data\" sheetId=\"7\" r:id=\"rId3\"/><sheet name=\"Other\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>")
        try write("xl/_rels/workbook.xml.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"t\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId3\" Type=\"t\" Target=\"worksheets/sheet2.xml\"/></Relationships>")
        try write("xl/sharedStrings.xml", "<sst xmlns=\"\(main)\"><si><t>Name</t></si><si><t>Total</t></si><si><r><t>Tom </t></r><r><t>&amp; Jerry</t></r><rPh><t>ignored</t></rPh></si><si><t>When</t></si><si><t>Paid</t></si></sst>")
        try write("xl/styles.xml", "<styleSheet xmlns=\"\(main)\"><numFmts><numFmt numFmtId=\"164\" formatCode=\"dd.mm.yyyy\"/></numFmts><cellXfs><xf numFmtId=\"0\"/><xf numFmtId=\"164\"/></cellXfs></styleSheet>")
        try write("xl/worksheets/sheet1.xml", "<worksheet xmlns=\"\(main)\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>wrong sheet</t></is></c></row></sheetData></worksheet>")
        try write("xl/worksheets/sheet2.xml", """
        <worksheet xmlns="\(main)"><cols><col min="1" max="1" width="9"/></cols><sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>3</v></c><c r="D1" t="s"><v>4</v></c></row>
        <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><f>SUM(E2:F2)</f><v>0.30000000000000004</v></c><c r="C2" s="1"><v>45292</v></c><c r="D2" t="b"><v>1</v></c></row>
        <row r="4"><c r="A4" s="1"/><c r="B4"><v>42</v></c><c r="D4" t="str"><f>A1</f><v>text</v></c></row>
        </sheetData></worksheet>
        """)
        let xlsx = temp.appendingPathComponent("book.xlsx")
        let zip = ProcessRunner.run(executable: "/usr/bin/ditto", arguments: ["-c", "-k", "--norsrc", "--noextattr", book.path, xlsx.path])
        XCTAssertEqual(zip.exitCode, 0)

        XCTAssertEqual(try XLSXReader.read(xlsx), [
            ["Name", "Total", "When", "Paid"],
            ["Tom & Jerry", "0.3", "2024-01-01", "TRUE"],
            ["", "", "", ""],
            ["", "42", "", "text"]
        ])
        let csv = temp.appendingPathComponent("book.csv")
        try SpreadsheetConverter().convert(from: xlsx, detected: .xlsx, spec: OutputSpec(format: .csv), to: csv, context: context)
        XCTAssertTrue(try String(contentsOf: csv, encoding: .utf8).hasPrefix("Name,Total,When,Paid\nTom & Jerry,0.3,2024-01-01,TRUE\n"))
    }

    func testNumbersStayNumbersAndTextStaysText() throws {
        let csv = temp.appendingPathComponent("n.csv")
        try "id,qty,price\n007,3,1.50\n".write(to: csv, atomically: true, encoding: .utf8)
        let json = temp.appendingPathComponent("n.json")
        try SpreadsheetConverter().convert(from: csv, detected: .csv, spec: OutputSpec(format: .json), to: json, context: context)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [[String: Any]])
        XCTAssertEqual(object.first?["id"] as? String, "007")
        XCTAssertEqual(object.first?["qty"] as? Int, 3)
        XCTAssertEqual(object.first?["price"] as? Double, 1.5)
    }

    func testTOMLRoundTripsThroughJSON() throws {
        let toml = "title = \"Demo\"\ntags = [\"a\", \"b\"]\n\n[owner]\nname = \"Ann\"\n\n[[servers]]\nhost = \"one\"\nport = 80\n\n[[servers]]\nhost = \"two\"\nport = 81\n"
        let value = try TOMLBridge.parse(toml)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: ConfigValue.dump(value, format: .json)) as? [String: Any])
        XCTAssertEqual(json["tags"] as? [String], ["a", "b"])
        XCTAssertEqual((json["servers"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((json["owner"] as? [String: Any])?["name"] as? String, "Ann")
        XCTAssertEqual(try TOMLBridge.parse(TOMLBridge.dump(value)), value)
    }
}

final class RenameIntentTests: XCTestCase {
    private func rename(_ old: String, _ new: String) -> Bool {
        RenameCoordinator.isUserRename(from: URL(fileURLWithPath: old), to: URL(fileURLWithPath: new))
    }

    func testSafeSavesAndDownloadsAreNotConversionRequests() {
        // Jupyter, VS Code and most editors write a temporary file and rename it into place.
        XCTAssertFalse(rename("/w/.~notebook.ipynb", "/w/notebook.ipynb"))
        XCTAssertFalse(rename("/w/notebook.ipynb.tmp", "/w/notebook.ipynb"))
        XCTAssertFalse(rename("/w/notebook.ipynb.4f2a1b", "/w/notebook.ipynb"))
        XCTAssertFalse(rename("/w/report.docx~", "/w/report.docx"))
        XCTAssertFalse(rename("/w/movie.mp4.crdownload", "/w/movie.mp4"))
        XCTAssertFalse(rename("/w/photo.jpg.part", "/w/photo.jpg"))
        // Moved in from elsewhere: not a rename in place.
        XCTAssertFalse(rename("/tmp/x/photo.png", "/w/photo.jpg"))
    }

    func testChangingTheExtensionInPlaceIsARequest() {
        XCTAssertTrue(rename("/w/photo.png", "/w/photo.jpg"))
        XCTAssertTrue(rename("/w/report.doc", "/w/report.pdf"))
        XCTAssertTrue(rename("/w/notes", "/w/notes.pdf"))
        // Same extension: a plain rename, which the parser then rejects as "not a candidate".
        XCTAssertFalse(TransformationParser.isConversionCandidate(oldName: "a.ipynb", newName: "b.ipynb"))
    }
}

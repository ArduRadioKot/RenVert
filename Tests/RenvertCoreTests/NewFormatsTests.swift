import XCTest
import AppKit
import AVFoundation
import PDFKit
@testable import RenvertCore

final class NewFormatsTests: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("renvert-new-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private var context: ConversionContext {
        ConversionContext(settings: AppSettings(), cancellation: CancellationToken())
    }

    private func url(_ name: String) -> URL { temp.appendingPathComponent(name) }

    // MARK: Images

    func testTGAAndPSDRoundTrip() throws {
        let png = try writePNG("art.png")
        for (format, name) in [(FormatID.tga, "art.tga"), (.psd, "art.psd")] {
            XCTAssertTrue(FormatRegistry.canConvert(from: .png, to: format))
            let encoded = url(name)
            try ImageConverter().convert(from: png, detected: .png, spec: OutputSpec(format: format), to: encoded, context: context)
            let back = url("back-\(format.rawValue).png")
            try ImageConverter().convert(from: encoded, detected: format, spec: OutputSpec(format: .png), to: back, context: context)
            XCTAssertEqual(try FormatDetector.detect(at: back).id, .png)
            let size = try XCTUnwrap(NSImage(contentsOf: back)?.representations.first)
            XCTAssertEqual(size.pixelsWide, 32)
        }
        XCTAssertEqual(try FormatDetector.detect(at: url("art.psd")).id, .psd)
    }

    func testRawAndSignaturelessFormatsFollowOriginalName() throws {
        // A DNG is a TIFF container: the bytes say TIFF, the old name says which RAW it is.
        let tiff = url("shot.jpg")
        let png = try writePNG("src.png")
        try ImageConverter().convert(from: png, detected: .png, spec: OutputSpec(format: .tiff), to: tiff, context: context)
        XCTAssertEqual(try FormatDetector.detect(at: tiff, originalFilename: "shot.dng").id, .dng)
        XCTAssertTrue(FormatRegistry.canConvert(from: .dng, to: .jpeg))
        XCTAssertTrue(FormatRegistry.canConvert(from: .cr3, to: .heic))
        XCTAssertFalse(FormatRegistry.canConvert(from: .png, to: .dng))
        XCTAssertTrue(FormatRegistry.canConvert(from: .jxl, to: .png))
        XCTAssertFalse(FormatRegistry.canConvert(from: .png, to: .jxl))

        let obj = url("cube.stl")
        try Self.cubeOBJ.write(to: obj, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FormatDetector.detect(at: obj, originalFilename: "cube.obj").id, .obj)
    }

    // MARK: Archives

    func testSevenZipAndCompressedTarRoundTrip() throws {
        let folder = url("Photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "hello".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let expected: [(FormatID, String)] = [(.sevenZ, "Photos.7z"), (.txz, "Photos.txz"), (.tbz2, "Photos.tbz2")]
        for (format, name) in expected {
            XCTAssertTrue(FormatRegistry.canConvert(from: .folder, to: format))
            let archive = url(name)
            try ArchiveConverter().convert(from: folder, detected: .folder, spec: OutputSpec(format: format), to: archive, context: context)
            XCTAssertEqual(try FormatDetector.detect(at: archive).id, format)

            // Back to ZIP: one top-level folder, named after the archive, with the file inside.
            let zip = url("out-\(format.rawValue).zip")
            try ArchiveConverter().convert(from: archive, detected: format, spec: OutputSpec(format: .zip), to: zip, context: context)
            let listing = ProcessRunner.run(executable: "/usr/bin/unzip", arguments: ["-Z", "-1", zip.path]).stdout
            XCTAssertTrue(listing.contains("Photos/a.txt"), listing)
        }
        XCTAssertTrue(FormatRegistry.canConvert(from: .cbr, to: .cbz))
        XCTAssertFalse(FormatRegistry.canConvert(from: .zip, to: .cbr))
    }

    func testZipBecomesNumPyAndPyTorchArchives() throws {
        XCTAssertTrue(FormatRegistry.canConvert(from: .zip, to: .npz))
        XCTAssertTrue(FormatRegistry.canConvert(from: .zip, to: .pt))
        XCTAssertTrue(FormatRegistry.canConvert(from: .npz, to: .zip))
        XCTAssertTrue(FormatRegistry.canConvert(from: .pt, to: .zip))
        XCTAssertFalse(FormatRegistry.canConvert(from: .folder, to: .npz))
        XCTAssertFalse(FormatRegistry.canConvert(from: .folder, to: .pt))
        XCTAssertEqual(FormatRegistry.resolve("pth"), .pt)

        let python = try XCTUnwrap(pythonWithNumpy(), "numpy is required to check the archives")
        let folder = url("Pack")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("note.txt"))
        try Data([0, 1, 2, 255]).write(to: folder.appendingPathComponent("raw.bin"))
        let sample = folder.appendingPathComponent("sample.npy")
        let made = ProcessRunner.run(executable: python, arguments: [
            "-c", "import numpy as np, sys; np.save(sys.argv[1], np.array([1, 2, 3], dtype='int64'))", sample.path
        ])
        XCTAssertEqual(made.exitCode, 0, made.stderr)
        let originalNPY = try Data(contentsOf: sample)

        let zip = url("Pack.zip")
        try ArchiveConverter().archiveFolder(folder, to: zip, format: .zip)
        XCTAssertEqual(try FormatDetector.detect(at: zip).id, .zip)

        let npz = url("Pack.npz")
        try ArchiveConverter().convert(from: zip, detected: .zip, spec: OutputSpec(format: .npz), to: npz, context: context)
        XCTAssertEqual(try FormatDetector.detect(at: npz).id, .npz)
        let npzDir = url("npz-unpacked")
        try FileManager.default.createDirectory(at: npzDir, withIntermediateDirectories: true)
        let unpackedNPZ = ProcessRunner.run(executable: "/usr/bin/ditto", arguments: ["-x", "-k", npz.path, npzDir.path])
        XCTAssertEqual(unpackedNPZ.exitCode, 0, unpackedNPZ.stderr)
        XCTAssertEqual(try Data(contentsOf: npzDir.appendingPathComponent("Pack/sample.npy")), originalNPY)
        let note = try Data(contentsOf: npzDir.appendingPathComponent("Pack/note.txt.npy"))
        XCTAssertEqual(try npyPayload(note), Data("hello".utf8))
        let raw = try Data(contentsOf: npzDir.appendingPathComponent("Pack/raw.bin.npy"))
        XCTAssertEqual(try npyPayload(raw), Data([0, 1, 2, 255]))

        let pt = url("weights.pt")
        try ArchiveConverter().convert(from: zip, detected: .zip, spec: OutputSpec(format: .pt), to: pt, context: context)
        XCTAssertEqual(try FormatDetector.detect(at: pt).id, .pt)
        let pth = url("weights.pth")
        try Data(contentsOf: pt).write(to: pth)
        XCTAssertEqual(try FormatDetector.detect(at: pth).id, .pt)

        let script = url("check.py")
        try """
import pickle, sys, zipfile
import numpy as np
npz, pt = sys.argv[1:3]
loaded = np.load(npz)
assert list(loaded["Pack/sample"]) == [1, 2, 3]
assert bytes(loaded["Pack/note.txt"]) == b"hello"
assert bytes(loaded["Pack/raw.bin"]) == bytes([0, 1, 2, 255])
with zipfile.ZipFile(pt) as archive:
    assert archive.read("weights/byteorder") == b"little"
    payload = pickle.loads(archive.read("weights/data.pkl"))
assert payload["Pack/note.txt"] == b"hello"
assert payload["Pack/raw.bin"] == bytes([0, 1, 2, 255])
assert payload["Pack/sample.npy"][:6] == bytes([0x93]) + b"NUMPY"
""".write(to: script, atomically: true, encoding: .utf8)
        let checked = ProcessRunner.run(executable: python, arguments: [script.path, npz.path, pt.path])
        XCTAssertEqual(checked.exitCode, 0, checked.stdout + checked.stderr)

        let npzZip = url("from-npz.zip")
        try ArchiveConverter().convert(from: npz, detected: .npz, spec: OutputSpec(format: .zip), to: npzZip, context: context)
        XCTAssertEqual(try Data(contentsOf: npzZip), try Data(contentsOf: npz))
        let ptZip = url("from-pt.zip")
        try ArchiveConverter().convert(from: pt, detected: .pt, spec: OutputSpec(format: .zip), to: ptZip, context: context)
        XCTAssertEqual(try Data(contentsOf: ptZip), try Data(contentsOf: pt))
    }

    private func pythonWithNumpy() -> String? {
        for path in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let probe = ProcessRunner.run(executable: path, arguments: ["-c", "import numpy, pickle, zipfile"])
            if probe.exitCode == 0 { return path }
        }
        return nil
    }

    private func npyPayload(_ data: Data) throws -> Data {
        let magic = Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59])
        XCTAssertEqual(data.prefix(6), magic)
        XCTAssertEqual(data[6], 1)
        let headerLength = Int(data[8]) | (Int(data[9]) << 8)
        let payloadStart = 10 + headerLength
        XCTAssertEqual(payloadStart % 64, 0)
        return data.subdata(in: payloadStart..<data.count)
    }

    // MARK: Documents

    func testDocAndOdtRoundTrip() throws {
        let text = url("note.txt")
        try "Renvert keeps this sentence.".write(to: text, atomically: true, encoding: .utf8)
        for format in [FormatID.doc, .odt] {
            let written = url("note.\(format.rawValue)")
            try DocumentConverter().convert(from: text, detected: .txt, spec: OutputSpec(format: format), to: written, context: context)
            XCTAssertEqual(try FormatDetector.detect(at: written).id, format)
            let back = url("back-\(format.rawValue).txt")
            try DocumentConverter().convert(from: written, detected: format, spec: OutputSpec(format: .txt), to: back, context: context)
            XCTAssertTrue(try String(contentsOf: back, encoding: .utf8).contains("Renvert keeps this sentence."))
        }
    }

    // MARK: 3D models

    func testModelFormatsConvertBetweenEachOther() throws {
        // The file already carries the target's extension, as it does after a rename in Finder.
        let source = url("cube.stl")
        try Self.cubeOBJ.write(to: source, atomically: true, encoding: .utf8)
        let stl = url("out.stl")
        try ModelConverter().convert(from: source, detected: .obj, spec: OutputSpec(format: .stl), to: stl, context: context)
        XCTAssertGreaterThan(try Data(contentsOf: stl).count, 84)

        let ply = url("out.ply")
        try ModelConverter().convert(from: stl, detected: .stl, spec: OutputSpec(format: .ply), to: ply, context: context)
        XCTAssertEqual(try FormatDetector.detect(at: ply).id, .ply)

        let usda = url("out.usda")
        try ModelConverter().convert(from: ply, detected: .ply, spec: OutputSpec(format: .usda), to: usda, context: context)
        XCTAssertEqual(try FormatDetector.detect(at: usda).id, .usda)

        let obj = url("out.obj")
        try ModelConverter().convert(from: usda, detected: .usda, spec: OutputSpec(format: .obj), to: obj, context: context)
        XCTAssertTrue(try String(contentsOf: obj, encoding: .utf8).contains("\nf "))
        XCTAssertFalse(FormatRegistry.canConvert(from: .obj, to: .usdz))
    }

    // MARK: Audio

    func testNativeAudioWritesFlacWavAiffAndM4A() throws {
        let wav = try writeTone("tone.wav")
        var previous = (wav, FormatID.wav)
        for format in [FormatID.flac, .m4a, .aiff, .caf, .wav] {
            XCTAssertEqual(FormatRegistry.support(from: previous.1, to: format), .native)
            let next = url("tone-\(format.rawValue).\(FormatRegistry.preferredExtension(for: format))")
            try NativeAudio.transcode(from: previous.0, spec: OutputSpec(format: format), to: next, context: context)
            XCTAssertEqual(try FormatDetector.detect(at: next).id, format)
            let frames = try AVAudioFile(forReading: next).length
            XCTAssertGreaterThan(frames, 40_000)
            previous = (next, format)
        }
        XCTAssertEqual(FormatRegistry.support(from: .mp3, to: .wav), .native)
        XCTAssertEqual(FormatRegistry.support(from: .wav, to: .mp3), .ffmpeg)
    }

    // MARK: PDF and image quality

    /// Copies results out for a look by eye when RENVERT_KEEP_OUTPUT names a folder.
    private func keep(_ file: URL) {
        guard let dir = ProcessInfo.processInfo.environment["RENVERT_KEEP_OUTPUT"] else { return }
        let target = URL(fileURLWithPath: dir).appendingPathComponent(file.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: file, to: target)
    }

    private func longText(paragraphs: Int) -> String {
        (1...paragraphs).map { "Paragraph \($0). Renvert writes dark text on white paper, from the top of the page down." }
            .joined(separator: "\n\n")
    }

    /// Fraction of dark pixels in a horizontal band of the image (0 = top, 1 = bottom).
    private func darkShare(of file: URL, from top: Double, to bottom: Double) throws -> Double {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: file)))
        var dark = 0, total = 0
        for y in stride(from: Int(Double(rep.pixelsHigh) * top), to: Int(Double(rep.pixelsHigh) * bottom), by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                total += 1
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.alphaComponent > 0.5, color.brightnessComponent < 0.5 { dark += 1 }
            }
        }
        return Double(dark) / Double(max(total, 1))
    }

    func testTextToPDFIsDarkOnWhiteFromTheTop() throws {
        let text = url("letter.txt")
        try longText(paragraphs: 3).write(to: text, atomically: true, encoding: .utf8)
        let pdf = url("letter.pdf")
        try DocumentConverter().convert(from: text, detected: .txt, spec: OutputSpec(format: .pdf), to: pdf, context: context)
        keep(pdf)

        let png = url("letter.png")
        try DocumentConverter().convert(from: pdf, detected: .pdf, spec: OutputSpec(format: .png), to: png, context: context)
        keep(png)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: png)))
        // Opaque white paper: a transparent or dark corner means the page was not filled.
        let corner = try XCTUnwrap(rep.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(corner.alphaComponent, 0.99)
        XCTAssertGreaterThan(corner.brightnessComponent, 0.95)
        // 200 dpi by default.
        XCTAssertEqual(Double(rep.pixelsWide), Double(NSPrintInfo.shared.paperSize.width) * 200 / 72, accuracy: 2)
        // Three short paragraphs sit in the top quarter and leave the bottom half empty.
        XCTAssertGreaterThan(try darkShare(of: png, from: 0.03, to: 0.25), 0.005)
        XCTAssertEqual(try darkShare(of: png, from: 0.5, to: 1), 0, accuracy: 0.0005)
    }

    func testEveryPDFPageBecomesAnImage() throws {
        let support = url("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let text = url("book.txt")
        try longText(paragraphs: 80).write(to: text, atomically: true, encoding: .utf8)
        let original = url("book.pdf")
        try DocumentConverter().convert(from: text, detected: .txt, spec: OutputSpec(format: .pdf), to: original, context: context)
        let pageCount = try XCTUnwrap(PDFDocumentProbe.pageCount(original))
        XCTAssertGreaterThan(pageCount, 1)

        // The user renames book.pdf to book.jpg.
        let renamed = url("book.jpg")
        try FileManager.default.moveItem(at: original, to: renamed)
        let outcome = try ConversionEngine().perform(
            PendingConversion(
                sourceURL: original,
                commandURL: renamed,
                detected: try FormatDetector.detect(at: renamed),
                command: try TransformationParser.parseFilename(renamed.lastPathComponent),
                originalName: "book.pdf"
            ),
            settings: AppSettings(confirmationMode: .automatic),
            backups: BackupStore(directory: support),
            journal: OperationJournal(directory: support),
            history: HistoryStore(directory: support),
            ignore: IgnoreSet(),
            cancellation: CancellationToken()
        )
        XCTAssertEqual(outcome.destinations.count, pageCount)
        XCTAssertEqual(outcome.destinations.first?.lastPathComponent, "book.jpg")
        XCTAssertEqual(outcome.destinations.dropFirst().first?.lastPathComponent, "book 2.jpg")
        for file in outcome.destinations {
            XCTAssertEqual(try FormatDetector.detect(at: file).id, .jpeg)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.path).filter { $0.hasPrefix(".renvert-") }
        XCTAssertEqual(leftovers, [])
    }

    func testPhotoToPDFFitsThePaperAndStaysSmall() throws {
        let photo = try writePhoto("photo.png", width: 3000, height: 2000)
        let pdf = url("photo.pdf")
        try ImageConverter().convert(from: photo, detected: .png, spec: OutputSpec(format: .pdf), to: pdf, context: context)
        keep(pdf)
        let box = try XCTUnwrap(PDFDocumentProbe.firstPageSize(pdf))
        let paper = NSPrintInfo.shared.paperSize
        XCTAssertLessThanOrEqual(box.width, max(paper.width, paper.height) + 1)
        XCTAssertEqual(box.width / box.height, 1.5, accuracy: 0.01)
        // Stored as JPEG, not as raw pixels (which would be megabytes for 6 MP).
        let pngSize = try Data(contentsOf: photo).count
        XCTAssertLessThan(try Data(contentsOf: pdf).count, max(pngSize, 400_000))
    }

    func testSVGConvertsAfterRenameAndComesOutLarge() throws {
        // Renamed already: SVG bytes under a .png name.
        let renamed = url("icon.png")
        try """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="10" fill="#0a84ff"/>
        </svg>
        """.write(to: renamed, atomically: true, encoding: .utf8)
        let detected = try FormatDetector.detect(at: renamed, originalFilename: "icon.svg")
        XCTAssertEqual(detected.id, .svg)
        let png = url("icon-out.png")
        try ImageConverter().convert(from: renamed, detected: detected.id, spec: OutputSpec(format: .png), to: png, context: context)
        keep(png)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: png)))
        XCTAssertEqual(rep.pixelsWide, 2048)
        let center = try XCTUnwrap(rep.colorAt(x: 1024, y: 1024)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(center.blueComponent, 0.8)
        XCTAssertLessThan(try XCTUnwrap(rep.colorAt(x: 4, y: 4)).alphaComponent, 0.1)
    }

    // MARK: Extra image formats

    func testImageIOWritesJPEG2000EXRASTCAndPPM() throws {
        let png = try writePNG("tile.png")
        for format in [FormatID.jp2, .exr, .astc, .ppm] {
            XCTAssertTrue(FormatRegistry.canConvert(from: .png, to: format))
            let encoded = url("tile.\(format.rawValue)")
            try ImageConverter().convert(from: png, detected: .png, spec: OutputSpec(format: format), to: encoded, context: context)
            XCTAssertEqual(try FormatDetector.detect(at: encoded).id, format, format.rawValue)
            let back = url("back-\(format.rawValue).png")
            try ImageConverter().convert(from: encoded, detected: format, spec: OutputSpec(format: .png), to: back, context: context)
            XCTAssertEqual(try FormatDetector.detect(at: back).id, .png)
        }
    }

    func testSQLiteJSONLinesAndSeveralTables() throws {
        let csv = url("people.csv")
        try "name,city\nAda,London\nGrace,New York\n".write(to: csv, atomically: true, encoding: .utf8)
        let db = url("people.sqlite")
        try SpreadsheetConverter().convert(from: csv, detected: .csv, spec: OutputSpec(format: .sqlite), to: db, context: context)
        XCTAssertEqual(try FormatDetector.detect(at: db).id, .sqlite)
        let back = url("people-back.csv")
        try SpreadsheetConverter().convert(from: db, detected: .sqlite, spec: OutputSpec(format: .csv), to: back, context: context)
        let text = try String(contentsOf: back, encoding: .utf8)
        XCTAssertTrue(text.contains("Ada"))
        XCTAssertTrue(text.contains("London"))

        let jsonl = url("people.jsonl")
        try SpreadsheetConverter().convert(from: csv, detected: .csv, spec: OutputSpec(format: .jsonl), to: jsonl, context: context)
        XCTAssertEqual(try FormatDetector.detect(at: jsonl).id, .jsonl)
        let fromLines = url("from-lines.csv")
        try SpreadsheetConverter().convert(from: jsonl, detected: .jsonl, spec: OutputSpec(format: .csv), to: fromLines, context: context)
        XCTAssertTrue(try String(contentsOf: fromLines, encoding: .utf8).contains("Grace"))

        let multi = url("multi.sqlite")
        let script = "CREATE TABLE people(name TEXT); INSERT INTO people VALUES ('Ada'); CREATE TABLE cities(name TEXT); INSERT INTO cities VALUES ('London');"
        let result = ProcessRunner.run(executable: "/usr/bin/sqlite3", arguments: [multi.path, script])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let json = url("multi.json")
        try SpreadsheetConverter().convert(from: multi, detected: .sqlite, spec: OutputSpec(format: .json), to: json, context: context)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any]
        XCTAssertNotNil(object?["people"])
        XCTAssertNotNil(object?["cities"])
    }

    func testTracksContactsAndCalendar() throws {
        let gpx = url("walk.gpx")
        try """
        <?xml version="1.0"?><gpx version="1.1"><trk><trkseg>
        <trkpt lat="51.5" lon="-0.12"><ele>12</ele><name>Start</name></trkpt>
        </trkseg></trk></gpx>
        """.write(to: gpx, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FormatDetector.detect(at: gpx).id, .gpx)
        let geo = url("walk.geojson")
        try BeyondConverter().convert(from: gpx, detected: .gpx, spec: OutputSpec(format: .geojson), to: geo, context: context)
        XCTAssertEqual(try FormatDetector.detect(at: geo).id, .geojson)
        let csv = url("walk.csv")
        try BeyondConverter().convert(from: geo, detected: .geojson, spec: OutputSpec(format: .csv), to: csv, context: context)
        XCTAssertTrue(try String(contentsOf: csv, encoding: .utf8).contains("51.5"))
        XCTAssertTrue(try String(contentsOf: csv, encoding: .utf8).contains("Start"))

        let vcf = url("ada.vcf")
        try "BEGIN:VCARD\nVERSION:3.0\nFN:Ada Lovelace\nEMAIL:ada@example.com\nTEL:+44\nEND:VCARD\n".write(to: vcf, atomically: true, encoding: .utf8)
        let cards = url("ada.csv")
        try BeyondConverter().convert(from: vcf, detected: .vcf, spec: OutputSpec(format: .csv), to: cards, context: context)
        XCTAssertTrue(try String(contentsOf: cards, encoding: .utf8).contains("ada@example.com"))
        let back = url("ada-back.vcf")
        try BeyondConverter().convert(from: cards, detected: .csv, spec: OutputSpec(format: .vcf), to: back, context: context)
        XCTAssertTrue(try String(contentsOf: back, encoding: .utf8).contains("FN:Ada Lovelace"))

        let ics = url("meet.ics")
        try "BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Launch\nDTSTART:20261116T090000Z\nLOCATION:Studio\nEND:VEVENT\nEND:VCALENDAR\n".write(to: ics, atomically: true, encoding: .utf8)
        let events = url("meet.csv")
        try BeyondConverter().convert(from: ics, detected: .ics, spec: OutputSpec(format: .csv), to: events, context: context)
        XCTAssertTrue(try String(contentsOf: events, encoding: .utf8).contains("Launch"))
        XCTAssertTrue(try String(contentsOf: events, encoding: .utf8).contains("Studio"))
    }

    func testMailOutlineBase64AndQR() throws {
        let eml = url("note.eml")
        try "From: Ada <ada@example.com>\nSubject: Hello\nMIME-Version: 1.0\nContent-Type: text/plain; charset=utf-8\n\nThe body is here.\n".write(to: eml, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FormatDetector.detect(at: eml).id, .eml)
        let txt = url("note.txt")
        try DocumentConverter().convert(from: eml, detected: .eml, spec: OutputSpec(format: .txt), to: txt, context: context)
        let letter = try String(contentsOf: txt, encoding: .utf8)
        XCTAssertTrue(letter.contains("Hello"))
        XCTAssertTrue(letter.contains("The body is here."))

        let opml = url("tree.opml")
        try "<?xml version=\"1.0\"?><opml version=\"2.0\"><body><outline text=\"Root\"><outline text=\"Child\"/></outline></body></opml>".write(to: opml, atomically: true, encoding: .utf8)
        let outline = url("tree.txt")
        try DocumentConverter().convert(from: opml, detected: .opml, spec: OutputSpec(format: .txt), to: outline, context: context)
        let tree = try String(contentsOf: outline, encoding: .utf8)
        XCTAssertTrue(tree.contains("Root"))
        XCTAssertTrue(tree.contains("  Child"))

        let png = try writePNG("badge.png")
        let b64 = url("badge.b64")
        try BeyondConverter().convert(from: png, detected: .png, spec: OutputSpec(format: .b64), to: b64, context: context)
        let restored = url("badge-back.png")
        try BeyondConverter().convert(from: b64, detected: .b64, spec: OutputSpec(format: .png), to: restored, context: context)
        XCTAssertEqual(try FormatDetector.detect(at: restored).id, .png)

        let payload = url("link.txt")
        try "https://renvert.app/qr".write(to: payload, atomically: true, encoding: .utf8)
        let code = url("link.png")
        try BeyondConverter().convert(from: payload, detected: .txt, spec: OutputSpec(format: .png, modifiers: [.qr]), to: code, context: context)
        XCTAssertEqual(try FormatDetector.detect(at: code).id, .png)
        let read = url("link-read.txt")
        try BeyondConverter().convert(from: code, detected: .png, spec: OutputSpec(format: .txt, modifiers: [.qr]), to: read, context: context)
        XCTAssertEqual(try String(contentsOf: read, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "https://renvert.app/qr")
    }

    func testFontBecomesAnImage() throws {
        let candidates = [
            "/System/Library/Fonts/Supplemental/Arial.ttf",
            "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
            "/Library/Fonts/Arial.ttf"
        ]
        guard let source = candidates.map({ URL(fileURLWithPath: $0) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("No TrueType font on this Mac")
        }
        let copy = url("sample.ttf")
        try FileManager.default.copyItem(at: source, to: copy)
        XCTAssertEqual(try FormatDetector.detect(at: copy).id, .ttf)
        let png = url("sample.png")
        try BeyondConverter().convert(from: copy, detected: .ttf, spec: OutputSpec(format: .png), to: png, context: context)
        XCTAssertEqual(try FormatDetector.detect(at: png).id, .png)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: png)))
        XCTAssertGreaterThan(rep.pixelsWide, 400)
    }

    func testConfigDialectsBookmarksFeedsAndPlaylists() throws {
        let ini = url("db.ini")
        try "[database]\nhost = localhost\nport = 5432\n".write(to: ini, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FormatDetector.detect(at: ini).id, .ini)
        let json = url("db.json")
        try ConfigConverter().convert(from: ini, detected: .ini, spec: OutputSpec(format: .json), to: json, context: context)
        let jsonText = try String(contentsOf: json, encoding: .utf8)
        XCTAssertTrue(jsonText.contains("localhost"))
        XCTAssertTrue(jsonText.contains("5432"))
        let back = url("db-back.ini")
        try ConfigConverter().convert(from: json, detected: .json, spec: OutputSpec(format: .ini), to: back, context: context)
        XCTAssertTrue(try String(contentsOf: back, encoding: .utf8).contains("[database]"))

        let env = url("app.env")
        try "export HOST=\"localhost\"\nPORT=5432\n".write(to: env, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FormatDetector.detect(at: env).id, .env)
        let envJSON = url("app.json")
        try ConfigConverter().convert(from: env, detected: .env, spec: OutputSpec(format: .json), to: envJSON, context: context)
        XCTAssertTrue(try String(contentsOf: envJSON, encoding: .utf8).contains("localhost"))

        let properties = url("app.properties")
        try "server.host=localhost\n".write(to: properties, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FormatDetector.detect(at: properties).id, .properties)
        let propertiesJSON = url("properties.json")
        try ConfigConverter().convert(from: properties, detected: .properties, spec: OutputSpec(format: .json), to: propertiesJSON, context: context)
        XCTAssertTrue(try String(contentsOf: propertiesJSON, encoding: .utf8).contains("localhost"))

        let strings = url("Localizable.strings")
        try "\"Greeting\" = \"Hello\";\n".write(to: strings, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FormatDetector.detect(at: strings).id, .strings)
        let stringsJSON = url("strings.json")
        try ConfigConverter().convert(from: strings, detected: .strings, spec: OutputSpec(format: .json), to: stringsJSON, context: context)
        XCTAssertTrue(try String(contentsOf: stringsJSON, encoding: .utf8).contains("Hello"))

        let webloc = url("site.webloc")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>URL</key><string>https://renvert.app</string></dict></plist>
        """.write(to: webloc, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FormatDetector.detect(at: webloc, originalFilename: "site.webloc").id, .webloc)
        let link = url("site.txt")
        try BeyondConverter().convert(from: webloc, detected: .webloc, spec: OutputSpec(format: .txt), to: link, context: context)
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "https://renvert.app")
        let shortcut = url("site.url")
        try BeyondConverter().convert(from: link, detected: .txt, spec: OutputSpec(format: .url), to: shortcut, context: context)
        XCTAssertEqual(try FormatDetector.detect(at: shortcut).id, .url)
        XCTAssertTrue(try String(contentsOf: shortcut, encoding: .utf8).contains("https://renvert.app"))

        let rss = url("news.rss")
        try "<rss version=\"2.0\"><channel><item><title>Hello</title><link>https://renvert.app</link></item></channel></rss>".write(to: rss, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FormatDetector.detect(at: rss).id, .rss)
        let feed = url("news.json")
        try BeyondConverter().convert(from: rss, detected: .rss, spec: OutputSpec(format: .json), to: feed, context: context)
        XCTAssertTrue(try String(contentsOf: feed, encoding: .utf8).contains("Hello"))
        let atom = url("news.atom")
        try BeyondConverter().convert(from: feed, detected: .json, spec: OutputSpec(format: .atom), to: atom, context: context)
        XCTAssertEqual(try FormatDetector.detect(at: atom).id, .atom)

        let tcx = url("ride.tcx")
        try "<TrainingCenterDatabase><Trackpoint><Position><LatitudeDegrees>51.5</LatitudeDegrees><LongitudeDegrees>-0.12</LongitudeDegrees></Position><AltitudeMeters>12</AltitudeMeters></Trackpoint></TrainingCenterDatabase>".write(to: tcx, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FormatDetector.detect(at: tcx).id, .tcx)
        let gpx = url("ride.gpx")
        try BeyondConverter().convert(from: tcx, detected: .tcx, spec: OutputSpec(format: .gpx), to: gpx, context: context)
        XCTAssertTrue(try String(contentsOf: gpx, encoding: .utf8).contains("51.5"))

        let playlist = url("show.m3u")
        try "#EXTM3U\n#EXTINF:12,Intro\nhttps://example.com/a.mp3\n".write(to: playlist, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FormatDetector.detect(at: playlist).id, .m3u)
        let songs = url("show.json")
        try BeyondConverter().convert(from: playlist, detected: .m3u, spec: OutputSpec(format: .json), to: songs, context: context)
        let songsText = try String(contentsOf: songs, encoding: .utf8)
        XCTAssertTrue(songsText.contains("Intro"))
        XCTAssertTrue(songsText.contains("a.mp3"))

        let lyrics = url("song.lrc")
        try "[00:01.50]Hello there\n".write(to: lyrics, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FormatDetector.detect(at: lyrics).id, .lrc)
        let srt = url("song.srt")
        try MiscConverter().convert(from: lyrics, detected: .lrc, spec: OutputSpec(format: .srt), to: srt, context: context)
        let srtText = try String(contentsOf: srt, encoding: .utf8)
        XCTAssertTrue(srtText.contains("Hello there"))
        XCTAssertTrue(srtText.contains("00:00:01,500"))
    }

    func testTurnedOffFormatIsRefusedAndOldSettingsStillLoad() throws {
        var settings = AppSettings(confirmationMode: .automatic)
        settings.setFormat(.png, enabled: false)
        XCTAssertFalse(settings.allowsFormat(.png))
        let png = try writePNG("blocked.png")
        let renamed = url("blocked.jpg")
        try FileManager.default.copyItem(at: png, to: renamed)
        XCTAssertThrowsError(try ConversionEngine().perform(
            PendingConversion(
                sourceURL: png,
                commandURL: renamed,
                detected: try FormatDetector.detect(at: renamed, originalFilename: "blocked.png"),
                command: try TransformationParser.parseFilename("blocked.jpg"),
                originalName: "blocked.png"
            ),
            settings: settings,
            backups: BackupStore(directory: temp),
            journal: OperationJournal(directory: temp),
            history: HistoryStore(directory: temp),
            ignore: IgnoreSet(),
            cancellation: CancellationToken()
        )) { error in
            XCTAssertEqual(error as? RenvertError, .formatDisabled("png"))
        }

        let old = #"{"language":"ru","confirmationMode":"automatic","hasCompletedOnboarding":true}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.language, .russian)
        XCTAssertEqual(decoded.confirmationMode, .automatic)
        XCTAssertTrue(decoded.hasCompletedOnboarding)
        XCTAssertTrue(decoded.disabledFormats.isEmpty)
        var roundTrip = decoded
        roundTrip.setFormat(.heic, enabled: false)
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(roundTrip))
        XCTAssertFalse(again.allowsFormat(.heic))
        XCTAssertEqual(again.language, .russian)
    }

    func testTracksBibliographyPalettesAndCaptions() throws {
        XCTAssertEqual(FormatRegistry.resolve("editorconfig"), .ini)

        let nmea = url("track.nmea")
        try "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\n".write(to: nmea, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FormatDetector.detect(at: nmea).id, .nmea)
        let gpx = url("track.gpx")
        try BeyondConverter().convert(from: nmea, detected: .nmea, spec: OutputSpec(format: .gpx), to: gpx, context: context)
        let gpxText = try String(contentsOf: gpx, encoding: .utf8)
        XCTAssertTrue(gpxText.contains("48.1"))
        XCTAssertTrue(gpxText.contains("11.5"))

        let igc = url("flight.igc")
        try "AXRenvert\nHFDTEDATE:010100\nB1101355206343N00006198WA0058700558\n".write(to: igc, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FormatDetector.detect(at: igc).id, .igc)
        let flight = url("flight.gpx")
        try BeyondConverter().convert(from: igc, detected: .igc, spec: OutputSpec(format: .gpx), to: flight, context: context)
        XCTAssertTrue(try String(contentsOf: flight, encoding: .utf8).contains("52.1"))

        let bib = url("papers.bib")
        try "@article{lovelace,\n  title = {Notes},\n  author = {Ada Lovelace},\n  year = {1843}\n}\n".write(to: bib, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FormatDetector.detect(at: bib).id, .bib)
        let citations = url("papers.json")
        try BeyondConverter().convert(from: bib, detected: .bib, spec: OutputSpec(format: .json), to: citations, context: context)
        let citationText = try String(contentsOf: citations, encoding: .utf8)
        XCTAssertTrue(citationText.contains("Ada Lovelace"))
        XCTAssertTrue(citationText.contains("1843"))

        let ldif = url("people.ldif")
        try "dn: cn=Ada Lovelace,dc=example,dc=com\ncn: Ada Lovelace\nmail: ada@example.com\n".write(to: ldif, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FormatDetector.detect(at: ldif).id, .ldif)
        let directory = url("people.csv")
        try BeyondConverter().convert(from: ldif, detected: .ldif, spec: OutputSpec(format: .csv), to: directory, context: context)
        XCTAssertTrue(try String(contentsOf: directory, encoding: .utf8).contains("ada@example.com"))

        let cue = url("album.cue")
        try "FILE \"album.wav\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"Intro\"\n    INDEX 01 00:00:00\n".write(to: cue, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FormatDetector.detect(at: cue).id, .cue)
        let songs = url("album.json")
        try BeyondConverter().convert(from: cue, detected: .cue, spec: OutputSpec(format: .json), to: songs, context: context)
        let songText = try String(contentsOf: songs, encoding: .utf8)
        XCTAssertTrue(songText.contains("Intro"))
        XCTAssertTrue(songText.contains("album.wav"))

        let youtube = url("clip.sbv")
        try "0:00:01.000,0:00:03.000\nHello there\n".write(to: youtube, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FormatDetector.detect(at: youtube).id, .sbv)
        let captions = url("clip.srt")
        try MiscConverter().convert(from: youtube, detected: .sbv, spec: OutputSpec(format: .srt), to: captions, context: context)
        XCTAssertTrue(try String(contentsOf: captions, encoding: .utf8).contains("00:00:01,000"))

        let sami = url("clip.smi")
        try "<SAMI><BODY>\n<SYNC Start=1500><P>Hello there\n</BODY></SAMI>\n".write(to: sami, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FormatDetector.detect(at: sami).id, .smi)
        let fromSami = url("clip-sami.srt")
        try MiscConverter().convert(from: sami, detected: .smi, spec: OutputSpec(format: .srt), to: fromSami, context: context)
        XCTAssertTrue(try String(contentsOf: fromSami, encoding: .utf8).contains("Hello there"))

        let palette = url("paint.gpl")
        try "GIMP Palette\nName: Renvert\n#\n255 128 0 Orange\n".write(to: palette, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FormatDetector.detect(at: palette).id, .gpl)
        let css = url("paint.css")
        try BeyondConverter().convert(from: palette, detected: .gpl, spec: OutputSpec(format: .css), to: css, context: context)
        XCTAssertTrue(try String(contentsOf: css, encoding: .utf8).lowercased().contains("ff8000"))
        let colors = url("paint.clr")
        try BeyondConverter().convert(from: palette, detected: .gpl, spec: OutputSpec(format: .clr), to: colors, context: context)
        XCTAssertEqual(try FormatDetector.detect(at: colors).id, .clr)
        let back = url("paint.json")
        try BeyondConverter().convert(from: colors, detected: .clr, spec: OutputSpec(format: .json), to: back, context: context)
        XCTAssertTrue(try String(contentsOf: back, encoding: .utf8).contains("FF8000"))
    }

    // MARK: Fixtures

    private func writePhoto(_ name: String, width: Int, height: Int) throws -> URL {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        // Noise, so the file does not compress to nothing the way a flat color would.
        let data = try XCTUnwrap(rep.bitmapData)
        var seed: UInt32 = 12345
        for index in 0..<(rep.bytesPerRow * height) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            data[index] = UInt8(truncatingIfNeeded: (seed >> 24) / 4 + UInt32(index % 200))
        }
        let destination = url(name)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: destination)
        return destination
    }

    private static let cubeOBJ = """
    v 0 0 0
    v 1 0 0
    v 1 1 0
    v 0 1 0
    v 0 0 1
    v 1 0 1
    v 1 1 1
    v 0 1 1
    f 1 2 3
    f 1 3 4
    f 5 6 7
    f 5 7 8
    f 1 2 6
    f 1 6 5
    f 3 4 8
    f 3 8 7

    """

    private func writePNG(_ name: String) throws -> URL {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        for x in 0..<32 { for y in 0..<32 { rep.setColor(.systemTeal, atX: x, y: y) } }
        let destination = url(name)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: destination)
        return destination
    }

    private func writeTone(_ name: String) throws -> URL {
        let destination = url(name)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let file = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ])
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        for channel in 0..<2 {
            let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
            for frame in 0..<44_100 { samples[frame] = sin(Float(frame) * 0.06) * 0.4 }
        }
        try file.write(from: buffer)
        return destination
    }
}

enum PDFDocumentProbe {
    static func pageCount(_ url: URL) -> Int? { PDFDocument(url: url)?.pageCount }
    static func firstPageSize(_ url: URL) -> CGSize? { PDFDocument(url: url)?.page(at: 0)?.bounds(for: .mediaBox).size }
}

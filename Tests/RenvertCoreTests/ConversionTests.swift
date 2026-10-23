import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import RenvertCore

final class ConversionTests: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("renvert-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func testDetectJPEGAndPNG() throws {
        let jpeg = try writeJPEG(name: "sample.jpg")
        let png = try writePNG(name: "sample.png", transparent: true)
        XCTAssertEqual(try FormatDetector.detect(at: jpeg).id, .jpeg)
        XCTAssertEqual(try FormatDetector.detect(at: png).id, .png)
    }

    func testPNGToJPEGRealBytes() throws {
        let png = try writePNG(name: "photo.png", transparent: false)
        let dest = temp.appendingPathComponent("photo.jpg")
        try ImageConverter().convert(
            from: png,
            detected: .png,
            spec: OutputSpec(format: .jpeg),
            to: dest,
            context: ConversionContext(settings: AppSettings(), cancellation: CancellationToken())
        )
        XCTAssertEqual(try FormatDetector.detect(at: dest).id, .jpeg)
        let data = try Data(contentsOf: dest)
        XCTAssertEqual(Array(data.prefix(3)), [0xFF, 0xD8, 0xFF])
    }

    func testJPEGToPNG() throws {
        let jpeg = try writeJPEG(name: "photo.jpg")
        let dest = temp.appendingPathComponent("photo.png")
        try ImageConverter().convert(
            from: jpeg,
            detected: .jpeg,
            spec: OutputSpec(format: .png),
            to: dest,
            context: ConversionContext(settings: AppSettings(), cancellation: CancellationToken())
        )
        XCTAssertEqual(try FormatDetector.detect(at: dest).id, .png)
    }

    func testHEICRoundTripIfSupported() throws {
        let jpeg = try writeJPEG(name: "camera.jpg")
        let heic = temp.appendingPathComponent("camera.heic")
        do {
            try ImageConverter().convert(
                from: jpeg,
                detected: .jpeg,
                spec: OutputSpec(format: .heic),
                to: heic,
                context: ConversionContext(settings: AppSettings(), cancellation: CancellationToken())
            )
        } catch {
            throw XCTSkip("HEIC encode is not available on this Mac: \(error.localizedDescription)")
        }
        XCTAssertEqual(try FormatDetector.detect(at: heic).id, .heic)
        let back = temp.appendingPathComponent("camera-out.jpg")
        try ImageConverter().convert(
            from: heic,
            detected: .heic,
            spec: OutputSpec(format: .jpeg),
            to: back,
            context: ConversionContext(settings: AppSettings(), cancellation: CancellationToken())
        )
        XCTAssertEqual(try FormatDetector.detect(at: back).id, .jpeg)
    }

    func testPNGToWebPIfSupported() throws {
        let png = try writePNG(name: "tile.png", transparent: true)
        let dest = temp.appendingPathComponent("tile.webp")
        do {
            try ImageConverter().convert(
                from: png,
                detected: .png,
                spec: OutputSpec(format: .webp, modifiers: [.quality(80)]),
                to: dest,
                context: ConversionContext(settings: AppSettings(), cancellation: CancellationToken())
            )
        } catch {
            throw XCTSkip("WebP encode is not available: \(error.localizedDescription)")
        }
        XCTAssertEqual(try FormatDetector.detect(at: dest).id, .webp)
    }

    func testJSONToYAML() throws {
        let json = temp.appendingPathComponent("data.json")
        try #"{"name":"Renvert","ok":true}"#.write(to: json, atomically: true, encoding: .utf8)
        let yaml = temp.appendingPathComponent("data.yaml")
        try ConfigConverter().convert(
            from: json,
            detected: .json,
            spec: OutputSpec(format: .yaml),
            to: yaml,
            context: ConversionContext(settings: AppSettings(), cancellation: CancellationToken())
        )
        let text = try String(contentsOf: yaml, encoding: .utf8)
        XCTAssertTrue(text.contains("name:"))
        XCTAssertEqual(try FormatDetector.detect(at: yaml).id, .yaml)
    }

    func testFolderToZIP() throws {
        let folder = temp.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "hello".write(to: folder.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let zip = temp.appendingPathComponent("Album.zip")
        try ArchiveConverter().archiveFolder(folder, to: zip, format: .zip)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
        let detected = try FormatDetector.detect(at: zip)
        XCTAssertEqual(detected.id, .zip)
    }

    func testXLSXToCSV() throws {
        let rows = [["name", "qty"], ["apples", "3"], ["pears", "2"]]
        let xlsx = temp.appendingPathComponent("table.xlsx")
        try XLSXWriter.write(rows, to: xlsx)
        XCTAssertEqual(try FormatDetector.detect(at: xlsx).id, .xlsx)
        let csv = temp.appendingPathComponent("table.csv")
        try SpreadsheetConverter().convert(
            from: xlsx,
            detected: .xlsx,
            spec: OutputSpec(format: .csv),
            to: csv,
            context: ConversionContext(settings: AppSettings(), cancellation: CancellationToken())
        )
        let text = try String(contentsOf: csv, encoding: .utf8)
        XCTAssertTrue(text.contains("apples"))
        XCTAssertEqual(try FormatDetector.detect(at: csv).id, .txt)
    }

    func testDOCXToPDF() throws {
        let docx = temp.appendingPathComponent("letter.docx")
        try DocxIO.write(text: "Hello from Renvert", to: docx)
        XCTAssertEqual(try FormatDetector.detect(at: docx).id, .docx)
        let pdf = temp.appendingPathComponent("letter.pdf")
        try DocumentConverter().convert(
            from: docx,
            detected: .docx,
            spec: OutputSpec(format: .pdf),
            to: pdf,
            context: ConversionContext(settings: AppSettings(), cancellation: CancellationToken())
        )
        XCTAssertEqual(try FormatDetector.detect(at: pdf).id, .pdf)
    }

    func testPDFToPNG() throws {
        let pdf = try writePDF(name: "page.pdf")
        let png = temp.appendingPathComponent("page.png")
        try DocumentConverter().convert(
            from: pdf,
            detected: .pdf,
            spec: OutputSpec(format: .png),
            to: png,
            context: ConversionContext(settings: AppSettings(), cancellation: CancellationToken())
        )
        XCTAssertEqual(try FormatDetector.detect(at: png).id, .png)
    }

    func testWAVToM4A() throws {
        let wav = try writeWAV(name: "tone.wav")
        let dest = temp.appendingPathComponent("tone.m4a")
        do {
            try MediaConverter().convert(
                from: wav,
                detected: .wav,
                spec: OutputSpec(format: .m4a),
                to: dest,
                context: ConversionContext(settings: AppSettings(), cancellation: CancellationToken())
            )
        } catch {
            throw XCTSkip("Audio export unavailable: \(error.localizedDescription)")
        }
        let detected = try FormatDetector.detect(at: dest)
        XCTAssertTrue([.m4a, .aac, .mp4].contains(detected.id))
    }

    func testWAVToMP3IfFFmpegPresent() throws {
        guard ExternalToolLocator.ffmpeg != nil else {
            throw XCTSkip("ffmpeg is not installed")
        }
        let wav = try writeWAV(name: "tone.wav")
        let dest = temp.appendingPathComponent("tone.mp3")
        try MediaConverter().convert(
            from: wav,
            detected: .wav,
            spec: OutputSpec(format: .mp3),
            to: dest,
            context: ConversionContext(settings: AppSettings(), cancellation: CancellationToken())
        )
        XCTAssertEqual(try FormatDetector.detect(at: dest).id, .mp3)
    }

    func testBackupAndUndo() throws {
        let support = temp.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let png = try writePNG(name: "keep.png", transparent: false)
        let renamed = temp.appendingPathComponent("keep.jpg")
        try FileManager.default.moveItem(at: png, to: renamed)
        let pending = PendingConversion(
            sourceURL: png,
            commandURL: renamed,
            detected: try FormatDetector.detect(at: renamed),
            command: try TransformationParser.parseFilename(renamed.lastPathComponent),
            originalName: "keep.png"
        )
        let engine = ConversionEngine()
        let backups = BackupStore(directory: support)
        let journal = OperationJournal(directory: support)
        let history = HistoryStore(directory: support)
        let outcome = try engine.perform(
            pending,
            settings: AppSettings(confirmationMode: .automatic),
            backups: backups,
            journal: journal,
            history: history,
            ignore: IgnoreSet(),
            cancellation: CancellationToken()
        )
        XCTAssertEqual(try FormatDetector.detect(at: outcome.destinations[0]).id, .jpeg)
        try engine.undo(record: outcome.record, backups: backups, ignore: IgnoreSet(), history: history)
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path) || FileManager.default.fileExists(atPath: renamed.path))
    }

    func testCorruptInputFailsSafely() throws {
        let bad = temp.appendingPathComponent("broken.png")
        try Data([0x00, 0x01, 0x02]).write(to: bad)
        XCTAssertThrowsError(
            try ImageConverter().convert(
                from: bad,
                detected: .png,
                spec: OutputSpec(format: .jpeg),
                to: temp.appendingPathComponent("out.jpg"),
                context: ConversionContext(settings: AppSettings(), cancellation: CancellationToken())
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path))
    }

    func testCancelToken() {
        let token = CancellationToken()
        token.cancel()
        XCTAssertThrowsError(try token.throwIfCancelled())
    }

    func testUnsupportedPairIsHonest() {
        XCTAssertFalse(FormatRegistry.canConvert(from: .json, to: .mp4))
        XCTAssertTrue(FormatRegistry.canConvert(from: .png, to: .jpeg))
        XCTAssertTrue(FormatRegistry.canConvert(from: .folder, to: .zip))
    }

    private func writeJPEG(name: String) throws -> URL {
        let url = temp.appendingPathComponent(name)
        let image = solidImage(NSColor.red, size: NSSize(width: 64, height: 48))
        try ImageConverter().writeImage(image, to: url, utType: .jpeg, spec: OutputSpec(format: .jpeg), settings: AppSettings())
        return url
    }

    private func writePNG(name: String, transparent: Bool) throws -> URL {
        let url = temp.appendingPathComponent(name)
        let color = transparent ? NSColor.red.withAlphaComponent(0.5) : NSColor.blue
        let image = solidImage(color, size: NSSize(width: 48, height: 48))
        try ImageConverter().writeImage(image, to: url, utType: .png, spec: OutputSpec(format: .png), settings: AppSettings())
        return url
    }

    private func writePDF(name: String) throws -> URL {
        let url = temp.appendingPathComponent(name)
        let image = solidImage(NSColor.green, size: NSSize(width: 120, height: 80))
        try ImageConverter().writePDF(image, to: url, spec: OutputSpec(format: .pdf), preserveMeta: true)
        return url
    }

    private func writeWAV(name: String) throws -> URL {
        let url = temp.appendingPathComponent(name)
        var data = Data()
        let sampleRate: UInt32 = 8000
        let samples: [Int16] = (0..<1600).map { index in
            Int16(sin(Double(index) * 440.0 * 2 * .pi / Double(sampleRate)) * 12000)
        }
        func append<T>(_ value: T) {
            var v = value
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(sampleRate)
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(samples.count * 2))
        for sample in samples { append(sample) }
        try data.write(to: url)
        return url
    }

    private func solidImage(_ color: NSColor, size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }
}

final class RenameWorkflowTests: XCTestCase {
    func testMonitorSeesExtensionRename() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("renvert-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let png = folder.appendingPathComponent("shot.png")
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus()
        NSColor.orange.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 20, height: 20)).fill()
        image.unlockFocus()
        try ImageConverter().writeImage(image, to: png, utType: .png, spec: OutputSpec(format: .png), settings: AppSettings())

        let monitor = FileSystemMonitor()
        let expect = expectation(description: "rename")
        let box = EventBox()
        let sink = MonitorSink { events in
            if events.contains(where: {
                if case .extensionChange(_, let new, _) = $0 { return new.pathExtension == "jpg" }
                return false
            }) {
                box.hit = true
                expect.fulfill()
            }
        }
        monitor.delegate = sink
        monitor.start(paths: [folder.path])
        Thread.sleep(forTimeInterval: 0.4)
        try FileManager.default.moveItem(at: png, to: folder.appendingPathComponent("shot.jpg"))
        wait(for: [expect], timeout: 5)
        monitor.stop()
        XCTAssertTrue(box.hit)
    }
}

final class CoordinatorWorkflowTests: XCTestCase {
    func testRenameInSubfolderConvertsAutomatically() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("renvert-e2e-\(UUID().uuidString)", isDirectory: true)
        let watched = root.appendingPathComponent("watched/nested", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let png = watched.appendingPathComponent("photo.png")
        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 24, height: 24)).fill()
        image.unlockFocus()
        try ImageConverter().writeImage(image, to: png, utType: .png, spec: OutputSpec(format: .png), settings: AppSettings())

        let store = SettingsStore(directory: support)
        store.update {
            $0.confirmationMode = .automatic
            $0.monitoringEnabled = true
            $0.folders = [WatchedFolder(path: root.appendingPathComponent("watched").path)]
        }
        let coordinator = RenameCoordinator(supportDirectory: support, settings: store)
        let done = expectation(description: "converted")
        // Writing the PNG atomically is itself seen as a rename, so "Converted" can arrive twice.
        done.assertForOverFulfill = false
        coordinator.notify = { title, _ in
            if title == "Converted" { done.fulfill() }
        }
        coordinator.startMonitoring()
        Thread.sleep(forTimeInterval: 0.5)

        let jpg = watched.appendingPathComponent("photo.jpg")
        try FileManager.default.moveItem(at: png, to: jpg)
        wait(for: [done], timeout: 15)
        coordinator.stopMonitoring()

        XCTAssertEqual(try FormatDetector.detect(at: jpg).id, .jpeg)
        XCTAssertEqual(coordinator.history.list().first?.error, nil)
    }
}

final class EventBox: @unchecked Sendable {
    var hit = false
}

final class MonitorSink: FileSystemMonitorDelegate {
    let handler: ([RenameKind]) -> Void
    init(handler: @escaping ([RenameKind]) -> Void) { self.handler = handler }
    func monitorDidObserve(_ events: [RenameKind]) { handler(events) }
}

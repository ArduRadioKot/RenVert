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

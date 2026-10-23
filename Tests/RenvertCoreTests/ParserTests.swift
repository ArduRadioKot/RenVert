import XCTest
@testable import RenvertCore

final class ParserTests: XCTestCase {
    func testQualityAndNometa() throws {
        let command = try TransformationParser.parseFilename("photo.webp+q80+nometa")
        XCTAssertEqual(command.stem, "photo")
        XCTAssertEqual(command.outputs.count, 1)
        XCTAssertEqual(command.outputs[0].format, .webp)
        XCTAssertEqual(command.outputs[0].modifiers, [.quality(80), .noMeta])
        XCTAssertFalse(command.skipConfirmation)
    }

    func testMultiOutputPerTargetModifiers() throws {
        let command = try TransformationParser.parseFilename("photo.webp+q80,png")
        XCTAssertEqual(command.outputs.map(\.format), [.webp, .png])
        XCTAssertEqual(command.outputs[0].modifiers, [.quality(80)])
        XCTAssertEqual(command.outputs[1].modifiers, [])
    }

    func testKeepOriginalAndVariants() throws {
        let command = try TransformationParser.parseFilename("photo.jpg,jpg+q60,jpg+q90")
        XCTAssertEqual(command.outputs.count, 3)
        XCTAssertEqual(command.outputs[1].modifiers, [.quality(60)])
    }

    func testSkipConfirmation() throws {
        let command = try TransformationParser.parseFilename("clip.mp4+mute!")
        XCTAssertTrue(command.skipConfirmation)
        XCTAssertEqual(command.outputs[0].modifiers, [.mute])
    }

    func testOpenSettings() throws {
        let command = try TransformationParser.parseFilename("photo.jpg+")
        XCTAssertTrue(command.opensSettings)
    }

    func testFolderZip() throws {
        let command = try TransformationParser.parseFilename("Photos.folder,zip")
        XCTAssertEqual(command.outputs.map(\.format), [.folder, .zip])
    }

    func testTimeAndPages() throws {
        let command = try TransformationParser.parseFilename("movie.mp4+trim1m30-2m+at90+page2-5")
        XCTAssertTrue(command.outputs[0].modifiers.contains(.trim(start: TimeValue(seconds: 90), end: TimeValue(seconds: 120))))
        XCTAssertTrue(command.outputs[0].modifiers.contains(.at(TimeValue(seconds: 90))))
        XCTAssertTrue(command.outputs[0].modifiers.contains(.pages(.closed(2...5))))
    }

    func testSpeedAndSize() throws {
        let command = try TransformationParser.parseFilename("clip.mp4+speed2x+5mb")
        XCTAssertEqual(command.outputs[0].modifiers, [.speed(2), .maxBytes(5_000_000)])
    }

    func testDottedStem() throws {
        let command = try TransformationParser.parseFilename("my.photo.name.png,webp")
        XCTAssertEqual(command.stem, "my.photo.name")
    }

    func testUnknownModifier() {
        XCTAssertThrowsError(try TransformationParser.parseFilename("photo.jpg+notreal"))
    }

    func testCandidateDetection() {
        XCTAssertTrue(TransformationParser.isConversionCandidate(oldName: "a.heic", newName: "a.jpg"))
        XCTAssertFalse(TransformationParser.isConversionCandidate(oldName: "a.jpg", newName: "b.jpg"))
        XCTAssertTrue(TransformationParser.isConversionCandidate(oldName: "a.jpg", newName: "a.jpg+min"))
    }

    func testOutputNamerStripsModifiers() {
        let url = OutputNamer.url(
            directory: URL(fileURLWithPath: "/tmp"),
            stem: "photo",
            spec: OutputSpec(format: .webp, modifiers: [.quality(80)]),
            collidingWith: []
        )
        XCTAssertEqual(url.lastPathComponent, "photo (q80).webp")
        XCTAssertFalse(url.lastPathComponent.contains("+"))
    }
}

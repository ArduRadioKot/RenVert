import XCTest
@testable import RenvertCore

final class UpdateFeedTests: XCTestCase {
    private let repository = "ArduRadioKot/RenVert"

    func testVersionOrdering() {
        XCTAssertEqual(ReleaseVersion("v1.2.3"), ReleaseVersion("1.2.3"))
        XCTAssertLessThan(ReleaseVersion("1.9.0")!, ReleaseVersion("1.10.0")!)
        XCTAssertLessThan(ReleaseVersion("1.2")!, ReleaseVersion("1.2.1")!)
        XCTAssertNil(ReleaseVersion("1.2.0-rc1"))
        XCTAssertNil(ReleaseVersion("nightly"))
    }

    func testNewerReleaseIsAvailable() throws {
        let result = try GitHubUpdateFeed.interpret(
            releaseJSON(tag: "v1.2.0", prerelease: false, assets: [
                asset("Renvert-1.2.0-arm64.dmg", "https://github.com/ArduRadioKot/RenVert/releases/download/v1.2.0/Renvert-1.2.0-arm64.dmg"),
                asset("Renvert-1.2.0.dmg", "https://github.com/ArduRadioKot/RenVert/releases/download/v1.2.0/Renvert-1.2.0.dmg")
            ]),
            currentVersion: "1.0.0",
            statusCode: 200,
            repository: repository
        )
        guard case .available(let update) = result else {
            return XCTFail("expected an update, got \(result)")
        }
        XCTAssertEqual(update.version, "1.2.0")
        XCTAssertEqual(update.assetName, "Renvert-1.2.0.dmg")
        XCTAssertEqual(update.notes, "Fixes")
    }

    func testCurrentAndOlderReleasesAreUpToDate() throws {
        let same = try GitHubUpdateFeed.interpret(
            releaseJSON(tag: "v1.0.0", prerelease: false, assets: [asset("Renvert-1.0.0.dmg", downloadURL("Renvert-1.0.0.dmg"))]),
            currentVersion: "1.0.0",
            statusCode: 200,
            repository: repository
        )
        XCTAssertEqual(same, .upToDate)

        let older = try GitHubUpdateFeed.interpret(
            releaseJSON(tag: "0.9.0", prerelease: false, assets: [asset("Renvert-0.9.0.dmg", downloadURL("Renvert-0.9.0.dmg"))]),
            currentVersion: "1.0.0",
            statusCode: 200,
            repository: repository
        )
        XCTAssertEqual(older, .upToDate)
    }

    func testPrereleaseAndUnstableTagsAreIgnored() throws {
        let preview = try GitHubUpdateFeed.interpret(
            releaseJSON(tag: "v2.0.0", prerelease: true, assets: [asset("Renvert-2.0.0.dmg", downloadURL("Renvert-2.0.0.dmg"))]),
            currentVersion: "1.0.0",
            statusCode: 200,
            repository: repository
        )
        XCTAssertEqual(preview, .upToDate)

        let candidate = try GitHubUpdateFeed.interpret(
            releaseJSON(tag: "v2.0.0-rc1", prerelease: false, assets: [asset("Renvert-2.0.0.dmg", downloadURL("Renvert-2.0.0.dmg"))]),
            currentVersion: "1.0.0",
            statusCode: 200,
            repository: repository
        )
        XCTAssertEqual(candidate, .upToDate)
    }

    func testMissingReleaseAndBadPayload() throws {
        let empty = try GitHubUpdateFeed.interpret(Data(), currentVersion: "1.0.0", statusCode: 404, repository: repository)
        XCTAssertEqual(empty, .nonePublished)
        XCTAssertThrowsError(try GitHubUpdateFeed.interpret(Data("[]".utf8), currentVersion: "1.0.0", statusCode: 200, repository: repository))
        XCTAssertThrowsError(try GitHubUpdateFeed.interpret(Data("{}".utf8), currentVersion: "1.0.0", statusCode: 500, repository: repository))
    }

    func testRejectsForeignAndNonDiskAssets() throws {
        XCTAssertThrowsError(try GitHubUpdateFeed.interpret(
            releaseJSON(tag: "v1.4.0", prerelease: false, assets: [
                asset("Renvert-1.4.0.dmg", "https://example.com/Renvert-1.4.0.dmg"),
                asset("Renvert-1.4.0.zip", downloadURL("Renvert-1.4.0.zip"))
            ]),
            currentVersion: "1.0.0",
            statusCode: 200,
            repository: repository
        )) { error in
            XCTAssertEqual(
                error as? UpdateFeedError,
                .noDiskImage(URL(string: "https://github.com/ArduRadioKot/RenVert/releases/tag/v1.4.0")!)
            )
        }

        XCTAssertFalse(UpdateDownloadPolicy.isTrustedAsset(
            URL(string: "https://github.com/other/RenVert/releases/download/v1.0.0/Renvert-1.0.0.dmg")!,
            repository: repository
        ))
        XCTAssertTrue(UpdateDownloadPolicy.isTrustedRedirect(
            URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1")!
        ))
    }

    private func downloadURL(_ name: String) -> String {
        "https://github.com/ArduRadioKot/RenVert/releases/download/v1.2.0/\(name)"
    }

    private func asset(_ name: String, _ url: String) -> String {
        #"{"name":"\#(name)","browser_download_url":"\#(url)","size":19000000}"#
    }

    private func releaseJSON(tag: String, prerelease: Bool, assets: [String]) -> Data {
        let body = """
        {"tag_name":"\(tag)","html_url":"https://github.com/ArduRadioKot/RenVert/releases/tag/\(tag)","body":"Fixes","prerelease":\(prerelease),"assets":[\(assets.joined(separator: ","))]}
        """
        return Data(body.utf8)
    }
}

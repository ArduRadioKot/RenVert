import Foundation

/// A stable `major.minor.patch` version. Pre-release tags (`1.2.0-rc1`) are rejected.
public struct ReleaseVersion: Comparable, Equatable, Sendable {
    public var numbers: [Int]

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        guard !text.isEmpty, !text.contains(where: { $0 == "-" || $0 == "+" }) else { return nil }
        var numbers: [Int] = []
        for part in text.split(separator: ".", omittingEmptySubsequences: false) {
            guard let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        guard !numbers.isEmpty else { return nil }
        self.numbers = numbers
    }

    public var display: String {
        numbers.map(String.init).joined(separator: ".")
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0..<count {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

public struct AvailableUpdate: Codable, Equatable, Sendable {
    public var version: String
    public var notes: String
    public var assetName: String
    public var downloadURL: URL
    public var releaseURL: URL
    public var byteCount: Int64

    public init(version: String, notes: String, assetName: String, downloadURL: URL, releaseURL: URL, byteCount: Int64) {
        self.version = version
        self.notes = notes
        self.assetName = assetName
        self.downloadURL = downloadURL
        self.releaseURL = releaseURL
        self.byteCount = byteCount
    }
}

public enum UpdateCheck: Equatable, Sendable {
    case upToDate
    case nonePublished
    case available(AvailableUpdate)
}

public enum UpdateFeedError: Error, Equatable {
    case badResponse
    case noDiskImage(URL)
}

public enum UpdateDownloadPolicy {
    /// The release asset must be this repository's own disk image. Redirects may land on GitHub's CDN.
    public static func isTrustedAsset(_ url: URL, repository: String) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        guard host == "github.com" else { return false }
        let prefix = "/" + repository + "/releases/download/"
        return url.path.lowercased().hasPrefix(prefix.lowercased())
    }

    public static func isTrustedRedirect(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }
}

public enum GitHubUpdateFeed {
    public static func latestReleaseURL(repository: String) -> URL? {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
        guard parts.allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) && !$0.isEmpty }) else { return nil }
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    }

    public static func interpret(
        _ data: Data,
        currentVersion: String,
        statusCode: Int,
        repository: String
    ) throws -> UpdateCheck {
        if statusCode == 404 { return .nonePublished }
        guard (200..<300).contains(statusCode) else { throw UpdateFeedError.badResponse }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release: GitHubRelease
        do {
            release = try decoder.decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateFeedError.badResponse
        }
        if release.prerelease { return .upToDate }
        guard let remote = ReleaseVersion(release.tagName), let current = ReleaseVersion(currentVersion) else {
            return .upToDate
        }
        guard remote > current else { return .upToDate }
        guard let asset = preferredDiskImage(in: release, version: remote.display, repository: repository) else {
            throw UpdateFeedError.noDiskImage(release.htmlUrl)
        }
        let notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return .available(AvailableUpdate(
            version: remote.display,
            notes: String(notes.prefix(800)),
            assetName: asset.name,
            downloadURL: asset.browserDownloadUrl,
            releaseURL: release.htmlUrl,
            byteCount: asset.size
        ))
    }

    static func preferredDiskImage(in release: GitHubRelease, version: String, repository: String) -> GitHubRelease.Asset? {
        let candidates = release.assets.filter { asset in
            let name = asset.name.lowercased()
            return name.hasSuffix(".dmg")
                && name.contains("renvert")
                && UpdateDownloadPolicy.isTrustedAsset(asset.browserDownloadUrl, repository: repository)
        }
        return candidates.min { lhs, rhs in
            rank(lhs.name, version: version) < rank(rhs.name, version: version)
        }
    }

    /// Lower is better. The disk image produced by `scripts/package-dmg.sh` is `Renvert-<version>.dmg`.
    private static func rank(_ name: String, version: String) -> Int {
        let lower = name.lowercased()
        if lower == "renvert-\(version).dmg" { return 0 }
        if lower.contains("arm64") || lower.contains("x86") || lower.contains("intel") { return 2 }
        return 1
    }
}

struct GitHubRelease: Decodable, Equatable {
    var tagName: String
    /// `convertFromSnakeCase` turns `html_url` into `htmlUrl`, not `htmlURL`.
    var htmlUrl: URL
    var body: String?
    var prerelease: Bool
    var assets: [Asset]

    struct Asset: Decodable, Equatable {
        var name: String
        var browserDownloadUrl: URL
        var size: Int64
    }
}

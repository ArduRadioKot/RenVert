import Foundation
import Darwin

public struct FileKey: Hashable, Codable, Sendable {
    public var device: UInt64
    public var inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public struct FileRecord: Hashable, Sendable {
    public var key: FileKey
    public var url: URL
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date
}

public enum FileIdentity {
    public static func key(for url: URL) throws -> FileKey {
        var status = stat()
        let result = url.path.withCString { stat($0, &status) }
        guard result == 0 else { throw RenvertError.fileNotFound(url.path) }
        return FileKey(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }

    public static func record(for url: URL) throws -> FileRecord {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey
        ])
        return FileRecord(
            key: try key(for: url),
            url: url.standardizedFileURL,
            name: url.lastPathComponent,
            isDirectory: values.isDirectory ?? false,
            size: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate ?? .distantPast
        )
    }

    public static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }
}

public final class IgnoreSet: @unchecked Sendable {
    private struct Entry {
        var until: Date
        var path: String
        var key: FileKey?
    }

    private let queue = DispatchQueue(label: "app.renvert.ignore")
    private var entries: [Entry] = []

    public init() {}

    public func remember(url: URL, key: FileKey?, duration: TimeInterval = 8) {
        queue.sync {
            entries.append(Entry(until: Date().addingTimeInterval(duration), path: url.standardizedFileURL.path, key: key))
        }
    }

    public func contains(url: URL, key: FileKey?) -> Bool {
        queue.sync {
            pruneLocked()
            let path = url.standardizedFileURL.path
            return entries.contains { entry in
                entry.path == path || (key != nil && entry.key == key)
            }
        }
    }

    private func pruneLocked() {
        let now = Date()
        entries.removeAll { $0.until < now }
    }
}

public enum PathRules {
    public static func shouldIgnore(url: URL, excluded: [String]) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") { return true }
        let lowered = name.lowercased()
        let suffixes = [".tmp", ".crdownload", ".download", ".part", ".partial"]
        if suffixes.contains(where: { lowered.hasSuffix($0) }) { return true }
        if ["thumbs.db", ".ds_store", "desktop.ini"].contains(lowered) { return true }
        let path = url.standardizedFileURL.path
        return excluded.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}

public enum FileStability {
    public static func waitUntilStable(
        url: URL,
        timeout: TimeInterval = 12,
        poll: TimeInterval = 0.2
    ) throws -> FileRecord {
        let deadline = Date().addingTimeInterval(timeout)
        var last: FileRecord?
        var stableCount = 0
        while Date() < deadline {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw RenvertError.fileNotFound(url.path)
            }
            if FileIdentity.isSymlink(url) { throw RenvertError.symlinkSkipped }
            try materializeIfNeeded(url)
            let current = try FileIdentity.record(for: url)
            if let last, last.size == current.size && last.modified == current.modified {
                stableCount += 1
                if stableCount >= 2 { return current }
            } else {
                stableCount = 0
            }
            last = current
            Thread.sleep(forTimeInterval: poll)
        }
        throw RenvertError.fileBusy(url.path)
    }

    public static func materializeIfNeeded(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
        ])
        guard values.isUbiquitousItem == true else { return }
        if values.ubiquitousItemDownloadingStatus == .current { return }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        throw RenvertError.stillDownloading
    }
}

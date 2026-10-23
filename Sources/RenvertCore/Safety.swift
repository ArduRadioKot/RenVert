import Foundation

public struct HistoryRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var sourcePath: String
    public var destinationPaths: [String]
    public var sourceFormat: String
    public var targetFormats: [String]
    public var sourceBytes: Int64
    public var resultBytes: Int64
    public var duration: TimeInterval
    public var backupPath: String?
    public var error: String?
    public var undone: Bool

    public var succeeded: Bool { error == nil }
}

public final class HistoryStore: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "app.renvert.history")
    private var records: [HistoryRecord]

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([HistoryRecord].self, from: data) {
            records = decoded
        } else {
            records = []
        }
    }

    public func list() -> [HistoryRecord] {
        queue.sync { records }
    }

    public func upsert(_ record: HistoryRecord) {
        queue.sync {
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                records[index] = record
            } else {
                records.insert(record, at: 0)
            }
            persistLocked()
        }
    }

    public func clear() {
        queue.sync {
            records = []
            persistLocked()
        }
    }

    private func persistLocked() {
        records = Array(records.prefix(1000))
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

public struct JournalEntry: Codable, Sendable {
    public var id: UUID
    public var sourcePath: String
    public var commandPath: String
    public var backupPath: String
    public var destinationPaths: [String]
    public var startedAt: Date
    public var phase: String
}

public final class OperationJournal: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "app.renvert.journal")

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("journal.json")
    }

    public func write(_ entry: JournalEntry) {
        queue.sync {
            if let data = try? JSONEncoder().encode(entry) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    public func clear() {
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }

    public func pending() -> JournalEntry? {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(JournalEntry.self, from: data)
        }
    }
}

public final class BackupStore {
    public let root: URL
    private let fm = FileManager.default

    public init(directory: URL) {
        root = directory.appendingPathComponent("Backups", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func copyOriginal(_ url: URL, id: UUID) throws -> URL {
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(url.lastPathComponent)
        if url.hasDirectoryPath {
            try fm.copyItem(at: url, to: dest)
        } else {
            try fm.copyItem(at: url, to: dest)
        }
        return dest
    }

    public func restore(backup: URL, to destination: URL) throws {
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: backup, to: destination)
    }

    public func prune(policy: BackupPolicy, records: [HistoryRecord]) {
        let cutoff = Date().addingTimeInterval(-TimeInterval(policy.retainDays * 86_400))
        for record in records where record.createdAt < cutoff {
            if let path = record.backupPath {
                try? fm.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
            }
        }
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
        var total: Int64 = 0
        let sized = folders.compactMap { url -> (URL, Int64)? in
            let size = directorySize(url)
            total += size
            return (url, size)
        }.sorted { $0.1 > $1.1 }
        if total <= policy.maxBytes { return }
        var running = total
        for (url, size) in sized where running > policy.maxBytes {
            try? fm.removeItem(at: url)
            running -= size
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        var total: Int64 = 0
        while let file = enumerator?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}

public enum AtomicWriter {
    public static func replace(original: URL, with converted: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var replaceError: Error?
        coordinator.coordinate(writingItemAt: original, options: .forReplacing, error: &coordinatorError) { url in
            do {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: converted)
            } catch {
                replaceError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let replaceError { throw replaceError }
    }

    public static func move(_ source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            throw RenvertError.destinationConflict(destination.path)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public static func sameVolumeTemp(near url: URL, ext: String) throws -> URL {
        let dir = url.deletingLastPathComponent()
        return dir.appendingPathComponent(".renvert-\(UUID().uuidString).\(ext)")
    }
}

public enum BookmarkStore {
    public static func create(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public static func resolve(_ data: Data) -> URL? {
        var stale = false
        let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        _ = url?.startAccessingSecurityScopedResource()
        return url
    }
}

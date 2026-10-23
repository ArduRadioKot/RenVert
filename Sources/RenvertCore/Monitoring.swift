import Foundation
import CoreServices
import Darwin

public enum RenameKind: Sendable {
    case extensionChange(oldURL: URL, newURL: URL, record: FileRecord)
    case created(URL)
}

public protocol FileSystemMonitorDelegate: AnyObject {
    func monitorDidObserve(_ events: [RenameKind])
}

/// Watches folders with FSEvents and pairs rename halves by inode, so no directory is ever scanned.
///
/// Everything the FSEvents callback reads lives on `queue`; public setters hop onto it.
public final class FileSystemMonitor: @unchecked Sendable {
    private struct Half {
        var path: String
        var seen: Date
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "app.renvert.fsevents")
    private var departed: [UInt64: Half] = [:]
    private var arrived: [UInt64: Half] = [:]
    public weak var delegate: FileSystemMonitorDelegate?
    private var _recursiveDefault = true
    private var _excluded: [String] = []
    private var paths: [String] = []

    public var recursiveDefault: Bool {
        get { queue.sync { _recursiveDefault } }
        set { queue.sync { _recursiveDefault = newValue } }
    }

    public var excluded: [String] {
        get { queue.sync { _excluded } }
        set { queue.sync { _excluded = newValue } }
    }

    public init() {}

    /// The stream retains the monitor, so by now it is already torn down; its final release can run on `queue`
    /// itself, which rules out `queue.sync` here.
    deinit {}

    public func start(paths: [String]) {
        stop()
        let resolved = paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map(Self.realPath)
        queue.sync { self.paths = resolved }
        guard !resolved.isEmpty else { return }

        // The stream retains the monitor so an in-flight callback never sees a freed object.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<FileSystemMonitor>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<FileSystemMonitor>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagUseExtendedData |
            kFSEventStreamCreateFlagNoDefer
        )
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, eventPaths, eventFlags, _ in
                guard let info else { return }
                let monitor = Unmanaged<FileSystemMonitor>.fromOpaque(info).takeUnretainedValue()
                let items = unsafeBitCast(eventPaths, to: NSArray.self)
                var batch: [(path: String, inode: UInt64?, flags: FSEventStreamEventFlags)] = []
                for index in 0..<count {
                    let flag = eventFlags[index]
                    if let dict = items[index] as? NSDictionary,
                       let path = dict[kFSEventStreamEventExtendedDataPathKey as String] as? String {
                        let inode = (dict[kFSEventStreamEventExtendedFileIDKey as String] as? NSNumber)?.uint64Value
                        batch.append((path, inode, flag))
                    } else if let path = items[index] as? String {
                        batch.append((path, nil, flag))
                    }
                }
                monitor.handle(batch)
            },
            &context,
            resolved as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        )
        guard let stream else {
            AppLog.error("FSEvents stream could not be created")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) {
            AppLog.error("FSEvents stream did not start")
        }
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        queue.sync {
            departed.removeAll()
            arrived.removeAll()
        }
    }

    private func handle(_ batch: [(path: String, inode: UInt64?, flags: FSEventStreamEventFlags)]) {
        let now = Date()
        departed = departed.filter { now.timeIntervalSince($0.value.seen) < 5 }
        arrived = arrived.filter { now.timeIntervalSince($0.value.seen) < 5 }

        var observed: [RenameKind] = []
        for event in batch {
            let renamed = event.flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
            let createdFlag = event.flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0
            let url = URL(fileURLWithPath: event.path)
            guard isInsideWatched(url) else { continue }
            let liveInode = currentInode(event.path)

            if renamed, let inode = event.inode ?? liveInode {
                if liveInode == inode {
                    if let old = departed.removeValue(forKey: inode), old.path != event.path {
                        if let change = makeChange(oldPath: old.path, newURL: url) {
                            observed.append(change)
                        }
                    } else {
                        arrived[inode] = Half(path: event.path, seen: now)
                    }
                } else if liveInode == nil {
                    if let new = arrived.removeValue(forKey: inode), new.path != event.path {
                        if let change = makeChange(oldPath: event.path, newURL: URL(fileURLWithPath: new.path)) {
                            observed.append(change)
                        }
                    } else {
                        departed[inode] = Half(path: event.path, seen: now)
                    }
                }
                continue
            }

            if createdFlag, liveInode != nil, !PathRules.shouldIgnore(url: url, excluded: _excluded) {
                observed.append(.created(url))
            }
        }

        if !observed.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.monitorDidObserve(observed)
            }
        }
    }

    private func makeChange(oldPath: String, newURL: URL) -> RenameKind? {
        if PathRules.shouldIgnore(url: newURL, excluded: _excluded) { return nil }
        guard let record = try? FileIdentity.record(for: newURL) else { return nil }
        return .extensionChange(oldURL: URL(fileURLWithPath: oldPath), newURL: newURL, record: record)
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func isInsideWatched(_ url: URL) -> Bool {
        let path = url.path
        return paths.contains { root in
            guard path == root || path.hasPrefix(root + "/") else { return false }
            if _recursiveDefault { return true }
            return url.deletingLastPathComponent().path == root
        }
    }

    private func currentInode(_ path: String) -> UInt64? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }
}

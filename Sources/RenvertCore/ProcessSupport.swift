import Foundation

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
}

public enum ProcessRunner {
    @discardableResult
    public static func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 300,
        cancellation: CancellationToken? = nil
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "DYLD_LIBRARY_PATH")
        environment.removeValue(forKey: "DYLD_FRAMEWORK_PATH")
        environment["DYLD_FALLBACK_LIBRARY_PATH"] = "/opt/homebrew/lib:/usr/local/lib:/usr/lib"
        process.environment = environment

        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if cancellation?.isCancelled == true {
                process.terminate()
                return ProcessResult(exitCode: -2, stdout: "", stderr: "cancelled")
            }
            if Date() > deadline {
                process.terminate()
                return ProcessResult(exitCode: -3, stdout: "", stderr: "timeout")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

public enum ExternalToolLocator {
    public static func find(_ name: String, extra: [URL] = []) -> URL? {
        var candidates: [URL] = extra
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/\(name)") {
            candidates.append(bundled)
        }
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name) {
            candidates.append(exe)
        }
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
            URL(fileURLWithPath: "/opt/local/bin/\(name)"),
            URL(fileURLWithPath: "/usr/bin/\(name)")
        ])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static var ffmpeg: URL? {
        guard let url = find("ffmpeg") else { return nil }
        let probe = ProcessRunner.run(executable: url.path, arguments: ["-version"], timeout: 5)
        return probe.exitCode == 0 ? url : nil
    }
    public static var ffprobe: URL? { find("ffprobe") }
    public static var magick: URL? { find("magick") }
    public static var pandoc: URL? { find("pandoc") }
    public static var soffice: URL? { find("soffice") }
}

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    public func throwIfCancelled() throws {
        if isCancelled { throw RenvertError.cancelled }
    }
}

public enum AppLog {
    public static func info(_ message: String) {
        NSLog("[Renvert] %@", message)
    }

    public static func error(_ message: String) {
        NSLog("[Renvert][error] %@", message)
    }
}

public enum DiskSpace {
    public static func ensureFreeSpace(on url: URL, needed: Int64) throws {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        if available > 0 && available < needed {
            throw RenvertError.notEnoughSpace
        }
    }
}

import Foundation

public enum ConfirmationMode: String, Codable, CaseIterable, Sendable {
    case automatic
    case askFirst
}

public enum PerformanceProfile: String, Codable, CaseIterable, Sendable {
    case low, medium, high

    public var maxConcurrentTasks: Int {
        switch self {
        case .low: return 1
        case .medium: return 2
        case .high: return max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        }
    }

    public var qos: QualityOfService {
        switch self {
        case .low: return .utility
        case .medium: return .userInitiated
        case .high: return .userInitiated
        }
    }
}

public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case english = "en"
    case russian = "ru"
}

public struct WatchedFolder: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var bookmark: Data?
    public var path: String
    public var recursive: Bool
    public var enabled: Bool

    public init(id: UUID = UUID(), bookmark: Data? = nil, path: String, recursive: Bool = true, enabled: Bool = true) {
        self.id = id
        self.bookmark = bookmark
        self.path = path
        self.recursive = recursive
        self.enabled = enabled
    }
}

public struct ConversionDefaults: Codable, Equatable, Sendable {
    public var jpegQuality: Double
    public var webpQuality: Double
    public var preserveMetadata: Bool
    public var hardwareAcceleration: Bool
    public var convertMismatchedNewFiles: Bool

    public init(
        jpegQuality: Double = 0.82,
        webpQuality: Double = 0.8,
        preserveMetadata: Bool = true,
        hardwareAcceleration: Bool = true,
        convertMismatchedNewFiles: Bool = false
    ) {
        self.jpegQuality = jpegQuality
        self.webpQuality = webpQuality
        self.preserveMetadata = preserveMetadata
        self.hardwareAcceleration = hardwareAcceleration
        self.convertMismatchedNewFiles = convertMismatchedNewFiles
    }
}

public struct BackupPolicy: Codable, Equatable, Sendable {
    public var retainDays: Int
    public var maxBytes: Int64

    public init(retainDays: Int = 30, maxBytes: Int64 = 5_000_000_000) {
        self.retainDays = retainDays
        self.maxBytes = maxBytes
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var monitoringEnabled: Bool
    public var launchAtLogin: Bool
    public var confirmationMode: ConfirmationMode
    public var notificationsEnabled: Bool
    public var language: AppLanguage
    public var folders: [WatchedFolder]
    public var excludedPaths: [String]
    public var watchExternalVolumes: Bool
    public var conversion: ConversionDefaults
    public var performance: PerformanceProfile
    public var backups: BackupPolicy
    public var hasCompletedOnboarding: Bool

    public init(
        monitoringEnabled: Bool = true,
        launchAtLogin: Bool = false,
        confirmationMode: ConfirmationMode = .askFirst,
        notificationsEnabled: Bool = true,
        language: AppLanguage = .english,
        folders: [WatchedFolder] = AppSettings.defaultFolders(),
        excludedPaths: [String] = [],
        watchExternalVolumes: Bool = false,
        conversion: ConversionDefaults = ConversionDefaults(),
        performance: PerformanceProfile = .medium,
        backups: BackupPolicy = BackupPolicy(),
        hasCompletedOnboarding: Bool = false
    ) {
        self.monitoringEnabled = monitoringEnabled
        self.launchAtLogin = launchAtLogin
        self.confirmationMode = confirmationMode
        self.notificationsEnabled = notificationsEnabled
        self.language = language
        self.folders = folders
        self.excludedPaths = excludedPaths
        self.watchExternalVolumes = watchExternalVolumes
        self.conversion = conversion
        self.performance = performance
        self.backups = backups
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    public static func defaultFolders() -> [WatchedFolder] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            WatchedFolder(path: home.appendingPathComponent("Desktop").path),
            WatchedFolder(path: home.appendingPathComponent("Downloads").path),
            WatchedFolder(path: home.appendingPathComponent("Documents").path)
        ]
    }
}

public final class SettingsStore: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "app.renvert.settings")
    private var cached: AppSettings

    public init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Renvert", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            cached = decoded
        } else {
            cached = AppSettings()
        }
    }

    public var settings: AppSettings {
        queue.sync { cached }
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        queue.sync {
            mutate(&cached)
            persistLocked()
        }
    }

    private func persistLocked() {
        let data = try? JSONEncoder().encode(cached)
        try? data?.write(to: url, options: .atomic)
    }
}

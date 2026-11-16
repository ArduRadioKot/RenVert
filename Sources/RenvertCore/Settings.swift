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
    /// Format ids the user turned off. A rename that uses one of them is left alone.
    public var disabledFormats: [String]

    public init(
        monitoringEnabled: Bool = true,
        launchAtLogin: Bool = false,
        confirmationMode: ConfirmationMode = .askFirst,
        notificationsEnabled: Bool = true,
        language: AppLanguage = .system,
        folders: [WatchedFolder] = AppSettings.defaultFolders(),
        excludedPaths: [String] = [],
        watchExternalVolumes: Bool = false,
        conversion: ConversionDefaults = ConversionDefaults(),
        performance: PerformanceProfile = .medium,
        backups: BackupPolicy = BackupPolicy(),
        hasCompletedOnboarding: Bool = false,
        disabledFormats: [String] = []
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
        self.disabledFormats = disabledFormats
    }

    public func allowsFormat(_ id: FormatID) -> Bool {
        !disabledFormats.contains(id.rawValue)
    }

    public mutating func setFormat(_ id: FormatID, enabled: Bool) {
        if enabled {
            disabledFormats.removeAll { $0 == id.rawValue }
        } else if !disabledFormats.contains(id.rawValue) {
            disabledFormats.append(id.rawValue)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case monitoringEnabled, launchAtLogin, confirmationMode, notificationsEnabled, language
        case folders, excludedPaths, watchExternalVolumes, conversion, performance, backups
        case hasCompletedOnboarding, disabledFormats
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        monitoringEnabled = try container.decodeIfPresent(Bool.self, forKey: .monitoringEnabled) ?? defaults.monitoringEnabled
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        confirmationMode = try container.decodeIfPresent(ConfirmationMode.self, forKey: .confirmationMode) ?? defaults.confirmationMode
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? defaults.notificationsEnabled
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? defaults.language
        folders = try container.decodeIfPresent([WatchedFolder].self, forKey: .folders) ?? defaults.folders
        excludedPaths = try container.decodeIfPresent([String].self, forKey: .excludedPaths) ?? defaults.excludedPaths
        watchExternalVolumes = try container.decodeIfPresent(Bool.self, forKey: .watchExternalVolumes) ?? defaults.watchExternalVolumes
        conversion = try container.decodeIfPresent(ConversionDefaults.self, forKey: .conversion) ?? defaults.conversion
        performance = try container.decodeIfPresent(PerformanceProfile.self, forKey: .performance) ?? defaults.performance
        backups = try container.decodeIfPresent(BackupPolicy.self, forKey: .backups) ?? defaults.backups
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? defaults.hasCompletedOnboarding
        disabledFormats = try container.decodeIfPresent([String].self, forKey: .disabledFormats) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(monitoringEnabled, forKey: .monitoringEnabled)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(confirmationMode, forKey: .confirmationMode)
        try container.encode(notificationsEnabled, forKey: .notificationsEnabled)
        try container.encode(language, forKey: .language)
        try container.encode(folders, forKey: .folders)
        try container.encode(excludedPaths, forKey: .excludedPaths)
        try container.encode(watchExternalVolumes, forKey: .watchExternalVolumes)
        try container.encode(conversion, forKey: .conversion)
        try container.encode(performance, forKey: .performance)
        try container.encode(backups, forKey: .backups)
        try container.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
        try container.encode(disabledFormats, forKey: .disabledFormats)
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

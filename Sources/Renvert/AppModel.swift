import Foundation
import AppKit
import Combine
import SwiftUI
import UserNotifications
import ServiceManagement
#if canImport(RenvertCore)
import RenvertCore
#endif

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var isMonitoring: Bool
    @Published var activeTasks: [ConversionTaskSnapshot] = []
    @Published var recentTasks: [ConversionTaskSnapshot] = []
    @Published var history: [HistoryRecord] = []
    @Published var pendingQueue: [PendingConversion] = []
    @Published var blockedFolders: [String] = []
    @Published var showOnboarding: Bool
    @Published var lastError: String?
    @Published var updatePhase: UpdatePhase = .idle

    let coordinator: RenameCoordinator
    let updates = UpdateController()
    let settingsStore: SettingsStore
    let supportDirectory: URL
    private var updateObservers: Set<AnyCancellable> = []

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Renvert", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        supportDirectory = support
        let store = SettingsStore(directory: support)
        Self.writeLanguagePreference(store.settings.language)
        Localization.configure(base: Self.stringsBundle, language: store.settings.language)
        settingsStore = store
        settings = store.settings
        isMonitoring = store.settings.monitoringEnabled
        showOnboarding = !store.settings.hasCompletedOnboarding
        coordinator = RenameCoordinator(supportDirectory: support, settings: store)
        coordinator.confirmationHandler = { [weak self] pending in
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.pendingQueue.contains(where: { $0.commandURL == pending.commandURL }) {
                    self.pendingQueue.append(pending)
                }
            }
            return false
        }
        coordinator.notify = { [weak self] title, body in
            DispatchQueue.main.async {
                self?.refreshHistory()
                self?.postNotification(title: title, body: body)
            }
        }
        coordinator.onQueueChange = { [weak self] in
            DispatchQueue.main.async { self?.refreshQueue() }
        }
        refreshHistory()
        applyLaunchAtLogin()
        requestNotificationPermission()
        updates.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                self?.updatePhase = phase
            }
            .store(in: &updateObservers)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.settings.monitoringEnabled {
                self.startWatching()
            }
        }
    }

    /// Touching each folder triggers the macOS privacy prompt; FSEvents stays silent for folders the app may not read.
    func startWatching() {
        let folders = settings.folders.filter(\.enabled).map(\.path)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let blocked = folders.filter { path in
                (try? FileManager.default.contentsOfDirectory(atPath: path)) == nil
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.blockedFolders = blocked
                for path in blocked {
                    AppLog.error("No access to \(path)")
                }
                AppLog.info("Watching \(folders.count - blocked.count) of \(folders.count) folders")
                self.coordinator.startMonitoring()
            }
        }
    }

    func openPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    func refreshQueue() {
        let snap = coordinator.queue.snapshots()
        activeTasks = snap.active
        recentTasks = snap.recent
    }

    func refreshHistory() {
        history = coordinator.history.list()
    }

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        let old = settings
        settingsStore.update(mutate)
        settings = settingsStore.settings
        isMonitoring = settings.monitoringEnabled

        if old.performance != settings.performance {
            coordinator.queue.configure(profile: settings.performance)
        }
        // Restarting FSEvents and re-probing folder access is expensive; sliders fire on every step.
        let watchChanged = old.monitoringEnabled != settings.monitoringEnabled
            || old.folders != settings.folders
            || old.excludedPaths != settings.excludedPaths
        if watchChanged {
            if settings.monitoringEnabled {
                startWatching()
            } else {
                coordinator.stopMonitoring()
                blockedFolders = []
            }
        }
        if old.launchAtLogin != settings.launchAtLogin {
            applyLaunchAtLogin()
        }
        if old.language != settings.language {
            applyLanguage()
        }
    }

    /// Renvert's own strings switch at once; views rebuild because they are keyed on the language.
    private func applyLanguage() {
        Self.writeLanguagePreference(settings.language)
        Localization.setLanguage(settings.language)
        objectWillChange.send()
    }

    /// Bundle that holds the compiled string catalog.
    private static var stringsBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }

    /// System-provided text (open panels, standard controls) follows this from the next launch.
    private static func writeLanguagePreference(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    func removeFolder(_ folder: WatchedFolder) {
        updateSettings { $0.folders.removeAll { $0.id == folder.id } }
    }

    func toggleMonitoring() {
        updateSettings { $0.monitoringEnabled.toggle() }
    }

    func cancel(_ id: UUID) {
        coordinator.queue.cancel(id)
    }

    func cancelAll() {
        coordinator.queue.cancelAll()
    }

    var pendingConfirmation: PendingConversion? { pendingQueue.first }

    func confirmPending() {
        guard !pendingQueue.isEmpty else { return }
        let pending = pendingQueue.removeFirst()
        coordinator.enqueue(pending)
    }

    func declinePending() {
        guard !pendingQueue.isEmpty else { return }
        pendingQueue.removeFirst()
    }

    func dismissHistory(_ record: HistoryRecord) {
        coordinator.history.remove(id: record.id)
        refreshHistory()
    }

    func undo(_ record: HistoryRecord) {
        do {
            try coordinator.engine.undo(record: record, backups: coordinator.backups, ignore: coordinator.ignore, history: coordinator.history)
            refreshHistory()
        } catch {
            refreshHistory()
            lastError = L("Couldn’t undo: \(error.localizedDescription)")
        }
    }

    func completeOnboarding(selected: [WatchedFolder]) {
        updateSettings {
            $0.folders = selected
            $0.hasCompletedOnboarding = true
            $0.monitoringEnabled = true
        }
        showOnboarding = false
    }

    func addFolder(_ url: URL) {
        let bookmark = BookmarkStore.create(for: url)
        updateSettings {
            $0.folders.append(WatchedFolder(bookmark: bookmark, path: url.path, recursive: true, enabled: true))
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func applyLaunchAtLogin() {
        do {
            if settings.launchAtLogin {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AppLog.error("Launch at login: \(error.localizedDescription)")
            lastError = L("Couldn’t change launch at login: \(error.localizedDescription)")
            let actual = SMAppService.mainApp.status == .enabled
            if actual != settings.launchAtLogin {
                settingsStore.update { $0.launchAtLogin = actual }
                settings = settingsStore.settings
            }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postNotification(title: String, body: String) {
        guard settings.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title == "Converted" ? L("Converted") : L("Conversion failed")
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

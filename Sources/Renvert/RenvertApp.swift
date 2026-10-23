import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
#if canImport(RenvertCore)
import RenvertCore
#endif

@main
struct RenvertApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.model)
                .frame(minWidth: 720, minHeight: 480)
        }
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button(String(localized: "Quit Renvert")) {
                    appDelegate.model.quit()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            CommandGroup(replacing: .appInfo) {
                Button(String(localized: "About")) {
                    AppActivation.reveal()
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Renvert"
                    ])
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button(String(localized: "Settings…")) {
                    WindowRouter.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private let statusBar = StatusBarController()
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var confirmPanel: NSPanel?
    private var observers: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app has no windows most of the time; without this macOS quietly kills it to reclaim memory.
        ProcessInfo.processInfo.disableAutomaticTermination("Renvert watches folders from the menu bar")
        statusBar.install(model: model)
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        NotificationCenter.default.addObserver(forName: .renvertOpenOnboarding, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.presentOnboarding() }
        }
        NotificationCenter.default.addObserver(forName: .renvertCloseOnboarding, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onboardingWindow?.close() }
        }
        NotificationCenter.default.addObserver(forName: .renvertOpenSettings, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.presentSettings() }
        }
        NotificationCenter.default.addObserver(forName: .renvertKeepStatusVisible, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.statusBar.install(model: self.model)
            }
        }

        model.$pendingQueue
            .receive(on: RunLoop.main)
            .sink { [weak self] queue in
                if queue.isEmpty {
                    self?.confirmPanel?.orderOut(nil)
                } else {
                    self?.presentConfirmation()
                }
            }
            .store(in: &observers)

        if model.showOnboarding {
            presentOnboarding()
        }
    }

    /// Logs who asked the app to quit, so an unexpected exit can be told apart from a crash.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            AppLog.info("Quit requested by Apple Event from \(name)")
        } else {
            let caller = Thread.callStackSymbols.dropFirst().prefix(12).joined(separator: " | ")
            AppLog.info("Quit requested in-app: \(caller)")
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBar.install(model: model)
        if model.showOnboarding {
            presentOnboarding()
        } else {
            presentSettings()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: .renvertOpenURLs, object: urls)
    }

    @objc func convertService(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let paths = pboard.propertyList(forType: .fileURL) else {
            if let items = pboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
                NotificationCenter.default.post(name: .renvertOpenURLs, object: items.map { URL(fileURLWithPath: $0) })
            }
            return
        }
        _ = paths
    }

    private func presentOnboarding() {
        AppActivation.reveal()
        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = makeWindow(
            OnboardingView().environmentObject(model),
            size: NSSize(width: 460, height: 560),
            style: [.titled, .closable]
        )
        window.makeKeyAndOrderFront(nil)
        onboardingWindow = window
    }

    private func presentSettings() {
        AppActivation.reveal()
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = makeWindow(
            SettingsView().environmentObject(model),
            size: NSSize(width: 720, height: 500),
            style: [.titled, .closable, .miniaturizable, .resizable],
            showsTitle: true
        )
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 720, height: 480)
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    private func presentConfirmation() {
        let panel: NSPanel
        if let existing = confirmPanel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 170),
                styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.title = "Renvert"
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            applyGlass(to: panel, root: ConfirmationView().environmentObject(model), showsTitle: false)
            confirmPanel = panel
        }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.maxX - panel.frame.width - 16,
                y: frame.maxY - panel.frame.height - 12
            ))
        }
        panel.orderFrontRegardless()
    }

    private func makeWindow<Content: View>(
        _ root: Content,
        size: NSSize,
        style: NSWindow.StyleMask,
        showsTitle: Bool = false
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: style.union(.fullSizeContentView),
            backing: .buffered,
            defer: false
        )
        window.title = "Renvert"
        window.isReleasedWhenClosed = false
        applyGlass(to: window, root: root, showsTitle: showsTitle)
        window.center()
        return window
    }

    private func applyGlass<Content: View>(to window: NSWindow, root: Content, showsTitle: Bool) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = showsTitle ? .visible : .hidden
        // Dragging by the background steals mouseDown from SwiftUI buttons, so they never press.
        // Titled windows still move from the title bar.
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = GlassHost.make(root, look: .regular)
    }
}

extension Notification.Name {
    static let renvertOpenURLs = Notification.Name("renvert.openURLs")
    static let renvertOpenOnboarding = Notification.Name("renvert.openOnboarding")
    static let renvertCloseOnboarding = Notification.Name("renvert.closeOnboarding")
    static let renvertOpenSettings = Notification.Name("renvert.openSettings")
    static let renvertKeepStatusVisible = Notification.Name("renvert.keepStatusVisible")
}

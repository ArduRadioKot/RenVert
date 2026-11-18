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
                Button(L("Quit Renvert")) {
                    appDelegate.model.quit()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            CommandGroup(replacing: .appInfo) {
                Button(L("About")) {
                    AppActivation.reveal()
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Renvert"
                    ])
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button(L("Settings…")) {
                    WindowRouter.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
                Button(L("Check for Updates…")) {
                    appDelegate.model.updates.check(userInitiated: true)
                }
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
        NotificationCenter.default.addObserver(forName: .renvertConfirmationHeight, object: nil, queue: .main) { [weak self] note in
            let height = note.object as? CGFloat ?? 0
            Task { @MainActor in self?.resizeConfirmation(height: height) }
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
        model.updates.canPrompt = { [weak self] in
            self?.onboardingWindow?.isVisible != true
        }
        model.updates.start()
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
            OnboardingView(),
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
            SettingsView(),
            size: NSSize(width: 720, height: 500),
            style: [.titled, .closable, .miniaturizable, .resizable],
            chromeless: false
        )
        window.toolbarStyle = .unified
        window.setFrameAutosaveName("RenvertSettings")
        window.minSize = NSSize(width: 720, height: 480)
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    private func presentConfirmation() {
        let panel: NSPanel
        if let existing = confirmPanel {
            panel = existing
        } else {
            panel = ConfirmationPanel(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 460),
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.hasShadow = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            install(ConfirmationView(), in: panel, chromeless: true, cornerRadius: 22)
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

    private func resizeConfirmation(height: CGFloat) {
        guard let panel = confirmPanel, height > 1 else { return }
        let width: CGFloat = 340
        let screen = panel.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? panel.frame
        var frame = panel.frame
        let top = frame.height > 1 ? frame.maxY : visible.maxY - 12
        frame.size = NSSize(width: width, height: height)
        frame.origin.x = min(max(visible.maxX - width - 16, visible.minX + 8), visible.maxX - width - 8)
        frame.origin.y = min(max(top - height, visible.minY + 8), visible.maxY - height - 12)
        panel.setFrame(frame, display: true)
        GlassHost.clearFrame(of: panel, cornerRadius: 22)
    }

    private func makeWindow<Content: View>(
        _ root: Content,
        size: NSSize,
        style: NSWindow.StyleMask,
        chromeless: Bool = true
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: style.union(.fullSizeContentView),
            backing: .buffered,
            defer: false
        )
        window.title = "Renvert"
        window.isReleasedWhenClosed = false
        install(root, in: window, chromeless: chromeless)
        window.center()
        return window
    }

    /// Liquid Glass window with standard macOS controls on top.
    ///
    /// `chromeless` hides the title, for the welcome window and the confirmation panel.
    private func install<Content: View>(_ root: Content, in window: NSWindow, chromeless: Bool, cornerRadius: CGFloat = 0) {
        window.titlebarAppearsTransparent = true
        if chromeless {
            window.titleVisibility = .hidden
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = GlassHost.make(LocalizedRoot(model: model) { root }, cornerRadius: cornerRadius, fitsContent: false)
        if cornerRadius > 0 {
            GlassHost.clearFrame(of: window, cornerRadius: cornerRadius)
        }
    }
}

private final class ConfirmationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var isOpaque: Bool {
        get { false }
        set { super.isOpaque = false }
    }

    override func contentRect(forFrameRect frameRect: NSRect) -> NSRect { frameRect }
    override func frameRect(forContentRect contentRect: NSRect) -> NSRect { contentRect }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            makeKey()
        }
        super.sendEvent(event)
    }
}

/// Rebuilds a window's content when the language changes so every string is looked up again.
struct LocalizedRoot<Content: View>: View {
    @ObservedObject var model: AppModel
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .environmentObject(model)
            .environment(\.locale, Localization.locale)
            .id(model.settings.language)
    }
}

extension Notification.Name {
    static let renvertOpenURLs = Notification.Name("renvert.openURLs")
    static let renvertOpenOnboarding = Notification.Name("renvert.openOnboarding")
    static let renvertCloseOnboarding = Notification.Name("renvert.closeOnboarding")
    static let renvertOpenSettings = Notification.Name("renvert.openSettings")
    static let renvertKeepStatusVisible = Notification.Name("renvert.keepStatusVisible")
    static let renvertConfirmationHeight = Notification.Name("renvert.confirmationHeight")
}

import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    static let autosaveName = "RenvertMenu"

    private var item: NSStatusItem?
    private var panel: MenuPanel?
    private var panelObservers: [NSObjectProtocol] = []
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var lastDismissal = Date.distantPast
    private weak var model: AppModel?

    func install(model: AppModel) {
        self.model = model
        if let item {
            item.isVisible = true
            return
        }
        Self.preferRightSide()
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.autosaveName = Self.autosaveName
        status.behavior = []
        status.isVisible = true
        if let button = status.button {
            button.image = BrandMark.menuImage()
            button.imagePosition = .imageOnly
            button.toolTip = "Renvert"
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.setAccessibilityLabel("Renvert")
        }
        item = status
    }

    func showPopover() {
        guard panel?.isVisible != true else { return }
        presentPanel()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if panel?.isVisible == true {
            dismissPanel()
            return
        }
        // Clicking the status item also resigns the panel's key status; don't reopen it right away.
        guard Date().timeIntervalSince(lastDismissal) > 0.25 else { return }
        presentPanel()
    }

    private func presentPanel() {
        guard let model else { return }
        let content = GlassHost.make(
            MenuBarView().environmentObject(model),
            look: .clear,
            cornerRadius: Self.panelCornerRadius,
            sizesToFitContent: true
        )
        let panel = MenuPanel(
            contentRect: NSRect(origin: .zero, size: content.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.contentView = content
        panel.onCancel = { [weak self] in self?.dismissPanel() }
        self.panel = panel
        positionPanel()

        let center = NotificationCenter.default
        panelObservers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                // Resigning key also happens on the mouse-down that presses a button.
                // Closing immediately cancels that press, so decide on the next turn.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.dismissIfPointerIsOutside() }
                }
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.positionPanel() }
            }
        ]
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.dismissIfPointerIsOutside() }
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // Defer so this callback is not still on the stack when the monitor is removed,
            // and so the button receives the press before the panel decides to close.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.dismissIfPointerIsOutside() }
            }
            return event
        }

        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        content.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Outside clicks and deactivation close the panel. A click on a button is inside the frame
    /// and has to reach that button; closing here used to cancel the press.
    private func dismissIfPointerIsOutside() {
        guard let panel else { return }
        let inside = panel.frame.contains(NSEvent.mouseLocation)
        if inside && (panel.isKeyWindow || NSEvent.pressedMouseButtons != 0) {
            return
        }
        dismissPanel()
    }

    private func dismissPanel() {
        guard let panel else { return }
        self.panel = nil
        lastDismissal = Date()
        panelObservers.forEach(NotificationCenter.default.removeObserver)
        panelObservers = []
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        let fadingView = panel.contentView
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            fadingView?.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
            fadingView?.alphaValue = 1
        }
    }

    /// Keeps the panel's top edge pinned under the status item while its content grows or shrinks.
    private func positionPanel() {
        guard let panel, let button = item?.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        let size = panel.frame.size
        let margin: CGFloat = 8
        let x = min(max(anchor.midX - size.width / 2, visible.minX + margin), visible.maxX - size.width - margin)
        let y = anchor.minY - 6 - size.height
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        panel.invalidateShadow()
    }

    private static let panelCornerRadius: CGFloat = 24

    /// New status items land at the far left of the extras, which is behind the notch on MacBooks.
    /// macOS reads this per-item default, measured from the right screen edge, before placing the item.
    private static func preferRightSide() {
        let defaults = UserDefaults.standard
        let positionKey = "NSStatusItem Preferred Position \(autosaveName)"
        if defaults.object(forKey: positionKey) == nil {
            defaults.set(240.0, forKey: positionKey)
        }
        defaults.set(true, forKey: "NSStatusItem Visible \(autosaveName)")
        defaults.set(true, forKey: "NSStatusItem VisibleCC \(autosaveName)")
    }

}

private final class MenuPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func sendEvent(_ event: NSEvent) {
        // A borderless panel ignores the click that should press a button unless it is already key.
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            makeKey()
        }
        super.sendEvent(event)
    }
}

enum WindowRouter {
    static func showSettings() {
        AppActivation.reveal()
        NotificationCenter.default.post(name: .renvertOpenSettings, object: nil)
    }
}

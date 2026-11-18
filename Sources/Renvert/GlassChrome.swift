import SwiftUI
import AppKit
#if canImport(RenvertCore)
import RenvertCore
#endif

@MainActor
enum GlassHost {
    /// Puts SwiftUI content on a Liquid Glass surface that samples the desktop behind the window.
    ///
    /// The glass is a sibling under the hosting view, not its parent. As the glass view's
    /// `contentView` the hosting view sat below private material layers that swallowed clicks,
    /// and SwiftUI could not reach the window's title bar and toolbar.
    ///
    /// `fitsContent` lets the content size the window (menu bar panel). Windows turn it off so a
    /// NavigationSplitView takes the window's size instead of its own ideal height.
    static func make<Content: View>(_ root: Content, cornerRadius: CGFloat = 0, fitsContent: Bool) -> NSView {
        let hosting = InteractiveHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.focusRingType = .none
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        if !fitsContent {
            hosting.sizingOptions = []
            // Lets `navigationTitle` and SwiftUI toolbars drive the window's title bar.
            hosting.sceneBridgingOptions = [.title, .toolbars]
        }

        let backdrop: NSView
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            // Regular glass frosts what is behind enough to keep text readable. On its own it
            // turns into a near-black slab in Dark Mode, so a white tint lifts it toward the
            // lighter tone of Apple's own panels.
            glass.style = .regular
            // The glass draws a dark fringe on its own edge. Extend it past the clip so that fringe is cut off.
            glass.cornerRadius = cornerRadius > 0 ? cornerRadius + 1 : 0
            glass.tintColor = NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                // Dark mode gets a black veil, which darkens the glass instead of lifting it.
                return dark ? NSColor.black.withAlphaComponent(0.3) : NSColor.white.withAlphaComponent(0.5)
            }
            backdrop = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = fitsContent ? .popover : .underWindowBackground
            effect.blendingMode = .behindWindow
            effect.state = .active
            if cornerRadius > 0 {
                effect.maskImage = roundedMask(radius: cornerRadius)
            }
            backdrop = effect
        }

        let container = NSView()
        container.focusRingType = .none
        let glassOutset: CGFloat
        if #available(macOS 26, *), cornerRadius > 0, backdrop is NSGlassEffectView {
            glassOutset = 1
        } else {
            glassOutset = 0
        }
        pin(backdrop, to: container, outset: glassOutset)
        pin(hosting, to: container, outset: 0)
        container.wantsLayer = true
        container.clipsToBounds = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.isOpaque = false
        if cornerRadius > 0 {
            container.layer?.cornerRadius = cornerRadius
            container.layer?.masksToBounds = true
        }
        return container
    }

    private static func pin(_ view: NSView, to container: NSView, outset: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: -outset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: outset),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: -outset),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: outset)
        ])
    }

    /// The panel's frame view is a square. Past the rounded glass it stays black, which reads as a border.
    static func clearFrame(of window: NSWindow, cornerRadius: CGFloat) {
        guard cornerRadius > 0, let content = window.contentView, !clearingFrame else { return }
        clearingFrame = true
        defer { clearingFrame = false }
        window.isOpaque = false
        window.backgroundColor = .clear
        let scale = window.backingScaleFactor > 1
            ? window.backingScaleFactor
            : (window.screen ?? NSScreen.main)?.backingScaleFactor ?? 2
        for view in [content, content.superview].compactMap({ $0 }) {
            view.wantsLayer = true
            view.clipsToBounds = true
            view.focusRingType = .none
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.isOpaque = false
            view.layer?.borderWidth = 0
            view.layer?.borderColor = NSColor.clear.cgColor
            view.layer?.cornerRadius = cornerRadius
            view.layer?.masksToBounds = true
            view.layer?.contentsScale = scale
        }
        window.invalidateShadow()
    }

    private static var clearingFrame = false

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

extension View {
    /// Liquid Glass button on macOS 26, the standard bordered button before it.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// Glass platter on macOS 26, a soft translucent fill before it.
    @ViewBuilder
    func glassPlatter(cornerRadius: CGFloat = 12) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(.white.opacity(0.06)), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
        }
    }
}

enum AppActivation {
    static func reveal() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .renvertKeepStatusVisible, object: nil)
    }
}

/// Hosting view that accepts the click that also makes the panel key.
final class InteractiveHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }
}

/// Grouped-box platter for banners and grouped rows outside a Form.
struct GlassModule<Content: View>: View {
    var title: String?
    var spacing: CGFloat = 10
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPlatter()
    }
}

struct AccessWarning: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if !model.blockedFolders.isEmpty {
            GlassModule {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.orange.gradient, in: Circle())
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("No access to some folders"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(model.blockedFolders.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(L("Allow Renvert in Privacy & Security → Files and Folders, then relaunch."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // Translated titles can be too long to sit side by side in the menu panel.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { actions }
                            VStack(alignment: .leading, spacing: 6) { actions }
                        }
                        .controlSize(.small)
                        .padding(.top, 2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button(L("Open Settings")) { model.openPrivacySettings() }
            .glassButton(prominent: true)
            .fixedSize()
        Button(L("Check Again")) { model.startWatching() }
            .glassButton()
            .fixedSize()
    }
}

struct ErrorBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let message = model.lastError {
            GlassModule {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.red.gradient, in: Circle())
                    Text(message)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        model.lastError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Dismiss"))
                }
            }
        }
    }
}

struct HoverHighlight: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

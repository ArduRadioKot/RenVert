import SwiftUI
import AppKit

enum GlassLook {
    /// Most transparent Liquid Glass, used for the floating menu bar panel.
    case clear
    /// Standard Liquid Glass, used for windows that hold forms and tables.
    case regular
}

@MainActor
enum GlassHost {
    /// Wraps SwiftUI content in a window-level glass surface that samples the desktop behind the window.
    ///
    /// The hosting view is the glass view's content, and its sizing options are turned off for
    /// windows. Otherwise NavigationSplitView keeps its ideal height (about 2500 pt), gets
    /// centered in the window, and the visible slice is empty glass.
    static func make<Content: View>(
        _ root: Content,
        look: GlassLook,
        cornerRadius: CGFloat = 0,
        sizesToFitContent: Bool = false
    ) -> NSView {
        let hosting = InteractiveHostingView(rootView: root)
        if !sizesToFitContent {
            hosting.sizingOptions = []
        }

        let container: NSView
        if #available(macOS 26, *) {
            let glass = ClickableGlassEffectView()
            // Untinted regular glass, as in Apple's own windows and Control Center:
            // it picks its light or dark tone from the system appearance.
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.tintColor = nil
            glass.contentView = hosting
            container = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = look == .clear ? .popover : .windowBackground
            effect.blendingMode = .behindWindow
            effect.state = .active
            if cornerRadius > 0 {
                effect.maskImage = roundedMask(radius: cornerRadius)
            }
            hosting.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: effect.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
            ])
            container = effect
        }
        return container
    }

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

enum AppActivation {
    static func reveal() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .renvertKeepStatusVisible, object: nil)
    }
}

extension View {
    /// A capsule button whose hit target is the label itself.
    ///
    /// `.glass` / `.glassProminent` nest another glass surface inside the window's
    /// `NSGlassEffectView`. On macOS 26 that inner surface takes the click and the
    /// button action never runs. This style draws on the glass and keeps the press
    /// on the SwiftUI button.
    func glassButton(prominent: Bool = false) -> some View {
        buttonStyle(LiquidButtonStyle(prominent: prominent))
    }
}

/// Hosting view that accepts the click that also makes the panel key.
final class InteractiveHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Glass plate whose private material layers sit above `contentView` and otherwise swallow clicks.
@available(macOS 26, *)
final class ClickableGlassEffectView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in our superview's space, and `hitTest` on the content view expects its
        // superview's space too. Converting into the (flipped) hosting view itself mirrors Y,
        // so clicks land on the wrong control.
        guard frame.contains(point) else { return nil }
        guard let contentView, let host = contentView.superview else { return super.hitTest(point) }
        let local = host.convert(point, from: superview)
        if let hit = contentView.hitTest(local) {
            return hit
        }
        return contentView.frame.contains(local) ? contentView : nil
    }
}

private struct LiquidButtonStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: prominent ? .semibold : .medium))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .contentShape(Capsule())
            .background {
                Capsule(style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.08)))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(prominent ? 0 : 0.12), lineWidth: 0.5)
                    }
                    .allowsHitTesting(false)
            }
            .opacity(!isEnabled ? 0.4 : (configuration.isPressed ? 0.72 : 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var fontSize: CGFloat {
        switch controlSize {
        case .mini: 10
        case .small: 11
        case .large: 14
        case .extraLarge: 15
        default: 13
        }
    }

    private var horizontalPadding: CGFloat {
        switch controlSize {
        case .mini: 7
        case .small: 9
        case .large: 14
        case .extraLarge: 18
        default: 12
        }
    }

    private var verticalPadding: CGFloat {
        switch controlSize {
        case .mini: 2
        case .small: 3
        case .large: 6
        case .extraLarge: 8
        default: 5
        }
    }
}

/// Control Center–style module: a soft platter that sits on top of the glass instead of adding more glass.
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
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
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
                        Text(String(localized: "No access to some folders"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(model.blockedFolders.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(String(localized: "Allow Renvert in Privacy & Security → Files and Folders, then relaunch."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button(String(localized: "Open Settings")) { model.openPrivacySettings() }
                                .glassButton(prominent: true)
                            Button(String(localized: "Check Again")) { model.startWatching() }
                                .glassButton()
                        }
                        .controlSize(.small)
                        .padding(.top, 2)
                    }
                }
            }
        }
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
                    .accessibilityLabel(String(localized: "Dismiss"))
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
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

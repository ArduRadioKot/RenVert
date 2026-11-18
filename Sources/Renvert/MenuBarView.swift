import SwiftUI
import AppKit
#if canImport(RenvertCore)
import RenvertCore
#endif

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .padding(.horizontal, MenuMetrics.inset)
                .padding(.top, 4)

            AccessWarning()
                .padding(.horizontal, MenuMetrics.inset)
            ErrorBanner()
                .padding(.horizontal, MenuMetrics.inset)

            if !model.activeTasks.isEmpty {
                MenuSection(title: L("In progress")) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.activeTasks) { task in
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 26, height: 26)
                                Text(task.name)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Button {
                                    model.cancel(task.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 15))
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(L("Cancel"))
                                .accessibilityLabel(L("Cancel"))
                            }
                        }
                        if model.activeTasks.count > 1 {
                            Button(L("Cancel All"), role: .destructive) { model.cancelAll() }
                                .glassButton()
                                .controlSize(.small)
                        }
                    }
                }
            }

            if let pending = model.pendingConfirmation {
                ConversionPrompt(pending: pending)
                    .id(pending.id)
                    .padding(.horizontal, 4)
            }

            MenuSection(title: L("Recent"), spacing: 2) {
                recentList
            }

            updateRow
            Divider()
                .padding(.horizontal, MenuMetrics.inset)
            footer
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(width: 320)
        .onAppear {
            model.refreshQueue()
            model.refreshHistory()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BrandMark(size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("Renvert")
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.isMonitoring ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(model.isMonitoring ? L("Watching folders") : L("Monitoring paused"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Toggle(isOn: Binding(
                get: { model.isMonitoring },
                set: { _ in model.toggleMonitoring() }
            )) {
                Text(model.isMonitoring ? L("Pause Monitoring") : L("Resume Monitoring"))
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .help(model.isMonitoring ? L("Pause Monitoring") : L("Resume Monitoring"))
        }
    }

    @ViewBuilder
    private var updateRow: some View {
        switch model.updatePhase {
        case .available(let update):
            Button {
                model.updates.install(update)
            } label: {
                Label(String(format: L("Update to %@"), update.version), systemImage: "arrow.down.circle")
            }
            .glassButton(prominent: true)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, MenuMetrics.inset)
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Downloading update…"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ProgressView(value: fraction ?? 0)
                    .progressViewStyle(.linear)
            }
            .padding(.horizontal, MenuMetrics.inset)
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Installing update…"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, MenuMetrics.inset)
        default:
            EmptyView()
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            MenuRow(title: L("Settings…"), shortcut: "⌘,") {
                WindowRouter.showSettings()
            }
            MenuRow(title: L("Quit Renvert"), shortcut: "⌘Q") {
                model.quit()
            }
        }
    }

    @ViewBuilder
    private var recentList: some View {
        let recents = Array(model.history.prefix(5))
        if recents.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(L("No recent conversions"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(recents) { record in
                    RecentConversionRow(record: record)
                        .padding(.horizontal, -MenuMetrics.inset)
                }
            }
            .animation(.easeOut(duration: 0.18), value: recents)
        }
    }

}

struct FormatBadge: View {
    let text: String

    var body: some View {
        Text(text.uppercased().prefix(4))
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// One finished conversion in the menu bar panel. Swipe left to remove it from the list.
struct RecentConversionRow: View {
    @EnvironmentObject private var model: AppModel
    let record: HistoryRecord
    @State private var offset: CGFloat = 0
    @StateObject private var trackpad = TrackpadSwipe()

    private let parked: CGFloat = 72
    private let commit: CGFloat = 120

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                statusIcon
                VStack(alignment: .leading, spacing: 1) {
                    Text(URL(fileURLWithPath: record.sourcePath).lastPathComponent)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(record.error ?? record.targetFormats.joined(separator: ", "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if offset < 0 {
                    withAnimation(.snappy(duration: 0.2)) { offset = 0 }
                } else {
                    model.reveal(record.destinationPaths.first ?? record.sourcePath)
                }
            }
            .gesture(drag)
            .help(L("Show in Finder"))
            if record.succeeded && !record.undone {
                Button(L("Undo")) { model.undo(record) }
                    .glassButton()
                    .controlSize(.small)
            }
        }
        .modifier(HoverHighlight())
        .onHover { inside in
            if inside {
                trackpad.arm()
            } else {
                trackpad.disarm()
            }
        }
        .offset(x: offset)
        .overlay(alignment: .trailing) {
            let revealed = max(0, -offset)
            if revealed > 0 {
                Button {
                    model.dismissHistory(record)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: revealed, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel(L("Remove"))
                .help(L("Remove"))
            }
        }
        .clipped()
        .onAppear { bindTrackpad() }
        .onChange(of: offset) { _, _ in bindTrackpad() }
        .onDisappear { trackpad.disarm() }
    }

    private func bindTrackpad() {
        trackpad.onChange = { offset = min(0, $0) }
        trackpad.onEnd = { settle($0) }
        trackpad.currentOffset = { offset }
    }

    private func settle(_ width: CGFloat) {
        if width < -commit {
            model.dismissHistory(record)
        } else if width < -36 {
            withAnimation(.snappy(duration: 0.2)) { offset = -parked }
        } else {
            withAnimation(.snappy(duration: 0.2)) { offset = 0 }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                offset = min(0, value.translation.width)
            }
            .onEnded { value in
                let width = value.translation.width
                guard abs(width) > abs(value.translation.height), width < 0 else {
                    settle(0)
                    return
                }
                settle(width)
            }
    }

    private var statusIcon: some View {
        let symbol: String
        let tint: Color
        if !record.succeeded {
            symbol = "exclamationmark"
            tint = .red
        } else if record.undone {
            symbol = "arrow.uturn.backward"
            tint = .gray
        } else {
            symbol = "checkmark"
            tint = .green
        }
        return Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(tint.gradient, in: Circle())
    }
}

/// Two-finger trackpad swipe. AppKit reports it as a scroll, not a drag.
final class TrackpadSwipe: ObservableObject {
    var onChange: ((CGFloat) -> Void)?
    var onEnd: ((CGFloat) -> Void)?
    var currentOffset: () -> CGFloat = { 0 }

    private var monitor: Any?
    private var base: CGFloat = 0
    private var moved: CGFloat = 0
    private var tracking = false
    private var ignoreMomentum = false

    func arm() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func disarm() {
        if tracking {
            let width = base + moved
            tracking = false
            moved = 0
            onEnd?(width)
        }
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let trackpad = event.phase != [] || event.momentumPhase != []
        guard trackpad else { return event }

        if event.momentumPhase != [] {
            if ignoreMomentum {
                if event.momentumPhase == .ended { ignoreMomentum = false }
                return nil
            }
            return event
        }

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        if !tracking {
            guard event.phase == .began || event.phase == .changed, abs(dx) > abs(dy) else { return event }
            tracking = true
            base = currentOffset()
            moved = 0
        }

        // Follow the fingers. Natural scrolling already matches them; the other setting does not.
        let finger = event.isDirectionInvertedFromDevice ? dx : -dx
        moved += finger
        let width = base + moved
        onChange?(width)

        if event.phase == .ended || event.phase == .cancelled {
            tracking = false
            ignoreMomentum = true
            let final = width
            moved = 0
            onEnd?(final)
        }
        return nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

enum MenuMetrics {
    /// Text inset from the panel edge, matching the hover highlight's own padding.
    static let inset: CGFloat = 8
}

/// Menu section in the style of system menu bar extras: a small caption above flat rows.
struct MenuSection<Content: View>: View {
    let title: String
    var spacing: CGFloat = 10
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: spacing) {
                content()
            }
        }
        .padding(.horizontal, MenuMetrics.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A menu item row: full-width, highlighted while the pointer is over it.
struct MenuRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                Spacer(minLength: 12)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 13))
                        .foregroundStyle(hovering ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
                }
            }
            .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, MenuMetrics.inset)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Color.accentColor : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

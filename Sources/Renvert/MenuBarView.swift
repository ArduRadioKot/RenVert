import SwiftUI
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
                MenuSection(title: L("Convert")) {
                    HStack(spacing: 10) {
                        FormatBadge(text: pending.detected.id.rawValue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pending.commandURL.lastPathComponent)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(conversionSummary(pending))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button(L("Skip")) { model.declinePending() }
                            .glassButton()
                        Button(L("Convert")) { model.confirmPending() }
                            .keyboardShortcut(.defaultAction)
                            .glassButton(prominent: true)
                    }
                    .controlSize(.regular)
                }
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
                    HStack(spacing: 10) {
                        Button {
                            model.reveal(record.destinationPaths.first ?? record.sourcePath)
                        } label: {
                            HStack(spacing: 10) {
                                statusIcon(for: record)
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
                        }
                        .buttonStyle(.plain)
                        .help(L("Show in Finder"))
                        if record.succeeded && !record.undone {
                            Button(L("Undo")) { model.undo(record) }
                                .glassButton()
                                .controlSize(.small)
                        }
                    }
                    .modifier(HoverHighlight())
                    .padding(.horizontal, -MenuMetrics.inset)
                }
            }
        }
    }

    private func statusIcon(for record: HistoryRecord) -> some View {
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

    private func conversionSummary(_ pending: PendingConversion) -> String {
        let outputs = pending.command.outputs
            .map { FormatRegistry.preferredExtension(for: $0.format) }
            .joined(separator: ", ")
        return "\(pending.detected.id.rawValue.uppercased()) → \(outputs)"
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

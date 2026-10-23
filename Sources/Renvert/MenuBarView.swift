import SwiftUI
#if canImport(RenvertCore)
import RenvertCore
#endif

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 2)

            AccessWarning()
            ErrorBanner()

            if !model.activeTasks.isEmpty {
                GlassModule(title: String(localized: "In progress")) {
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
                                .help(String(localized: "Cancel"))
                                .accessibilityLabel(String(localized: "Cancel"))
                            }
                        }
                        if model.activeTasks.count > 1 {
                            Button(String(localized: "Cancel All"), role: .destructive) { model.cancelAll() }
                                .glassButton()
                                .controlSize(.small)
                        }
                    }
                }
            }

            if let pending = model.pendingConfirmation {
                GlassModule(title: String(localized: "Convert")) {
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
                        Button(String(localized: "Skip")) { model.declinePending() }
                            .glassButton()
                        Button(String(localized: "Convert")) { model.confirmPending() }
                            .keyboardShortcut(.defaultAction)
                            .glassButton(prominent: true)
                    }
                    .controlSize(.regular)
                }
            }

            GlassModule(title: String(localized: "Recent"), spacing: 4) {
                recentList
            }

            footer
                .padding(.top, 2)
        }
        .padding(12)
        .frame(width: 340)
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
                    Text(model.isMonitoring ? String(localized: "Watching folders") : String(localized: "Monitoring paused"))
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
                Text(model.isMonitoring ? String(localized: "Pause Monitoring") : String(localized: "Resume Monitoring"))
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .help(model.isMonitoring ? String(localized: "Pause Monitoring") : String(localized: "Resume Monitoring"))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                WindowRouter.showSettings()
            } label: {
                Label(String(localized: "Settings…"), systemImage: "gearshape")
            }
            .glassButton()
            Spacer(minLength: 8)
            Button(String(localized: "Quit")) {
                model.quit()
            }
            .glassButton()
            .help(String(localized: "Quit Renvert"))
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private var recentList: some View {
        let recents = Array(model.history.prefix(5))
        if recents.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(String(localized: "No recent conversions"))
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
                        .help(String(localized: "Show in Finder"))
                        if record.succeeded && !record.undone {
                            Button(String(localized: "Undo")) { model.undo(record) }
                                .glassButton()
                                .controlSize(.small)
                        }
                    }
                    .modifier(HoverHighlight())
                }
            }
            .padding(.horizontal, -8)
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

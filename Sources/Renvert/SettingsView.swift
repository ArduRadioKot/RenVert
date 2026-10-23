import SwiftUI
import AppKit
#if canImport(RenvertCore)
import RenvertCore
#endif

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general, folders, conversions, performance, history, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .folders: String(localized: "Folders")
        case .conversions: String(localized: "Conversions")
        case .performance: String(localized: "Performance")
        case .history: String(localized: "History")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .folders: "folder"
        case .conversions: "arrow.triangle.2.circlepath"
        case .performance: "speedometer"
        case .history: "clock"
        case .about: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .folders: .blue
        case .conversions: .orange
        case .performance: .green
        case .history: .indigo
        case .about: .teal
        }
    }
}

/// System Settings–style colored rounded-square icon.
struct SidebarIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// System Settings–style sidebar row with its own selection highlight.
struct SidebarRow: View {
    let item: SettingsSection
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SidebarIcon(symbol: item.symbol, tint: item.tint)
                Text(item.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.85))
                                     : AnyShapeStyle(Color.primary.opacity(hovering ? 0.06 : 0)))
            )
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: SettingsSection? = .general

    private var section: SettingsSection { selection ?? .general }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            // A List or Table in the detail reports a huge ideal height. NavigationSplitView
            // then lays itself out at that height and the window shows an empty slice.
            GeometryReader { proxy in
                detail
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        ErrorBanner()
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                    }
                    .navigationTitle(section.title)
            }
        }
        .toolbar(removing: .sidebarToggle)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 720, minHeight: 480)
        .environmentObject(model)
    }

    private var sidebar: some View {
        // Plain buttons instead of a selectable List: the List's outline view never receives
        // clicks inside the window's glass host, so rows could not be selected.
        ScrollView {
            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases) { item in
                    SidebarRow(item: item, isSelected: item == section) {
                        selection = item
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Renvert")
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.isMonitoring ? String(localized: "Watching folders") : String(localized: "Monitoring paused"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(String(localized: "Quit")) {
                    model.quit()
                }
                .glassButton()
                .help(String(localized: "Quit Renvert"))
                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .general: GeneralSettingsView()
        case .folders: FolderSettingsView()
        case .conversions: ConversionSettingsView()
        case .performance: PerformanceSettingsView()
        case .history: HistorySettingsView()
        case .about: AboutSettingsView()
        }
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Toggle(String(localized: "Launch at login"), isOn: binding(\.launchAtLogin))
            Toggle(String(localized: "Watch folders"), isOn: binding(\.monitoringEnabled))
            Picker(String(localized: "When a conversion is detected"), selection: binding(\.confirmationMode)) {
                Text(String(localized: "Convert automatically")).tag(ConfirmationMode.automatic)
                Text(String(localized: "Ask first")).tag(ConfirmationMode.askFirst)
            }
            Toggle(String(localized: "Notifications"), isOn: binding(\.notificationsEnabled))
            Picker(String(localized: "Language"), selection: binding(\.language)) {
                Text(String(localized: "System")).tag(AppLanguage.system)
                Text("English").tag(AppLanguage.english)
                Text("Русский").tag(AppLanguage.russian)
            }
            if model.needsRelaunchForLanguage {
                LabeledContent(String(localized: "The new language applies after a relaunch.")) {
                    Button(String(localized: "Relaunch")) { model.relaunch() }
                        .glassButton(prominent: true)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(8)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in
                model.updateSettings { $0[keyPath: keyPath] = newValue }
            }
        )
    }
}

struct FolderSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AccessWarning()
            Text(String(localized: "Renvert only watches these folders. Drag more in, or grant access when macOS asks."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(model.settings.folders) { folder in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: FileManager.default.fileExists(atPath: folder.path) ? "folder" : "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(URL(fileURLWithPath: folder.path).lastPathComponent)
                                .lineLimit(1)
                            Text(folder.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Toggle(String(localized: "Recursive"), isOn: Binding(
                                get: { folder.recursive },
                                set: { value in
                                    model.updateSettings { settings in
                                        if let index = settings.folders.firstIndex(of: folder) {
                                            settings.folders[index].recursive = value
                                        }
                                    }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                        }
                        Spacer(minLength: 16)
                        Toggle(String(localized: "Enabled"), isOn: Binding(
                            get: { folder.enabled },
                            set: { value in
                                model.updateSettings { settings in
                                    if let index = settings.folders.firstIndex(of: folder) {
                                        settings.folders[index].enabled = value
                                    }
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                        Button {
                            model.removeFolder(folder)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 15))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Remove Folder"))
                        .accessibilityLabel(String(localized: "Remove Folder"))
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { offsets in
                    model.updateSettings { $0.folders.remove(atOffsets: offsets) }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)

            VStack(alignment: .leading, spacing: 10) {
                Button(String(localized: "Add Folder…")) { pickFolder() }
                    .glassButton()
                Toggle(String(localized: "Watch external volumes when they appear"), isOn: Binding(
                    get: { model.settings.watchExternalVolumes },
                    set: { value in model.updateSettings { $0.watchExternalVolumes = value } }
                ))
            }
        }
        .padding(20)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.hasDirectoryPath {
                        DispatchQueue.main.async { model.addFolder(url) }
                    }
                }
            }
            return true
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            panel.urls.forEach(model.addFolder)
        }
    }
}

struct ConversionSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Slider(value: Binding(
                get: { model.settings.conversion.jpegQuality },
                set: { value in model.updateSettings { $0.conversion.jpegQuality = value } }
            ), in: 0.3...1) {
                Text(String(localized: "JPEG quality"))
            }
            Slider(value: Binding(
                get: { model.settings.conversion.webpQuality },
                set: { value in model.updateSettings { $0.conversion.webpQuality = value } }
            ), in: 0.3...1) {
                Text(String(localized: "WebP quality"))
            }
            Toggle(String(localized: "Preserve metadata when the format allows it"), isOn: Binding(
                get: { model.settings.conversion.preserveMetadata },
                set: { value in model.updateSettings { $0.conversion.preserveMetadata = value } }
            ))
            Toggle(String(localized: "Use hardware acceleration"), isOn: Binding(
                get: { model.settings.conversion.hardwareAcceleration },
                set: { value in model.updateSettings { $0.conversion.hardwareAcceleration = value } }
            ))
            Toggle(String(localized: "Offer to convert new files whose extension does not match their contents"), isOn: Binding(
                get: { model.settings.conversion.convertMismatchedNewFiles },
                set: { value in model.updateSettings { $0.conversion.convertMismatchedNewFiles = value } }
            ))
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(8)
    }
}

struct PerformanceSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Picker(String(localized: "Load"), selection: Binding(
                get: { model.settings.performance },
                set: { value in model.updateSettings { $0.performance = value } }
            )) {
                Text(String(localized: "Low")).tag(PerformanceProfile.low)
                Text(String(localized: "Medium")).tag(PerformanceProfile.medium)
                Text(String(localized: "High")).tag(PerformanceProfile.high)
            }
            LabeledContent(String(localized: "Parallel conversions"), value: "\(model.settings.performance.maxConcurrentTasks)")
            Text(String(localized: "Temporary files are written on the same volume as the destination so replacements stay atomic."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(8)
    }
}

struct HistorySettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                Stepper(value: Binding(
                    get: { model.settings.backups.retainDays },
                    set: { value in model.updateSettings { $0.backups.retainDays = value } }
                ), in: 1...365) {
                    Text(String(localized: "Keep backups for \(model.settings.backups.retainDays) days"))
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Button(String(localized: "Clear History")) {
                    model.coordinator.history.clear()
                    model.refreshHistory()
                }
                .glassButton()
                .fixedSize()
            }
            Table(model.history) {
                TableColumn(String(localized: "When")) { record in
                    Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .lineLimit(1)
                }
                .width(min: 120, ideal: 140)
                TableColumn(String(localized: "Source")) { record in
                    Text(URL(fileURLWithPath: record.sourcePath).lastPathComponent)
                        .lineLimit(1)
                }
                TableColumn(String(localized: "Result")) { record in
                    Text(record.error ?? record.targetFormats.joined(separator: ", "))
                        .lineLimit(1)
                }
                TableColumn(String(localized: "Size")) { record in
                    Text(ByteCountFormatter.string(fromByteCount: record.resultBytes, countStyle: .file))
                        .lineLimit(1)
                }
                .width(min: 72, ideal: 88)
                TableColumn("") { record in
                    HStack(spacing: 8) {
                        Button(String(localized: "Show")) {
                            model.reveal(record.destinationPaths.first ?? record.sourcePath)
                        }
                        .fixedSize()
                        if record.succeeded && !record.undone {
                            Button(String(localized: "Undo")) { model.undo(record) }
                                .fixedSize()
                        }
                    }
                }
                .width(min: 132, ideal: 148)
            }
        }
        .padding(20)
        .onAppear { model.refreshHistory() }
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 14) {
            BrandMark(size: 96)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            Text("Renvert")
                .font(.system(size: 26, weight: .bold))
            Text(String(localized: "A native macOS rename-to-convert utility. Files never leave this Mac."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            Text(String(localized: "Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")"))
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text(String(localized: "Authors: FrogeeSoft"))
                    .font(.system(size: 13, weight: .semibold))
                Text("© 2026 FrogeeSoft")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

import SwiftUI
import AppKit
#if canImport(RenvertCore)
import RenvertCore
#endif

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general, folders, conversions, formats, performance, history, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L("General")
        case .folders: L("Folders")
        case .conversions: L("Conversions")
        case .formats: L("Formats")
        case .performance: L("Performance")
        case .history: L("History")
        case .about: L("About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .folders: "folder"
        case .conversions: "arrow.triangle.2.circlepath"
        case .formats: "checklist"
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
        case .formats: .purple
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

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: SettingsSection? = .general

    private var section: SettingsSection { selection ?? .general }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { item in
                Label {
                    Text(item.title)
                } icon: {
                    SidebarIcon(symbol: item.symbol, tint: item.tint)
                }
                .tag(item)
            }
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
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
            }
            .navigationTitle(section.title)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .general: GeneralSettingsView()
        case .folders: FolderSettingsView()
        case .conversions: ConversionSettingsView()
        case .formats: FormatSettingsView()
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
            Toggle(L("Launch at login"), isOn: binding(\.launchAtLogin))
            Toggle(L("Watch folders"), isOn: binding(\.monitoringEnabled))
            Picker(L("When a conversion is detected"), selection: binding(\.confirmationMode)) {
                Text(L("Convert automatically")).tag(ConfirmationMode.automatic)
                Text(L("Ask first")).tag(ConfirmationMode.askFirst)
            }
            Toggle(L("Notifications"), isOn: binding(\.notificationsEnabled))
            Picker(L("Language"), selection: binding(\.language)) {
                Text(L("System")).tag(AppLanguage.system)
                Text("English").tag(AppLanguage.english)
                Text("Русский").tag(AppLanguage.russian)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
        Form {
            if !model.blockedFolders.isEmpty {
                Section {
                    AccessWarning()
                        .listRowInsets(EdgeInsets())
                }
            }
            Section {
                ForEach(model.settings.folders) { folder in
                    FolderRow(folder: folder)
                }
                HStack {
                    Spacer(minLength: 0)
                    Button(L("Add Folder…")) { pickFolder() }
                        .glassButton()
                }
            } footer: {
                Text(L("Renvert only watches these folders. Drag more in, or grant access when macOS asks."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle(L("Watch external volumes when they appear"), isOn: Binding(
                    get: { model.settings.watchExternalVolumes },
                    set: { value in model.updateSettings { $0.watchExternalVolumes = value } }
                ))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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

private struct FolderRow: View {
    @EnvironmentObject private var model: AppModel
    let folder: WatchedFolder

    private var exists: Bool { FileManager.default.fileExists(atPath: folder.path) }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if exists {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                        .resizable()
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.yellow)
                        .padding(4)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: folder.path).lastPathComponent)
                    .lineLimit(1)
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Toggle(L("Recursive"), isOn: binding(\.recursive))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .fixedSize()
            Toggle(L("Enabled"), isOn: binding(\.enabled))
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
            .help(L("Remove Folder"))
            .accessibilityLabel(L("Remove Folder"))
        }
    }

    private func binding(_ keyPath: WritableKeyPath<WatchedFolder, Bool>) -> Binding<Bool> {
        Binding(
            get: { folder[keyPath: keyPath] },
            set: { value in
                model.updateSettings { settings in
                    if let index = settings.folders.firstIndex(where: { $0.id == folder.id }) {
                        settings.folders[index][keyPath: keyPath] = value
                    }
                }
            }
        )
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
                Text(L("JPEG quality"))
            }
            Slider(value: Binding(
                get: { model.settings.conversion.webpQuality },
                set: { value in model.updateSettings { $0.conversion.webpQuality = value } }
            ), in: 0.3...1) {
                Text(L("WebP quality"))
            }
            Toggle(L("Preserve metadata when the format allows it"), isOn: Binding(
                get: { model.settings.conversion.preserveMetadata },
                set: { value in model.updateSettings { $0.conversion.preserveMetadata = value } }
            ))
            Toggle(L("Use hardware acceleration"), isOn: Binding(
                get: { model.settings.conversion.hardwareAcceleration },
                set: { value in model.updateSettings { $0.conversion.hardwareAcceleration = value } }
            ))
            Toggle(L("Offer to convert new files whose extension does not match their contents"), isOn: Binding(
                get: { model.settings.conversion.convertMismatchedNewFiles },
                set: { value in model.updateSettings { $0.conversion.convertMismatchedNewFiles = value } }
            ))
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

struct FormatSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""

    private var groups: [(category: FormatCategory, formats: [FormatDescriptor])] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let order: [FormatCategory] = [
            .image, .audio, .video, .document, .email, .spreadsheet, .config, .geo, .palette,
            .archive, .subtitle, .font, .model, .certificate, .folder, .ebook
        ]
        return order.compactMap { category in
            let formats = FormatRegistry.configurable
                .filter { $0.category == category }
                .filter { descriptor in
                    guard !needle.isEmpty else { return true }
                    let names = ([descriptor.id.rawValue] + descriptor.extensions).joined(separator: " ").lowercased()
                    return names.contains(needle)
                }
                .sorted { $0.id.rawValue < $1.id.rawValue }
            return formats.isEmpty ? nil : (category, formats)
        }
    }

    var body: some View {
        Form {
            Section {
                TextField(L("Search formats"), text: $query)
                HStack {
                    Button(L("Enable all")) {
                        model.updateSettings { $0.disabledFormats = [] }
                    }
                    Button(L("Turn all off")) {
                        let ids = FormatRegistry.configurable.map(\.id.rawValue)
                        model.updateSettings { $0.disabledFormats = ids }
                    }
                }
            } footer: {
                Text(L("Turn a format off and Renvert will ignore it when you rename a file."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.category) { group in
                Section {
                    ForEach(group.formats, id: \.id) { descriptor in
                        Toggle(isOn: binding(descriptor.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(descriptor.id.rawValue.uppercased())
                                Text(descriptor.extensions.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(title(group.category))
                        Spacer()
                        let enabled = group.formats.allSatisfy { model.settings.allowsFormat($0.id) }
                        Button(enabled ? L("Turn off") : L("Turn on")) {
                            let turnOn = !enabled
                            model.updateSettings { settings in
                                for descriptor in group.formats {
                                    settings.setFormat(descriptor.id, enabled: turnOn)
                                }
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func binding(_ id: FormatID) -> Binding<Bool> {
        Binding(
            get: { model.settings.allowsFormat(id) },
            set: { enabled in model.updateSettings { $0.setFormat(id, enabled: enabled) } }
        )
    }

    private func title(_ category: FormatCategory) -> String {
        switch category {
        case .image: L("Images")
        case .audio: L("Audio")
        case .video: L("Video")
        case .document: L("Documents")
        case .email: L("Mail")
        case .spreadsheet: L("Spreadsheets")
        case .config: L("Config")
        case .geo: L("Tracks")
        case .palette: L("Palettes")
        case .archive: L("Archives")
        case .font: L("Fonts")
        case .model: L("3D models")
        case .subtitle: L("Subtitles")
        case .certificate: L("Certificates")
        case .folder: L("Folder")
        case .ebook: L("E-books")
        }
    }
}

struct PerformanceSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Picker(L("Load"), selection: Binding(
                get: { model.settings.performance },
                set: { value in model.updateSettings { $0.performance = value } }
            )) {
                Text(L("Low")).tag(PerformanceProfile.low)
                Text(L("Medium")).tag(PerformanceProfile.medium)
                Text(L("High")).tag(PerformanceProfile.high)
            }
            LabeledContent(L("Parallel conversions"), value: "\(model.settings.performance.maxConcurrentTasks)")
            Text(L("Temporary files are written on the same volume as the destination so replacements stay atomic."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
                    Text(L("Keep backups for \(model.settings.backups.retainDays) days"))
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Button(L("Clear History")) {
                    model.coordinator.history.clear()
                    model.refreshHistory()
                }
                .glassButton()
                .fixedSize()
            }
            Table(model.history) {
                TableColumn(L("When")) { record in
                    Text(record.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Localization.locale)))
                        .lineLimit(1)
                }
                .width(min: 100, ideal: 120)
                TableColumn(L("Source")) { record in
                    Text(URL(fileURLWithPath: record.sourcePath).lastPathComponent)
                        .lineLimit(1)
                }
                .width(min: 80, ideal: 130)
                TableColumn(L("Result")) { record in
                    Text(record.error ?? record.targetFormats.joined(separator: ", "))
                        .lineLimit(1)
                }
                .width(min: 80, ideal: 130)
                TableColumn(L("Size")) { record in
                    Text(ByteCountFormatter.string(fromByteCount: record.resultBytes, countStyle: .file))
                        .lineLimit(1)
                }
                .width(min: 56, ideal: 70)
                TableColumn("") { record in
                    HStack(spacing: 8) {
                        Button(L("Show")) {
                            model.reveal(record.destinationPaths.first ?? record.sourcePath)
                        }
                        .fixedSize()
                        if record.succeeded && !record.undone {
                            Button(L("Undo")) { model.undo(record) }
                                .fixedSize()
                        }
                    }
                }
                .width(min: 110, ideal: 120)
            }
            .tableStyle(.bordered)
            .scrollContentBackground(.hidden)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        }
        .padding(20)
        .onAppear { model.refreshHistory() }
    }
}

struct AboutSettingsView: View {
    @EnvironmentObject private var model: AppModel

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var updateStatus: String {
        switch model.updatePhase {
        case .idle:
            return L("Updates come from GitHub releases.")
        case .checking:
            return L("Checking for updates…")
        case .upToDate:
            return L("Renvert is up to date.")
        case .nonePublished:
            return L("No GitHub releases yet.")
        case .available(let update):
            return String(format: L("Renvert %@ is available"), update.version)
        case .downloading:
            return L("Downloading update…")
        case .installing:
            return L("Installing update…")
        case .failed(let message):
            return message
        }
    }

    private var updateBusy: Bool {
        switch model.updatePhase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            BrandMark(size: 96)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            Text("Renvert")
                .font(.system(size: 26, weight: .bold))
            Text(L("A native macOS rename-to-convert utility. Files never leave this Mac."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            Text(String(format: L("Version %@"), version))
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text(L("Authors: FrogeeSoft"))
                    .font(.system(size: 13, weight: .semibold))
                Text("© 2026 FrogeeSoft")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 8)

            VStack(spacing: 10) {
                Text(updateStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                if case .downloading(let fraction) = model.updatePhase {
                    ProgressView(value: fraction ?? 0)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 280)
                }
                HStack(spacing: 8) {
                    Button(L("Check for Updates…")) {
                        model.updates.check(userInitiated: true)
                    }
                    .glassButton()
                    .disabled(updateBusy)
                    if case .available(let update) = model.updatePhase {
                        Button(L("Install Update")) {
                            model.updates.install(update)
                        }
                        .keyboardShortcut(.defaultAction)
                        .glassButton(prominent: true)
                    }
                }
                .controlSize(.regular)
                Toggle(L("Check for updates automatically"), isOn: Binding(
                    get: { model.updates.automatic },
                    set: { model.updates.automatic = $0 }
                ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

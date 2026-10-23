import SwiftUI
import AppKit
#if canImport(RenvertCore)
import RenvertCore
#endif

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var desktop = true
    @State private var downloads = true
    @State private var documents = true

    var body: some View {
        VStack(spacing: 0) {
            BrandMark(size: 72)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
                .padding(.bottom, 18)

            Text(String(localized: "Rename to convert"))
                .font(.system(size: 26, weight: .bold))
                .padding(.bottom, 8)

            Text(String(localized: "Change a file’s extension in Finder. Renvert converts the actual contents, keeps a backup, and stays in the menu bar."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 22)

            GlassModule(title: String(localized: "Folders to watch"), spacing: 2) {
                folderRow(String(localized: "Desktop"), symbol: "menubar.dock.rectangle", isOn: $desktop)
                folderRow(String(localized: "Downloads"), symbol: "arrow.down.circle.fill", isOn: $downloads)
                folderRow(String(localized: "Documents"), symbol: "doc.fill", isOn: $documents)
            }

            Text(String(localized: "Renvert asks for folder access only for the locations you select. Full Disk Access is optional and only needed to watch locations outside those folders."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
                .padding(.horizontal, 8)

            Spacer(minLength: 20)

            Button {
                let home = FileManager.default.homeDirectoryForCurrentUser
                var folders: [WatchedFolder] = []
                if desktop { folders.append(WatchedFolder(path: home.appendingPathComponent("Desktop").path)) }
                if downloads { folders.append(WatchedFolder(path: home.appendingPathComponent("Downloads").path)) }
                if documents { folders.append(WatchedFolder(path: home.appendingPathComponent("Documents").path)) }
                model.completeOnboarding(selected: folders)
                NotificationCenter.default.post(name: .renvertCloseOnboarding, object: nil)
            } label: {
                Text(String(localized: "Start Watching"))
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .glassButton(prominent: true)
            .controlSize(.extraLarge)
        }
        .padding(.horizontal, 32)
        .padding(.top, 40)
        .padding(.bottom, 28)
        .frame(width: 460, height: 560)
    }

    private func folderRow(_ title: String, symbol: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

struct ConfirmationView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let pending = model.pendingConfirmation {
                HStack(spacing: 12) {
                    FormatBadge(text: pending.detected.id.rawValue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "Convert this file?"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(pending.commandURL.lastPathComponent)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(pending.detected.id.rawValue.uppercased()) → \(pending.command.outputs.map { $0.format.rawValue.uppercased() }.joined(separator: ", "))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button(String(localized: "Show in Finder")) {
                        model.reveal(pending.commandURL.path)
                    }
                    .glassButton()
                    .fixedSize()
                    Spacer(minLength: 8)
                    Button(String(localized: "Skip")) { model.declinePending() }
                        .glassButton()
                        .fixedSize()
                    Button(String(localized: "Convert")) { model.confirmPending() }
                        .keyboardShortcut(.defaultAction)
                        .glassButton(prominent: true)
                        .fixedSize()
                }
            } else {
                Text(String(localized: "No pending conversion"))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 18)
        .frame(width: 400, height: 170)
    }
}

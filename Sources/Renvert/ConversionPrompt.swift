import SwiftUI
import AppKit
#if canImport(RenvertCore)
import RenvertCore
#endif

/// The conversion question, used by the floating panel and the menu bar.
struct ConversionPrompt: View {
    @EnvironmentObject private var model: AppModel
    let pending: PendingConversion
    @State private var settingsOpen = false
    @State private var preview: NSImage?

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center) {
                Text(L("Convert this file?"))
                    .font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 8)
                Button {
                    model.declinePending()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Skip"))
            }

            Image(nsImage: preview ?? NSWorkspace.shared.icon(forFile: pending.commandURL.path))
                .resizable()
                .scaledToFill()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )

            Text(pending.commandURL.lastPathComponent)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 10) {
                formatCard(pending.detected.id.rawValue.uppercased(), caption: L("actual"))
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                formatCard(expectedName, caption: L("expected"))
            }

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { settingsOpen.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .rotationEffect(.degrees(settingsOpen ? 90 : 0))
                        Text(L("Conversion settings"))
                            .font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if settingsOpen {
                    settingsBody
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(byteCount)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(L("Keep original file"), isOn: Binding(
                get: { pending.keepOriginal },
                set: { model.setKeepOriginal($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                model.confirmPending()
            } label: {
                Text(L("Convert Now"))
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .glassButton(prominent: true)
            .controlSize(.large)

            Button {
                model.excludePendingFolder()
            } label: {
                Text(String(format: L("Exclude \"%@\""), abbreviatedFolder))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .onAppear(perform: loadPreview)
        .onChange(of: pending.id) { _, _ in
            settingsOpen = false
            loadPreview()
        }
    }

    private var expectedName: String {
        let names = pending.command.outputs.map { $0.format.rawValue.uppercased() }
        return names.isEmpty ? pending.detected.id.rawValue.uppercased() : names.joined(separator: ", ")
    }

    private var byteCount: String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: pending.commandURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var abbreviatedFolder: String {
        let path = pending.commandURL.deletingLastPathComponent().path
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private var showsQuality: Bool {
        pending.command.outputs.contains { spec in
            FormatRegistry.descriptor(for: spec.format).category == .image || spec.format == .pdf
        }
    }

    private var qualityPercent: Int {
        for spec in pending.command.outputs {
            if let value = spec.quality() { return value }
        }
        let usesWebP = pending.command.outputs.contains { $0.format == .webp }
        let fraction = usesWebP ? model.settings.conversion.webpQuality : model.settings.conversion.jpegQuality
        return Int((fraction * 100).rounded())
    }

    private var otherFlags: [String] {
        var seen: [String] = []
        for spec in pending.command.outputs {
            for modifier in spec.modifiers {
                if case .quality = modifier { continue }
                let label = modifier.shortLabel
                if !seen.contains(label) { seen.append(label) }
            }
        }
        return seen
    }

    @ViewBuilder
    private var settingsBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsQuality {
                HStack {
                    Text(L("Quality"))
                        .font(.system(size: 12))
                    Spacer()
                    Text("\(qualityPercent)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: Binding(
                    get: { Double(qualityPercent) },
                    set: { model.setPendingQuality(Int($0.rounded())) }
                ), in: 30...100)
            }
            if otherFlags.isEmpty && !showsQuality {
                Text(L("No extra settings for this conversion."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if !otherFlags.isEmpty {
                Text(otherFlags.joined(separator: ", "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 16)
    }

    private func formatCard(_ name: String, caption: String) -> some View {
        VStack(spacing: 2) {
            Text(name)
                .font(.system(size: 16, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func loadPreview() {
        let url = pending.commandURL
        let id = pending.id
        preview = NSWorkspace.shared.icon(forFile: url.path)
        Task.detached(priority: .userInitiated) {
            let image = Self.thumbnail(for: url)
            await MainActor.run {
                if id == pending.id { preview = image }
            }
        }
    }

    private static func thumbnail(for url: URL) -> NSImage {
        let side: CGFloat = 168
        guard let source = NSImage(contentsOf: url), source.size.width > 1, source.size.height > 1 else {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        let scale = max(side / source.size.width, side / source.size.height)
        let width = source.size.width * scale
        let height = source.size.height * scale
        source.draw(
            in: NSRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        image.unlockFocus()
        return image
    }
}

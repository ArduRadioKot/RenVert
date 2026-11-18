import Foundation

public struct PendingConversion: Identifiable, Sendable {
    public var id: UUID
    public var sourceURL: URL
    public var commandURL: URL
    public var detected: DetectedFormat
    public var command: ConversionCommand
    public var originalName: String

    public init(id: UUID = UUID(), sourceURL: URL, commandURL: URL, detected: DetectedFormat, command: ConversionCommand, originalName: String) {
        self.id = id
        self.sourceURL = sourceURL
        self.commandURL = commandURL
        self.detected = detected
        self.command = command
        self.originalName = originalName
    }
}

public struct ConversionOutcome: Sendable {
    public var destinations: [URL]
    public var record: HistoryRecord
}

public final class ConversionEngine {
    private let image = ImageConverter()
    private let media = MediaConverter()
    private let documents = DocumentConverter()
    private let sheets = SpreadsheetConverter()
    private let archives = ArchiveConverter()
    private let configs = ConfigConverter()
    private let intelligence = IntelligenceConverter()
    private let models = ModelConverter()
    private let misc = MiscConverter()

    public init() {}

    public func converter(for source: FormatID, target: FormatID) -> Converter? {
        if BeyondConverter.handles(from: source, to: target) { return BeyondConverter() }
        if source == .sqlite || target == .sqlite || source == .jsonl || target == .jsonl { return sheets }
        if source == .eml || source == .emlx { return documents }
        if FormatRegistry.support(from: source, to: target) == .unavailable { return nil }
        let src = FormatRegistry.descriptor(for: source)
        let dst = FormatRegistry.descriptor(for: target)
        // A PDF's own text layer is read by the document converter, which falls back to OCR.
        if target == .txt && src.category == .image { return intelligence }
        if dst.category == .subtitle && (src.category == .audio || src.category == .video) { return media }
        if source == .pdf && imageEncodable.contains(target) { return documents }
        if src.category == .image { return image }
        if src.category == .audio || src.category == .video { return media }
        if [.csv, .tsv, .xlsx].contains(source) && nativeDocuments.contains(target) { return documents }
        if src.category == .document || target == .pdf || target == .docx { return documents }
        if src.category == .spreadsheet || (tableFormats.contains(target) && src.category != .config) { return sheets }
        if src.category == .config { return configs }
        if src.category == .archive || source == .folder { return archives }
        if src.category == .model { return models }
        return misc
    }

    public func perform(
        _ pending: PendingConversion,
        settings: AppSettings,
        backups: BackupStore,
        journal: OperationJournal,
        history: HistoryStore,
        ignore: IgnoreSet,
        cancellation: CancellationToken,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws -> ConversionOutcome {
        let started = Date()
        let source = pending.commandURL
        let recordID = pending.id
        let detected = try FormatDetector.detect(at: source, originalFilename: pending.originalName)
        try cancellation.throwIfCancelled()
        guard settings.allowsFormat(detected.id) else {
            throw RenvertError.formatDisabled(detected.id.rawValue)
        }

        let sourceSize = (try? FileIdentity.record(for: source).size) ?? 0
        try DiskSpace.ensureFreeSpace(on: source, needed: max(sourceSize * 3, 1_000_000))

        let backup = try backups.copyOriginal(source, id: recordID)
        ignore.remember(url: backup, key: try? FileIdentity.key(for: backup))

        var destinations: [URL] = []
        var createdTemps: [URL] = []
        journal.write(JournalEntry(
            id: recordID,
            sourcePath: pending.sourceURL.path,
            commandPath: source.path,
            backupPath: backup.path,
            destinationPaths: [],
            startedAt: started,
            phase: "converting"
        ))

        do {
            let keepSourceName = pending.command.outputs.count == 1 && !pending.command.outputs[0].openSettings
            for (index, spec) in pending.command.outputs.enumerated() {
                try cancellation.throwIfCancelled()
                if spec.format == .folder {
                    continue
                }

                let isIdentity = detected.id == spec.format && spec.isIdentityCandidate
                let dest: URL
                if keepSourceName, pending.command.outputs.count == 1 {
                    dest = cleanedURL(for: source, spec: spec, stem: pending.command.stem)
                } else {
                    dest = OutputNamer.url(
                        directory: source.deletingLastPathComponent(),
                        stem: pending.command.stem,
                        spec: spec,
                        collidingWith: destinations + [source]
                    )
                }

                if isIdentity && dest.standardizedFileURL == source.standardizedFileURL {
                    destinations.append(dest)
                    continue
                }
                if isIdentity && dest.standardizedFileURL != source.standardizedFileURL {
                    try FileManager.default.copyItem(at: source, to: dest)
                    ignore.remember(url: dest, key: try? FileIdentity.key(for: dest))
                    destinations.append(dest)
                    continue
                }

                guard settings.allowsFormat(spec.format) else {
                    throw RenvertError.formatDisabled(spec.format.rawValue)
                }
                let qr = spec.hasQR && QRCode.canConvert(from: detected.id, to: spec.format)
                guard qr || FormatRegistry.canConvert(from: detected.id, to: spec.format) else {
                    throw RenvertError.unsupportedConversion(from: detected.id.rawValue, to: spec.format.rawValue)
                }
                guard let converter = qr ? BeyondConverter() : converter(for: detected.id, target: spec.format) else {
                    throw RenvertError.unsupportedConversion(from: detected.id.rawValue, to: spec.format.rawValue)
                }

                let temp = try AtomicWriter.sameVolumeTemp(near: dest, ext: FormatRegistry.preferredExtension(for: spec.format))
                createdTemps.append(temp)
                var context = ConversionContext(settings: settings, cancellation: cancellation) { value in
                    let overall = (Double(index) + value) / Double(pending.command.outputs.count)
                    onProgress?(overall)
                }
                let extras = ExtraOutputs()
                context.extraOutputs = extras
                do {
                    try converter.convert(from: source, detected: detected.id, spec: spec, to: temp, context: context)
                } catch {
                    createdTemps.append(contentsOf: extras.all)
                    throw error
                }
                createdTemps.append(contentsOf: extras.all)
                try verify(temp, expected: spec.format)

                if dest.standardizedFileURL == source.standardizedFileURL {
                    try AtomicWriter.replace(original: source, with: temp)
                    ignore.remember(url: dest, key: try? FileIdentity.key(for: dest))
                } else {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        throw RenvertError.destinationConflict(dest.path)
                    }
                    try AtomicWriter.move(temp, to: dest)
                    ignore.remember(url: dest, key: try? FileIdentity.key(for: dest))
                }
                destinations.append(dest)

                // Further pages land next to the first as "Name 2.ext", "Name 3.ext".
                let stem = dest.deletingPathExtension().lastPathComponent
                var number = 2
                for extra in extras.all {
                    var target: URL
                    repeat {
                        target = dest.deletingLastPathComponent()
                            .appendingPathComponent("\(stem) \(number).\(dest.pathExtension)")
                        number += 1
                    } while FileManager.default.fileExists(atPath: target.path)
                    try AtomicWriter.move(extra, to: target)
                    ignore.remember(url: target, key: try? FileIdentity.key(for: target))
                    destinations.append(target)
                }
            }

            if !destinations.contains(where: { $0.standardizedFileURL == source.standardizedFileURL }) {
                ignore.remember(url: source, key: try? FileIdentity.key(for: source))
                try FileManager.default.removeItem(at: source)
            }

            journal.clear()
            let resultBytes = destinations.reduce(Int64(0)) { partial, url in
                partial + ((try? FileIdentity.record(for: url).size) ?? 0)
            }
            let record = HistoryRecord(
                id: recordID,
                createdAt: started,
                sourcePath: pending.sourceURL.path,
                destinationPaths: destinations.map(\.path),
                sourceFormat: detected.id.rawValue,
                targetFormats: pending.command.outputs.map(\.format.rawValue),
                sourceBytes: sourceSize,
                resultBytes: resultBytes,
                duration: Date().timeIntervalSince(started),
                backupPath: backup.path,
                error: nil,
                undone: false
            )
            history.upsert(record)
            return ConversionOutcome(destinations: destinations, record: record)
        } catch {
            for temp in createdTemps where FileManager.default.fileExists(atPath: temp.path) {
                try? FileManager.default.removeItem(at: temp)
            }
            try? recover(source: pending.sourceURL, command: source, backup: backup)
            journal.clear()
            let record = HistoryRecord(
                id: recordID,
                createdAt: started,
                sourcePath: pending.sourceURL.path,
                destinationPaths: [],
                sourceFormat: detected.id.rawValue,
                targetFormats: pending.command.outputs.map(\.format.rawValue),
                sourceBytes: sourceSize,
                resultBytes: 0,
                duration: Date().timeIntervalSince(started),
                backupPath: backup.path,
                error: error.localizedDescription,
                undone: false
            )
            history.upsert(record)
            throw error
        }
    }

    public func undo(record: HistoryRecord, backups: BackupStore, ignore: IgnoreSet, history: HistoryStore) throws {
        guard let backupPath = record.backupPath else { throw RenvertError.fileNotFound("backup") }
        let backup = URL(fileURLWithPath: backupPath)
        guard FileManager.default.fileExists(atPath: backup.path) else { throw RenvertError.fileNotFound(backup.path) }
        let restoreURL = URL(fileURLWithPath: record.sourcePath)
        ignore.remember(url: restoreURL, key: nil, duration: 10)
        for path in record.destinationPaths where path != record.sourcePath {
            let dest = URL(fileURLWithPath: path)
            ignore.remember(url: dest, key: try? FileIdentity.key(for: dest))
            try? FileManager.default.removeItem(at: dest)
        }
        try backups.restore(backup: backup, to: restoreURL)
        var updated = record
        updated.undone = true
        history.upsert(updated)
    }

    public func recoverInterrupted(journal: OperationJournal) {
        guard let entry = journal.pending() else { return }
        let backup = URL(fileURLWithPath: entry.backupPath)
        let command = URL(fileURLWithPath: entry.commandPath)
        let original = URL(fileURLWithPath: entry.sourcePath)
        try? recover(source: original, command: command, backup: backup)
        journal.clear()
    }

    private func recover(source: URL, command: URL, backup: URL) throws {
        if FileManager.default.fileExists(atPath: command.path) {
            try FileManager.default.removeItem(at: command)
        }
        if !FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.copyItem(at: backup, to: source)
        }
    }

    private func verify(_ url: URL, expected: FormatID) throws {
        if expected == .folder { return }
        if extensionOnlyFormats.contains(expected) {
            // No signature to check: an empty or missing file is the only detectable failure.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0 else { throw RenvertError.formatMismatch(expected: expected.rawValue, actual: "empty") }
            return
        }
        let detected = try FormatDetector.detect(at: url)
        let aliases: [FormatID: Set<FormatID>] = [
            .jpeg: [.jpeg],
            .mp4: [.mp4, .mov],
            .mov: [.mov, .mp4],
            .m4a: [.m4a, .aac, .mp4],
            .aac: [.aac, .m4a, .mp4],
            .alac: [.alac, .m4a, .mp4],
            .zip: [.zip, .docx, .xlsx, .pptx, .epub, .npz, .pt],
            .npz: [.npz, .zip],
            .pt: [.pt, .zip],
            .docx: [.docx, .zip],
            .xlsx: [.xlsx, .zip],
            .pptx: [.pptx, .zip],
            .epub: [.epub, .zip],
            .tgz: [.tgz, .gzip],
            .odt: [.odt, .zip],
            .cbt: [.cbt, .tar],
            .cbz: [.cbz, .zip],
            .gzip: [.gzip, .tgz],
            .csv: [.csv, .txt],
            .tsv: [.tsv, .txt],
            .markdown: [.markdown, .txt],
            .yaml: [.yaml, .txt],
            .toml: [.toml, .txt],
            .html: [.html, .xml],
            .xml: [.xml, .html],
            .srt: [.srt, .txt, .vtt],
            .vtt: [.vtt, .txt, .srt],
            .gpx: [.gpx, .xml],
            .kml: [.kml, .xml],
            .geojson: [.geojson, .json],
            .jsonl: [.jsonl, .txt, .json],
            .vcf: [.vcf, .txt],
            .ics: [.ics, .txt],
            .eml: [.eml, .txt],
            .opml: [.opml, .xml],
            .b64: [.b64, .txt],
            .ini: [.ini, .txt],
            .env: [.env, .txt],
            .properties: [.properties, .txt],
            .strings: [.strings, .txt],
            .webloc: [.webloc, .plist, .xml],
            .url: [.url, .txt, .ini],
            .rss: [.rss, .xml],
            .atom: [.atom, .xml],
            .tcx: [.tcx, .xml],
            .m3u: [.m3u, .txt],
            .lrc: [.lrc, .txt, .srt],
            .sbv: [.sbv, .txt, .srt],
            .smi: [.smi, .xml, .txt],
            .nmea: [.nmea, .txt],
            .igc: [.igc, .txt],
            .cue: [.cue, .txt],
            .bib: [.bib, .txt],
            .ldif: [.ldif, .txt],
            .gpl: [.gpl, .txt],
            .hex: [.hex, .txt],
            .css: [.css, .txt],
            .clr: [.clr],
            .webm: [.webm, .mkv],
            .mkv: [.mkv, .webm],
            .opus: [.opus, .ogg],
            .ogg: [.ogg, .opus]
        ]
        if detected.id == expected { return }
        if aliases[expected]?.contains(detected.id) == true { return }
        // Plain-text formats share their bytes: a one-line TOML reads as text, a table saved
        // as .txt reads as CSV. Any text is acceptable where text was asked for.
        let textual: Set<FormatID> = [
            .txt, .markdown, .html, .xml, .csv, .tsv, .yaml, .toml, .json, .plist, .srt, .vtt,
            .adoc, .rst, .org, .svg, .jsonl, .vcf, .ics, .eml, .opml, .b64, .gpx, .kml, .tcx,
            .ini, .env, .properties, .strings, .url, .rss, .atom, .m3u, .lrc, .webloc,
            .sbv, .smi, .nmea, .igc, .cue, .bib, .ldif, .gpl, .hex, .css
        ]
        if textual.contains(expected), textual.contains(detected.id), expected != .html, expected != .json, expected != .plist { return }
        throw RenvertError.formatMismatch(expected: expected.rawValue, actual: detected.id.rawValue)
    }

    private func cleanedURL(for commandURL: URL, spec: OutputSpec, stem: String) -> URL {
        commandURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem).\(FormatRegistry.preferredExtension(for: spec.format))")
    }
}

public extension TransformationParser {
    static func safeStem(_ name: String) -> String {
        (try? parseFilename(name).stem) ?? URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    }
}

public final class RenameCoordinator: FileSystemMonitorDelegate {
    public var settingsStore: SettingsStore
    public let engine = ConversionEngine()
    public let ignore = IgnoreSet()
    public let backups: BackupStore
    public let journal: OperationJournal
    public let history: HistoryStore
    public let queue: ConversionQueue
    public let monitor = FileSystemMonitor()

    public var confirmationHandler: ((PendingConversion) -> Bool)?
    public var notify: ((String, String) -> Void)?
    public var onQueueChange: (() -> Void)?

    private var debounce: [String: DispatchWorkItem] = [:]
    private let debounceQueue = DispatchQueue(label: "app.renvert.debounce")

    public init(supportDirectory: URL, settings: SettingsStore) {
        settingsStore = settings
        backups = BackupStore(directory: supportDirectory)
        journal = OperationJournal(directory: supportDirectory)
        history = HistoryStore(directory: supportDirectory)
        queue = ConversionQueue(profile: settings.settings.performance)
        monitor.delegate = self
        queue.onChange = { [weak self] in self?.onQueueChange?() }
        engine.recoverInterrupted(journal: journal)
    }

    public func startMonitoring() {
        let settings = settingsStore.settings
        guard settings.monitoringEnabled else {
            monitor.stop()
            return
        }
        monitor.excluded = settings.excludedPaths + [backups.root.path]
        monitor.recursiveDefault = true
        let paths = settings.folders.filter(\.enabled).map(\.path)
        monitor.start(paths: paths)
    }

    public func stopMonitoring() {
        monitor.stop()
    }

    public func monitorDidObserve(_ events: [RenameKind]) {
        let settings = settingsStore.settings
        for event in events {
            switch event {
            case .extensionChange(let oldURL, let newURL, _):
                AppLog.info("Rename \(oldURL.lastPathComponent) -> \(newURL.lastPathComponent)")
                schedule(oldURL: oldURL, newURL: newURL)
            case .created(let url):
                if settings.conversion.convertMismatchedNewFiles {
                    schedule(oldURL: url, newURL: url)
                }
            }
        }
    }

    public func convertManually(urls: [URL], format: FormatID, modifiers: [Modifier] = []) {
        for url in urls {
            let command = ConversionCommand(
                stem: url.deletingPathExtension().lastPathComponent,
                outputs: [OutputSpec(format: format, modifiers: modifiers)],
                skipConfirmation: true
            )
            enqueue(
                PendingConversion(
                    sourceURL: url,
                    commandURL: url,
                    detected: (try? FormatDetector.detect(at: url)) ?? DetectedFormat(id: .txt, confidence: 0, via: "manual"),
                    command: command,
                    originalName: url.lastPathComponent
                )
            )
        }
    }

    /// Tells a rename made by a person from the way apps save files.
    ///
    /// Editors write to a temporary file and rename it over the document ("safe save"), and
    /// downloads arrive as `.crdownload` or `.part`. Those are renames too, but nobody asked
    /// for a conversion. A request is a file that stays in its folder and trades one known
    /// extension for another.
    static func isUserRename(from oldURL: URL, to newURL: URL) -> Bool {
        guard oldURL.deletingLastPathComponent().standardizedFileURL == newURL.deletingLastPathComponent().standardizedFileURL else {
            return false
        }
        let oldName = oldURL.lastPathComponent
        if oldName.hasPrefix(".") || oldName.hasPrefix("~") || oldName.hasSuffix("~") { return false }
        let oldExt = oldURL.pathExtension.lowercased()
        if oldExt.isEmpty { return true }
        let temporary: Set<String> = ["tmp", "temp", "part", "partial", "crdownload", "download", "swp", "swx", "bak", "lock"]
        if temporary.contains(oldExt) { return false }
        return FormatRegistry.resolve(oldExt) != nil
    }

    private func schedule(oldURL: URL, newURL: URL) {
        if ignore.contains(url: newURL, key: try? FileIdentity.key(for: newURL)) { return }
        if PathRules.shouldIgnore(url: newURL, excluded: settingsStore.settings.excludedPaths) { return }
        debounceQueue.async {
            self.debounce[newURL.path]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.evaluate(oldURL: oldURL, newURL: newURL)
            }
            self.debounce[newURL.path] = work
            self.debounceQueue.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    private func evaluate(oldURL: URL, newURL: URL) {
        do {
            _ = try FileStability.waitUntilStable(url: newURL)
            if ignore.contains(url: newURL, key: try? FileIdentity.key(for: newURL)) { return }
            // A new file (same URL twice) is checked for a wrong extension when that option is on.
            // A rename counts only when the user changed the extension in place.
            let isNewFile = oldURL.standardizedFileURL == newURL.standardizedFileURL
            guard isNewFile || Self.isUserRename(from: oldURL, to: newURL) else { return }
            let command: ConversionCommand
            if isNewFile {
                command = try TransformationParser.parseFilename(newURL.lastPathComponent)
            } else if let parsed = TransformationParser.interpretRename(oldName: oldURL.lastPathComponent, newName: newURL.lastPathComponent) {
                command = parsed
            } else {
                return
            }
            let detected = try FormatDetector.detect(at: newURL, originalFilename: oldURL.lastPathComponent)
            let settings = settingsStore.settings
            // Nothing to offer: .ipynb is JSON inside, .numbers is a ZIP, and so on. Asking to
            // "convert" those would only end in an error, so the rename is left alone.
            let convertible = command.outputs.contains { spec in
                guard settings.allowsFormat(detected.id), settings.allowsFormat(spec.format) else { return false }
                return spec.format == .folder || spec.format == detected.id
                    || FormatRegistry.canConvert(from: detected.id, to: spec.format)
                    || (spec.hasQR && QRCode.canConvert(from: detected.id, to: spec.format))
            }
            guard convertible || command.opensSettings else {
                AppLog.info("Left alone \(newURL.lastPathComponent): no conversion from \(detected.id.rawValue)")
                return
            }
            if command.outputs.count == 1,
               let only = command.outputs.first,
               only.format == detected.id,
               only.isIdentityCandidate,
               !only.openSettings {
                return
            }
            let pending = PendingConversion(
                sourceURL: oldURL,
                commandURL: newURL,
                detected: detected,
                command: command,
                originalName: oldURL.lastPathComponent
            )
            let needsAsk = settings.confirmationMode == .askFirst && !command.skipConfirmation || command.opensSettings
            if needsAsk {
                DispatchQueue.main.async {
                    if self.confirmationHandler?(pending) == true {
                        self.enqueue(pending)
                    }
                }
            } else {
                enqueue(pending)
            }
        } catch {
            AppLog.error("Skipped \(newURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public func enqueue(_ pending: PendingConversion) {
        let settings = settingsStore.settings
        _ = queue.submit(id: pending.id, name: pending.commandURL.lastPathComponent) { [weak self] token in
            guard let self else { return }
            do {
                let outcome = try self.engine.perform(
                    pending,
                    settings: settings,
                    backups: self.backups,
                    journal: self.journal,
                    history: self.history,
                    ignore: self.ignore,
                    cancellation: token,
                    onProgress: { value in self.queue.updateProgress(pending.id, value) }
                )
                self.notify?("Converted", outcome.destinations.map(\.lastPathComponent).joined(separator: ", "))
            } catch {
                self.notify?("Conversion failed", error.localizedDescription)
                throw error
            }
        }
    }
}

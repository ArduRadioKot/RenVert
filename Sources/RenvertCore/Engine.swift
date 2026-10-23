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
    private let misc = MiscConverter()

    public init() {}

    public func converter(for source: FormatID, target: FormatID) -> Converter? {
        if FormatRegistry.support(from: source, to: target) == .unavailable { return nil }
        let src = FormatRegistry.descriptor(for: source)
        let dst = FormatRegistry.descriptor(for: target)
        if target == .txt && (src.category == .image || source == .pdf) { return intelligence }
        if dst.category == .subtitle && (src.category == .audio || src.category == .video) { return media }
        if src.category == .image || (source == .pdf && imageEncodable.contains(target)) { return image }
        if src.category == .audio || src.category == .video { return media }
        if src.category == .document || target == .pdf || target == .docx { return documents }
        if src.category == .spreadsheet || tableFormats.contains(target) && src.category != .config { return sheets }
        if src.category == .config { return configs }
        if src.category == .archive || source == .folder { return archives }
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
        let detected = try FormatDetector.detect(at: source)
        try cancellation.throwIfCancelled()

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
                    dest = cleanedURL(for: source, spec: spec)
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

                guard FormatRegistry.canConvert(from: detected.id, to: spec.format) else {
                    throw RenvertError.unsupportedConversion(from: detected.id.rawValue, to: spec.format.rawValue)
                }
                guard let converter = converter(for: detected.id, target: spec.format) else {
                    throw RenvertError.unsupportedConversion(from: detected.id.rawValue, to: spec.format.rawValue)
                }

                let temp = try AtomicWriter.sameVolumeTemp(near: dest, ext: FormatRegistry.preferredExtension(for: spec.format))
                createdTemps.append(temp)
                let context = ConversionContext(settings: settings, cancellation: cancellation) { value in
                    let overall = (Double(index) + value) / Double(pending.command.outputs.count)
                    onProgress?(overall)
                }
                try converter.convert(from: source, detected: detected.id, spec: spec, to: temp, context: context)
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
        let detected = try FormatDetector.detect(at: url)
        let aliases: [FormatID: Set<FormatID>] = [
            .jpeg: [.jpeg],
            .mp4: [.mp4, .mov],
            .m4a: [.m4a, .aac, .mp4],
            .zip: [.zip, .docx, .xlsx, .pptx, .epub],
            .docx: [.docx, .zip],
            .xlsx: [.xlsx, .zip],
            .tgz: [.tgz, .gzip],
            .gzip: [.gzip, .tgz]
        ]
        if detected.id == expected { return }
        if aliases[expected]?.contains(detected.id) == true { return }
        throw RenvertError.formatMismatch(expected: expected.rawValue, actual: detected.id.rawValue)
    }

    private func cleanedURL(for commandURL: URL, spec: OutputSpec) -> URL {
        let destName = "\(TransformationParser.safeStem(commandURL.lastPathComponent)).\(FormatRegistry.preferredExtension(for: spec.format))"
        // Prefer parsed stem from the command name itself.
        if let parsed = try? TransformationParser.parseFilename(commandURL.lastPathComponent) {
            return commandURL.deletingLastPathComponent()
                .appendingPathComponent("\(parsed.stem).\(FormatRegistry.preferredExtension(for: spec.format))")
        }
        return commandURL.deletingLastPathComponent().appendingPathComponent(destName)
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
            guard TransformationParser.isConversionCandidate(oldName: oldURL.lastPathComponent, newName: newURL.lastPathComponent)
                    || (try? TransformationParser.parseFilename(newURL.lastPathComponent)) != nil else { return }
            let command = try TransformationParser.parseFilename(newURL.lastPathComponent)
            let detected = try FormatDetector.detect(at: newURL)
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
            let settings = settingsStore.settings
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

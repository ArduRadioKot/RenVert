import AppKit
#if canImport(RenvertCore)
import RenvertCore
#endif

enum UpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case nonePublished
    case available(AvailableUpdate)
    case downloading(Double?)
    case installing
    case failed(String)
}

enum UpdateConfiguration {
    static var repository: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "RenvertGitHubRepository") as? String,
           GitHubUpdateFeed.latestReleaseURL(repository: value) != nil {
            return value
        }
        return "ArduRadioKot/RenVert"
    }

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "app.renvert.macos"
    }
}

/// Checks GitHub releases and replaces this app with the disk image from a newer stable release.
@MainActor
final class UpdateController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var phase: UpdatePhase = .idle
    @Published var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: Keys.automatic) }
    }

    /// Return false while onboarding is on screen so the prompt waits for the next check.
    var canPrompt: () -> Bool = { true }

    private var timer: Timer?
    private var downloadWatcher: DownloadWatcher?
    private var checkInFlight = false
    private var downloadPanel: NSPanel?
    private var progressIndicator: NSProgressIndicator?
    private var cancelled = false

    override init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.automatic) == nil {
            automatic = true
        } else {
            automatic = defaults.bool(forKey: Keys.automatic)
        }
        super.init()
    }

    func start() {
        if let cached = cachedUpdate(), isNewer(cached.version) {
            phase = .available(cached)
        }
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await self.checkIfDue()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkIfDue()
            }
        }
    }

    func check(userInitiated: Bool) {
        guard !isBusy, !checkInFlight else { return }
        Task { await self.checkNow(userInitiated: userInitiated) }
    }

    func install(_ update: AvailableUpdate) {
        guard !isBusy else { return }
        Task { await self.downloadAndInstall(update) }
    }

    @objc private func cancelDownload() {
        cancelled = true
        downloadWatcher?.cancel()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === downloadPanel {
            cancelDownload()
        }
        return true
    }

    private var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    private func checkIfDue() async {
        guard automatic, !isBusy, !checkInFlight else { return }
        let last = UserDefaults.standard.object(forKey: Keys.lastCheck) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 6 * 60 * 60 else { return }
        await checkNow(userInitiated: false)
    }

    private func checkNow(userInitiated: Bool) async {
        checkInFlight = true
        defer { checkInFlight = false }
        let remembered = phase
        phase = .checking
        do {
            let result = try await fetchLatest()
            UserDefaults.standard.set(Date(), forKey: Keys.lastCheck)
            switch result {
            case .upToDate:
                clearCache()
                phase = userInitiated ? .upToDate : .idle
                if userInitiated { showNotice(L("Renvert is up to date.")) }
            case .nonePublished:
                clearCache()
                phase = userInitiated ? .nonePublished : .idle
                if userInitiated { showNotice(L("No GitHub releases yet.")) }
            case .available(let update):
                cache(update)
                phase = .available(update)
                if userInitiated || shouldPrompt(update) {
                    prompt(update, userInitiated: userInitiated)
                }
            }
        } catch let error as UpdateFeedError {
            switch error {
            case .noDiskImage(let page):
                UserDefaults.standard.set(Date(), forKey: Keys.lastCheck)
                let text = L("The release has no Renvert disk image.")
                phase = userInitiated ? .failed(text) : restore(remembered)
                if userInitiated { showMissingImageAlert(text, page: page) }
            case .badResponse:
                let text = L("Couldn’t check for updates.")
                phase = userInitiated ? .failed(text) : restore(remembered)
                if userInitiated { showNotice(text) }
            }
        } catch {
            let text = String(format: L("Couldn’t check for updates: %@"), error.localizedDescription)
            phase = userInitiated ? .failed(text) : restore(remembered)
            if userInitiated {
                showNotice(text)
            } else {
                AppLog.error("Update check failed: \(error.localizedDescription)")
            }
        }
    }

    private func downloadAndInstall(_ update: AvailableUpdate) async {
        guard UpdateDownloadPolicy.isTrustedAsset(update.downloadURL, repository: UpdateConfiguration.repository) else {
            let text = L("The release has no Renvert disk image.")
            phase = .failed(text)
            showNotice(text)
            return
        }
        guard let destination = installationDestination() else {
            let text = L("Renvert can’t update itself from this folder. Move it to Applications and try again.")
            phase = .failed(text)
            showNotice(text)
            return
        }

        cancelled = false
        phase = .downloading(nil)
        showDownloadPanel()
        let diskImage = FileManager.default.temporaryDirectory.appendingPathComponent("Renvert-\(UUID().uuidString).dmg")
        defer {
            try? FileManager.default.removeItem(at: diskImage)
            downloadPanel?.orderOut(nil)
        }

        do {
            try await download(update, to: diskImage)
            if cancelled { throw CancellationError() }
            phase = .installing
            progressIndicator?.isIndeterminate = true
            progressIndicator?.startAnimation(nil)
            let staged = try await Task.detached {
                try Self.extractApp(
                    from: diskImage,
                    expectedVersion: update.version,
                    bundleIdentifier: UpdateConfiguration.bundleIdentifier
                )
            }.value
            if cancelled {
                try? FileManager.default.removeItem(at: staged)
                throw CancellationError()
            }
            try launchInstaller(staged: staged, destination: destination)
            phase = .installing
            NSApp.terminate(nil)
        } catch is CancellationError {
            downloadPanel?.orderOut(nil)
            phase = .available(update)
        } catch let error as URLError where error.code == .cancelled {
            downloadPanel?.orderOut(nil)
            phase = .available(update)
        } catch {
            downloadPanel?.orderOut(nil)
            AppLog.error("Update install failed: \(error.localizedDescription)")
            let text = String(format: L("Couldn’t install the update: %@"), error.localizedDescription)
            phase = .failed(text)
            showNotice(text)
        }
    }

    private func download(_ update: AvailableUpdate, to destination: URL) async throws {
        let watcher = DownloadWatcher(
            destination: destination,
            repository: UpdateConfiguration.repository,
            onProgress: { [weak self] fraction in
                Task { @MainActor in
                    self?.phase = .downloading(fraction)
                    self?.progressIndicator?.isIndeterminate = false
                    self?.progressIndicator?.doubleValue = fraction
                }
            }
        )
        downloadWatcher = watcher
        defer { downloadWatcher = nil }
        var request = URLRequest(url: update.downloadURL)
        request.setValue("Renvert/\(UpdateConfiguration.currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        try await watcher.download(request)
    }

    private func prompt(_ update: AvailableUpdate, userInitiated: Bool) {
        if !userInitiated {
            guard canPrompt() else { return }
            if UserDefaults.standard.string(forKey: Keys.deferred) == update.version { return }
        }
        AppActivation.reveal()
        let alert = NSAlert()
        alert.messageText = String(format: L("Renvert %@ is available"), update.version)
        let relaunch = L("The app will relaunch after the update is installed.")
        alert.informativeText = update.notes.isEmpty ? relaunch : update.notes + "\n\n" + relaunch
        alert.addButton(withTitle: L("Install Update"))
        alert.addButton(withTitle: L("Later"))
        alert.addButton(withTitle: L("Release Notes"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            install(update)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(update.releaseURL)
        default:
            UserDefaults.standard.set(update.version, forKey: Keys.deferred)
        }
    }

    private func showDownloadPanel() {
        if downloadPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 132),
                styleMask: [.titled, .closable, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = "Renvert"
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.delegate = self

            let label = NSTextField(labelWithString: L("Downloading update…"))
            label.frame = NSRect(x: 20, y: 88, width: 340, height: 20)
            label.font = .systemFont(ofSize: 13, weight: .semibold)

            let detail = NSTextField(wrappingLabelWithString: L("The app will relaunch after the update is installed."))
            detail.frame = NSRect(x: 20, y: 52, width: 340, height: 34)
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor

            let indicator = NSProgressIndicator(frame: NSRect(x: 20, y: 28, width: 230, height: 16))
            indicator.style = .bar
            indicator.minValue = 0
            indicator.maxValue = 1
            indicator.isIndeterminate = true
            indicator.startAnimation(nil)

            let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelDownload))
            cancel.frame = NSRect(x: 262, y: 16, width: 98, height: 28)
            cancel.bezelStyle = .rounded

            panel.contentView?.addSubview(label)
            panel.contentView?.addSubview(detail)
            panel.contentView?.addSubview(indicator)
            panel.contentView?.addSubview(cancel)
            downloadPanel = panel
            progressIndicator = indicator
        }
        progressIndicator?.doubleValue = 0
        progressIndicator?.isIndeterminate = true
        progressIndicator?.startAnimation(nil)
        AppActivation.reveal()
        downloadPanel?.center()
        downloadPanel?.makeKeyAndOrderFront(nil)
    }

    private func fetchLatest() async throws -> UpdateCheck {
        guard let url = GitHubUpdateFeed.latestReleaseURL(repository: UpdateConfiguration.repository) else {
            throw UpdateFeedError.badResponse
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Renvert/\(UpdateConfiguration.currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try GitHubUpdateFeed.interpret(
            data,
            currentVersion: UpdateConfiguration.currentVersion,
            statusCode: code,
            repository: UpdateConfiguration.repository
        )
    }

    /// A copy launched from the disk image itself is installed into Applications. Otherwise the running app is replaced.
    private func installationDestination() -> URL? {
        let current = Bundle.main.bundleURL.standardizedFileURL
        let applications = URL(fileURLWithPath: "/Applications/Renvert.app")
        let candidate = current.path.hasPrefix("/Volumes/") ? applications : current
        let parent = candidate.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else { return nil }
        return candidate
    }

    private func launchInstaller(staged: URL, destination: URL) throws {
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("renvert-update-\(UUID().uuidString).zsh")
        try Self.installerScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Detach before this process exits, or launchd can take the helper down with the app.
        process.arguments = [
            "-c",
            "nohup \"$0\" \"$1\" \"$2\" \"$3\" >/dev/null 2>&1 &",
            scriptURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            staged.path,
            destination.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateInstallFailure.badDownload
        }
        AppLog.info("Update helper started for \(destination.path)")
    }

    private func shouldPrompt(_ update: AvailableUpdate) -> Bool {
        UserDefaults.standard.string(forKey: Keys.deferred) != update.version
    }

    private func showNotice(_ text: String) {
        AppActivation.reveal()
        let alert = NSAlert()
        alert.messageText = "Renvert"
        alert.informativeText = text
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }

    private func showMissingImageAlert(_ text: String, page: URL) {
        AppActivation.reveal()
        let alert = NSAlert()
        alert.messageText = "Renvert"
        alert.informativeText = text
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Release Notes"))
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(page)
        }
    }

    private func restore(_ remembered: UpdatePhase) -> UpdatePhase {
        if case .available = remembered { return remembered }
        if case .failed = remembered { return .idle }
        if case .available = phase { return phase }
        return remembered == .checking ? .idle : remembered
    }

    private func isNewer(_ version: String) -> Bool {
        guard let remote = ReleaseVersion(version), let current = ReleaseVersion(UpdateConfiguration.currentVersion) else {
            return false
        }
        return remote > current
    }

    private func cache(_ update: AvailableUpdate) {
        if let data = try? JSONEncoder().encode(update) {
            UserDefaults.standard.set(data, forKey: Keys.cached)
        }
    }

    private func cachedUpdate() -> AvailableUpdate? {
        guard let data = UserDefaults.standard.data(forKey: Keys.cached) else { return nil }
        return try? JSONDecoder().decode(AvailableUpdate.self, from: data)
    }

    private func clearCache() {
        UserDefaults.standard.removeObject(forKey: Keys.cached)
        UserDefaults.standard.removeObject(forKey: Keys.deferred)
    }

    private enum Keys {
        static let automatic = "renvert.updates.automatic"
        static let lastCheck = "renvert.updates.lastCheck"
        static let deferred = "renvert.updates.deferredVersion"
        static let cached = "renvert.updates.cached"
    }

    /// Waits until Renvert exits, swaps the bundle, then relaunches. Runs outside the bundle so it can replace it.
    private static let installerScript = """
    #!/bin/zsh
    set -euo pipefail
    pid="$1"
    source="$2"
    dest="$3"
    log="${HOME}/Library/Application Support/Renvert/update.log"
    mkdir -p "${HOME}/Library/Application Support/Renvert"
    exec >> "$log" 2>&1
    echo "$(date) installing $source -> $dest after pid $pid"
    for _ in {1..200}; do
      if ! kill -0 "$pid" 2>/dev/null; then
        break
      fi
      sleep 0.15
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "app did not exit"
      exit 1
    fi
    parent="$(dirname "$dest")"
    tmp="${parent}/.Renvert.update.$$"
    rm -rf "$tmp"
    /usr/bin/ditto "$source" "$tmp"
    backup="${parent}/.Renvert.previous.$$"
    if [[ -d "$dest" ]]; then
      /bin/mv "$dest" "$backup"
    fi
    if ! /bin/mv "$tmp" "$dest"; then
      echo "swap failed"
      if [[ -d "$backup" ]]; then
        /bin/mv "$backup" "$dest" || true
      fi
      exit 1
    fi
    rm -rf "$backup" "$source"
    /usr/bin/xattr -dr com.apple.quarantine "$dest" || true
    /usr/bin/open "$dest"
    rm -f "$0"
    """
}

private enum UpdateInstallFailure: LocalizedError {
    case badDownload
    case mount(String)
    case rejectedBundle

    var errorDescription: String? {
        switch self {
        case .badDownload:
            return L("The download was not a Renvert disk image.")
        case .mount(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return L("The disk image could not be opened.") }
            return trimmed
        case .rejectedBundle:
            return L("The disk image does not contain this version of Renvert.")
        }
    }
}

private struct CommandResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

private func runCommand(_ executable: String, _ arguments: [String]) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    return CommandResult(
        status: process.terminationStatus,
        stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
}

extension UpdateController {
    fileprivate nonisolated static func extractApp(from diskImage: URL, expectedVersion: String, bundleIdentifier: String) throws -> URL {
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("renvert-mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let attached = try runCommand("/usr/bin/hdiutil", [
            "attach", "-readonly", "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mount.path, diskImage.path
        ])
        defer {
            _ = try? runCommand("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? FileManager.default.removeItem(at: mount)
        }
        guard attached.status == 0 else { throw UpdateInstallFailure.mount(attached.stderr) }

        let contents = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.lastPathComponent == "Renvert.app" }) else {
            throw UpdateInstallFailure.rejectedBundle
        }
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("Renvert-staged-\(UUID().uuidString).app")
        let copied = try runCommand("/usr/bin/ditto", [app.path, staged.path])
        guard copied.status == 0 else {
            try? FileManager.default.removeItem(at: staged)
            throw UpdateInstallFailure.mount(copied.stderr)
        }
        guard let bundle = Bundle(url: staged),
              bundle.bundleIdentifier == bundleIdentifier,
              let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let found = ReleaseVersion(raw),
              let expected = ReleaseVersion(expectedVersion),
              found >= expected
        else {
            try? FileManager.default.removeItem(at: staged)
            throw UpdateInstallFailure.rejectedBundle
        }
        return staged
    }
}

/// Downloads a release asset, moves it before URLSession deletes the temp file, and blocks redirects off GitHub.
private final class DownloadWatcher: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let repository: String
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var failure: Error?

    init(destination: URL, repository: String, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.repository = repository
        self.onProgress = onProgress
    }

    func download(_ request: URLRequest) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            session.downloadTask(with: request).resume()
        }
    }

    func cancel() {
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            failure = UpdateInstallFailure.badDownload
            return
        }
        if let finalURL = response.url,
           !UpdateDownloadPolicy.isTrustedRedirect(finalURL),
           !UpdateDownloadPolicy.isTrustedAsset(finalURL, repository: repository) {
            failure = UpdateInstallFailure.badDownload
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
        } else if let failure {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, UpdateDownloadPolicy.isTrustedRedirect(url) else { return nil }
        return request
    }
}

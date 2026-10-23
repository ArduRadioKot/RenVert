import Foundation

public enum TaskState: String, Sendable {
    case queued, running, succeeded, failed, cancelled
}

public struct ConversionTaskSnapshot: Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var progress: Double
    public var state: TaskState
    public var detail: String
}

public final class ConversionQueue: @unchecked Sendable {
    public struct RunningTask {
        public var id: UUID
        public var name: String
        public var progress: Double
        public var state: TaskState
        public var token: CancellationToken
        public var work: (CancellationToken) throws -> Void
    }

    private let lock = NSLock()
    private var pending: [RunningTask] = []
    private var active: [UUID: RunningTask] = [:]
    private var recent: [ConversionTaskSnapshot] = []
    private var maxConcurrent: Int
    private let qos: DispatchQoS

    public var onChange: (() -> Void)?

    public init(profile: PerformanceProfile) {
        maxConcurrent = profile.maxConcurrentTasks
        qos = DispatchQoS(qosClass: profile.qos == .utility ? .utility : .userInitiated, relativePriority: 0)
    }

    public func configure(profile: PerformanceProfile) {
        lock.lock()
        maxConcurrent = profile.maxConcurrentTasks
        lock.unlock()
        pump()
    }

    public func submit(id: UUID = UUID(), name: String, work: @escaping (CancellationToken) throws -> Void) -> CancellationToken {
        let token = CancellationToken()
        let task = RunningTask(id: id, name: name, progress: 0, state: .queued, token: token, work: work)
        lock.lock()
        pending.append(task)
        lock.unlock()
        emit()
        pump()
        return token
    }

    public func cancel(_ id: UUID) {
        lock.lock()
        if let index = pending.firstIndex(where: { $0.id == id }) {
            var task = pending.remove(at: index)
            task.state = .cancelled
            task.token.cancel()
            recent.insert(snapshot(task), at: 0)
        }
        if let task = active[id] {
            task.token.cancel()
        }
        lock.unlock()
        emit()
    }

    public func cancelAll() {
        lock.lock()
        pending.forEach { $0.token.cancel() }
        active.values.forEach { $0.token.cancel() }
        pending.removeAll()
        lock.unlock()
        emit()
    }

    public func snapshots() -> (active: [ConversionTaskSnapshot], recent: [ConversionTaskSnapshot]) {
        lock.lock()
        defer { lock.unlock() }
        return (active.values.map(snapshot), Array(recent.prefix(12)))
    }

    public var activeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return active.count + pending.count
    }

    public var overallProgress: Double {
        lock.lock(); defer { lock.unlock() }
        let items = Array(active.values)
        guard !items.isEmpty else { return pending.isEmpty ? 1 : 0 }
        return items.map(\.progress).reduce(0, +) / Double(items.count)
    }

    public func updateProgress(_ id: UUID, _ value: Double) {
        lock.lock()
        active[id]?.progress = value
        lock.unlock()
        emit()
    }

    private func pump() {
        lock.lock()
        while active.count < maxConcurrent, !pending.isEmpty {
            var task = pending.removeFirst()
            task.state = .running
            active[task.id] = task
            let work = task.work
            let token = task.token
            let id = task.id
            lock.unlock()
            DispatchQueue.global(qos: qos.qosClass).async { [weak self] in
                do {
                    try token.throwIfCancelled()
                    try work(token)
                    self?.finish(id, .succeeded, nil)
                } catch let error as RenvertError where error == .cancelled {
                    self?.finish(id, .cancelled, error.localizedDescription)
                } catch {
                    self?.finish(id, .failed, error.localizedDescription)
                }
            }
            lock.lock()
        }
        lock.unlock()
    }

    private func finish(_ id: UUID, _ state: TaskState, _ detail: String?) {
        lock.lock()
        if var task = active.removeValue(forKey: id) {
            task.state = state
            task.progress = state == .succeeded ? 1 : task.progress
            var snap = snapshot(task)
            snap.detail = detail ?? ""
            recent.insert(snap, at: 0)
            recent = Array(recent.prefix(20))
        }
        lock.unlock()
        emit()
        pump()
    }

    private func snapshot(_ task: RunningTask) -> ConversionTaskSnapshot {
        ConversionTaskSnapshot(id: task.id, name: task.name, progress: task.progress, state: task.state, detail: "")
    }

    private func emit() {
        DispatchQueue.main.async { self.onChange?() }
    }
}

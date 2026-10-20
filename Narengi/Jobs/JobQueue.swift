import Foundation

/// Handed to a job's work closure so it can report progress (0…1) from any thread.
struct JobContext: Sendable {
    let reportProgress: @Sendable (Double) -> Void
}

@MainActor
final class Job: ObservableObject, Identifiable {
    typealias Work = @Sendable (JobContext) async throws -> [URL]

    enum State: Equatable {
        case queued
        case running
        case finished([URL])
        case failed(String)
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .queued, .running: return false
            case .finished, .failed, .cancelled: return true
            }
        }
    }

    let id = UUID()
    let title: String
    let sourceName: String
    @Published fileprivate(set) var state: State = .queued
    @Published fileprivate(set) var progress: Double = 0
    @Published fileprivate(set) var cancelRequested = false

    fileprivate let work: Work
    fileprivate var task: Task<Void, Never>?

    init(title: String, sourceName: String = "", work: @escaping Work) {
        self.title = title
        self.sourceName = sourceName
        self.work = work
    }

    var outputs: [URL] {
        if case .finished(let urls) = state { return urls }
        return []
    }
}

/// What a batch of jobs produced once nothing is queued or running any more.
struct BatchResult: Equatable {
    var outputs: [URL]
    var failedCount: Int
    var cancelledCount: Int
}

/// Runs jobs with bounded concurrency. Single drops and multi-file batches both go through here:
/// every file becomes one job, so each has its own progress, error and cancel button.
@MainActor
final class JobQueue: ObservableObject {
    @Published private(set) var jobs: [Job] = []

    let maxConcurrent: Int
    var onJobAdded: ((Job) -> Void)?
    var onBatchFinished: ((BatchResult) -> Void)?

    private var batch: [Job] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int = 2) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    var runningCount: Int { jobs.filter { $0.state == .running }.count }
    var isIdle: Bool { jobs.allSatisfy { $0.state.isTerminal } }

    @discardableResult
    func enqueue(title: String, sourceName: String = "", work: @escaping Job.Work) -> Job {
        let job = Job(title: title, sourceName: sourceName, work: work)
        if isIdle { batch = [] }
        batch.append(job)
        jobs.append(job)
        onJobAdded?(job)
        pump()
        return job
    }

    func cancel(_ job: Job) {
        switch job.state {
        case .queued:
            job.state = .cancelled
            jobDidEnd()
        case .running:
            job.cancelRequested = true
            job.task?.cancel()
        case .finished, .failed, .cancelled:
            break
        }
    }

    func cancelAll() {
        jobs.forEach(cancel)
    }

    /// Removes a finished job from the list (the HUD calls this when you dismiss a row).
    func remove(_ job: Job) {
        guard job.state.isTerminal else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isTerminal }
    }

    /// Suspends until every job has reached a terminal state.
    func waitUntilIdle() async {
        if isIdle { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: -

    private func pump() {
        while runningCount < maxConcurrent, let next = jobs.first(where: { $0.state == .queued }) {
            start(next)
        }
    }

    private func start(_ job: Job) {
        job.state = .running
        Log.job.notice("Job started: \(job.id.uuidString, privacy: .public)")
        let context = JobContext { [weak job] value in
            Task { @MainActor in
                guard let job, job.state == .running else { return }
                job.progress = min(1, max(job.progress, value))
            }
        }
        let work = job.work
        job.task = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<[URL], Error>
            do {
                result = .success(try await work(context))
            } catch {
                result = .failure(error)
            }
            await self?.complete(job, with: result)
        }
    }

    private func complete(_ job: Job, with result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            job.progress = 1
            job.state = .finished(urls)
        case .failure(let error):
            if error is CancellationError || (job.cancelRequested && (error as? URLError)?.code == .cancelled) {
                job.state = .cancelled
            } else {
                job.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
        job.task = nil
        switch job.state {
        case .finished(let urls): Log.job.notice("Job finished: \(job.id.uuidString, privacy: .public), \(urls.count) output(s)")
        case .failed(let message): Log.job.error("Job failed: \(job.id.uuidString, privacy: .public): \(message, privacy: .public)")
        case .cancelled: Log.job.notice("Job cancelled: \(job.id.uuidString, privacy: .public)")
        default: break
        }
        jobDidEnd()
    }

    private func jobDidEnd() {
        pump()
        guard isIdle else { return }

        let finished = batch
        batch = []
        if !finished.isEmpty {
            onBatchFinished?(BatchResult(
                outputs: finished.flatMap(\.outputs),
                failedCount: finished.filter { if case .failed = $0.state { return true } else { return false } }.count,
                cancelledCount: finished.filter { $0.state == .cancelled }.count))
        }
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }
}

import XCTest
@testable import Narengi

private actor Counter {
    private(set) var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

@MainActor
final class JobQueueTests: XCTestCase {
    private let outURL = URL(fileURLWithPath: "/tmp/out.png")

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testSuccessfulJobFinishesWithOutputs() async {
        let queue = JobQueue()
        let url = outURL
        let job = queue.enqueue(title: "ok") { _ in [url] }
        XCTAssertTrue([.queued, .running].contains(job.state))
        await queue.waitUntilIdle()
        XCTAssertEqual(job.state, .finished([url]))
        XCTAssertEqual(job.progress, 1)
        XCTAssertEqual(job.outputs, [url])
    }

    func testFailureCarriesLocalizedMessage() async {
        let queue = JobQueue()
        let job = queue.enqueue(title: "bad") { _ in throw ConversionError.noText }
        await queue.waitUntilIdle()
        XCTAssertEqual(job.state, .failed(ConversionError.noText.errorDescription!))
    }

    func testProgressIsReportedAndNeverGoesBackwards() async {
        let queue = JobQueue()
        let gate = Counter()
        let job = queue.enqueue(title: "progress") { context in
            context.reportProgress(0.6)
            context.reportProgress(0.3)
            await gate.enter()
            while await gate.current > 0 { try await Task.sleep(nanoseconds: 5_000_000) }
            return []
        }
        await waitUntil { job.progress >= 0.6 }
        XCTAssertEqual(job.progress, 0.6, accuracy: 0.0001)
        await gate.leave()
        await queue.waitUntilIdle()
        XCTAssertEqual(job.progress, 1)
    }

    func testCancellingRunningJobEndsCancelled() async {
        let queue = JobQueue()
        let job = queue.enqueue(title: "long") { _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return []
        }
        await waitUntil { job.state == .running }
        queue.cancel(job)
        XCTAssertTrue(job.cancelRequested)
        await queue.waitUntilIdle()
        XCTAssertEqual(job.state, .cancelled)
    }

    func testCancellingQueuedJobSkipsItImmediately() async {
        let queue = JobQueue(maxConcurrent: 1)
        let first = queue.enqueue(title: "blocker") { _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return []
        }
        let ran = Counter()
        let second = queue.enqueue(title: "queued") { _ in await ran.enter(); return [] }
        await waitUntil { first.state == .running }
        XCTAssertEqual(second.state, .queued)

        queue.cancel(second)
        XCTAssertEqual(second.state, .cancelled)

        queue.cancel(first)
        await queue.waitUntilIdle()
        let peak = await ran.peak
        XCTAssertEqual(peak, 0, "a cancelled queued job must never start")
    }

    func testConcurrencyLimitIsRespected() async {
        let queue = JobQueue(maxConcurrent: 2)
        let counter = Counter()
        for index in 0..<8 {
            queue.enqueue(title: "job \(index)") { _ in
                await counter.enter()
                try await Task.sleep(nanoseconds: 30_000_000)
                await counter.leave()
                return []
            }
        }
        await queue.waitUntilIdle()
        let peak = await counter.peak
        XCTAssertEqual(peak, 2)
        XCTAssertTrue(queue.jobs.allSatisfy { $0.state == .finished([]) })
    }

    func testBatchCallbackFiresOnceWithTotals() async {
        let queue = JobQueue(maxConcurrent: 2)
        var results: [BatchResult] = []
        queue.onBatchFinished = { results.append($0) }
        let a = URL(fileURLWithPath: "/tmp/a.png"), b = URL(fileURLWithPath: "/tmp/b.png")
        queue.enqueue(title: "a") { _ in [a] }
        queue.enqueue(title: "b") { _ in [b] }
        queue.enqueue(title: "c") { _ in throw ConversionError.passwordProtected }
        await queue.waitUntilIdle()

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(Set(results[0].outputs), [a, b])
        XCTAssertEqual(results[0].failedCount, 1)
        XCTAssertEqual(results[0].cancelledCount, 0)
    }

    func testNewBatchStartsAfterPreviousOneFinished() async {
        let queue = JobQueue()
        var results: [BatchResult] = []
        queue.onBatchFinished = { results.append($0) }
        queue.enqueue(title: "one") { _ in [] }
        await queue.waitUntilIdle()
        queue.enqueue(title: "two") { _ in [] }
        await queue.waitUntilIdle()
        XCTAssertEqual(results.count, 2)
    }

    func testRemoveOnlyDropsFinishedJobs() async {
        let queue = JobQueue(maxConcurrent: 1)
        let running = queue.enqueue(title: "running") { _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return []
        }
        await waitUntil { running.state == .running }
        queue.remove(running)
        XCTAssertEqual(queue.jobs.count, 1, "a running job can't be removed")

        queue.cancel(running)
        await queue.waitUntilIdle()
        queue.remove(running)
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    func testCancelAllStopsEverything() async {
        let queue = JobQueue(maxConcurrent: 2)
        let jobs = (0..<4).map { index in
            queue.enqueue(title: "j\(index)") { _ in
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return []
            }
        }
        await waitUntil { queue.runningCount == 2 }
        queue.cancelAll()
        await queue.waitUntilIdle()
        XCTAssertTrue(jobs.allSatisfy { $0.state == .cancelled })
    }
}

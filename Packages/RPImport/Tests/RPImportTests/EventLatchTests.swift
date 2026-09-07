import Foundation
import Testing

@testable import RPImport

/// Records how a background `wait()` finished, so a lost wakeup shows up as a
/// **failed** test rather than a suite that hangs forever — which is exactly
/// what the bug being fixed did to an MTP import.
private final class WaitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Void, any Error>?

    func record(_ result: Result<Void, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        if value == nil { value = result }
    }

    var result: Result<Void, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    var isFinished: Bool { result != nil }
}

@discardableResult
private func waitInBackground(on latch: EventLatch, into recorder: WaitRecorder) -> Task<
    Void, Never
> {
    Task.detached {
        do {
            try await latch.wait()
            recorder.record(.success(()))
        } catch {
            recorder.record(.failure(error))
        }
    }
}

/// Polls up to `timeout` for the recorder to fill in. Returns `nil` if the
/// waiter never resumed.
private func settledResult(
    _ recorders: [WaitRecorder], timeout: Duration = .seconds(2)
) async -> [Result<Void, any Error>]? {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        let done = recorders.compactMap(\.result)
        if done.count == recorders.count { return done }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return nil
}

private struct Boom: Error, Equatable {}

@Suite("EventLatch — the ImageCaptureCore lost-wakeup fix")
struct EventLatchTests {
    @Test("A signal that lands before anyone waits is not lost")
    func signalBeforeWait() async {
        let latch = EventLatch()
        latch.signal()

        let recorder = WaitRecorder()
        waitInBackground(on: latch, into: recorder)
        let results = await settledResult([recorder])

        #expect(results != nil, "wait() never resumed after an earlier signal()")
        #expect(results?.first?.isSuccess == true)
    }

    @Test("A waiter parked before the signal is resumed by it")
    func waitBeforeSignal() async {
        let latch = EventLatch()
        let recorder = WaitRecorder()
        waitInBackground(on: latch, into: recorder)

        // Give the waiter a moment to actually park, then settle it.
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!recorder.isFinished)
        latch.signal()

        let results = await settledResult([recorder])
        #expect(results?.first?.isSuccess == true)
    }

    @Test("Every waiter is resumed, not just the first")
    func manyWaiters() async {
        let latch = EventLatch()
        let recorders = (0..<8).map { _ in WaitRecorder() }
        for recorder in recorders { waitInBackground(on: latch, into: recorder) }
        try? await Task.sleep(for: .milliseconds(20))
        latch.signal()

        let results = await settledResult(recorders)
        #expect(results?.count == 8)
        #expect(results?.allSatisfy(\.isSuccess) == true)
    }

    @Test("fail() makes present and future waiters throw instead of hanging")
    func failureIsLatchedToo() async {
        let latch = EventLatch()
        let parked = WaitRecorder()
        waitInBackground(on: latch, into: parked)
        try? await Task.sleep(for: .milliseconds(20))

        latch.fail(Boom())

        let late = WaitRecorder()
        waitInBackground(on: latch, into: late)

        let results = await settledResult([parked, late])
        #expect(results?.count == 2)
        #expect(results?.allSatisfy { $0.thrownError as? Boom == Boom() } == true)
    }

    @Test("The first settlement wins; a later one is ignored")
    func firstSettlementWins() async {
        let latch = EventLatch()
        latch.signal()
        latch.fail(Boom())

        let recorder = WaitRecorder()
        waitInBackground(on: latch, into: recorder)
        #expect(await settledResult([recorder])?.first?.isSuccess == true)
        #expect(latch.isSettled)
    }

    /// The actual race, driven repeatedly: ImageCaptureCore signals from its
    /// own thread while the importer is deciding to wait. Before the latch, the
    /// signal could land in the gap between "no files yet" and "park the
    /// continuation", and the import hung with no timeout on that path.
    @Test("A signal racing a wait from another thread is never lost")
    func signalRacingWait() async {
        for iteration in 0..<50 {
            let latch = EventLatch()
            let recorder = WaitRecorder()

            DispatchQueue.global().async { latch.signal() }
            waitInBackground(on: latch, into: recorder)

            let results = await settledResult([recorder], timeout: .seconds(2))
            #expect(results?.first?.isSuccess == true, "lost wakeup on iteration \(iteration)")
            if results == nil { break }
        }
    }
}

extension Result where Success == Void {
    fileprivate var isSuccess: Bool {
        if case .success = self { true } else { false }
    }

    fileprivate var thrownError: (any Error)? {
        if case .failure(let error) = self { error } else { nil }
    }
}

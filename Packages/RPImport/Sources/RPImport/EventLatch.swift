import Foundation

/// A one-shot rendezvous between an `async` caller and a callback that may fire
/// **before** the caller gets around to waiting.
///
/// It exists because of a real hang. `ICCameraSession.contents()` used to look
/// at `camera.mediaFiles`, find it empty, and only then park a continuation
/// under a lock. ImageCaptureCore delivers
/// `deviceDidBecomeReady(withCompleteContentCatalog:)` on its own thread, so it
/// could land in that gap: the delegate found no continuation to resume, the
/// continuation was registered a microsecond later, and the import waited for
/// an event that had already happened — forever, since that path has no
/// timeout.
///
/// A latch fixes it by remembering that the event happened. ``signal()`` and
/// ``fail(_:)`` are idempotent and the first one wins; ``wait()`` returns (or
/// throws) immediately once the latch is settled, no matter which side got
/// there first. Any number of waiters is fine — all of them are resumed.
///
/// Deliberately *not* an actor: the callers are ImageCaptureCore delegate
/// methods on an arbitrary thread, which cannot `await`.
final class EventLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var settled: Result<Void, any Error>?
    private var waiters: [CheckedContinuation<Void, any Error>] = []

    /// True once ``signal()`` or ``fail(_:)`` has been called.
    var isSettled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return settled != nil
    }

    /// Suspends until the latch is settled. Returns at once if it already is.
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let settled {
                lock.unlock()
                continuation.resume(with: settled)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    /// Marks the event as having happened and resumes every waiter.
    func signal() {
        settle(with: .success(()))
    }

    /// Settles the latch with an error, so waiters — present and future —
    /// throw instead of hanging. Used when the device disappears mid-import.
    func fail(_ error: any Error) {
        settle(with: .failure(error))
    }

    private func settle(with result: Result<Void, any Error>) {
        lock.lock()
        guard settled == nil else {
            lock.unlock()
            return  // First settlement wins; a later one is a no-op.
        }
        settled = result
        let pending = waiters
        waiters = []
        lock.unlock()
        for continuation in pending { continuation.resume(with: result) }
    }
}

import Foundation

/// Process-wide mutual exclusion for the two `RPEngineFeatureFlags` that the
/// per-shot mask suites drive — `bodySkinSync` and `backgroundLock`.
///
/// The async twin of `RPEngineTests/RPEngineTestFlags`, and it exists for the
/// same reason and the same observed failure. `@Suite(.serialized)` orders the
/// tests *inside* one suite; it does not order two suites against each other,
/// and the flags are a process-global store. `BodySkinSyncWiringTests` and
/// `BackgroundLockWiringTests` both set both flags around an
/// `await controller.open(…)`, so without this the second suite's "both flags
/// off" case lands inside the first suite's "bodySkinSync on" case and the first
/// one fails with an empty mask. That is not a hypothetical: it is what the
/// macOS run did the first time these two suites existed together.
///
/// Two shape decisions, both forced:
///
/// * an `actor` and not an `NSLock`, because the critical section spans
///   `await`s — blocking the main thread on a lock while a `@MainActor` test is
///   suspended is a deadlock, not a wait;
/// * ``exclusive(_:)`` is `@MainActor`, because both suites are, and a
///   `nonisolated` entry point would have to *send* their non-Sendable closures
///   across isolation. Only the waiting happens off the main actor.
///
/// Scoped to the contending flags, not to feature flags in general:
/// `LivePreviewWiringTests` drives `colorSliders` and is deliberately left
/// alone.
enum RPUIMaskFlagLock {
    private actor Gate {
        private var isHeld = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            while isHeld {
                await withCheckedContinuation { waiters.append($0) }
            }
            isHeld = true
        }

        func release() {
            isHeld = false
            guard !waiters.isEmpty else { return }
            waiters.removeFirst().resume()
        }
    }

    private static let gate = Gate()

    /// Runs `body` with exclusive access to the mask feature flags.
    ///
    /// `throws` rather than `rethrows` so the release can happen on both paths
    /// without a `defer` that would have to spawn a `Task` to await the actor.
    @MainActor
    static func exclusive(_ body: () async throws -> Void) async throws {
        await gate.acquire()
        do {
            try await body()
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()
    }
}

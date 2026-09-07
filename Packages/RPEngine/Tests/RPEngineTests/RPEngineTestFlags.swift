import Foundation

@testable import RPEngine

/// Process-wide mutual exclusion for `RPEngineFeatureFlags`.
///
/// `@Suite(.serialized)` orders the tests *inside* one suite; it does not order
/// two suites against each other, and Swift Testing runs suites concurrently.
/// `RPEngineFeatureFlags` is a process-global store, so
/// `GuidedFilterTests.flagGatesConstruction` setting `guidedFilter = false` can
/// land in the middle of a Phase 2 skin test that needs it on, and
/// `RenderGraphTests.skinNodeHasItsOwnFlag` can see `skinSliders = true` because
/// `SkinRenderNodeTests` is mid-run.
///
/// That is the hazard `RPEngineFeatureFlags.resetToDefaults()`'s doc comment and
/// docs/ADR-0006 both warn about; it was latent between the spike S3 suites
/// (`GuidedFilterTests` and `SpikeS3BenchTests` both drive `guidedFilter`) and
/// became a reproducible failure once Phase 2 added two more suites that flip
/// flags. Every RPEngine test that reads or writes a flag takes this lock for
/// its whole body.
///
/// Not recursive on purpose: a nested `exclusive` would be a sign that a helper
/// is taking the lock a test already holds, and a deadlock is a better bug
/// report than a silent re-entry.
enum RPEngineTestFlags {
    private static let lock = NSLock()

    /// Runs `body` with exclusive access to the flag store.
    static func exclusive<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Runs `body` with the three flags the Phase 2 skin path needs on, and puts
    /// them back afterwards — the targeted restore
    /// `RPEngineFeatureFlags.resetToDefaults()`'s doc comment asks for, rather
    /// than wiping flags another suite is relying on.
    static func withSkinRenderGraph<T>(_ body: () throws -> T) rethrows -> T {
        try exclusive {
            RPEngineFeatureFlags.enableSkinRenderGraph()
            defer { RPEngineFeatureFlags.disableSkinRenderGraph() }
            return try body()
        }
    }

    /// `enter` / `leave` form, for tests whose body is not conveniently a
    /// closure. Pair it with `defer`:
    ///
    /// ```swift
    /// let flags = RPEngineTestFlags.enter { RPEngineFeatureFlags.mlsMeshWarp = true }
    /// defer { flags.leave { RPEngineFeatureFlags.mlsMeshWarp = false } }
    /// ```
    static func enter(_ configure: () -> Void) -> Scope {
        lock.lock()
        configure()
        return Scope()
    }

    /// Same, for the Phase 2 skin path.
    static func enterSkinRenderGraph() -> Scope {
        enter { RPEngineFeatureFlags.enableSkinRenderGraph() }
    }

    /// Same, for the Phase 2 "Mặt" (warp) path. Pair with
    /// `defer { flags.leave { RPEngineFeatureFlags.disableWarpRenderGraph() } }`
    /// — `Scope.leave`'s default restore is the *skin* one, because that path
    /// landed first and every existing call site relies on it.
    static func enterWarpRenderGraph() -> Scope {
        enter { RPEngineFeatureFlags.enableWarpRenderGraph() }
    }

    /// Same, for the Phase 2 "Mắt / Răng" (eyes/teeth) path. Pair with
    /// `defer { flags.leave { RPEngineFeatureFlags.disableEyesTeethRenderGraph() } }`
    /// — `Scope.leave`'s default restore is the *skin* one, because that path
    /// landed first and every existing call site relies on it.
    static func enterEyesTeethRenderGraph() -> Scope {
        enter { RPEngineFeatureFlags.enableEyesTeethRenderGraph() }
    }

    /// Same, for the Phase 2 "Color" path. Pair with
    /// `defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }`
    /// — `Scope.leave`'s default restore is the *skin* one, because that path
    /// landed first and every existing call site relies on it.
    static func enterColorRenderGraph() -> Scope {
        enter { RPEngineFeatureFlags.enableColorRenderGraph() }
    }

    /// A held lock plus the flag change that goes with it.
    ///
    /// **Non-copyable on purpose.** The previous version was a copyable struct
    /// with a `consuming func leave()`, which is only half a guarantee: a copy
    /// can be consumed too, so two `leave()` calls could unlock an `NSLock` this
    /// scope no longer holds. That is undefined behaviour and the damage would
    /// land in whichever *other* suite happened to hold the lock at the time.
    ///
    /// `~Copyable` makes a copy a compile error, so exactly one `Scope` exists
    /// per `enter`, and the unlock moved into `deinit`, which the language then
    /// runs exactly once at scope exit. The unlock therefore cannot happen twice
    /// even if `leave` is called twice.
    ///
    /// `leave` is `borrowing`, not `consuming`, because Swift refuses to consume
    /// a noncopyable value inside `defer` ("noncopyable 'flags' cannot be
    /// consumed when captured by an escaping closure"), and `defer` is the only
    /// way to pair the scope with an early `return` or a `throw`. Ordering is
    /// what makes that safe: `defer` bodies run *before* the enclosing scope's
    /// values are destroyed, so `leave` restores the flags and `deinit` then
    /// releases the lock.
    struct Scope: ~Copyable {
        /// The teardown to run if the test never calls `leave` — which used to
        /// deadlock the whole suite. Nothing else can hold the lock while this
        /// scope is alive, so a full reset here cannot disturb another suite.
        private let fallback: Teardown

        fileprivate init() { self.fallback = Teardown() }

        /// Restores the flags. Idempotent: the first call wins and the fallback
        /// is cancelled. The lock is released by `deinit`, not here.
        borrowing func leave(
            _ restore: () -> Void = { RPEngineFeatureFlags.disableSkinRenderGraph() }
        ) {
            guard fallback.claim() else { return }
            restore()
        }

        deinit {
            if fallback.claim() { RPEngineFeatureFlags.resetToDefaults() }
            RPEngineTestFlags.lock.unlock()
        }

        /// One bit of "has the teardown already run", in a box because `deinit`
        /// and a `borrowing` method both need to write it.
        private final class Teardown {
            private var done = false
            /// `true` the first time only.
            func claim() -> Bool {
                if done { return false }
                done = true
                return true
            }
        }
    }
}

import Foundation

@testable import RPVision

/// Process-wide mutual exclusion for `RPVisionFeatureFlags`, the RPVision twin of
/// `RPEngineTestFlags`.
///
/// `@Suite(.serialized)` orders the tests *inside* one suite; it does not order
/// two suites against each other, and Swift Testing runs suites concurrently.
/// `RPVisionFeatureFlags` is a process-global store (docs/ADR-0006), so
/// `PersonSegmenterTests.flagGatesConstruction` setting `personSegmentation =
/// false` lands in the middle of `PersonSegmentationBenchTests.measure`, which
/// then fails with "RPVision feature 'personSegmentation' is disabled" — observed,
/// not theorised: that is exactly how the full macOS suite failed before this
/// existed, while each suite passed on its own.
///
/// Scoped to the flags whose *two* owning suites take this lock. It is not a
/// blanket guard for the whole package: the older suites
/// (`FaceParsingModelTests`, `FaceLandmark478BenchTests`, `FaceAnalyzerTests`,
/// `BlazeFaceTests`) each own their flag outright and do not contend, so they are
/// left alone rather than rewritten from under another task.
///
/// Not recursive on purpose: a nested `exclusive` would mean a helper is taking a
/// lock its caller already holds, and a deadlock is a better bug report than a
/// silent re-entry.
enum RPVisionTestFlags {
    private static let lock = NSLock()

    /// Runs `body` with exclusive access to the flag store.
    static func exclusive<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Runs `body` with `RPVisionFeatureFlags.personSegmentation` on, and puts it
    /// back afterwards — the targeted restore `resetToDefaults()`'s doc comment
    /// asks for, rather than wiping flags another suite is relying on.
    static func withPersonSegmentation<T>(_ body: () throws -> T) rethrows -> T {
        try exclusive {
            RPVisionFeatureFlags.personSegmentation = true
            defer { RPVisionFeatureFlags.personSegmentation = false }
            return try body()
        }
    }
}

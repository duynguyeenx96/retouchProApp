import CoreGraphics
import Foundation
import RPEngine
import RPVision
import Testing

/// docs/ADR-0021 §v2 — the app-side adapter that makes RPVision's
/// `PersonSegmenter` an `RPEngine.SubjectMaskProviding`.
///
/// **What is deliberately not re-tested here: Vision.**
/// `RPVisionTests/PersonSegmenterTests` covers the request, the orientation and
/// the non-uniform mask affine, and `VNGeneratePersonSegmentationRequest` cannot
/// be performed on the iOS Simulator at all
/// (`Research/bench/p6-background-lock-ios-simulator.json`), so a test here that
/// went through Vision would be macOS-only and timing-dependent. What is left is
/// the bookkeeping this file adds on top — the cache key, the quality mapping,
/// the coalescing, and the `nil`-is-an-answer contract — and all of it is
/// exercised through the injected `Segmenting` seam.
///
/// `.serialized` because `RPVisionFeatureFlags` is a process-global store.
@Suite("Person segmentation subject-mask provider", .serialized)
struct PersonSegmenterSubjectMaskProviderTests {

    static func image(width: Int = 64, height: Int = 48) throws -> PreviewImage {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.6, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return PreviewImage(cgImage: try #require(context.makeImage()))
    }

    static func mask(_ value: UInt8) -> RenderMask {
        RenderMask(
            width: 8, height: 6, values: [UInt8](repeating: value, count: 48),
            maskToImage: CGAffineTransform(scaleX: 8, y: 8))
    }

    /// Counts runs per key, so "cached" and "coalesced" are observable.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _keys: [String] = []
        var keys: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _keys
        }
        func record(_ key: String) {
            lock.lock()
            defer { lock.unlock() }
            _keys.append(key)
        }
    }

    /// The performance contract is written into `SubjectMaskProviding` itself
    /// ("a conformance must key on the shot's content hash **and** the pixel size
    /// **and** the quality level, and return a cached mask"), because the request
    /// is 5–55 ms and a slider drag issues 30–60 redraws a second.
    @Test("One run per key; the same shot at the same size and quality is cached")
    func cachesByContentHashSizeAndQuality() async throws {
        let recorder = Recorder()
        let provider = PersonSegmenterSubjectMaskProvider { _, _, key in
            recorder.record(key)
            return Self.mask(255)
        }
        let image = try Self.image()

        _ = try await provider.subjectMask(for: image, contentHash: "a", quality: .balanced)
        _ = try await provider.subjectMask(for: image, contentHash: "a", quality: .balanced)
        #expect(recorder.keys.count == 1)

        // A different quality is a different mask (256x192 vs 2016x1512), so it
        // must not be served from the first answer.
        _ = try await provider.subjectMask(for: image, contentHash: "a", quality: .accurate)
        #expect(recorder.keys.count == 2)

        // A different size is a different pixel grid — the same reason
        // FaceAnalyzerFaceInputProvider's key carries the size.
        let larger = try Self.image(width: 128, height: 96)
        _ = try await provider.subjectMask(for: larger, contentHash: "a", quality: .balanced)
        #expect(recorder.keys.count == 3)

        _ = try await provider.subjectMask(for: image, contentHash: "b", quality: .balanced)
        #expect(recorder.keys.count == 4)

        #expect(
            recorder.keys == [
                "a@64x48@balanced", "a@64x48@accurate", "a@128x96@balanced", "b@64x48@balanced",
            ])
    }

    /// The case a fast filmstrip walk produces: several callers land on one key
    /// while the request is still running. They must share it, as
    /// `FaceAnalyzer.analysis(of:contentHash:)` does, rather than start three
    /// 17 ms Vision requests.
    @Test("Concurrent callers on one key share a single run")
    func concurrentCallersCoalesce() async throws {
        let recorder = Recorder()
        let provider = PersonSegmenterSubjectMaskProvider { _, _, key in
            recorder.record(key)
            // Long enough that the other callers are certainly waiting.
            Thread.sleep(forTimeInterval: 0.2)
            return Self.mask(128)
        }
        let image = try Self.image()

        let results = try await withThrowingTaskGroup(of: RenderMask?.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await provider.subjectMask(
                        for: image, contentHash: "shared", quality: .fast)
                }
            }
            var collected: [RenderMask?] = []
            for try await result in group { collected.append(result) }
            return collected
        }
        #expect(results.count == 4)
        #expect(results.allSatisfy { $0?.values.first == 128 })
        #expect(recorder.keys == ["shared@64x48@fast"])
    }

    /// `nil` means "no subject in this frame" and must survive the cache as a
    /// *value*, not become a repeated request or an empty mask. ADR-0021 §v2:
    /// a caller turning this `nil` into an all-zero mask would multiply every
    /// landscape's skin coverage by zero.
    @Test("nil is cached as an answer, not retried and not turned into an empty mask")
    func nilIsAnAnswer() async throws {
        let recorder = Recorder()
        let provider = PersonSegmenterSubjectMaskProvider { _, _, key in
            recorder.record(key)
            return nil
        }
        let image = try Self.image()
        let first = try await provider.subjectMask(
            for: image, contentHash: "empty", quality: .balanced)
        let second = try await provider.subjectMask(
            for: image, contentHash: "empty", quality: .balanced)
        #expect(first == nil)
        #expect(second == nil)
        #expect(recorder.keys.count == 1)
    }

    /// A thrown failure is not cached: "this went wrong" must stay retryable,
    /// while `nil` ("there is no person here") does not.
    @Test("A failure propagates and is not cached as an answer")
    func failuresPropagate() async throws {
        struct Boom: Error {}
        let recorder = Recorder()
        let provider = PersonSegmenterSubjectMaskProvider { _, _, key in
            recorder.record(key)
            throw Boom()
        }
        let image = try Self.image()
        await #expect(throws: Boom.self) {
            _ = try await provider.subjectMask(for: image, contentHash: "bad", quality: .balanced)
        }
        await #expect(throws: Boom.self) {
            _ = try await provider.subjectMask(for: image, contentHash: "bad", quality: .balanced)
        }
        #expect(recorder.keys.count == 2)
    }

    /// The two quality enums are separate types on purpose — RPEngine must not
    /// import Vision to spell a level — so the mapping is the one place they can
    /// drift. Every case, by name.
    @Test("Every SubjectMaskQuality maps to the PersonSegmentationQuality of the same name")
    func qualityMappingIsComplete() {
        for quality in SubjectMaskQuality.allCases {
            let mapped = PersonSegmenterSubjectMaskProvider.visionQuality(quality)
            #expect(mapped.rawValue == quality.rawValue)
        }
        #expect(SubjectMaskQuality.allCases.count == PersonSegmentationQuality.allCases.count)
    }

    /// With the RPVision flag off — the shipping default — there is no provider,
    /// and the reason is a named case rather than a `nil` that looks like "this
    /// photo has no person in it" (docs/ADR-0015).
    @Test("standard() refuses while personSegmentation is off, and says so by name")
    func standardRefusesWhileTheFlagIsOff() {
        let previous = RPVisionFeatureFlags.personSegmentation
        defer { RPVisionFeatureFlags.personSegmentation = previous }
        RPVisionFeatureFlags.personSegmentation = false
        let outcome = PersonSegmenterSubjectMaskProvider.standard()
        #expect(outcome.provider == nil)
        if case .featureDisabled = outcome {} else {
            Issue.record("expected .featureDisabled, got \(outcome)")
        }
        // Off is the expected state, so it writes no startup-log line; the
        // launch's `renderSummary` already lists which experiments are on.
        #expect(outcome.diagnostic == nil)
    }
}

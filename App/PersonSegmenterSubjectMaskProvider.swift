import CoreGraphics
import Foundation
import RPEngine
import RPVision

/// `RPEngine.SubjectMaskProviding` on top of RPVision's `PersonSegmenter`.
///
/// The sibling of ``FaceAnalyzerFaceInputProvider``, and for the same structural
/// reason: the app target is the only place that links both RPEngine and
/// RPVision, so this is where `VNGeneratePersonSegmentationRequest`'s answer
/// becomes a plain `RenderMask` (docs/ADR-0009 — RPEngine imports neither Vision
/// nor RPVision).
///
/// ## What consumes it today
/// One thing: docs/ADR-0021 §v2, the whole-body skin mask. `LivePreviewController`
/// asks for a subject mask once per shot and hands it to
/// `BodySkinMask.make(image:subject:)`, which multiplies it into the colour
/// classifier's coverage so skin-coloured wood *behind* the subject can never be
/// reported as skin. "Khoá nền" (docs/PLAN.md §6.1, ADR-0018) is the other
/// intended consumer and is **not** wired here — `BackgroundLockMaskSource` still
/// has no node reading its texture and no UI. This type is the adapter both will
/// share when it is.
///
/// ## Cache key and the performance contract
/// ``SubjectMaskProviding`` makes caching part of the protocol, because the
/// request costs 5–55 ms depending on quality
/// (`Research/bench/p6-background-lock-macos.json`) and a slider drag issues
/// 30–60 redraws a second. The key is `"<contentHash>@<width>x<height>@<quality>"`
/// — all three components, for the reason ``FaceAnalyzerFaceInputProvider``'s key
/// carries the size: the same file at two sizes is two different pixel grids, and
/// the same file at two quality levels is two different masks (256x192 vs
/// 2016x1512).
///
/// Concurrent callers on the same key share one run, like `FaceAnalyzer`'s
/// `inFlight` table does: a fast filmstrip walk is exactly the case that would
/// otherwise start the same request three times.
///
/// ## `nil` is an answer, not a failure
/// `PersonSegmenter.mask(for:)` returns `nil` when Vision found no person, and
/// this passes that through unchanged. ``SubjectMaskProviding`` is explicit that
/// a caller must **not** read `nil` as an all-zero mask: for `BodySkinMask` that
/// would multiply the whole frame by zero and silently switch the feature off on
/// every landscape. A *failure* (the flag is off, the Simulator cannot create an
/// inference context) is thrown instead, so the two can never be confused.
final class PersonSegmenterSubjectMaskProvider: SubjectMaskProviding {
    /// One segmentation run. Injectable for exactly one reason: the caching and
    /// coalescing above is the part of this file that can be got wrong, and
    /// `VNGeneratePersonSegmentationRequest` **cannot run on the iOS Simulator**
    /// at all (`PersonSegmenter.unsupportedReason()` and
    /// `Research/bench/p6-background-lock-ios-simulator.json`), so a test that
    /// went through Vision would have no iOS coverage and would be timing-
    /// dependent on macOS. `PersonSegmenterTests` already covers the request
    /// itself; this seam covers the bookkeeping around it.
    typealias Segmenting = @Sendable (CGImage, SubjectMaskQuality, String) throws -> RenderMask?

    private let cache: MaskCache

    init(cacheCapacity: Int = 8, segment: @escaping Segmenting = PersonSegmenterSubjectMaskProvider.segmentWithVision) {
        self.cache = MaskCache(capacity: cacheCapacity, segment: segment)
    }

    /// The real thing: one `VNGeneratePersonSegmentationRequest`, logged.
    ///
    /// On a real iPhone this log line is the only trace that the request ran at
    /// all, and "no person in the frame" has to be distinguishable from "it never
    /// ran" (docs/ADR-0015).
    static func segmentWithVision(
        _ image: CGImage, quality: SubjectMaskQuality, key: String
    ) throws -> RenderMask? {
        let started = ContinuousClock.now
        let segmenter = try PersonSegmenter(quality: visionQuality(quality))
        let found = try segmenter.mask(for: image)
        let ms = Double((started.duration(to: .now)).components.attoseconds) / 1e15
        if let found {
            AppLog.write(
                "person segmentation: \(found.width)x\(found.height) mask for \(key) — "
                    + String(format: "%.1f ms", ms))
        } else {
            AppLog.write(
                "person segmentation: NO SUBJECT found in \(key) — "
                    + String(format: "%.1f ms", ms))
        }
        return found.map {
            RenderMask(
                width: $0.width, height: $0.height, values: $0.values,
                maskToImage: $0.maskToImage)
        }
    }

    /// Why there is no provider, when there is none — same shape as
    /// ``FaceAnalyzerFaceInputProvider/Outcome``, and for the same reason
    /// (docs/ADR-0015): a silent `nil` makes "the flag is off" look identical to
    /// "this photo has no person in it".
    enum Outcome {
        case ready(PersonSegmenterSubjectMaskProvider)
        /// `RPVisionFeatureFlags.personSegmentation` is off — the shipping
        /// default, since no UI asks for a subject mask yet.
        case featureDisabled
        /// The request family cannot run on this machine at all. The iOS
        /// Simulator is the known case: `PersonSegmenter.unsupportedReason()`
        /// probes it by *trying*, because it is not a version check.
        case unsupported(String)

        var provider: PersonSegmenterSubjectMaskProvider? {
            if case .ready(let provider) = self { return provider }
            return nil
        }

        /// Appended to the startup log when it is not `.ready`.
        var diagnostic: String? {
            switch self {
            case .ready: nil
            // Nothing to say: off is the shipping default, and `renderSummary`
            // already lists the experiments a launch turned on. Same reasoning as
            // `FaceAnalyzerFaceInputProvider.Outcome.noModels`.
            case .featureDisabled: nil
            case .unsupported(let reason):
                "person segmentation: UNSUPPORTED on this machine — \(reason)"
            }
        }
    }

    /// Builds one if the flag is on.
    ///
    /// - Parameter probe: run `PersonSegmenter.unsupportedReason()` as well. It
    ///   costs one 64x48 request, so it is opt-in: the app pays it once at
    ///   launch to get the reason into `session.log`, and tests skip it.
    static func standard(probe: Bool = false) -> Outcome {
        guard RPVisionFeatureFlags.personSegmentation else { return .featureDisabled }
        if probe, let reason = PersonSegmenter.unsupportedReason() {
            return .unsupported(reason)
        }
        return .ready(PersonSegmenterSubjectMaskProvider())
    }

    func subjectMask(
        for image: PreviewImage, contentHash: String, quality: SubjectMaskQuality
    ) async throws -> RenderMask? {
        let key = Self.cacheKey(contentHash: contentHash, size: image.pixelSize, quality: quality)
        return try await cache.mask(forKey: key, image: image.cgImage, quality: quality)
    }

    static func cacheKey(contentHash: String, size: CGSize, quality: SubjectMaskQuality) -> String {
        "\(contentHash)@\(Int(size.width))x\(Int(size.height))@\(quality.rawValue)"
    }

    /// RPEngine's quality names to RPVision's. Two enums rather than one because
    /// RPEngine must not import Vision to spell a quality level
    /// (``SubjectMaskQuality``'s own note); the cost of that is this `switch`,
    /// which has no arithmetic in it and cannot drift silently — adding a case on
    /// either side fails to compile here.
    static func visionQuality(_ quality: SubjectMaskQuality) -> PersonSegmentationQuality {
        switch quality {
        case .fast: .fast
        case .balanced: .balanced
        case .accurate: .accurate
        }
    }

    /// The actor holding the answers, so the cache needs no lock and concurrent
    /// callers on one key share one request.
    private actor MaskCache {
        private let capacity: Int
        private let segment: Segmenting
        /// Insertion-ordered keys; the oldest is evicted first. A handful of
        /// masks is a few hundred kilobytes, so this is a small LRU-by-age, not a
        /// true LRU — the access pattern is "the shot that is open".
        private var order: [String] = []
        private var values: [String: RenderMask?] = [:]
        private var inFlight: [String: Task<RenderMask?, Error>] = [:]

        init(capacity: Int, segment: @escaping Segmenting) {
            self.capacity = max(1, capacity)
            self.segment = segment
        }

        func mask(
            forKey key: String, image: CGImage, quality: SubjectMaskQuality
        ) async throws -> RenderMask? {
            if let hit = values[key] { return hit }
            if let running = inFlight[key] { return try await running.value }
            let run = segment
            let task = Task.detached(priority: .userInitiated) { () throws -> RenderMask? in
                // Off the caller's actor: the Vision request is tens of
                // milliseconds of synchronous work and the caller is the main
                // actor (`LivePreviewController.open`).
                try run(image, quality, key)
            }
            inFlight[key] = task
            defer { inFlight[key] = nil }
            do {
                let result = try await task.value
                store(result, forKey: key)
                return result
            } catch {
                AppLog.write("person segmentation FAILED for \(key): \(error)")
                throw error
            }
        }

        private func store(_ mask: RenderMask?, forKey key: String) {
            if values[key] == nil { order.append(key) }
            values[key] = mask
            while order.count > capacity {
                let oldest = order.removeFirst()
                values[oldest] = nil
            }
        }
    }
}

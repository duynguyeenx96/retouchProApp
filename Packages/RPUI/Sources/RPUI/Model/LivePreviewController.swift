import CoreGraphics
import Foundation
import Metal
import OSLog
import Observation
import RPCore
import RPEngine

/// The canvas's live GPU preview: one shot on the GPU, the real `RenderGraph`
/// over it, redrawn when a slider moves.
///
/// ## What it owns and what it does not
///
/// It owns the `RPEngine.LivePreviewRenderer` (source texture + graph + present
/// pass), the shot's `[FaceRenderInput]`, and the *decision* of when a redraw is
/// needed. It does not own the `MTKView` — that is `LivePreviewMetalView`, which
/// reads ``version`` and asks for a redraw — and it does not own the
/// `EditState`, which stays in ``EditorModel`` and on disk.
///
/// ## The performance rule this type exists to enforce
///
/// Face analysis is ~36 ms per image on an M-series Mac
/// (`Research/bench/p2-face-analyzer-macos.json`) and a slider drag issues tens
/// of redraws a second. So analysis runs **once per shot**, in ``open(_:)``, and
/// the resulting `[FaceRenderInput]` is kept here; a slider change only bumps
/// ``version``, and the draw callback only re-runs the graph. Decode and upload
/// are likewise once per shot. `FaceAnalyzer`'s own content-hash cache is behind
/// the provider, so re-opening a shot is a cache hit rather than a second
/// inference (warm 0.052 ms).
///
/// ## Failure is a state, not a crash
///
/// No Metal device, a source too large, a provider that throws — all of them
/// land in ``failureMessage`` and the canvas falls back to the decoded
/// `PreviewImage` it already has. An editor that cannot show the photo because
/// the GPU path is unhappy is worse than one showing the unedited photo with a
/// message.
@MainActor
@Observable
public final class LivePreviewController {
    /// The engine object. Exposed because the `MTKView` coordinator drives it
    /// directly on the draw callback — going through this class for every frame
    /// would just be a hop.
    public let renderer: LivePreviewRenderer
    private let faceProvider: any FaceInputProviding
    private let subjectProvider: any SubjectMaskProviding

    /// Unified-log channel, so a face-analysis failure is visible with
    /// `devicectl device process launch --console` on a real iPhone and not only
    /// in the canvas overlay.
    @ObservationIgnored
    nonisolated static let log = Logger(subsystem: "com.duynguyen.RetouchPro", category: "preview")

    /// Faces for the open shot, already in the preview texture's pixels.
    /// **Not** narrowed by the face selection — the UI draws all of them and
    /// lets the user pick; narrowing happens in ``renderRequest``.
    public private(set) var faces: [FaceRenderInput] = []
    /// Pixel size of the texture being edited (the decoded preview).
    public private(set) var sourceSize: CGSize = .zero
    /// Content hash of the open shot, so a re-open of the same shot is free.
    public private(set) var openContentHash: String?
    /// `true` between ``open(_:contentHash:editState:)`` and its completion.
    public private(set) var isPreparing = false
    /// Set when the GPU path is unusable; the canvas then shows the CPU-decoded
    /// image instead.
    public private(set) var failureMessage: String?
    /// `true` when face analysis was asked for and produced nothing — either the
    /// models are absent or the picture has no face in it. The panel uses it to
    /// explain why the face-dependent sliders do nothing.
    public private(set) var faceAnalysisRan = false

    /// Whole-frame skin coverage for the open shot (docs/PLAN.md §6.2 "Sửa da",
    /// docs/ADR-0021), already in the preview texture's pixels, or `nil`.
    ///
    /// `nil` on every path unless `RPEngineFeatureFlags.bodySkinSync` is on,
    /// which is the shipping default — see ``prepareBodySkinMask(for:contentHash:)``
    /// for why the whole computation is skipped rather than computed and ignored.
    /// `SkinRenderNode` reads it through ``renderRequest``.
    public private(set) var bodySkinMask: RenderMask?
    /// Mean coverage of ``bodySkinMask`` over the frame, for the status line and
    /// the log. `nil` when no mask was computed.
    public private(set) var bodySkinCoverageFraction: Double?
    /// `true` when a subject mask was found and multiplied into
    /// ``bodySkinMask`` (docs/ADR-0021 §v2). `false` means the classifier's
    /// coverage was used as-is — either because no person was found or because
    /// the segmentation request failed — **not** that everything was masked out.
    public private(set) var bodySkinUsedSubjectMask = false

    /// Which quality level the subject mask is asked for.
    ///
    /// `.balanced`, and this is a measured choice rather than a middle one.
    /// `Research/bench/p6-background-lock-macos.json`: `.fast` returns a 256x192
    /// mask whose mean coverage inside a detected face box is 0.90 (0.71 on one
    /// frame) against 0.997 for `.balanced`, because at a 2048 px preview a
    /// 256 px mask is ~25 px across a head. Since this mask is used as a
    /// *multiplier* on skin coverage, a boundary error there does not blur an
    /// edge, it deletes skin. `.accurate` costs 3x the milliseconds (54.5 vs
    /// 17.2 ms) for a 2016 px mask that the 320 px classifier grid immediately
    /// throws away. Once per shot, so 17 ms is affordable; no iPhone number
    /// exists yet, which is the other reason the whole path is flag-gated.
    public static let subjectMaskQuality: SubjectMaskQuality = .balanced

    /// Bumped whenever the graph must run again. The `MTKView` compares it with
    /// the version it last drew.
    public private(set) var version = 0
    /// The document the next redraw will render.
    public private(set) var editState = EditState()

    /// Milliseconds of the last completed redraw (graph only, wall clock).
    public private(set) var lastRenderMilliseconds: Double = 0
    /// Node names the last redraw actually ran.
    public private(set) var lastNodes: [String] = []
    private var recentMilliseconds: [Double] = []

    public init(
        renderer: LivePreviewRenderer,
        faceProvider: any FaceInputProviding = NoFaceInputProvider(),
        subjectProvider: any SubjectMaskProviding = NoSubjectMaskProvider()
    ) {
        self.renderer = renderer
        self.faceProvider = faceProvider
        self.subjectProvider = subjectProvider
    }

    /// Builds the standard renderer for this machine, or `nil` when there is no
    /// Metal device or the graph refuses to build.
    ///
    /// `nil` is a supported outcome: `RPUITests` and SwiftUI previews run
    /// without a GPU, and the canvas has a CPU fallback.
    public static func standard(
        faceProvider: any FaceInputProviding = NoFaceInputProvider(),
        subjectProvider: any SubjectMaskProviding = NoSubjectMaskProvider(),
        context: MetalContext? = MetalContext.shared
    ) -> LivePreviewController? {
        guard let context else { return nil }
        guard let renderer = try? LivePreviewRenderer(context: context) else { return nil }
        // Off the interaction path, once per process: without it the first
        // slider drag pays the shader compile (236 ms macOS / 1798 ms Simulator,
        // ADR-0007) and reads as a frozen UI.
        try? renderer.prewarm()
        return LivePreviewController(
            renderer: renderer, faceProvider: faceProvider, subjectProvider: subjectProvider)
    }

    // MARK: - Opening a shot

    /// Uploads a decoded shot and analyses its faces. Call once per shot.
    ///
    /// - Parameter image: the preview the canvas already decoded, at
    ///   `RenderQuality.preview.preferredLongEdge`. Analysis runs on these same
    ///   pixels, so the faces need no rescaling — the class of bug
    ///   `RenderRequest.faces` documents ("the graph does not scale them
    ///   itself") cannot happen here.
    public func open(_ image: PreviewImage, contentHash: String, editState: EditState) async {
        self.editState = editState
        guard openContentHash != contentHash || sourceSize != image.pixelSize else {
            // Same shot, new edits: keep the texture and the faces.
            invalidate()
            return
        }
        isPreparing = true
        failureMessage = nil
        faces = []
        faceAnalysisRan = false
        clearBodySkinMask()
        defer { isPreparing = false }

        do {
            try renderer.setSource(image.cgImage)
            sourceSize = image.pixelSize
            openContentHash = contentHash
        } catch {
            failureMessage = String(describing: error)
            openContentHash = nil
            sourceSize = .zero
            return
        }
        invalidate()

        let kinds = RenderMaskRequirements.forEnabledGroups()
        do {
            let found = try await faceProvider.faceInputs(
                for: image, contentHash: contentHash, kinds: kinds)
            // The shot may have changed while the analysis ran.
            guard openContentHash == contentHash else { return }
            faces = found
            faceAnalysisRan = true
            Self.log.log(
                "face analysis: \(found.count, privacy: .public) face(s) in \(contentHash, privacy: .public)")
            invalidate()
        } catch {
            faceAnalysisRan = false
            failureMessage = "Face analysis unavailable: \(error)"
            // Also to the unified log: on a real device the only way to see this
            // is `devicectl device process launch --console`, and a message that
            // exists solely inside a SwiftUI overlay is a message nobody reads
            // when the complaint is "the sliders do nothing" (docs/ADR-0015).
            Self.log.error(
                "face analysis failed for \(contentHash, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }

        await prepareBodySkinMask(for: image, contentHash: contentHash)
    }

    /// Drops the shot's textures. Call when the editor closes.
    public func close() {
        renderer.clearSource()
        faces = []
        sourceSize = .zero
        openContentHash = nil
        faceAnalysisRan = false
        clearBodySkinMask()
        invalidate()
    }

    // MARK: - Whole-body skin mask (docs/PLAN.md §6.2 "Sửa da", ADR-0021)

    /// Runs the subject segmentation and the whole-frame skin classifier **once
    /// per shot**, and keeps the result for ``renderRequest``.
    ///
    /// ## Why the flag is checked first and nothing runs behind it
    /// This is not a cheap step: a `VNGeneratePersonSegmentationRequest` (17 ms
    /// at `.balanced`) plus a CPU colour classification of every pixel of the
    /// preview (17.8 ms at 2048 px, `Research/bench/p6-skin-sync-macos.json`).
    /// With `RPEngineFeatureFlags.bodySkinSync` off — the shipping default, and
    /// it stays off because the classifier is still 0.000 IoU on the deepest skin
    /// tone (ADR-0021 §5) — `SkinRenderNode` ignores `RenderRequest.bodySkinMask`
    /// entirely, so computing one would be ~35 ms of work per shot thrown away.
    /// The guard is therefore the *whole* cost model of this feature, not an
    /// optimisation.
    ///
    /// ## Order, and why the subject mask comes first
    /// The segmentation is awaited before the classifier because it is an
    /// *input* to it (ADR-0021 §v2): `BodySkinMask.make` multiplies it into the
    /// coverage so background wood and rattan cannot be reported as skin. A
    /// missing subject mask (`nil` — no person in the frame) is passed through as
    /// `nil` and the classifier runs unmultiplied, which is v1's behaviour. It is
    /// **not** turned into an all-zero mask; that would silently remove all skin
    /// coverage from every frame Vision does not recognise a person in.
    ///
    /// ## Where the work happens
    /// Both halves are off the main actor — the classifier in a detached task,
    /// the segmentation inside the provider's own actor — and both are keyed on
    /// the shot, so a slider drag never reaches this method (the rule
    /// docs/ADR-0013 records for face analysis, applied to a second Vision
    /// request).
    private func prepareBodySkinMask(for image: PreviewImage, contentHash: String) async {
        guard RPEngineFeatureFlags.bodySkinSync else { return }
        var subject: RenderMask?
        do {
            subject = try await subjectProvider.subjectMask(
                for: image, contentHash: contentHash, quality: Self.subjectMaskQuality)
        } catch {
            // Not fatal and not a canvas failure: the classifier still has an
            // answer without a subject prior, it is just the v1 answer.
            Self.log.error(
                "subject mask failed for \(contentHash, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
        guard openContentHash == contentHash else { return }

        let source = image.cgImage
        let prior = subject
        let result: BodySkinMask.Result?
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try BodySkinMask.make(image: source, subject: prior)
            }.value
        } catch {
            Self.log.error(
                "body skin mask failed for \(contentHash, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            result = nil
        }
        guard openContentHash == contentHash, let result else { return }

        bodySkinMask = result.mask
        bodySkinCoverageFraction = result.coverageFraction
        bodySkinUsedSubjectMask = prior != nil
        Self.log.log(
            """
            body skin mask: \(result.mask.width, privacy: .public)x\
            \(result.mask.height, privacy: .public), coverage \
            \(String(format: "%.3f", result.coverageFraction), privacy: .public), \
            subject mask \(prior == nil ? "absent" : "applied", privacy: .public)
            """)
        invalidate()
    }

    private func clearBodySkinMask() {
        bodySkinMask = nil
        bodySkinCoverageFraction = nil
        bodySkinUsedSubjectMask = false
    }

    // MARK: - Edits

    /// The new document to render. Cheap — it only bumps ``version``; the graph
    /// runs on the next draw.
    public func update(editState: EditState) {
        guard editState != self.editState else { return }
        self.editState = editState
        invalidate()
    }

    /// Forces a redraw without an edit (a window resize does not need one, a
    /// feature-flag change does).
    public func invalidate() {
        version &+= 1
    }

    /// What the next redraw will ask the graph for, with the shot's face
    /// selection already applied.
    ///
    /// ``bodySkinMask`` needs no rescaling on the way in: it was classified from
    /// the very `PreviewImage` that was uploaded as the source texture, so it is
    /// already in the grid `RenderRequest.bodySkinMask` documents ("also already
    /// scaled to the texture being rendered"). That is the same property that
    /// lets ``faces`` go in unscaled.
    public var renderRequest: RenderRequest {
        var request = RenderRequest(
            editState: editState, allFaces: faces, quality: renderer.quality)
        request.bodySkinMask = bodySkinMask
        return request
    }

    /// `true` when the GPU path can put pixels on screen.
    public var isReady: Bool { failureMessage == nil && renderer.hasSource }

    // MARK: - Face selection

    /// The shot's current selection, resolved against the faces actually found.
    public var faceSelection: FaceSelection {
        FaceSelection(editState).resolved(faceCount: faces.count)
    }

    /// Bounding box of a detected face in preview-texture pixels. See
    /// ``FaceOverlayGeometry``, which holds the arithmetic so it is testable
    /// without a GPU.
    public func faceBox(_ index: Int) -> CGRect? {
        guard faces.indices.contains(index) else { return nil }
        return FaceOverlayGeometry.box(of: faces[index])
    }

    /// Every detected face's box, in preview-texture pixels.
    public var faceBoxes: [CGRect] {
        faces.indices.compactMap { faceBox($0) }
    }

    /// The face whose box contains `point` (preview-texture pixels).
    public func faceIndex(at point: CGPoint) -> Int? {
        FaceOverlayGeometry.index(at: point, in: faces)
    }

    // MARK: - Statistics (for the canvas HUD)

    /// Called by the `MTKView` coordinator after a redraw.
    public func recordFrame(milliseconds: Double, report: RenderReport) {
        lastRenderMilliseconds = milliseconds
        lastNodes = report.nodes
        recentMilliseconds.append(milliseconds)
        if recentMilliseconds.count > 30 { recentMilliseconds.removeFirst() }
    }

    /// Median of the last 30 redraws, or 0. A live diagnostic for the status
    /// bar — the numbers that get *filed* come from `Scripts/bench-live-preview.sh`
    /// (docs/PLAN.md §5: no conclusion from a screenshot).
    public var medianRenderMilliseconds: Double {
        guard !recentMilliseconds.isEmpty else { return 0 }
        let sorted = recentMilliseconds.sorted()
        return sorted[sorted.count / 2]
    }

    public var statusText: String {
        guard renderer.hasSource else { return "" }
        let size = "\(Int(sourceSize.width))×\(Int(sourceSize.height))"
        guard medianRenderMilliseconds > 0 else { return "GPU preview \(size)" }
        let ms = String(format: "%.2f", medianRenderMilliseconds)
        let fps = Int((1000 / max(medianRenderMilliseconds, 0.001)).rounded())
        let nodes = lastNodes.isEmpty ? "no edits" : lastNodes.joined(separator: "→")
        return "GPU preview \(size) · \(ms) ms · \(fps) fps · \(nodes)"
    }
}

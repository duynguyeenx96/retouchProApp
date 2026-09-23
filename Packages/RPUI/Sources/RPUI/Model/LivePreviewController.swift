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
    /// Read by the batch export (``PreviewFaceSource``) so a shot that is not
    /// open gets its faces from the very same provider the canvas uses.
    public let faceProvider: any FaceInputProviding
    /// Read by the export (``PreviewMaskSource``) for the same reason as
    /// ``faceProvider``: a shot that is not open gets its subject mask from the
    /// provider — and the provider's content-hash cache — the canvas uses.
    public let subjectProvider: any SubjectMaskProviding

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
    ///
    /// Computed regardless of the document's own "Sửa da" switch, the same way
    /// ``backgroundLockGate`` is: the switch is read at request-assembly time
    /// (`BodySkinSync.mask(for:bodySkinMask:)`), so flipping it must not cost a
    /// re-classification. With the feature flag off nothing here runs at all,
    /// which is what makes the shipping build pay nothing for either switch.
    public private(set) var bodySkinMask: RenderMask?
    /// Mean coverage of ``bodySkinMask`` over the frame, for the status line and
    /// the log. `nil` when no mask was computed.
    public private(set) var bodySkinCoverageFraction: Double?
    /// `true` when a subject mask was found and multiplied into
    /// ``bodySkinMask`` (docs/ADR-0021 §v2). `false` means the classifier's
    /// coverage was used as-is — either because no person was found or because
    /// the segmentation request failed — **not** that everything was masked out.
    public private(set) var bodySkinUsedSubjectMask = false

    /// The open shot's whole-frame subject mask, in the preview texture's
    /// pixels, or `nil` when no person was found (or when nothing asked for
    /// one).
    ///
    /// **One mask, two consumers.** It was already being computed here for
    /// "Sửa da" (`bodySkinMask` multiplies it in, ADR-0021 §v2); "Khoá nền"
    /// needs the same pixels, and a `VNGeneratePersonSegmentationRequest` is
    /// 17 ms at `.balanced`. So it is computed once per shot and published, and
    /// neither feature re-asks — the cache contract in
    /// `SubjectMaskProviding`'s doc comment, honoured one level above the
    /// provider as well as inside it.
    ///
    /// `nil` is a legitimate answer (a landscape, a product shot) and must be
    /// read as "there is nothing to lock", never as an all-zero mask.
    public private(set) var subjectMask: RenderMask?

    /// ``subjectMask`` rasterised to a full-resolution coverage texture and
    /// wrapped for `RenderRequest.gateMasks` — docs/PLAN.md §6.1 "Khoá nền".
    ///
    /// `nil` unless `RPEngineFeatureFlags.backgroundLock` is on (off by default,
    /// docs/ADR-0018) *and* the shot has a subject. Held per shot rather than
    /// rebuilt per frame: it is one `r8Unorm` texture the size of the preview,
    /// and a slider drag issues tens of redraws a second.
    ///
    /// Built regardless of the document's own toggle, because the toggle is read
    /// at request-assembly time (``BackgroundLock/gateMasks(for:subjectGate:)``)
    /// and flipping it must not cost a re-segmentation. The whole path still
    /// costs nothing in the shipping build: with the flag off nothing here runs
    /// at all.
    public private(set) var backgroundLockGate: TextureGateMask?
    /// Lazily built, and only when the flag is on — its initialiser throws while
    /// `RPEngineFeatureFlags.backgroundLock` is off.
    @ObservationIgnored
    private var backgroundLockSource: BackgroundLockMaskSource?

    /// The open shot's hand-painted mask — docs/PLAN.md §6.1 "Cọ mask thủ công",
    /// docs/ADR-0019.
    ///
    /// One session per shot, built at the **decoded preview's** size so
    /// `ManualMaskCoverage.maskToImage` is the identity and a brush point needs
    /// no rescaling (the same property that lets ``faces`` and ``bodySkinMask``
    /// go in unscaled). It is built once and kept alive across strokes because it
    /// owns two `r8Unorm` textures and the undo history; rebuilding it per stroke
    /// would throw both away.
    ///
    /// `nil` unless `RPEngineFeatureFlags.manualMask` is on — the producer-side
    /// gate, enforced one level down as well (`ManualMaskSession.init` throws
    /// while the flag is off), so with the flag off no `RenderRequest` can carry
    /// a painted gate at all.
    ///
    /// The paint API lives in `LivePreviewController+ManualMask.swift`; this is
    /// only the ownership.
    public private(set) var manualMask: ManualMaskSession?

    /// The stroke list the session was last told is the document
    /// (``open(_:contentHash:editState:manualMaskStrokes:)`` /
    /// ``setManualMaskStrokes(_:)``), normalised — kept so a session rebuilt for
    /// a new preview size replays the same strokes.
    ///
    /// Since 2026-09-23 this class does not *own* the brush document: the
    /// stroke list lives in ``EditorModel`` (`activeStrokes`), is persisted as
    /// `edits/<shot id>.strokes.json`, and undo walks it through the shot's
    /// history. The session here is the rasterised, derived view of it.
    @ObservationIgnored
    public internal(set) var manualMaskDocument: [ManualMaskStroke] = []

    /// `true` once ``prepareShotMasks(for:contentHash:)`` has finished for the
    /// open shot (including the fast "both flags off" return), i.e. once
    /// ``subjectMask`` and ``bodySkinMask`` are *final* rather than "not yet".
    /// The export reuses them only then; before that it builds its own the way
    /// this class would (``PreviewMaskSource``), rather than exporting a shot
    /// without a mask the canvas is about to show.
    public private(set) var shotMasksReady = false

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
    ///
    /// **"Khoá nền" does not get a quality level of its own.** It consumes
    /// ``subjectMask`` — the one mask this controller already computes — so it
    /// inherits this one, and `RPEngine.SubjectMaskQuality` still declares no
    /// default anywhere (docs/ADR-0018: that choice is blocked on an iPhone
    /// measurement nobody has made). Two levels would mean two requests per shot
    /// for the same pixels.
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
    /// What each render node's detection could **not** find on the last redraw,
    /// keyed by node name (`RenderReport.notices`). Empty on a healthy render.
    ///
    /// Surfaced exactly the way ``lastNodes`` is — written by ``recordFrame(milliseconds:report:)``
    /// after every draw, never computed here — so it is a *live* fact about the
    /// current shot and the current sliders rather than a one-shot event. The
    /// panel reads it through `GroupAvailability.blockedReason(...)` and shows it
    /// the same way it shows "no face detected": a persistent line above a
    /// disabled group, not a banner the user dismisses.
    public private(set) var detectionNotices: [String: String] = [:]
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
    ///
    /// - Parameter manualMaskStrokes: the shot's stored brush strokes
    ///   (`EditorModel.activeStrokes`), replayed onto the new session at the
    ///   preview's size — reopening a shot shows exactly the mask it was left with.
    public func open(
        _ image: PreviewImage, contentHash: String, editState: EditState,
        manualMaskStrokes: [ManualMaskStroke] = []
    ) async {
        self.editState = editState
        manualMaskDocument = manualMaskStrokes
        guard openContentHash != contentHash || sourceSize != image.pixelSize else {
            // Same shot, new edits: keep the texture and the faces — and bring
            // the brush in line with the document it was handed.
            setManualMaskStrokes(manualMaskStrokes)
            invalidate()
            return
        }
        isPreparing = true
        failureMessage = nil
        faces = []
        faceAnalysisRan = false
        // The previous shot's notices are about the previous shot. Dropping them
        // here means the panel says nothing until the new shot has actually been
        // rendered once, rather than blaming this photo for the last one's
        // missing hairline.
        detectionNotices = [:]
        clearShotMasks()
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
        // Synchronous and before the analyses: the brush is user input, so the
        // canvas has to be paintable the moment the picture is on screen rather
        // than after a 36 ms Core ML pass the brush does not depend on.
        prepareManualMask(for: image)
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

        await prepareShotMasks(for: image, contentHash: contentHash)
    }

    /// Drops the shot's textures. Call when the editor closes.
    public func close() {
        renderer.clearSource()
        faces = []
        sourceSize = .zero
        openContentHash = nil
        faceAnalysisRan = false
        detectionNotices = [:]
        clearShotMasks()
        manualMaskDocument = []
        invalidate()
    }

    // MARK: - Per-shot masks (§6.2 "Sửa da" / ADR-0021, §6.1 "Khoá nền" / ADR-0018)

    /// Runs the subject segmentation **once per shot** and hands the result to
    /// both features that want it, then runs the whole-frame skin classifier.
    ///
    /// ## Why the flags are checked first and nothing runs behind them
    /// This is not a cheap step: a `VNGeneratePersonSegmentationRequest` (17 ms
    /// at `.balanced`) plus a CPU colour classification of every pixel of the
    /// preview (17.8 ms at 2048 px, `Research/bench/p6-skin-sync-macos.json`).
    /// With `RPEngineFeatureFlags.bodySkinSync` off — the shipping default, and
    /// it stays off because the classifier is still 0.000 IoU on the deepest skin
    /// tone (ADR-0021 §5) — `SkinRenderNode` ignores `RenderRequest.bodySkinMask`
    /// entirely, so computing one would be ~35 ms of work per shot thrown away.
    /// The guards are therefore the *whole* cost model of these features, not an
    /// optimisation. With **both** flags off (the shipping build) this method
    /// returns before touching Vision at all, which is what makes "Khoá nền
    /// changes nothing today" true rather than merely invisible.
    ///
    /// ## One request, two consumers
    /// "Sửa da" multiplies the subject mask into its skin coverage (ADR-0021 §v2)
    /// and "Khoá nền" rasterises it into a gate (ADR-0018). Both read
    /// ``subjectMask``; the request is issued once. If only one of the two flags
    /// is on, the other half is skipped and the segmentation still happens once.
    ///
    /// ## Order, and why the subject mask comes first
    /// The segmentation is awaited before the classifier because it is an
    /// *input* to it (ADR-0021 §v2): `BodySkinMask.make` multiplies it into the
    /// coverage so background wood and rattan cannot be reported as skin. A
    /// missing subject mask (`nil` — no person in the frame) is passed through as
    /// `nil` and the classifier runs unmultiplied, which is v1's behaviour. It is
    /// **not** turned into an all-zero mask; that would silently remove all skin
    /// coverage from every frame Vision does not recognise a person in — and for
    /// "Khoá nền" the same `nil` means "there is nothing to lock", so the gate is
    /// simply absent and every node keeps its pre-6.1 behaviour.
    ///
    /// ## Where the work happens
    /// Both halves are off the main actor — the classifier in a detached task,
    /// the segmentation inside the provider's own actor — and both are keyed on
    /// the shot, so a slider drag never reaches this method (the rule
    /// docs/ADR-0013 records for face analysis, applied to a second Vision
    /// request).
    private func prepareShotMasks(for image: PreviewImage, contentHash: String) async {
        // Every exit below leaves the masks final for this shot — unless the
        // shot changed meanwhile, which the hash check keeps from marking the
        // *new* shot ready.
        defer { if openContentHash == contentHash { shotMasksReady = true } }
        guard RPEngineFeatureFlags.bodySkinSync || RPEngineFeatureFlags.backgroundLock else {
            return
        }
        var subject: RenderMask?
        do {
            subject = try await subjectProvider.subjectMask(
                for: image, contentHash: contentHash, quality: Self.subjectMaskQuality)
        } catch {
            // Not fatal and not a canvas failure: the classifier still has an
            // answer without a subject prior, it is just the v1 answer, and
            // "Khoá nền" simply gates nothing.
            Self.log.error(
                "subject mask failed for \(contentHash, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
        guard openContentHash == contentHash else { return }
        subjectMask = subject
        prepareBackgroundLockGate(for: image)

        guard RPEngineFeatureFlags.bodySkinSync else {
            invalidate()
            return
        }
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

    /// Rasterises ``subjectMask`` into the gate texture "Khoá nền" multiplies
    /// into every node's coverage — docs/PLAN.md §6.1, docs/ADR-0018.
    ///
    /// Synchronous and blocking (`waitUntilCompleted`) on purpose: it is one
    /// `rp_skin_mask` dispatch, once per shot, on a path that has already
    /// awaited a 17 ms Vision request — and the alternative, publishing the gate
    /// from a completion handler, would put a second "did the shot change while
    /// we were away" race next to the one this method is already inside.
    ///
    /// Everything here is skipped while `RPEngineFeatureFlags.backgroundLock` is
    /// off, which is the shipping default and is also enforced one level down:
    /// `BackgroundLockMaskSource.init` throws `RPEngineFeatureDisabled`.
    private func prepareBackgroundLockGate(for image: PreviewImage) {
        backgroundLockGate = nil
        guard RPEngineFeatureFlags.backgroundLock, let mask = subjectMask else { return }
        let width = Int(image.pixelSize.width)
        let height = Int(image.pixelSize.height)
        guard width > 0, height > 0 else { return }
        do {
            // The mask arrives in the preview image's pixels — the very pixels
            // uploaded as the source texture — so it needs no rescaling on the
            // way in, the same property that lets `faces` and `bodySkinMask` go
            // in unscaled.
            let source = try backgroundLockSource ?? BackgroundLockMaskSource(
                context: renderer.context)
            backgroundLockSource = source
            guard let commandBuffer = renderer.context.commandQueue.makeCommandBuffer() else {
                return
            }
            let texture = try source.encode(
                into: commandBuffer, mask: mask, width: width, height: height)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            guard let texture else { return }
            // Identity: the rasteriser writes at the size of the picture being
            // rendered, which is what `TextureGateMask`'s default transform
            // documents.
            backgroundLockGate = TextureGateMask(texture: texture)
            Self.log.log(
                "background lock gate: \(texture.width, privacy: .public)x\(texture.height, privacy: .public)"
            )
        } catch {
            Self.log.error(
                "background lock gate failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Builds the shot's ``manualMask`` session — docs/ADR-0019.
    ///
    /// Cheap enough to be synchronous: two `r8Unorm` textures (5.6 MB at a
    /// 2048 px preview) and a clear. There is no Vision request and no Core ML
    /// behind a brush, which is the whole reason this feature needs no
    /// detection-failure notice (`SliderSectionDescriptor.notifiesFromNodeNamed`
    /// is `nil` for it: user input cannot fail to be detected).
    ///
    /// The previous shot's session is dropped first, so a painted mask never
    /// leaks onto the next picture — masks are per shot
    /// (`edits/<shot id>.strokes.json`, docs/ADR-0019 addendum 2026-09-23).
    private func prepareManualMask(for image: PreviewImage) {
        manualMask = nil
        guard RPEngineFeatureFlags.manualMask else { return }
        let width = Int(image.pixelSize.width)
        let height = Int(image.pixelSize.height)
        guard width > 0, height > 0 else { return }
        do {
            let session = try ManualMaskSession(
                context: renderer.context, width: width, height: height)
            manualMask = session
            Self.log.log(
                "manual mask session: \(width, privacy: .public)x\(height, privacy: .public)")
            replayManualMaskDocument(into: session)
        } catch {
            // Not a canvas failure: every node keeps working, there is just
            // nothing to paint with.
            Self.log.error(
                "manual mask session failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Replays ``manualMaskDocument`` onto `session` at the session's size.
    ///
    /// Synchronous, like the session it fills: the canvas must not show the
    /// photo unmasked for a frame and then snap. The cost is the replay ADR-0019
    /// §7 measured, cut by the bounding-box dispatch that landed with stroke
    /// storage — see `Research/bench/p6-manual-mask-strokes-macos.json`.
    func replayManualMaskDocument(into session: ManualMaskSession) {
        let size = CGSize(width: session.width, height: session.height)
        let started = CFAbsoluteTimeGetCurrent()
        do {
            try session.replaceStrokes(manualMaskDocument.map { BrushStroke($0, imageSize: size) })
            if !manualMaskDocument.isEmpty {
                let ms = String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - started) * 1000)
                Self.log.log(
                    "manual mask replayed: \(self.manualMaskDocument.count, privacy: .public) stroke(s) in \(ms, privacy: .public) ms"
                )
            }
        } catch {
            Self.log.error(
                "manual mask replay failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func clearShotMasks() {
        shotMasksReady = false
        manualMask = nil
        bodySkinMask = nil
        bodySkinCoverageFraction = nil
        bodySkinUsedSubjectMask = false
        subjectMask = nil
        backgroundLockGate = nil
        backgroundLockSource?.releaseIntermediates()
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
    /// lets ``faces`` go in unscaled. It passes through
    /// ``RPEngine/BodySkinSync/mask(for:bodySkinMask:)`` (2026-09-21,
    /// docs/ADR-0021 §UI) so the document's own "Sửa da" switch decides whether
    /// the skin node ever sees it — the mirror of what
    /// ``RPEngine/BackgroundLock/gateMasks(for:subjectGate:)`` does one line
    /// below, and for the same reason: the *toggle* belongs at request assembly,
    /// where flipping it costs one frame, while `SkinRenderNode`'s union, its
    /// kernel and ADR-0009's 79.0 dB stay untouched. With the switch off the
    /// request carries no body mask, which is the state the node has always
    /// rendered as "bind the per-face coverage, byte for byte".
    ///
    /// ``backgroundLockGate`` is **appended** to `gateMasks` rather than
    /// assigned over it, and only when
    /// ``RPEngine/BackgroundLock/gateMasks(for:subjectGate:)`` says all three of
    /// its conditions hold. With the feature flag off, the document's toggle
    /// off, or no subject in the frame, the array stays empty — which
    /// `RenderGateMask` defines as "the node renders exactly the pixels it
    /// rendered before Phase 6.1", not "select nothing".
    /// The painted mask is appended the same way, and only when the user has
    /// actually painted something (``ManualMaskSession/isEmpty``). That guard is
    /// load-bearing rather than an optimisation: an untouched coverage texture is
    /// all zeros, and `RenderGateMask` multiplies — handing an empty mask to the
    /// graph would switch every mask-driven slider off in every shot the brush
    /// was merely *armed* on. "No gate" means the pre-6.1 render; "a gate of
    /// zeros" means nothing renders, and those are not the same sentence
    /// (docs/ADR-0019 §5).
    public var renderRequest: RenderRequest {
        var request = RenderRequest(
            editState: editState, allFaces: faces, quality: renderer.quality)
        request.bodySkinMask = BodySkinSync.mask(for: editState, bodySkinMask: bodySkinMask)
        request.gateMasks += BackgroundLock.gateMasks(
            for: editState, subjectGate: backgroundLockGate)
        if let manualMask, !manualMask.isEmpty {
            request.gateMasks.append(manualMask.coverage)
        }
        return request
    }

    /// The whole-frame masks ``renderRequest`` renders with, as CPU values the
    /// export can carry (`RPEngine.ExportMasks`), or `nil` when `contentHash`
    /// is not the open shot.
    ///
    /// All three are in the preview texture's pixels, so the reference size is
    /// ``sourceSize`` and the export rescales them the way it rescales
    /// ``faces``. The **raw** masks are handed over — not the
    /// `BodySkinSync`/`BackgroundLock`-filtered ones — because the export runs
    /// those same filters against the document it renders, which is the one
    /// captured when the button was pressed.
    ///
    /// * **No brush here.** The brush travels as its strokes
    ///   (`ExportMasks.brushStrokes`), which the caller takes from the document
    ///   (`EditorModel.activeStrokes`) and the export rasterises at render size
    ///   (docs/ADR-0019 addendum 2026-09-23) — this session's preview-sized
    ///   coverage is exactly what the export must *not* upsample.
    /// * `subjectMask`/`bodySkinMask` are only reported once ``shotMasksReady``;
    ///   the caller reads that flag to tell "no person found" (`nil`, final)
    ///   from "not computed yet" and builds its own in the second case.
    public func exportMasks(forContentHash contentHash: String) -> ExportMasks? {
        guard openContentHash == contentHash, sourceSize.width > 0, sourceSize.height > 0 else {
            return nil
        }
        return ExportMasks(
            referenceSize: sourceSize,
            subjectMask: shotMasksReady ? subjectMask : nil,
            bodySkinMask: shotMasksReady ? bodySkinMask : nil)
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
        // Assigned unconditionally, including when it is empty: a notice has to
        // disappear the moment the render stops reporting it (the user turned
        // the slider back to 0, or opened a shot whose hairline traces), which an
        // "only overwrite when non-empty" merge would prevent.
        detectionNotices = report.notices
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

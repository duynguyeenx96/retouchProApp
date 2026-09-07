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
        faceProvider: any FaceInputProviding = NoFaceInputProvider()
    ) {
        self.renderer = renderer
        self.faceProvider = faceProvider
    }

    /// Builds the standard renderer for this machine, or `nil` when there is no
    /// Metal device or the graph refuses to build.
    ///
    /// `nil` is a supported outcome: `RPUITests` and SwiftUI previews run
    /// without a GPU, and the canvas has a CPU fallback.
    public static func standard(
        faceProvider: any FaceInputProviding = NoFaceInputProvider(),
        context: MetalContext? = MetalContext.shared
    ) -> LivePreviewController? {
        guard let context else { return nil }
        guard let renderer = try? LivePreviewRenderer(context: context) else { return nil }
        // Off the interaction path, once per process: without it the first
        // slider drag pays the shader compile (236 ms macOS / 1798 ms Simulator,
        // ADR-0007) and reads as a frozen UI.
        try? renderer.prewarm()
        return LivePreviewController(renderer: renderer, faceProvider: faceProvider)
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
    }

    /// Drops the shot's textures. Call when the editor closes.
    public func close() {
        renderer.clearSource()
        faces = []
        sourceSize = .zero
        openContentHash = nil
        faceAnalysisRan = false
        invalidate()
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
    public var renderRequest: RenderRequest {
        RenderRequest(editState: editState, allFaces: faces, quality: renderer.quality)
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

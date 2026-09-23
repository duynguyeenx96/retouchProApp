import CoreGraphics
import Foundation
import Testing

import RPCore
import RPEngine
@testable import RPUI

/// docs/PLAN.md §6.1 / docs/ADR-0019 — the UI half of "Cọ mask thủ công".
///
/// The stroke model, the splat kernel, undo-by-replay and the gate arithmetic
/// are `RPEngineTests/ManualMaskTests`, and they are not re-tested here. What
/// only the UI can be wrong about, and what this file pins:
///
/// 1. **The conversion.** `BrushPoint.location` is in *mask pixels* and the
///    canvas is in points at some zoom and pan — the ADR is explicit that
///    converting is the UI's job because only the UI knows those. A stroke half
///    a frame out is the classic failure here, and the Mac's dual-pane
///    comparison is where it happens.
/// 2. **The lifecycle.** One session per shot, built at the decoded preview's
///    size, alive across strokes, gone when the shot changes or the editor
///    closes.
/// 3. **The empty-mask rule.** A session that exists but has not been painted on
///    must *not* reach `RenderRequest.gateMasks`: a gate multiplies, so an
///    all-zero coverage would switch every mask-driven slider off in every shot
///    the brush was merely armed on (ADR-0019 §5 — "an empty array is not an
///    all-zero mask", and neither is an empty mask a gate).
/// 4. **The lock.** With `RPEngineFeatureFlags.manualMask` off there is no
///    session, the rail item is locked, and tapping it does nothing.
///
/// `.serialized`, and it takes ``RPUIMaskFlagLock``, because `manualMask` is a
/// process-global bit that `RailLayoutTests` also reads.
@Suite("Phase 6.1 manual mask brush wiring", .serialized)
@MainActor
struct ManualMaskBrushWiringTests {

    static func withManualMask(_ isOn: Bool, _ body: () async throws -> Void) async throws {
        try await RPUIMaskFlagLock.exclusive {
            let previous = RPEngineFeatureFlags.manualMask
            RPEngineFeatureFlags.manualMask = isOn
            defer { RPEngineFeatureFlags.manualMask = previous }
            try await body()
        }
    }

    static func decodedFixture() throws -> (PreviewImage, URL) {
        let url = try TempProject.writePNG(
            at: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rpui-brush-\(UUID().uuidString).png"),
            size: 256)
        return (try ImageDecoder.decode(contentsOf: url, maxPixelSize: 2048), url)
    }

    // MARK: - Settings: 0–100 in, engine units out

    /// The brush bar is three ordinary 0–100 rows (docs/PLAN.md §0), and the
    /// engine wants mask pixels and 0…1. The conversion lives in one place so no
    /// view can invent a second one.
    @Test("The 0–100 controls map onto the engine's radius, hardness and flow")
    func settingsMapOntoEngineUnits() {
        let smallest = ManualMaskBrushSettings(size: 0)
        let largest = ManualMaskBrushSettings(size: 100)
        #expect(smallest.radiusInMaskPixels == ManualMaskBrushSettings.minimumRadius)
        #expect(largest.radiusInMaskPixels == ManualMaskBrushSettings.maximumRadius)

        let defaults = ManualMaskBrushSettings()
        #expect(defaults.mode == .add)
        #expect(defaults.flowFraction == 1)
        #expect(defaults.hardnessFraction == 0.5)
        #expect(defaults.radiusText == "64 px")

        // Out-of-range values are clamped rather than trusted: the rows are
        // driven by a drag, and `BrushStroke` would clamp them a second time.
        let wild = ManualMaskBrushSettings(size: 500, hardness: -20, flow: 1_000)
        #expect(wild.size == 100)
        #expect(wild.hardnessFraction == 0)
        #expect(wild.flowFraction == 1)
    }

    // MARK: - Geometry: view points → mask pixels

    /// The round trip, at a zoom and an offset that are not 1 and 0 — the case
    /// where an off-by-a-frame error actually shows.
    @Test("A view point converts to the mask pixel under it, and back")
    func viewPointsConvertToMaskPixels() throws {
        let imageSize = CGSize(width: 2048, height: 1024)
        var viewport = CanvasViewport()
        viewport.fit(imageSize: imageSize, in: CGSize(width: 800, height: 600))
        viewport.pan(by: CGSize(width: 37, height: -21))
        let frame = viewport.imageFrame(
            imageSize: imageSize, viewSize: CGSize(width: 800, height: 600))

        for expected in [CGPoint(x: 0, y: 0), CGPoint(x: 1024, y: 512), CGPoint(x: 2047, y: 1023)] {
            let view = ManualMaskBrushGeometry.viewPoint(
                maskPoint: expected, imageSize: imageSize, frame: frame)
            let back = try #require(
                ManualMaskBrushGeometry.maskPoint(
                    viewPoint: view, imageSize: imageSize, frame: frame))
            #expect(abs(back.x - expected.x) < 0.001)
            #expect(abs(back.y - expected.y) < 0.001)
        }

        // The brush is sized in image pixels, so its footprint on screen scales
        // with the zoom — that is what makes a mask painted zoomed-in match the
        // same gesture zoomed-out.
        let width = ManualMaskBrushGeometry.viewLength(
            maskLength: 100, imageSize: imageSize, frame: frame)
        #expect(abs(Double(width) - 100 * Double(viewport.zoom)) < 0.001)
    }

    /// The Mac's Trước | Sau layout: the picture the brush paints on is the
    /// **right-hand** pane, so a point has to have the pane's origin taken off
    /// it, and a point in the untouched left pane is not a place a mask can be
    /// painted at all.
    @Test("In the dual-pane comparison the mask is painted on the edited pane only")
    func dualPaneOriginIsRespected() {
        let imageSize = CGSize(width: 100, height: 100)
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let paneOriginX: CGFloat = 400

        let inEditedPane = ManualMaskBrushGeometry.maskPoint(
            viewPoint: CGPoint(x: 450, y: 25), paneOriginX: paneOriginX,
            imageSize: imageSize, frame: frame)
        #expect(inEditedPane == CGPoint(x: 50, y: 25))

        #expect(
            ManualMaskBrushGeometry.maskPoint(
                viewPoint: CGPoint(x: 120, y: 25), paneOriginX: paneOriginX,
                imageSize: imageSize, frame: frame) == nil)

        // A degenerate frame (no picture yet) answers nothing rather than
        // dividing by zero.
        #expect(
            ManualMaskBrushGeometry.maskPoint(
                viewPoint: .zero, imageSize: imageSize, frame: .zero) == nil)
    }

    // MARK: - The rail item and the mode

    /// With the flag off the rail entry is a dimmed placeholder that says why,
    /// and tapping it neither arms a brush nor moves the panel.
    @Test("With manualMask off the rail item is locked and inert")
    func railItemIsLockedWithTheFlagOff() async throws {
        try await Self.withManualMask(false) {
            let item = try #require(RailLayout.items.first { $0.id == "manualMask" })
            #expect(item.presentation == .manualMaskBrush)
            #expect(item.sectionKey == nil)
            #expect(item.isLocked)
            #expect(item.lockedHint == "Phase 6.1 · cọ mask đang tắt trong bản dựng này")
            #expect(!RailLayout.activeItems.contains { $0.id == item.id })

            let chrome = EditorChrome()
            chrome.activeGroupKey = EditState.SectionKey.skin
            chrome.selectRailItem(item)
            #expect(!chrome.isBrushing)
            #expect(chrome.activeGroupKey == EditState.SectionKey.skin)
            #expect(chrome.presetLibrary == nil)
        }
    }

    /// With the flag on it is a mode: tapping arms it, tapping again puts it
    /// away, and arming it keeps the slider panel where the user left it — the
    /// brush bar sits over the group already open, so painting is still *with*
    /// a group turned up. Switching to a **different** rail item, though, puts
    /// the brush away (2026-09-22): the two used to coexist, and a user
    /// reported that as the rail showing two items active at once with no way
    /// to tell which was "real".
    @Test("With manualMask on the rail item arms and disarms the brush")
    func railItemTogglesTheBrush() async throws {
        try await Self.withManualMask(true) {
            let item = try #require(RailLayout.items.first { $0.id == "manualMask" })
            #expect(!item.isLocked)
            #expect(item.lockedHint == "")
            #expect(RailLayout.activeItems.contains { $0.id == item.id })

            let chrome = EditorChrome()
            chrome.activeGroupKey = EditState.SectionKey.skin
            #expect(!chrome.isRailItemActive(item))

            chrome.selectRailItem(item)
            #expect(chrome.isBrushing)
            #expect(chrome.isRailItemActive(item))
            #expect(chrome.activeGroupKey == EditState.SectionKey.skin)

            // Picking a different rail item now puts the brush away — exactly
            // one thing is ever "the open panel".
            let face = try #require(RailLayout.leafItems.first { $0.id == "face" })
            chrome.selectRailItem(face)
            #expect(chrome.activeGroupKey == EditState.SectionKey.face)
            #expect(!chrome.isBrushing)
            #expect(!chrome.isRailItemActive(item))
            #expect(chrome.isRailItemActive(face))

            // Re-arming after switching away, then the plain toggle-off/on the
            // brush always had.
            chrome.selectRailItem(item)
            #expect(chrome.isBrushing)
            chrome.selectRailItem(item)
            #expect(!chrome.isBrushing)
            chrome.selectRailItem(item)
            #expect(chrome.isBrushing)
            chrome.disarmBrush()
            #expect(!chrome.isBrushing)

            // Leaving the editor puts it away, so it cannot come back armed over
            // a different photo (whose session is a different object).
            chrome.tab = .edit
            chrome.selectRailItem(item)
            #expect(chrome.isBrushing)
            chrome.tab = .library
            #expect(!chrome.isBrushing)
        }
    }

    /// User's request, 2026-09-21: the green tint must not come back on its own
    /// once a stroke has ended — the only way back is a deliberate hover/tap on
    /// a row in the brush bar's layer list, tracked by
    /// ``EditorChrome/previewedMaskStrokeIndex``. This pins the one place that
    /// index is cleared for the user without their asking: putting the brush
    /// away, so a stale preview from one session cannot leak into the next time
    /// the brush is armed.
    @Test("Disarming the brush clears whichever layer was being previewed")
    func disarmingClearsThePreviewedLayer() {
        let chrome = EditorChrome()
        #expect(chrome.previewedMaskStrokeIndex == nil)
        chrome.previewedMaskStrokeIndex = 2
        chrome.disarmBrush()
        #expect(chrome.previewedMaskStrokeIndex == nil)
    }

    // MARK: - Session lifecycle and the gate

    /// The lock, in the controller: with the flag off there is no session, so
    /// there is nothing that could ever reach `gateMasks` and every node renders
    /// what it rendered before Phase 6.1.
    @Test("With manualMask off no session is built and nothing is gated")
    func flagOffBuildsNoSession() async throws {
        guard let context = MetalContext.shared else { return }
        try await Self.withManualMask(false) {
            let controller = LivePreviewController(
                renderer: try LivePreviewRenderer(context: context))
            let (decoded, url) = try Self.decodedFixture()
            defer { try? FileManager.default.removeItem(at: url) }

            await controller.open(decoded, contentHash: "brush-off", editState: EditState())
            #expect(controller.manualMask == nil)
            #expect(!controller.canPaintManualMask)
            #expect(controller.renderRequest.gateMasks.isEmpty)

            // …and the paint calls are no-ops rather than crashes: the rail item
            // is locked, but a stale view could still call them.
            controller.beginManualMaskStroke(
                at: CGPoint(x: 10, y: 10), settings: ManualMaskBrushSettings())
            controller.extendManualMaskStroke(to: CGPoint(x: 20, y: 20))
            controller.endManualMaskStroke()
            #expect(controller.renderRequest.gateMasks.isEmpty)
            #expect(!controller.hasManualMask)
        }
    }

    /// The lifecycle claim: one session per shot at the preview's size, kept
    /// across strokes, and an identity transform — which is what makes the
    /// conversion above correct in the first place.
    @Test("With manualMask on, one session per shot at the preview's size")
    func flagOnBuildsOneSessionPerShot() async throws {
        guard let context = MetalContext.shared else { return }
        try await Self.withManualMask(true) {
            let controller = LivePreviewController(
                renderer: try LivePreviewRenderer(context: context))
            let (decoded, url) = try Self.decodedFixture()
            defer { try? FileManager.default.removeItem(at: url) }

            await controller.open(decoded, contentHash: "brush-on", editState: EditState())
            let session = try #require(controller.manualMask)
            #expect(session.width == Int(decoded.pixelSize.width))
            #expect(session.height == Int(decoded.pixelSize.height))
            #expect(session.coverage.maskToImage == .identity)
            #expect(controller.canPaintManualMask)

            // A slider drag must not rebuild it — it holds the undo history and
            // two textures.
            for step in 0..<20 {
                var state = EditState()
                state.setSlider(
                    ColorSliders.Key.exposure, in: EditState.SectionKey.color,
                    to: Double(step) + 1)
                controller.update(editState: state)
            }
            #expect(controller.manualMask === session)

            controller.close()
            #expect(controller.manualMask == nil)
        }
    }

    /// The whole feature in one test: an armed brush gates nothing, a painted
    /// stroke gates exactly one node input, undo takes it back out, and the
    /// canvas is told to redraw each time.
    @Test("A painted stroke becomes exactly one gate; the document taking it back removes it")
    func paintingAddsAGateAndUndoRemovesIt() async throws {
        guard let context = MetalContext.shared else { return }
        try await Self.withManualMask(true) {
            let controller = LivePreviewController(
                renderer: try LivePreviewRenderer(context: context))
            let (decoded, url) = try Self.decodedFixture()
            defer { try? FileManager.default.removeItem(at: url) }
            await controller.open(decoded, contentHash: "brush-paint", editState: EditState())
            let session = try #require(controller.manualMask)

            // Armed but unpainted: **no gate**. This is the assertion that keeps
            // an all-zero coverage from switching every mask-driven slider off.
            #expect(controller.renderRequest.gateMasks.isEmpty)
            #expect(!controller.hasManualMask)

            let before = controller.version
            controller.beginManualMaskStroke(
                at: CGPoint(x: 40, y: 40), settings: ManualMaskBrushSettings())
            controller.extendManualMaskStroke(to: CGPoint(x: 120, y: 90))
            controller.extendManualMaskStroke(to: CGPoint(x: 200, y: 40))
            controller.endManualMaskStroke()
            // The canvas was asked to redraw, and through `version` — the
            // property `LivePreviewMetalView` already watches.
            #expect(controller.version > before)

            #expect(controller.hasManualMask)
            #expect(controller.manualMaskStrokeCount == 1)
            #expect(controller.manualMaskStrokes.count == 1)
            #expect(controller.manualMaskStrokes[0].points.count == 3)
            #expect(controller.manualMaskStrokes[0].mode == .add)

            let gates = controller.renderRequest.gateMasks
            #expect(gates.count == 1)
            #expect(gates.first === session.coverage)
            #expect(gates.first?.isGateEnabled == true)
            #expect(gates.first?.gateWidth == Int(decoded.pixelSize.width))

            // Undo / redo / "Xoá mask" are the document's (EditorModel's one
            // history, docs/ADR-0025); what reaches the canvas is the stroke
            // list the document now says.
            let stored = controller.manualMaskDocument
            #expect(stored.count == 1)
            controller.setManualMaskStrokes([])
            #expect(!controller.hasManualMask)
            #expect(controller.renderRequest.gateMasks.isEmpty)

            controller.setManualMaskStrokes(stored)
            #expect(controller.renderRequest.gateMasks.count == 1)
            #expect(controller.manualMaskStrokes[0].points.count == 3)

            controller.setManualMaskStrokes([])
            #expect(!controller.hasManualMask)
            #expect(controller.renderRequest.gateMasks.isEmpty)
        }
    }

    /// Masks are per shot (ADR-0019 §8 keys them by shot id): opening the next
    /// picture must not inherit the last one's strokes.
    @Test("Opening another shot starts an empty mask")
    func maskDoesNotLeakBetweenShots() async throws {
        guard let context = MetalContext.shared else { return }
        try await Self.withManualMask(true) {
            let controller = LivePreviewController(
                renderer: try LivePreviewRenderer(context: context))
            let (first, firstURL) = try Self.decodedFixture()
            let (second, secondURL) = try Self.decodedFixture()
            defer {
                try? FileManager.default.removeItem(at: firstURL)
                try? FileManager.default.removeItem(at: secondURL)
            }

            await controller.open(first, contentHash: "shot-1", editState: EditState())
            controller.beginManualMaskStroke(
                at: CGPoint(x: 30, y: 30), settings: ManualMaskBrushSettings())
            controller.endManualMaskStroke()
            #expect(controller.hasManualMask)

            await controller.open(second, contentHash: "shot-2", editState: EditState())
            #expect(controller.manualMaskStrokeCount == 0)
            #expect(!controller.hasManualMask)
            #expect(controller.renderRequest.gateMasks.isEmpty)
        }
    }
}

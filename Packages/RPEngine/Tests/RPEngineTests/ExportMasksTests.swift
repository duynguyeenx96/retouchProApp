import CoreGraphics
import Foundation
import RPCore
import Testing

@testable import RPEngine

/// 2026-09-23 — the canvas's whole-frame masks reach the exported file.
///
/// 1. **No GPU**: the scaling contract of ``ExportMasks`` (per axis, from a
///    stated reference, never guessed) for the raster masks, and the brush
///    strokes passing through untouched (they are normalised).
/// 2. **GPU, measured**: a real export with a brush stroke (stored normalised,
///    rasterised by the export at render size) against the same export without
///    the mask and without any edit.
@Suite("Export carries the canvas's masks", .serialized)
struct ExportMasksTests {

    // MARK: - 1. No GPU

    private static func mask(width: Int, height: Int, fill: UInt8 = 255) -> RenderMask {
        RenderMask(
            width: width, height: height,
            values: [UInt8](repeating: fill, count: width * height), maskToImage: .identity)
    }

    @Test("Masks built on a 2048 px preview land on the 6000×4000 frame, per axis")
    func scalesPerAxisFromTheStatedReference() throws {
        // What ImageIO's thumbnailer actually returns for a 6000×4000 a6300 frame.
        let preview = CGSize(width: 2048, height: 1365)
        let render = CGSize(width: 6000, height: 4000)
        let stroke = ManualMaskStroke(
            radius: 0.02, hardness: 0.5, flow: 1, mode: .add,
            points: [.init(x: 0.5, y: 0.5)])
        let masks = ExportMasks(
            referenceSize: preview,
            brushStrokes: [stroke],
            subjectMask: RenderMask(
                width: 256, height: 192, values: [UInt8](repeating: 9, count: 256 * 192),
                maskToImage: CGAffineTransform(scaleX: 8, y: 1365.0 / 192.0)),
            bodySkinMask: Self.mask(width: 320, height: 213, fill: 7))

        let scaled = try masks.scaled(to: render)

        #expect(scaled.referenceSize == render)
        // The body mask's far corner is the frame's far corner, on both axes —
        // a uniform (width-derived) scale would put it at y = 3999.0.
        // (The body fixture's transform is the identity into the reference.)
        let bodyCorner = CGPoint(x: 2048, y: 1365).applying(
            scaled.bodySkinMask!.maskToImage)
        #expect(abs(bodyCorner.x - 6000) < 1e-9)
        #expect(abs(bodyCorner.y - 4000) < 1e-9)
        // A mask with its own non-identity transform keeps it, then scales.
        let subjectCorner = CGPoint(x: 256, y: 192).applying(scaled.subjectMask!.maskToImage)
        #expect(abs(subjectCorner.x - 6000) < 1e-9)
        #expect(abs(subjectCorner.y - 4000) < 1e-9)
        // Coverage bytes are untouched — only transforms move.
        #expect(scaled.bodySkinMask!.values == masks.bodySkinMask!.values)
        #expect(scaled.bodySkinMask!.width == 320)
        // Strokes are normalised: they need no transform and pass through.
        #expect(scaled.brushStrokes == [stroke])
    }

    @Test("No masks needs no reference size, and is left alone")
    func emptyIsAPassThrough() throws {
        let scaled = try ExportMasks.none.scaled(to: CGSize(width: 6000, height: 4000))
        #expect(scaled == .none)
        #expect(scaled.isEmpty)
    }

    @Test("A raster mask with no reference size is refused rather than assumed full-res")
    func missingReferenceIsAnError() throws {
        let masks = ExportMasks(referenceSize: .zero, bodySkinMask: Self.mask(width: 4, height: 4))
        #expect(throws: ExportMaskError.missingReferenceSize) {
            _ = try masks.scaled(to: CGSize(width: 6000, height: 4000))
        }
        // Strokes alone need none: they are fractions of the frame.
        let strokesOnly = ExportMasks(
            referenceSize: .zero,
            brushStrokes: [
                ManualMaskStroke(
                    radius: 0.01, hardness: 1, flow: 1, mode: .add, points: [.init(x: 0.1, y: 0.1)])
            ])
        #expect(try strokesOnly.scaled(to: CGSize(width: 6000, height: 4000)) == strokesOnly)
    }

    @Test("A reference of a different shape (a rotated decode) is refused, not stretched")
    func aspectMismatchIsAnError() {
        let masks = ExportMasks(
            referenceSize: CGSize(width: 1365, height: 2048),
            bodySkinMask: Self.mask(width: 1365, height: 2048))
        #expect(throws: ExportMaskError.self) {
            _ = try masks.scaled(to: CGSize(width: 6000, height: 4000))
        }
        // …while the half-pixel of rounding a real preview has is accepted.
        let real = ExportMasks(
            referenceSize: CGSize(width: 2048, height: 1366),
            bodySkinMask: Self.mask(width: 2048, height: 1366))
        #expect(throws: Never.self) {
            _ = try real.scaled(to: CGSize(width: 6000, height: 4000))
        }
    }

    // MARK: - 2. GPU, measured

    /// The measurement the task asked for: export with a brush stroke stored in
    /// normalised coordinates (as a half-size "preview" would record it) and
    /// rasterised by the export at full size; compare to the unedited export
    /// (outside the brush must match) and to the ungated export (inside must
    /// match).
    @Test("A brush stroke recorded on the preview gates the full-size export")
    func brushMaskReachesTheExportedFile() throws {
        guard let context = SpikeS3Support.context else { return }
        try ManualMaskTests.withManualMaskAndSkin {
            let width = SkinRenderNodeTests.width
            let height = SkinRenderNodeTests.height
            let fixture = try ExportRendererTests.Fixture(
                width: width, height: height, context: context)
            defer { fixture.cleanUp() }
            let renderer = try ExportRenderer(context: context)
            try renderer.prewarm()

            var edited = EditState()
            SkinRenderNodeTests.allSliders.write(into: &edited)
            let face = SkinRenderNodeTests.face
            let size = CGSize(width: width, height: height)

            // The "preview": half size. A hard dab over the middle of the face,
            // recorded the way the canvas records it — in preview pixels — and
            // stored normalised.
            let pw = width / 2
            let ph = height / 2
            let centre = CGPoint(x: Double(pw) * 0.45, y: Double(ph) * 0.5)
            let radius = 14.0
            let dab = BrushStroke(
                radius: radius, hardness: 1, flow: 1, mode: .add,
                points: [BrushPoint(location: centre)])
            let masks = ExportMasks(
                referenceSize: .zero,
                brushStrokes: [dab.normalized(imageSize: CGSize(width: pw, height: ph))])

            func export(_ state: EditState, _ masks: ExportMasks) throws -> (
                [Float], ExportResult
            ) {
                let result = try renderer.export(
                    ExportJob(
                        sourceURL: fixture.sourceURL, editState: state, faces: [face],
                        faceReferenceSize: size, masks: masks,
                        settings: ExportSettings(format: .tiff, bitDepth: .sixteen),
                        destinationDirectory: fixture.directory))
                return (try ExportRendererTests.decode(result.url), result)
            }

            let (plain, _) = try export(EditState(), .none)
            let (ungated, ungatedResult) = try export(edited, .none)
            let (gated, gatedResult) = try export(edited, masks)
            #expect(ungatedResult.appliedMasks.isEmpty)
            #expect(gatedResult.appliedMasks == ["manualMask"])

            // Classify every full-res pixel by where it lands on the brush,
            // scaled 2× — with a 2-pixel band either side for the bilinear edge.
            let fullCentre = CGPoint(x: centre.x * 2, y: centre.y * 2)
            let fullRadius = radius * 2
            var insideChanged = 0
            var insideCount = 0
            var outsideWorst: Float = 0
            var outsideChanged = 0
            var insideWorstVsUngated: Float = 0
            var ungatedChangedOutside = 0
            for y in 0..<height {
                for x in 0..<width {
                    let d = hypot(Double(x) + 0.5 - fullCentre.x, Double(y) + 0.5 - fullCentre.y)
                    let p = (y * width + x) * 4
                    var vsPlain: Float = 0
                    var vsUngated: Float = 0
                    var ungatedVsPlain: Float = 0
                    for c in 0..<3 {
                        vsPlain = max(vsPlain, abs(gated[p + c] - plain[p + c]))
                        vsUngated = max(vsUngated, abs(gated[p + c] - ungated[p + c]))
                        ungatedVsPlain = max(ungatedVsPlain, abs(ungated[p + c] - plain[p + c]))
                    }
                    if d <= fullRadius - 3 {
                        insideCount += 1
                        if vsPlain > 1e-3 { insideChanged += 1 }
                        insideWorstVsUngated = max(insideWorstVsUngated, vsUngated)
                    } else if d >= fullRadius + 3 {
                        outsideWorst = max(outsideWorst, vsPlain)
                        if vsPlain > 0 { outsideChanged += 1 }
                        if ungatedVsPlain > 1e-3 { ungatedChangedOutside += 1 }
                    }
                }
            }
            print(
                "EXPORT-MASK: inside brush \(insideChanged)/\(insideCount) px changed vs "
                    + "unedited, worst vs ungated \(insideWorstVsUngated); outside: "
                    + "\(outsideChanged) px differ from unedited (worst \(outsideWorst)), "
                    + "while the ungated export changed \(ungatedChangedOutside) px there")
            // The control is meaningful: without the mask the sliders really do
            // act outside the brush.
            #expect(ungatedChangedOutside > 100)
            // Outside the brush the gated file is the unedited file, bit for bit.
            #expect(outsideChanged == 0, "worst \(outsideWorst)")
            // Inside, the edit is there, and it is the ungated edit.
            #expect(insideChanged > insideCount / 2)
            #expect(insideWorstVsUngated < 2e-3)

            // Flag off: the mask is carried but not applied — the export is the
            // ungated one, exactly as the canvas would be with no session.
            RPEngineFeatureFlags.manualMask = false
            let (flagOff, flagOffResult) = try export(edited, masks)
            RPEngineFeatureFlags.manualMask = true
            #expect(flagOffResult.appliedMasks.isEmpty)
            #expect(SpikeTextureIO.maxAbsoluteDifference(flagOff, ungated) == 0)
        }
    }

    /// "Sửa da toàn thân": a whole-frame body mask built at half size reaches the
    /// skin node in the export, and only when the document's switch is on.
    @Test("The body skin mask widens the export's skin edit, behind the document switch")
    func bodySkinMaskReachesTheExportedFile() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.enableSkinRenderGraph()
            RPEngineFeatureFlags.bodySkinSync = true
        }
        defer {
            flags.leave {
                RPEngineFeatureFlags.bodySkinSync = false
                RPEngineFeatureFlags.disableSkinRenderGraph()
            }
        }
        let width = SkinRenderNodeTests.width
        let height = SkinRenderNodeTests.height
        let fixture = try ExportRendererTests.Fixture(width: width, height: height, context: context)
        defer { fixture.cleanUp() }
        let renderer = try ExportRenderer(context: context)
        try renderer.prewarm()

        var switchOff = EditState()
        SkinRenderNodeTests.allSliders.write(into: &switchOff)
        var switchOn = switchOff
        BodySkinSync(isOn: true).write(into: &switchOn)

        // Whole frame "skin", at a half-size reference.
        let masks = ExportMasks(
            referenceSize: CGSize(width: width / 2, height: height / 2),
            bodySkinMask: Self.mask(width: width / 2, height: height / 2))

        func export(_ state: EditState, _ masks: ExportMasks) throws -> ([Float], ExportResult) {
            let result = try renderer.export(
                ExportJob(
                    sourceURL: fixture.sourceURL, editState: state,
                    faces: [SkinRenderNodeTests.face],
                    faceReferenceSize: CGSize(width: width, height: height), masks: masks,
                    settings: ExportSettings(format: .tiff, bitDepth: .sixteen),
                    destinationDirectory: fixture.directory))
            return (try ExportRendererTests.decode(result.url), result)
        }

        let (faceOnly, _) = try export(switchOff, .none)
        let (carriedOff, carriedOffResult) = try export(switchOff, masks)
        let (widened, widenedResult) = try export(switchOn, masks)

        #expect(carriedOffResult.appliedMasks.isEmpty)
        #expect(widenedResult.appliedMasks == ["bodySkin"])
        // Switch off: carrying the mask changes nothing.
        #expect(SpikeTextureIO.maxAbsoluteDifference(carriedOff, faceOnly) == 0)
        // Switch on: more pixels are edited than the face alone reaches.
        var widenedPixels = 0
        for pixel in 0..<(width * height) {
            for c in 0..<3 where abs(widened[pixel * 4 + c] - faceOnly[pixel * 4 + c]) > 1e-3 {
                widenedPixels += 1
                break
            }
        }
        print("EXPORT-BODYSKIN: \(widenedPixels)/\(width * height) px differ from the face-only export")
        #expect(widenedPixels > 1000)
    }
}

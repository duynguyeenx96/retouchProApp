import CoreGraphics
import Foundation
import RPCore
import Testing

@testable import RPEngine

/// 2026-09-23 — the brush is stored as strokes, normalised to the frame, and
/// re-rasterised at whatever resolution is needed (docs/ADR-0019 addendum,
/// docs/ADR-0025).
///
/// Two claims, one test each:
///
/// 1. **Round trip at the same size is exact.** Painting a stroke, storing it
///    normalised (and through JSON, as the project does), and replaying it onto
///    a mask of the same size gives back the painted coverage byte for byte —
///    which is what makes "reopen the shot" show exactly what was left.
/// 2. **Two resolutions agree after scaling.** The same stored strokes
///    rasterised at N and 2N pixels, the 2N one box-filtered back down to N,
///    match within a small tolerance — so the export (rasterised at render
///    size) is the canvas's mask drawn sharper, not a different mask.
@Suite("Brush strokes as stored metadata", .serialized)
struct ManualMaskStrokeStorageTests {

    // MARK: - No GPU

    @Test("A stroke normalises and denormalises back to the same points and radius")
    func normalisedRoundTripIsExactEnough() {
        let size = CGSize(width: 2048, height: 1365)
        var stroke = BrushStroke(radius: 64, hardness: 0.35, flow: 0.8, mode: .subtract)
        stroke.points = (0..<50).map {
            BrushPoint(
                location: CGPoint(x: 13.37 * Double($0) + 0.25, y: 1364.9 - 21.7 * Double($0)),
                pressure: 0.3 + 0.01 * Double($0))
        }
        let stored = stroke.normalized(imageSize: size)
        #expect(stored.mode == .subtract)
        #expect(abs(stored.radius - 64.0 / 2048) < 1e-15)
        #expect(stored.points.allSatisfy { (0...1).contains($0.y) })

        let back = BrushStroke(stored, imageSize: size)
        #expect(back.mode == stroke.mode)
        #expect(back.hardness == stroke.hardness)
        #expect(back.flow == stroke.flow)
        #expect(abs(back.radius - stroke.radius) < 1e-9)
        for (a, b) in zip(back.points, stroke.points) {
            // Far below the Float precision the splat kernel reads centres in.
            #expect(abs(a.location.x - b.location.x) < 1e-9)
            #expect(abs(a.location.y - b.location.y) < 1e-9)
            #expect(a.pressure == b.pressure)
        }
    }

    @Test("Radius follows the long edge; points follow each axis")
    func scalesWithThePicture() {
        let stored = ManualMaskStroke(
            radius: 0.01, hardness: 1, flow: 1, mode: .add,
            points: [.init(x: 1, y: 1), .init(x: 0.5, y: 0.25)])
        let portrait = BrushStroke(stored, imageSize: CGSize(width: 4000, height: 6000))
        #expect(portrait.radius == 60)
        #expect(portrait.points[0].location == CGPoint(x: 4000, y: 6000))
        #expect(portrait.points[1].location == CGPoint(x: 2000, y: 1500))
        let preview = BrushStroke(stored, imageSize: CGSize(width: 1365, height: 2048))
        #expect(abs(preview.radius - 20.48) < 1e-12)
    }

    // MARK: - GPU

    @Test("Painted → stored → JSON → replayed at the same size is byte-identical")
    func replayAfterStorageIsExact() throws {
        guard let context = SpikeS3Support.context else { return }
        try ManualMaskTests.withManualMask {
            let width = 333
            let height = 222
            let size = CGSize(width: width, height: height)
            let painted = try ManualMaskSession(context: context, width: width, height: height)
            // Odd, non-integer coordinates and radii on purpose: anything that
            // survives these survives a real drag.
            var a = BrushStroke(radius: 17.3, hardness: 0.4, flow: 0.85, mode: .add)
            a.points = (0...60).map {
                let t = Double($0) / 60
                return BrushPoint(
                    location: CGPoint(x: 11.1 + t * 301.7, y: 40.3 + sin(t * 5) * 90.9 + 60),
                    pressure: 0.5 + 0.5 * t)
            }
            var b = BrushStroke(radius: 9.7, hardness: 0.9, flow: 1, mode: .subtract)
            b.points = (0...20).map {
                BrushPoint(location: CGPoint(x: 150.5 + Double($0) * 3.3, y: 101.1))
            }
            try ManualMaskTests.draw(a, in: painted)
            try ManualMaskTests.draw(b, in: painted)
            let expected = try painted.readValues()

            let stored = painted.strokes.map { $0.normalized(imageSize: size) }
            let data = try RPJSON.compactEncoder.encode(ManualMaskStrokeDocument(strokes: stored))
            let decoded = try RPJSON.decoder.decode(ManualMaskStrokeDocument.self, from: data)
            #expect(decoded.strokes == stored)

            let reopened = try ManualMaskSession(context: context, width: width, height: height)
            try reopened.replaceStrokes(decoded.strokes.map { BrushStroke($0, imageSize: size) })
            let replayed = try reopened.readValues()
            let differing = zip(replayed, expected).filter { $0 != $1 }.count
            print("STROKE-REPLAY: \(differing) of \(expected.count) bytes differ after storage")
            #expect(differing == 0)
        }
    }

    @Test("The same strokes rasterised at two resolutions agree after scaling")
    func twoResolutionsAgree() throws {
        guard let context = SpikeS3Support.context else { return }
        try ManualMaskTests.withManualMask {
            let strokes = Self.fixtureStrokes()
            let small = (width: 320, height: 213)
            let large = (width: 640, height: 426)
            let lo = try ManualMaskSession.rasterize(
                strokes, width: small.width, height: small.height, context: context
            ).readValues()
            let hi = try ManualMaskSession.rasterize(
                strokes, width: large.width, height: large.height, context: context
            ).readValues()

            // 2×2 box filter of the large one, back onto the small grid.
            var sumAbs = 0.0
            var worst = 0.0
            var coverageLo = 0.0
            var coverageHi = 0.0
            var edgePixels = 0
            for y in 0..<small.height {
                for x in 0..<small.width {
                    var acc = 0.0
                    for dy in 0..<2 {
                        for dx in 0..<2 {
                            acc += Double(hi[(y * 2 + dy) * large.width + x * 2 + dx])
                        }
                    }
                    let down = acc / 4 / 255
                    let base = Double(lo[y * small.width + x]) / 255
                    let diff = abs(down - base)
                    sumAbs += diff
                    worst = max(worst, diff)
                    if diff > 0.05 { edgePixels += 1 }
                    coverageLo += base
                    coverageHi += down
                }
            }
            let pixels = Double(small.width * small.height)
            let mean = sumAbs / pixels
            let areaRatio = coverageHi / max(coverageLo, 1e-9)
            print(
                "STROKE-TWO-RES: mean |diff| \(mean), worst \(worst), \(edgePixels) px > 0.05, "
                    + "painted-area ratio \(areaRatio) (320×213 vs 640×426 box-filtered)")
            #expect(coverageLo > pixels * 0.05, "fixture paints something")
            #expect(mean < 0.005)
            #expect(abs(areaRatio - 1) < 0.01)
            // Pointwise, only edge pixels can differ. The hard stroke (hardness
            // 1) is a step: one centre sample at N against the mean of four at
            // 2N can differ by up to 0.75 on the pixel the edge crosses, which
            // is sampling, not disagreement — so the bound is on how *few*
            // pixels differ, plus the step bound itself.
            #expect(worst <= 0.75)
            #expect(Double(edgePixels) < pixels * 0.03)
        }
    }

    /// A soft add stroke, a hard add stroke and a hard erase across both.
    static func fixtureStrokes() -> [ManualMaskStroke] {
        let soft = ManualMaskStroke(
            radius: 0.05, hardness: 0.5, flow: 1, mode: .add,
            points: (0...40).map {
                let t = Double($0) / 40
                return .init(x: 0.1 + 0.8 * t, y: 0.3 + 0.2 * sin(t * .pi), pressure: 1)
            })
        let hard = ManualMaskStroke(
            radius: 0.03, hardness: 1, flow: 0.8, mode: .add,
            points: (0...30).map {
                let t = Double($0) / 30
                return .init(x: 0.2 + 0.5 * t, y: 0.75, pressure: 0.4 + 0.6 * t)
            })
        let erase = ManualMaskStroke(
            radius: 0.02, hardness: 0.9, flow: 1, mode: .subtract,
            points: (0...20).map {
                let t = Double($0) / 20
                return .init(x: 0.5, y: 0.1 + 0.8 * t, pressure: 1)
            })
        return [soft, hard, erase]
    }
}

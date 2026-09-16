import CoreGraphics
import Foundation
import Testing

@testable import RPEngine

/// docs/ADR-0021 §v2 — the person-segmentation multiply on ``BodySkinMask``.
///
/// Everything here is CPU arithmetic on constructed masks: no Metal, no Vision,
/// no Core ML, so it runs identically on macOS and in the iOS Simulator (which
/// cannot perform `VNGeneratePersonSegmentationRequest` at all). The Vision half
/// is `RPVisionTests/PersonSegmenterTests`; what this file pins is the part that
/// is easy to get wrong by half a pixel — **relating two masks that are neither
/// the same size nor the same aspect ratio.**
///
/// That is not a hypothetical worry. Vision returns a fixed 4:3 (or 3:4) grid
/// and *stretches* the picture into it — a 2048x1365 frame comes back as
/// 512x384 — while the classifier works on a 320-px-wide grid that follows the
/// frame's real aspect. Relating them by pixel index, or by a single scale
/// factor, would put the subject mask several percent out of place, which no
/// amount of looking at a portrait would reveal.
@Suite("Body skin mask — subject intersection (ADR-0021 v2)")
struct BodySkinSubjectMaskTests {

    /// A coverage map with a value that depends on both axes, so a transpose or
    /// a flip cannot survive an equality check.
    static func gradient(width: Int, height: Int) -> [UInt8] {
        var values = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                values[y * width + x] = UInt8((x * 7 + y * 13) % 256)
            }
        }
        return values
    }

    /// A subject mask of any resolution over a `imageWidth` x `imageHeight`
    /// frame, filled by a predicate on **image** coordinates.
    static func subject(
        width: Int, height: Int, imageWidth: Int, imageHeight: Int,
        fill: (Double, Double) -> Bool
    ) -> RenderMask {
        var values = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let u = (Double(x) + 0.5) / Double(width)
                let v = (Double(y) + 0.5) / Double(height)
                values[y * width + x] = fill(u, v) ? 255 : 0
            }
        }
        return RenderMask(
            width: width, height: height, values: values,
            maskToImage: CGAffineTransform(
                scaleX: CGFloat(imageWidth) / CGFloat(width),
                y: CGFloat(imageHeight) / CGFloat(height)))
    }

    static func workingToImage(working: Int, workingHeight: Int, image: Int, imageHeight: Int)
        -> CGAffineTransform
    {
        CGAffineTransform(
            scaleX: CGFloat(image) / CGFloat(working),
            y: CGFloat(imageHeight) / CGFloat(workingHeight))
    }

    /// The property the whole design rests on: a subject mask that says "all
    /// subject" must not change a single byte, **whatever resolution it is**.
    /// If the resampling had an off-by-half-a-pixel in it, the edge rows would
    /// come back dimmed and this would fail.
    @Test("A saturated subject mask is the identity, at four different resolutions")
    func saturatedMaskChangesNothing() {
        let coverage = Self.gradient(width: 320, height: 213)
        for (w, h) in [(16, 12), (256, 192), (320, 213), (2016, 1512)] {
            let mask = Self.subject(
                width: w, height: h, imageWidth: 2048, imageHeight: 1365) { _, _ in true }
            let out = BodySkinMask.intersect(
                coverage, width: 320, height: 213, with: mask,
                coverageToImage: Self.workingToImage(
                    working: 320, workingHeight: 213, image: 2048, imageHeight: 1365))
            #expect(out == coverage, "resolution \(w)x\(h) was not the identity")
        }
    }

    @Test("An all-zero subject mask zeroes the coverage")
    func emptyMaskZeroesEverything() {
        let coverage = Self.gradient(width: 64, height: 48)
        let mask = Self.subject(
            width: 13, height: 9, imageWidth: 640, imageHeight: 480) { _, _ in false }
        let out = BodySkinMask.intersect(
            coverage, width: 64, height: 48, with: mask,
            coverageToImage: Self.workingToImage(
                working: 64, workingHeight: 48, image: 640, imageHeight: 480))
        #expect(out.allSatisfy { $0 == 0 })
    }

    /// The orientation test. A subject mask covering the **top** half must clear
    /// the bottom half of the coverage and nothing else — a y-flip in the affine
    /// would produce the exact opposite and still look plausible in a coverage
    /// fraction.
    @Test("Top-half subject clears the bottom half, not the top")
    func orientationIsNotFlipped() {
        let width = 100, height = 80
        let coverage = [UInt8](repeating: 200, count: width * height)
        let mask = Self.subject(
            width: 32, height: 24, imageWidth: 1000, imageHeight: 800) { _, v in v < 0.5 }
        let out = BodySkinMask.intersect(
            coverage, width: width, height: height, with: mask,
            coverageToImage: Self.workingToImage(
                working: width, workingHeight: height, image: 1000, imageHeight: 800))
        // Slack of two rows either side of the boundary, and it is not fudge:
        // the subject mask's texels are 800/24 = 33.3 image px tall against the
        // working grid's 10, so the bilinear ramp between the last "subject" row
        // and the first "background" row is genuinely ~3 working rows deep. What
        // the test is for is the *side* the ramp is on.
        for y in 0..<(height / 2 - 2) {
            for x in 0..<width { #expect(out[y * width + x] == 200, "(\(x),\(y))") }
        }
        for y in (height / 2 + 2)..<height {
            for x in 0..<width { #expect(out[y * width + x] == 0, "(\(x),\(y))") }
        }
    }

    /// The same, left/right, to catch a transpose.
    @Test("Left-half subject clears the right half, not the left")
    func orientationIsNotTransposed() {
        let width = 100, height = 80
        let coverage = [UInt8](repeating: 255, count: width * height)
        let mask = Self.subject(
            width: 40, height: 30, imageWidth: 1000, imageHeight: 800) { u, _ in u < 0.5 }
        let out = BodySkinMask.intersect(
            coverage, width: width, height: height, with: mask,
            coverageToImage: Self.workingToImage(
                working: width, workingHeight: height, image: 1000, imageHeight: 800))
        for y in 0..<height {
            for x in 0..<(width / 2 - 1) { #expect(out[y * width + x] == 255) }
            for x in (width / 2 + 1)..<width { #expect(out[y * width + x] == 0) }
        }
    }

    /// The case that motivated the affine composition: the subject mask is 4:3
    /// while the frame is 3:2, exactly as `VNGeneratePersonSegmentationRequest`
    /// returns it. The boundary must land at the same **image** fraction it was
    /// drawn at, not at the same mask fraction.
    @Test("A 4:3 subject mask over a 3:2 frame lands where the image says, not the grid")
    func nonUniformAspectIsHandled() {
        let imageWidth = 2048, imageHeight = 1365  // 3:2
        let working = 320, workingHeight = 213
        let coverage = [UInt8](repeating: 255, count: working * workingHeight)
        // 512x384 is 4:3 — the mask Vision hands back for this frame.
        let mask = Self.subject(
            width: 512, height: 384, imageWidth: imageWidth, imageHeight: imageHeight
        ) { u, v in u < 0.3 && v < 0.6 }
        let out = BodySkinMask.intersect(
            coverage, width: working, height: workingHeight, with: mask,
            coverageToImage: Self.workingToImage(
                working: working, workingHeight: workingHeight, image: imageWidth,
                imageHeight: imageHeight))

        let boundaryX = Int(0.3 * Double(working))
        let boundaryY = Int(0.6 * Double(workingHeight))
        #expect(out[(boundaryY / 2) * working + boundaryX / 2] == 255)
        #expect(out[(boundaryY / 2) * working + min(working - 1, boundaryX + 3)] == 0)
        #expect(out[min(workingHeight - 1, boundaryY + 3) * working + boundaryX / 2] == 0)
    }

    /// `nil` is not an all-zero mask. ``SubjectMaskProviding`` says so in words;
    /// this says it in bytes, because the failure mode — a landscape where Vision
    /// finds no person silently losing all skin coverage — is invisible.
    @Test("nil subject leaves the v1 coverage byte for byte")
    func nilSubjectIsV1() {
        let frame = SyntheticSkinFrame(skin: (224, 172, 105), clutter: true)
        let v1 = BodySkinMask.make(
            rgb: frame.rgb, componentsPerPixel: 3, width: frame.width, height: frame.height)
        let v2 = BodySkinMask.make(
            rgb: frame.rgb, componentsPerPixel: 3, width: frame.width, height: frame.height,
            subject: nil)
        #expect(v1.mask.values == v2.mask.values)
        #expect(v1.coverageFraction == v2.coverageFraction)
    }

    /// End to end through `make`, on the fixture the bench scores: a subject mask
    /// drawn around the skin region removes the wood leak, and `coverageFraction`
    /// follows the mask rather than being left at the pre-multiply value.
    @Test("The subject multiply removes the wood leak and updates coverageFraction")
    func subjectMaskRemovesTheWoodLeak() {
        let frame = SyntheticSkinFrame(skin: (198, 134, 66), clutter: true)
        let without = BodySkinMask.make(
            rgb: frame.rgb, componentsPerPixel: 3, width: frame.width, height: frame.height)
        // The subject silhouette, at a deliberately different resolution and
        // aspect ratio from the 320x240 frame.
        let subject = Self.subject(
            width: 96, height: 72, imageWidth: frame.width, imageHeight: frame.height
        ) { u, v in
            let x = u * Double(frame.width), y = v * Double(frame.height)
            return frame.truth[
                min(frame.height - 1, Int(y)) * frame.width + min(frame.width - 1, Int(x))]
        }
        let with = BodySkinMask.make(
            rgb: frame.rgb, componentsPerPixel: 3, width: frame.width, height: frame.height,
            subject: subject)

        let scoredWithout = frame.score(without.mask.values)
        let scoredWith = frame.score(with.mask.values)
        #expect(scoredWith.leakWood < scoredWithout.leakWood)
        #expect(scoredWith.leakWood < 0.02)
        #expect(with.coverageFraction < without.coverageFraction)
        // And the multiply never adds: every pixel is <= the v1 value.
        for i in 0..<with.mask.values.count {
            #expect(with.mask.values[i] <= without.mask.values[i])
        }
    }

    /// **The limitation, as a test.** Tone VI is rejected by `SkinCore.skinScore`'s
    /// Kovac `R <= 95` line, which runs *before* anything here, so a perfect
    /// subject mask cannot bring a single pixel back. This is asserted rather
    /// than only written down, so that a future change which quietly claims to
    /// fix deep skin tones has to face it (docs/ADR-0021 §v2).
    @Test("A perfect subject mask does not resurrect tone VI — a multiply cannot add area")
    func deepToneIsUnchangedByTheSubjectMask() {
        for clutter in [false, true] {
            let frame = SyntheticSkinFrame(skin: (91, 60, 17), clutter: clutter)
            let subject = Self.subject(
                width: 160, height: 120, imageWidth: frame.width, imageHeight: frame.height
            ) { u, v in
                let x = u * Double(frame.width), y = v * Double(frame.height)
                return frame.truth[
                    min(frame.height - 1, Int(y)) * frame.width + min(frame.width - 1, Int(x))]
            }
            let without = BodySkinMask.make(
                rgb: frame.rgb, componentsPerPixel: 3, width: frame.width, height: frame.height)
            let with = BodySkinMask.make(
                rgb: frame.rgb, componentsPerPixel: 3, width: frame.width, height: frame.height,
                subject: subject)
            #expect(frame.score(without.mask.values).iou == 0)
            #expect(frame.score(with.mask.values).iou == 0)
        }
    }
}

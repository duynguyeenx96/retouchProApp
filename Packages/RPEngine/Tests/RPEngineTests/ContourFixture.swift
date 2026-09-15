import CoreGraphics
import Foundation
import Metal
import RPCore

@testable import RPEngine

/// The fixture the "Tạo khối" (Contour) numbers are measured on: a flat-toned
/// portrait-shaped frame with a ``SyntheticFaceMesh`` in it, plus **probe
/// regions** cut from the mask's own anchors.
///
/// ## Why the picture is deliberately featureless
/// Contour is a mask, not a detector: what has to be measured is *where* the
/// effect lands and *how much*, and a textured photograph would make the per-
/// region means depend on the texture rather than on the mask. A smooth skin-tone
/// field with a gentle vertical ramp (so no pixel sits at 0 or 1, where every
/// gamma is a fixed point and a mask error would be invisible) isolates the mask.
///
/// The accuracy claim — the GPU computes the documented mask — is a PSNR against
/// `ColorReference` and does not depend on the fixture's content at all. The
/// **selectivity** claim does, and this is the arrangement ADR-0011 used for
/// eyes/teeth ("changes the teeth region, changes the gums region exactly 0"),
/// restated for a face's three contour zones.
///
/// The probes are cut from the lobes the production code builds, not from
/// hand-written coordinates: a probe written by hand would drift the moment a
/// constant in ``ContourMask`` moved, and would then be measuring the old
/// geometry while reporting the new one.
enum ContourFixture {
    enum Region: UInt8 {
        case elsewhere
        /// Inside the cheekbone highlight lobe, subject's right.
        case cheekHighlight
        /// Inside the cheek hollow shadow lobe, subject's right.
        case cheekShadow
        /// Inside the nose bridge highlight lobe.
        case noseBridge
        /// Inside the first jaw segment, subject's right.
        case jaw
        /// **Control 1** — the centre of the forehead. Inside the face, in the
        /// middle of the frame, and no contour zone claims it.
        case foreheadCentre
        /// **Control 2** — a corner of the frame, far outside the face.
        case outsideFace
    }

    struct Chart {
        var width: Int
        var height: Int
        /// Interleaved RGBA, quantised to half-float (the GPU reads rgba16Float,
        /// so an unquantised reference would be charged upload rounding the
        /// kernel did not cause).
        var pixels: [Float]
        var regions: [Region]
        var face: FaceRenderInput
        /// Every lobe with all three sliders at 100 — what the probes were cut
        /// from.
        var allLobes: [ContourLobe]
    }

    static let width = 384
    static let height = 448
    /// `|454 − 234|` ends up ≈ 197 px for this mesh; the frame is ~2 face widths
    /// across, which is roughly a head-and-shoulders crop.
    static let faceWidth: CGFloat = 200
    static let faceOrigin = CGPoint(x: 192, y: 70)

    static let chart: Chart = make()

    static func make() -> Chart {
        let face = SyntheticFaceMesh.renderInput(width: faceWidth, centre: faceOrigin)
        let lobes = ContourMask.lobes(
            faces: [face], sliders: ContourSliders(cheek: 100, nose: 100, jaw: 100))

        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = 0.42 + 0.16 * Double(y) / Double(height - 1)
                let o = (y * width + x) * 4
                pixels[o] = Float(min(1, v * 1.12))
                pixels[o + 1] = Float(v)
                pixels[o + 2] = Float(v * 0.92)
                pixels[o + 3] = 1
            }
        }

        // Probes: a disc at each lobe's own centre, small enough (0.035 × face
        // width ≈ 7 px) to sit well inside the lobe and not reach a neighbour.
        var regions = [Region](repeating: .elsewhere, count: width * height)
        let probeRadius = 0.035 * Double(faceWidth)
        func disc(_ centre: CGPoint, _ region: Region, radius: Double = probeRadius) {
            for y in 0..<height {
                for x in 0..<width {
                    let r = hypot(Double(x) + 0.5 - Double(centre.x), Double(y) + 0.5 - Double(centre.y))
                    if r < radius { regions[y * width + x] = region }
                }
            }
        }
        func centre(_ index: Int) -> CGPoint {
            CGPoint(x: CGFloat(lobes[index].centre.x), y: CGFloat(lobes[index].centre.y))
        }
        // Build order (ContourMask.lobes): cheek highlight L, cheek shadow L,
        // cheek highlight R, cheek shadow R, nose, then six jaw segments starting
        // on the subject's right.
        disc(centre(2), .cheekHighlight)
        disc(centre(3), .cheekShadow)
        disc(centre(4), .noseBridge, radius: 0.02 * Double(faceWidth))
        disc(centre(5), .jaw, radius: 0.02 * Double(faceWidth))

        let frame = FaceMeshFrame(landmarks: face.landmarks, faceWidth: face.faceWidth)!
        disc(point(frame, t: 0.10, u: 0), .foreheadCentre, radius: 0.04 * Double(faceWidth))
        disc(CGPoint(x: 18, y: 18), .outsideFace, radius: 14)

        let quantised = SpikeTextureIO.float16ToFloat32(SpikeTextureIO.float32ToFloat16(pixels))
        return Chart(
            width: width, height: height, pixels: quantised, regions: regions, face: face,
            allLobes: lobes)
    }

    /// A point at `t` down the face axis and `u` pixels off the midline — the
    /// same construction ``ContourMask`` anchors its lobes with.
    static func point(_ frame: FaceMeshFrame, t: CGFloat, u: CGFloat) -> CGPoint {
        CGPoint(
            x: frame.origin.x + frame.down.dx * (t * frame.length) + frame.lateral.dx * u,
            y: frame.origin.y + frame.down.dy * (t * frame.length) + frame.lateral.dy * u)
    }

    /// Mean absolute RGB change over one probe.
    static func meanChange(_ before: [Float], _ after: [Float], _ region: Region) -> Double {
        var sum = 0.0
        var count = 0
        for i in 0..<chart.regions.count where chart.regions[i] == region {
            let o = i * 4
            for channel in 0..<3 {
                sum += abs(Double(after[o + channel]) - Double(before[o + channel]))
            }
            count += 3
        }
        return count > 0 ? sum / Double(count) : 0
    }

    /// Mean **signed** luminance change over one probe — the number that says
    /// whether a zone was lightened or darkened, which `meanChange` hides.
    static func meanLuminanceChange(_ before: [Float], _ after: [Float], _ region: Region)
        -> Double
    {
        var sum = 0.0
        var count = 0
        for i in 0..<chart.regions.count where chart.regions[i] == region {
            let o = i * 4
            let b = ColorReference.luminance(
                (Double(before[o]), Double(before[o + 1]), Double(before[o + 2])))
            let a = ColorReference.luminance(
                (Double(after[o]), Double(after[o + 1]), Double(after[o + 2])))
            sum += a - b
            count += 1
        }
        return count > 0 ? sum / Double(count) : 0
    }

    /// Worst absolute channel change anywhere in one probe. `meanChange` can
    /// average a leak away; this cannot.
    static func maxChange(_ before: [Float], _ after: [Float], _ region: Region) -> Double {
        var worst = 0.0
        for i in 0..<chart.regions.count where chart.regions[i] == region {
            let o = i * 4
            for channel in 0..<3 {
                worst = max(worst, abs(Double(after[o + channel]) - Double(before[o + channel])))
            }
        }
        return worst
    }

    /// How many pixels of the frame the mask actually claims, at three
    /// thresholds. A contour that covered the whole frame would be Auto D&B under
    /// another name, so this is the number that says it is a *local* effect.
    static func coverage(_ lobes: [ContourLobe], threshold: Double) -> Double {
        var hit = 0
        for y in 0..<height {
            for x in 0..<width {
                let m = ContourMask.value(
                    at: CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5), lobes: lobes)
                if abs(m) > threshold { hit += 1 }
            }
        }
        return Double(hit) / Double(width * height)
    }

    /// A request carrying the contour sliders, optionally a colour grade on top,
    /// and one face.
    ///
    /// The two groups share a node, so `color:` is how a test asks for both at
    /// once — in particular for the case that matters, Auto D&B up *and* contour
    /// up, where a mix-up between the global dodge/burn and the masked one would
    /// show.
    static func request(
        _ sliders: ContourSliders, color: ColorSliders = ColorSliders(),
        quality: RenderQuality = .preview
    ) -> RenderRequest {
        var state = EditState()
        sliders.write(into: &state)
        color.write(into: &state)
        return RenderRequest(editState: state, faces: [chart.face], quality: quality)
    }

    /// Encodes the node once over the fixture and reads the result back as
    /// float32. Deliberately not through `RenderGraph`, for the same reason
    /// `ColorRenderNodeTests.runNode` is not.
    static func run(_ node: ColorRenderNode, context: MetalContext, request: RenderRequest) throws
        -> [Float]
    {
        let source = try SpikeTextureIO.makeTexture(
            fromFloatPixels: chart.pixels, width: width, height: height, device: context.device,
            usage: [.shaderRead, .shaderWrite])
        let destination = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: context.device, pixelFormat: .rgba32Float,
            usage: [.shaderRead, .shaderWrite])
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw MetalContext.Failure.noCommandQueue
        }
        try node.encode(
            into: commandBuffer, source: source, destination: destination, request: request)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return try RenderGraph.readFloat32(destination, queue: context.commandQueue)
    }
}

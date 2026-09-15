import CoreGraphics
import Foundation
import ImageIO
import RPCore

@testable import RPEngine

/// Fixtures for the Phase 6.2 "Đầu" (head reshape) suites.
///
/// Three sources, and every test says which it used:
///
/// * ``HairlineReference`` — the independent NumPy reference
///   (`Research/bench/hair-boundary-reference.py`) and the seven synthetic
///   shapes it emits as run-length rows. Committed as
///   `Research/bench/p6-head-hairline-reference.json`, so the geometry suite
///   runs on a machine with no `Research/spikes` and still compares the Swift
///   trace against a **different algorithm** rather than against itself.
/// * ``HairMaskFixtures`` — the real BiSeNet hair masks for the 11 a6300 frames
///   (spike S2, docs/ADR-0006), put back into the same pixel coordinates the
///   real 478-point meshes live in. Tracked in git but built from the spike's
///   two manifests, so the affine is derived once, here, and checked.
/// * ``SyntheticHead`` — a parametric head: ``SyntheticFaceMesh`` plus a hair
///   mask drawn around it. Not a stand-in for a real hairline in an accuracy
///   claim; it exists so the properties that must hold for *any* head (scale
///   invariance, which role moves, flag-off bit-exactness) are testable with no
///   `Research/` directory at all.
enum HeadFixtureRoot {
    /// Repository root, from this file's path — the same arrangement
    /// `FaceLandmarkFixtures.repositoryRoot` uses and for the same reason:
    /// `Research/` is hundreds of MB and is not in the test bundle.
    static var url: URL { FaceLandmarkFixtures.repositoryRoot }
}

// MARK: - The independent reference

/// `Research/bench/p6-head-hairline-reference.json`, as Swift sees it.
///
/// The comparison this enables is deliberately **not** "same boundary pixels":
/// the reference walks no ring at all. It records, for the largest 4-connected
/// component, the leftmost/rightmost member of every row and the
/// topmost/bottommost member of every column. Each of those four is provably on
/// the component's *outer* boundary (walk in from outside along that row or
/// column and you hit it first), so they must all appear in the Swift ring, and
/// the ring's own per-row/column extremes must be exactly these numbers. A hole
/// inside the region has a boundary too and is deliberately not in the ring —
/// which is why set equality would be the wrong test and these extremes are the
/// right one.
enum HairlineReference {
    struct Shape: Decodable {
        var name: String
        /// One entry per non-empty row: `[y, start, length, start, length…]`.
        var rle: [[Int]]
        var size: [Int]
        var mask_pixels: Int
        var component_pixels: Int
        var component_count: Int
        var bbox: [Int]?
        var start_pixel: [Int]?
        var rows: [[Int]]?
        var cols: [[Int]]?
    }

    struct Frame: Decodable {
        var image: String
        var size: [Int]
        var mask_pixels: Int
        var component_pixels: Int
        var component_count: Int
        var largest_component_fraction: Double
        var bbox: [Int]?
        var start_pixel: [Int]?
        var touches_edge: [String: Bool]?
        var rows: [[Int]]?
        var cols: [[Int]]?
    }

    struct Document: Decodable {
        var hair_class: Int
        var coverage_threshold: Int
        var synthetic: [Shape]
        var real: [Frame]
    }

    static let url = HeadFixtureRoot.url.appendingPathComponent(
        "Research/bench/p6-head-hairline-reference.json")

    /// `nil` when the reference has not been generated — the suite then skips
    /// loudly rather than passing on nothing.
    static let document: Document? = {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Document.self, from: data)
    }()

    /// A shape's bitmap as a ``RenderMask``, rebuilt from the run-length rows so
    /// the Swift side and the NumPy side are provably looking at the same bits.
    static func mask(_ shape: Shape) -> RenderMask {
        let width = shape.size[0]
        let height = shape.size[1]
        var values = [UInt8](repeating: 0, count: width * height)
        for row in shape.rle {
            let y = row[0]
            var i = 1
            while i + 1 < row.count {
                let start = row[i]
                let length = row[i + 1]
                for x in start..<(start + length) { values[y * width + x] = 255 }
                i += 2
            }
        }
        return RenderMask(
            width: width, height: height, values: values, maskToImage: .identity)
    }
}

/// The per-row / per-column extremes of a traced ring, computed the way the
/// reference computes them from a filled component — the two must agree.
enum RingExtremes {
    /// `rows[y] = (left, right)`, `cols[x] = (top, bottom)`, over mask pixels.
    ///
    /// The ring is in **image** pixels, so this takes the mask-space pixel back
    /// out of it: the trace maps pixel centres through `maskToImage`, so with the
    /// identity transform a point at `(x + 0.5, y + 0.5)` is pixel `(x, y)`.
    static func of(_ contour: [HairBoundary.Point]) -> (
        rows: [Int: (Int, Int)], cols: [Int: (Int, Int)]
    ) {
        var rows: [Int: (Int, Int)] = [:]
        var cols: [Int: (Int, Int)] = [:]
        for point in contour {
            let x = Int(floor(point.location.x))
            let y = Int(floor(point.location.y))
            if let existing = rows[y] {
                rows[y] = (min(existing.0, x), max(existing.1, x))
            } else {
                rows[y] = (x, x)
            }
            if let existing = cols[x] {
                cols[x] = (min(existing.0, y), max(existing.1, y))
            } else {
                cols[x] = (y, y)
            }
        }
        return (rows, cols)
    }
}

// MARK: - Real hair masks

/// The 11 real a6300 hair masks, in the coordinates of the crop the 478-point
/// meshes were measured on.
///
/// ## The affine, and why it is not obvious
/// The two spikes cut **different** crops out of the same upright 24 MP frame:
///
/// * `Research/spikes/S1-landmark/a6300/manifest.json` — an axis-aligned square,
///   `k = 3.5` around the Vision face box. `FaceLandmarkFixtures` reads its
///   meshes in *these* pixels.
/// * `Research/spikes/S2-face-parsing/a6300_upright/manifest.json` — a square
///   `k = 1.87` around the same box, cut out of the frame **after rotating it by
///   `+roll` about the face box centre** (`prepare_a6300.swift --upright`), which
///   is what the parsing model saw. The label PNG is that crop at 512².
///
/// So mask pixel → mesh pixel is: scale by `side / 512`, translate by the S2
/// crop origin, rotate by `−roll` about the face box centre (undoing the
/// derotation), translate by minus the S1 crop origin. All affine, all from the
/// manifests, no constant invented here.
///
/// **The sign of that rotation is measured, not assumed.** Both signs produce a
/// plausible-looking overlay, so the choice was made by rendering the face-oval
/// polygon and taking the IoU against the parser's own facial classes: `+roll`
/// wins on all 11 frames (mean 0.664 vs 0.634, and 0.596 vs 0.521 on DSC05239,
/// the frame with the largest roll at 0.72 rad). `HeadReshapeGeometryTests
/// .theRealHairMaskLinesUpWithTheRealMesh` re-runs that comparison so a silent
/// sign flip cannot survive, and the numbers are filed in
/// `Research/bench/p6-head-reshape-*.json` under `alignment`.
enum HairMaskFixtures {
    struct Frame {
        var image: String
        var mesh: FaceLandmarkFixtures.Mesh
        /// Class-17 coverage, 0 or 255, 512², with the affine above.
        var mask: RenderMask
        /// The same crop's full 19-class label map, for the alignment check.
        var labels: [UInt8]
        var labelSide: Int
        /// The manifest numbers the affine is built from, kept so the alignment
        /// check can build the *other* sign of the derotation from the same
        /// recipe rather than by mangling the matrix.
        var cropOrigin: CGPoint
        var cropSide: CGFloat
        var faceBoxCentre: CGPoint
        var roll: CGFloat
        var meshOrigin: CGPoint

        /// mask pixels → mesh pixels, with the derotation undone by `rollSign ×
        /// roll`. `-1` is the production choice; `+1` is the control.
        func maskToImage(rollSign: CGFloat) -> CGAffineTransform {
            let scale = cropSide / CGFloat(labelSide)
            var transform = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(
                    CGAffineTransform(translationX: cropOrigin.x, y: cropOrigin.y))
            transform = transform.concatenating(
                CGAffineTransform(translationX: faceBoxCentre.x, y: faceBoxCentre.y)
                    .rotated(by: rollSign * roll)
                    .translatedBy(x: -faceBoxCentre.x, y: -faceBoxCentre.y))
            return transform.concatenating(
                CGAffineTransform(translationX: -meshOrigin.x, y: -meshOrigin.y))
        }
    }

    struct Entry: Decodable {
        var image: String
        var crop_rect: [Double]
        var vision_largest_box: [Double]
        var vision_roll_rad: Double?
    }

    struct Manifest: Decodable { var images: [Entry] }

    static let hairClass: UInt8 = 17

    /// The 11 frames, or `[]` when the spike fixtures are absent.
    static let a6300: [Frame] = {
        let root = HeadFixtureRoot.url
        guard
            let data = try? Data(
                contentsOf: root.appendingPathComponent(
                    "Research/spikes/S2-face-parsing/a6300_upright/manifest.json")),
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return [] }
        var entries: [String: Entry] = [:]
        for entry in manifest.images { entries[entry.image] = entry }

        return FaceLandmarkFixtures.a6300.compactMap { mesh -> Frame? in
            guard let entry = entries[mesh.image], let origin = mesh.cropOrigin else {
                return nil
            }
            let name = (mesh.image as NSString).deletingPathExtension
            let url = root.appendingPathComponent(
                "Research/spikes/S2-face-parsing/a6300_upright/results/coreml_labels/\(name).png")
            guard let (labels, side) = loadLabels(url) else { return nil }

            let box = entry.vision_largest_box
            let crop = entry.crop_rect
            var values = [UInt8](repeating: 0, count: side * side)
            for i in 0..<values.count where labels[i] == hairClass { values[i] = 255 }

            var frame = Frame(
                image: mesh.image, mesh: mesh,
                mask: RenderMask(
                    width: side, height: side, values: values, maskToImage: .identity),
                labels: labels, labelSide: side,
                cropOrigin: CGPoint(x: crop[0], y: crop[1]), cropSide: CGFloat(crop[2]),
                faceBoxCentre: CGPoint(x: box[0] + box[2] / 2, y: box[1] + box[3] / 2),
                roll: CGFloat(entry.vision_roll_rad ?? 0), meshOrigin: origin)
            frame.mask.maskToImage = frame.maskToImage(rollSign: -1)
            return frame
        }
    }()

    /// The raw 8-bit class indices of a label PNG.
    ///
    /// Read straight out of the data provider rather than drawn into a context:
    /// these bytes are class **indices**, and drawing them through a grey colour
    /// space would colour-manage 17 into something else.
    static func loadLabels(_ url: URL) -> (values: [UInt8], side: Int)? {
        guard FileManager.default.fileExists(atPath: url.path),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            image.bitsPerComponent == 8, image.bitsPerPixel == 8,
            image.width == image.height,
            let data = image.dataProvider?.data as Data?
        else { return nil }
        let side = image.width
        let stride = image.bytesPerRow
        var values = [UInt8](repeating: 0, count: side * side)
        let bytes = [UInt8](data)
        for y in 0..<side {
            for x in 0..<side {
                values[y * side + x] = bytes[y * stride + x]
            }
        }
        return (values, side)
    }

    /// `FaceRenderInput` for one frame, with the hair mask attached.
    static func renderInput(_ frame: Frame, scale: CGFloat = 1) -> FaceRenderInput {
        var input = FaceLandmarkFixtures.renderInput(frame.mesh)
        input.masks[.hair] = frame.mask
        return scale == 1 ? input : input.scaled(by: scale)
    }

    /// The same frame in the coordinates of the full 24 MP upright original —
    /// the mesh by `FaceLandmarkFixtures.inFullFrame`, the mask by the same crop
    /// offset applied to its affine (the crop was cut at native resolution with
    /// no resampling, so this is exact and not a rescale).
    static func inFullFrame(_ frame: Frame)
        -> (input: FaceRenderInput, size: CGSize)?
    {
        guard let full = FaceLandmarkFixtures.inFullFrame(frame.mesh),
            let origin = frame.mesh.cropOrigin
        else { return nil }
        var input = FaceLandmarkFixtures.renderInput(full)
        var mask = frame.mask
        mask.maskToImage = mask.maskToImage.concatenating(
            CGAffineTransform(translationX: origin.x, y: origin.y))
        input.masks[.hair] = mask
        return (input, full.imageSize)
    }
}

/// One real a6300 frame, its real mesh **and** its real hair mask, resampled to a
/// size a `Double` CPU rasteriser can be run on inside a unit test.
///
/// The head equivalent of ``WarpImageFixture``, and it scales all three together:
/// the mesh by `scaled(by:)`, the mask by `RenderMask.scaled(by:)` (which moves
/// the *transform*, never resampling the 512² buffer — the production preview
/// path does exactly this).
struct HeadImageFixture {
    var image: String
    var pixels: [Float]
    var width: Int
    var height: Int
    var face: FaceRenderInput

    static func load(side: Int, name: String? = nil) throws -> HeadImageFixture? {
        let frames = HairMaskFixtures.a6300
        guard
            let frame = name.flatMap({ n in frames.first { $0.image == n } }) ?? frames.first,
            let url = FaceLandmarkFixtures.cropImageURL(frame.mesh)
        else { return nil }
        let image = try SpikeS3BenchTests.loadUpright(url)
        let mesh = frame.mesh
        let scale = CGFloat(side) / max(mesh.imageSize.width, mesh.imageSize.height)
        let width = Int((mesh.imageSize.width * scale).rounded())
        let height = Int((mesh.imageSize.height * scale).rounded())
        let (pixels, _, _) = try SpikeTextureIO.floatPixels(
            of: image, space: .sRGBEncoded, width: width, height: height)
        // The GPU reads an rgba16Float source, so the reference must start from
        // the same quantised values.
        let quantised = SpikeTextureIO.float16ToFloat32(
            SpikeTextureIO.float32ToFloat16(pixels))
        return HeadImageFixture(
            image: mesh.image, pixels: quantised, width: width, height: height,
            face: HairMaskFixtures.renderInput(frame, scale: scale))
    }
}

// MARK: - A synthetic head

/// ``SyntheticFaceMesh`` plus a hair mask around it, so every property that is a
/// property of the *code* can be tested without `Research/`.
///
/// The hair is an ellipse centred a little above the eye line, wide enough to
/// clear the face oval on both sides, with the lower half cut off at the mouth
/// line — a crude bob, but it has the two features that matter: it surrounds the
/// upper face oval (so the expanded ring has something to hit on every ray) and
/// its silhouette is well away from the frame edge (so nothing is clipped unless
/// a test asks for it).
enum SyntheticHead {
    struct Head {
        var face: FaceRenderInput
        var width: Int
        var height: Int
    }

    static func make(
        faceWidth: CGFloat = 200, centre: CGPoint = CGPoint(x: 192, y: 150),
        width: Int = 384, height: Int = 448, rotation: CGFloat = 0,
        maskScale: CGFloat = 2, clipped: Bool = false
    ) -> Head {
        var face = SyntheticFaceMesh.renderInput(
            width: faceWidth, centre: centre, rotation: rotation)
        face.masks[.hair] = hairMask(
            face: face, width: width, height: height, maskScale: maskScale, clipped: clipped)
        return Head(face: face, width: width, height: height)
    }

    /// The mask is built at `1 / maskScale` of the image's resolution, exactly
    /// like a real parsing mask (512² for a 24 MP frame), so `maskToImage` is a
    /// genuine scale and not the identity.
    static func hairMask(
        face: FaceRenderInput, width: Int, height: Int, maskScale: CGFloat, clipped: Bool
    ) -> RenderMask {
        let frame = FaceMeshFrame(landmarks: face.landmarks, faceWidth: face.faceWidth)!
        let maskWidth = Int((CGFloat(width) / maskScale).rounded())
        let maskHeight = Int((CGFloat(height) / maskScale).rounded())
        var values = [UInt8](repeating: 0, count: maskWidth * maskHeight)

        let hairCentre = HeadReshape.axisPoint(frame, t: 0.18)
        let semiU = 0.78 * frame.width
        let semiT = 0.62 * frame.length
        let cutoff = frame.tMouthLine

        for y in 0..<maskHeight {
            for x in 0..<maskWidth {
                let point = CGPoint(
                    x: (CGFloat(x) + 0.5) * maskScale, y: (CGFloat(y) + 0.5) * maskScale)
                let du = frame.u(point) - frame.u(hairCentre)
                let dt = (frame.t(point) - frame.t(hairCentre)) * frame.length
                guard (du * du) / (semiU * semiU) + (dt * dt) / (semiT * semiT) <= 1 else {
                    continue
                }
                guard frame.t(point) <= cutoff else { continue }
                values[y * maskWidth + x] = 255
            }
        }

        // The "clipped" variant simply extends the mask to the left edge, which
        // is what a parsing crop that cut the head looks like from here.
        if clipped {
            for y in 0..<maskHeight {
                var filled = false
                for x in 0..<maskWidth where values[y * maskWidth + x] == 255 {
                    filled = true
                    break
                }
                guard filled else { continue }
                for x in 0..<(maskWidth / 2) { values[y * maskWidth + x] = 255 }
            }
        }

        return RenderMask(
            width: maskWidth, height: maskHeight, values: values,
            maskToImage: CGAffineTransform(scaleX: maskScale, y: maskScale))
    }

    /// A request carrying head sliders and, optionally, the "Mặt" group's.
    static func request(
        _ head: HeadSliders, face: FaceSliders = FaceSliders(),
        faces: [FaceRenderInput], quality: RenderQuality = .preview
    ) -> RenderRequest {
        var state = EditState()
        head.write(into: &state)
        face.write(into: &state)
        return RenderRequest(editState: state, faces: faces, quality: quality)
    }
}

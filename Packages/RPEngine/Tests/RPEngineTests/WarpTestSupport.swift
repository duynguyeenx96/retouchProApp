import CoreGraphics
import Foundation

@testable import RPEngine

/// Fixtures for the Phase 2 "Mặt" (warp) suites.
///
/// Two sources, and the tests say which they used:
///
/// * ``FaceLandmarkFixtures`` — the **real** 478-point meshes `FaceAnalyzer`
///   produced for the 11 a6300 frames, straight out of
///   `Research/phase2/face-analyzer/results/a6300/twostage.json` (docs/ADR-0008),
///   together with the images they were measured on. Gitignored-sized fixtures,
///   so every test that needs them skips loudly rather than failing.
/// * ``SyntheticFaceMesh`` — a parametric 478-point face that runs anywhere. It
///   is *not* a stand-in for a real mesh in an accuracy claim; it exists so the
///   properties that must hold for **any** face (scale invariance, which
///   landmarks a slider touches, which direction they go) are tested on a machine
///   with no `Research/` directory.
enum FaceLandmarkFixtures {
    struct Mesh {
        /// File name, e.g. `DSC05123.jpg`.
        var image: String
        /// 478 points in the pixels of ``imageSize``, y down.
        var landmarks: [CGPoint]
        /// `|454 − 234|`, as `FaceAnalyzer` measured it.
        var faceWidth: CGFloat
        var imageSize: CGSize
        /// Origin of this square crop inside the upright full-resolution frame,
        /// from `Research/spikes/S1-landmark/a6300/manifest.json`. The crop was
        /// cut at native resolution with **no resampling**
        /// (`prepare_a6300.swift`), so full-frame landmarks are these plus this
        /// offset — which is what lets the 24 MP bench use real handles instead
        /// of invented ones.
        var cropOrigin: CGPoint?
        var fullFrameSize: CGSize?
    }

    /// Repository root, from this file's path. `Research/` is not in the test
    /// bundle (it is hundreds of MB), so the tests read it from the source tree,
    /// exactly as `SkinBenchTests.spikeRoot` does.
    static var repositoryRoot: URL {
        if let override = ProcessInfo.processInfo.environment["RP_REPO_ROOT"] {
            return URL(fileURLWithPath: override)
        }
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url = url.deletingLastPathComponent() }
        return url
    }

    private struct TwoStageFile: Decodable {
        struct Record: Decodable {
            var image: String
            var image_points: [Double]
            var image_w: Int
            var image_h: Int
            var face_width_px: Double
        }
        var records: [Record]
    }

    private struct Manifest: Decodable {
        struct Entry: Decodable {
            var image: String
            var crop_rect: [Double]
            var upright_size: [Double]
        }
        var images: [Entry]
    }

    /// The 11 real a6300 meshes, sorted by file name. Empty when the fixture is
    /// absent — callers print a SKIP and return.
    static let a6300: [Mesh] = {
        let root = repositoryRoot
        let url = root.appendingPathComponent(
            "Research/phase2/face-analyzer/results/a6300/twostage.json")
        guard let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(TwoStageFile.self, from: data)
        else { return [] }

        var crops: [String: Manifest.Entry] = [:]
        let manifestURL = root.appendingPathComponent(
            "Research/spikes/S1-landmark/a6300/manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        {
            for entry in manifest.images { crops[entry.image] = entry }
        }

        return file.records.compactMap { record -> Mesh? in
            guard record.image_points.count == FaceMesh.pointCount * 2 else { return nil }
            var points: [CGPoint] = []
            points.reserveCapacity(FaceMesh.pointCount)
            for i in 0..<FaceMesh.pointCount {
                points.append(
                    CGPoint(x: record.image_points[i * 2], y: record.image_points[i * 2 + 1]))
            }
            let entry = crops[record.image]
            return Mesh(
                image: record.image, landmarks: points,
                faceWidth: CGFloat(record.face_width_px),
                imageSize: CGSize(width: record.image_w, height: record.image_h),
                cropOrigin: entry.map { CGPoint(x: $0.crop_rect[0], y: $0.crop_rect[1]) },
                fullFrameSize: entry.map {
                    CGSize(width: $0.upright_size[0], height: $0.upright_size[1])
                })
        }
        .sorted { $0.image < $1.image }
    }()

    /// The square crop the mesh was measured on (2691² for `DSC05123`).
    static func cropImageURL(_ mesh: Mesh) -> URL? {
        let url = repositoryRoot.appendingPathComponent(
            "Research/spikes/S1-landmark/a6300/images/raw/\(mesh.image)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The full 24 MP upright frame the crop came from — spike S3's copy, which
    /// `SkinBenchTests` also uses.
    static func fullFrameURL(_ mesh: Mesh) -> URL? {
        let url = repositoryRoot.appendingPathComponent(
            "Research/spikes/S3-guided-filter-mls/images/full/\(mesh.image)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The same mesh scaled about the image origin — what a preview render sees
    /// (`FaceRenderInput.scaled(by:)` does exactly this in production).
    static func scaled(_ mesh: Mesh, by scale: CGFloat) -> Mesh {
        Mesh(
            image: mesh.image,
            landmarks: mesh.landmarks.map { CGPoint(x: $0.x * scale, y: $0.y * scale) },
            faceWidth: mesh.faceWidth * scale,
            imageSize: CGSize(
                width: (mesh.imageSize.width * scale).rounded(),
                height: (mesh.imageSize.height * scale).rounded()),
            cropOrigin: nil, fullFrameSize: nil)
    }

    /// The mesh moved into the coordinates of the full-resolution frame. `nil`
    /// when the manifest entry is missing.
    static func inFullFrame(_ mesh: Mesh) -> Mesh? {
        guard let origin = mesh.cropOrigin, let size = mesh.fullFrameSize else { return nil }
        return Mesh(
            image: mesh.image,
            landmarks: mesh.landmarks.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) },
            faceWidth: mesh.faceWidth, imageSize: size,
            cropOrigin: nil, fullFrameSize: nil)
    }

    static func renderInput(_ mesh: Mesh) -> FaceRenderInput {
        FaceRenderInput(landmarks: mesh.landmarks, faceWidth: mesh.faceWidth)
    }
}

/// A parametric 478-point face mesh, laid out from the proportions measured on
/// the 11 real a6300 meshes (`t` of the eye line 0.30, cheek line 0.43, mouth
/// line 0.70; face length 1.11 × face width).
///
/// **What it is for.** The properties a reshape slider must have for *any* face —
/// it moves the landmarks it claims to and no others, in the direction it claims,
/// and every magnitude scales with the face — are properties of the code, not of
/// a photograph, and they must be testable on a machine that has no `Research/`
/// directory. Accuracy claims use the real meshes; this does not appear in one.
///
/// Everything is built in a canonical frame (origin at the forehead centre, `+y`
/// toward the chin, `+x` at the subject's left) and then rotated, scaled and
/// translated, so a test can ask for the same face at two sizes and two angles
/// and compare exactly.
enum SyntheticFaceMesh {
    /// A face with `faceWidth ≈ width`, centred at `centre`, rolled by
    /// `rotation` radians.
    static func make(width: CGFloat, centre: CGPoint, rotation: CGFloat = 0) -> [CGPoint] {
        var canonical = [CGPoint](repeating: CGPoint(x: 0, y: 0.55), count: FaceMesh.pointCount)

        // --- Face oval: an ellipse, walked in the ring's own order so index 10
        //     lands on top and 152 at the bottom.
        let ovalCount = FaceMesh.faceOval.count
        for (position, index) in FaceMesh.faceOval.enumerated() {
            let angle = 2 * Double.pi * Double(position) / Double(ovalCount)
            canonical[index] = CGPoint(
                x: 0.5 * CGFloat(sin(angle)),
                y: 0.55 - 0.55 * CGFloat(cos(angle)))
        }

        // --- Eyes.
        //
        // The traversal is not guessed: measured on `DSC05172`'s real mesh, both
        // rings start at the corner on the **−x side of their own centre**
        // (33 at `u − ū = −0.088`, 362 at `−0.095`) and walk the **lower** lid
        // first (both reach their largest `t` around position 5). `π − 2πk/n`
        // reproduces that with `+y` pointing at the chin; `π + 2πk/n` walks the
        // upper lid first, which puts index 0 of the lip ring below the mouth
        // and silently inverts the "Môi đầy" direction test.
        let eyeCentres = [CGPoint(x: -0.22, y: 0.31), CGPoint(x: 0.22, y: 0.31)]
        for (side, ring) in [FaceMesh.eyeRingRight, FaceMesh.eyeRingLeft].enumerated() {
            for (position, index) in ring.enumerated() {
                let angle = Double.pi - 2 * Double.pi * Double(position) / Double(ring.count)
                canonical[index] = CGPoint(
                    x: eyeCentres[side].x + 0.090 * CGFloat(cos(angle)),
                    y: eyeCentres[side].y + 0.045 * CGFloat(sin(angle)))
            }
        }
        for (position, index) in FaceMesh.irisPoints.enumerated() {
            let side = position < 5 ? 1 : 0  // deliberately "wrong" order: the
            // production code assigns irises by distance, and this is what proves
            // it does not rely on the naming.
            let angle = 2 * Double.pi * Double(position % 5) / 5
            canonical[index] = CGPoint(
                x: eyeCentres[side].x + 0.025 * CGFloat(cos(angle)),
                y: eyeCentres[side].y + 0.025 * CGFloat(sin(angle)))
        }

        // --- Lips. Entry 0 of both rings is the subject's right corner (61, 78).
        let mouthCentre = CGPoint(x: 0, y: 0.77)
        for (ring, radii) in [
            (FaceMesh.lipsOuter, (x: CGFloat(0.20), y: CGFloat(0.075))),
            (FaceMesh.lipsInner, (x: CGFloat(0.14), y: CGFloat(0.030))),
        ] {
            for (position, index) in ring.enumerated() {
                let angle = Double.pi - 2 * Double.pi * Double(position) / Double(ring.count)
                canonical[index] = CGPoint(
                    x: mouthCentre.x + radii.x * CGFloat(cos(angle)),
                    y: mouthCentre.y + radii.y * CGFloat(sin(angle)))
            }
        }

        // --- Nose: the midline chain, then the two alae mirrored about it.
        let bridgeY: [CGFloat] = [0.31, 0.36, 0.41, 0.45, 0.49]
        for (position, index) in FaceMesh.noseBridge.enumerated() {
            canonical[index] = CGPoint(x: 0, y: bridgeY[position])
        }
        let centreOffsets: [(CGFloat, CGFloat)] = [
            (0, 0.53), (0, 0.57), (0, 0.60), (0, 0.615), (0, 0.625),
            (-0.030, 0.615), (0.030, 0.615),
        ]
        for (position, index) in FaceMesh.noseCentre.enumerated() {
            canonical[index] = CGPoint(x: centreOffsets[position].0, y: centreOffsets[position].1)
        }
        let alaCount = FaceMesh.noseAlaRight.count
        for position in 0..<alaCount {
            let s = CGFloat(position) / CGFloat(alaCount - 1)
            let x = 0.065 + 0.060 * s
            let y = 0.50 + 0.09 * s
            canonical[FaceMesh.noseAlaRight[position]] = CGPoint(x: -x, y: y)
            canonical[FaceMesh.noseAlaLeft[position]] = CGPoint(x: x, y: y)
        }

        // --- Canonical -> image.
        let (sine, cosine) = (sin(rotation), cos(rotation))
        return canonical.map { point in
            let x = point.x * width
            let y = point.y * width
            return CGPoint(
                x: centre.x + cosine * x - sine * y,
                y: centre.y + sine * x + cosine * y)
        }
    }

    /// `|454 − 234|` of a synthetic mesh — the number the production code uses,
    /// measured rather than assumed (the oval ellipse's extreme vertices do not
    /// land exactly on ±0.5).
    static func faceWidth(of landmarks: [CGPoint]) -> CGFloat {
        let a = landmarks[FaceMesh.cheekRight]
        let b = landmarks[FaceMesh.cheekLeft]
        return hypot(b.x - a.x, b.y - a.y)
    }

    static func renderInput(width: CGFloat, centre: CGPoint, rotation: CGFloat = 0)
        -> FaceRenderInput
    {
        let landmarks = make(width: width, centre: centre, rotation: rotation)
        return FaceRenderInput(landmarks: landmarks, faceWidth: faceWidth(of: landmarks))
    }
}

/// A CPU, `Double`-precision reference for the whole warp node: the
/// `MLSDeformation` grid solve plus a scanline rasterisation of the *same*
/// triangle mesh `MLSMeshWarp` draws.
///
/// ## Why a rasteriser and not just a PSNR against a blurred image
/// A warp is a geometric operation, so "PSNR of the output against something"
/// only means anything if the something encodes where the pixels were supposed
/// to go. Three independent checks are made, and this is the third:
///
/// 1. **Grid solve vs `MLSDeformation.grid`** — the float32 SIMD kernel against
///    the `Double` scalar reference, in pixels. This is spike S3's
///    `mls_gpu_vs_cpu.json` comparison, re-run on the *production* handles.
/// 2. **Landmark round-trip** — bilinear interpolation of the solved lattice at
///    each moved handle `p_i`, against the `q_i` the slider asked for. This is
///    the only number that says whether the *slider* did what it said; it is
///    dominated by the mesh density, which is exactly the thing ADR-0007 fixed
///    at 65/129.
/// 3. **Rendered image vs this reference** — which additionally covers the
///    triangulation, the clip-space mapping, the y flip, the uv assignment and
///    the bilinear sampler. None of those appear in (1) or (2), and all of them
///    can be wrong while producing a plausible picture.
///
/// The GPU side of (3) is Metal's hardware rasteriser, so this is not a
/// transcription of it: only the triangle list and the sampler's rules are
/// shared, and both are stated in `Shaders.metal` and reproduced here from that
/// statement.
enum WarpReference {
    /// The undeformed lattice `MLSMeshWarp.Resources` builds.
    static func sourceGrid(gridWidth: Int, gridHeight: Int, imageSize: CGSize) -> [CGPoint] {
        let cellsX = Double(gridWidth - 1)
        let cellsY = Double(gridHeight - 1)
        var out: [CGPoint] = []
        out.reserveCapacity(gridWidth * gridHeight)
        for y in 0..<gridHeight {
            for x in 0..<gridWidth {
                out.append(
                    CGPoint(
                        x: Double(x) / cellsX * Double(imageSize.width),
                        y: Double(y) / cellsY * Double(imageSize.height)))
            }
        }
        return out
    }

    /// Interleaved RGBA float32, row 0 at the top — the same layout
    /// `RenderGraph.renderPixels` returns. Alpha is 1 everywhere, matching the
    /// render pass's clear colour `(0, 0, 0, 1)`.
    static func render(
        source: [Float], width: Int, height: Int,
        control: MLSDeformation.ControlPoints, options: MLSDeformation.Options
    ) -> [Float] {
        let imageSize = CGSize(width: width, height: height)
        let deformed = MLSDeformation.grid(
            control: control, options: options, imageSize: imageSize)
        let undeformed = sourceGrid(
            gridWidth: options.gridWidth, gridHeight: options.gridHeight, imageSize: imageSize)

        var out = [Float](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) { out[i * 4 + 3] = 1 }

        func sample(_ u: Double, _ v: Double) -> (Double, Double, Double) {
            // Metal's `filter::linear, address::clamp_to_edge` on normalised
            // coordinates: texel space is `uv * size - 0.5`.
            let x = u * Double(width) - 0.5
            let y = v * Double(height) - 0.5
            let x0 = Int(floor(x)), y0 = Int(floor(y))
            let tx = x - Double(x0), ty = y - Double(y0)
            func texel(_ xi: Int, _ yi: Int) -> (Double, Double, Double) {
                let cx = min(max(xi, 0), width - 1)
                let cy = min(max(yi, 0), height - 1)
                let base = (cy * width + cx) * 4
                return (Double(source[base]), Double(source[base + 1]), Double(source[base + 2]))
            }
            let a = texel(x0, y0), b = texel(x0 + 1, y0)
            let c = texel(x0, y0 + 1), d = texel(x0 + 1, y0 + 1)
            func mix(_ p: Double, _ q: Double, _ t: Double) -> Double { p + (q - p) * t }
            return (
                mix(mix(a.0, b.0, tx), mix(c.0, d.0, tx), ty),
                mix(mix(a.1, b.1, tx), mix(c.1, d.1, tx), ty),
                mix(mix(a.2, b.2, tx), mix(c.2, d.2, tx), ty)
            )
        }

        func triangle(_ i0: Int, _ i1: Int, _ i2: Int) {
            let p0 = deformed[i0], p1 = deformed[i1], p2 = deformed[i2]
            let area =
                (Double(p1.x) - Double(p0.x)) * (Double(p2.y) - Double(p0.y))
                - (Double(p2.x) - Double(p0.x)) * (Double(p1.y) - Double(p0.y))
            guard abs(area) > 1e-12 else { return }
            let minX = max(0, Int(floor(min(p0.x, p1.x, p2.x) - 0.5)))
            let maxX = min(width - 1, Int(ceil(max(p0.x, p1.x, p2.x) + 0.5)))
            let minY = max(0, Int(floor(min(p0.y, p1.y, p2.y) - 0.5)))
            let maxY = min(height - 1, Int(ceil(max(p0.y, p1.y, p2.y) + 0.5)))
            guard minX <= maxX, minY <= maxY else { return }
            let uv0 = undeformed[i0], uv1 = undeformed[i1], uv2 = undeformed[i2]

            for py in minY...maxY {
                let sy = Double(py) + 0.5
                for px in minX...maxX {
                    let sx = Double(px) + 0.5
                    func edge(_ a: CGPoint, _ b: CGPoint) -> Double {
                        (Double(b.x) - Double(a.x)) * (sy - Double(a.y))
                            - (Double(b.y) - Double(a.y)) * (sx - Double(a.x))
                    }
                    let w0 = edge(p1, p2) / area
                    let w1 = edge(p2, p0) / area
                    let w2 = edge(p0, p1) / area
                    guard w0 >= 0, w1 >= 0, w2 >= 0 else { continue }
                    // w = 1 for every vertex, so the rasteriser's
                    // perspective-correct interpolation degenerates to affine.
                    let u =
                        (w0 * Double(uv0.x) + w1 * Double(uv1.x) + w2 * Double(uv2.x))
                        / Double(width)
                    let v =
                        (w0 * Double(uv0.y) + w1 * Double(uv1.y) + w2 * Double(uv2.y))
                        / Double(height)
                    let colour = sample(u, v)
                    let base = (py * width + px) * 4
                    out[base] = Float(colour.0)
                    out[base + 1] = Float(colour.1)
                    out[base + 2] = Float(colour.2)
                }
            }
        }

        // Exactly `MLSMeshWarp.Resources`' triangle list.
        for y in 0..<(options.gridHeight - 1) {
            for x in 0..<(options.gridWidth - 1) {
                let a = y * options.gridWidth + x
                let b = a + 1
                let c = (y + 1) * options.gridWidth + x
                let d = c + 1
                triangle(a, b, c)
                triangle(b, d, c)
            }
        }
        return out
    }
}

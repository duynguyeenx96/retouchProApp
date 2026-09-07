import CoreGraphics
import Foundation
import Metal
import Testing

@testable import RPEngine

/// Phase 0 spike S3 — MLS deformation maths. Pure CPU, no GPU needed.
@Suite("Spike S3 MLS deformation")
struct MLSDeformationTests {
    private static let imageSize = CGSize(width: 800, height: 600)

    private static func handles() -> [CGPoint] {
        [
            CGPoint(x: 100, y: 120), CGPoint(x: 700, y: 140), CGPoint(x: 380, y: 300),
            CGPoint(x: 150, y: 500), CGPoint(x: 660, y: 470), CGPoint(x: 400, y: 90),
        ]
    }

    /// If nothing moves, nothing may move. Catches a sign error in the
    /// `q* + a(v − p*)` recombination that a symmetric test would miss.
    @Test("q == p is the identity map everywhere")
    func identityDeformation() {
        let p = Self.handles()
        let control = MLSDeformation.ControlPoints(source: p, destination: p)
        for variant in MLSDeformation.Variant.allCases {
            let options = MLSDeformation.Options(variant: variant)
            for v in [CGPoint(x: 13, y: 17), CGPoint(x: 400, y: 300), CGPoint(x: 799, y: 599)] {
                let f = MLSDeformation.evaluate(v, control: control, options: options)
                #expect(abs(f.x - v.x) < 1e-9 && abs(f.y - v.y) < 1e-9, "\(variant) \(v) -> \(f)")
            }
        }
    }

    /// Schaefer's interpolation property: `f(p_i) = q_i`. The weights diverge at
    /// `v = p_i`, so this only holds if the implementation special-cases it —
    /// and if it does not, the slider handles do not land where the UI drew them.
    @Test("f(p_i) = q_i, exactly at the handle and in its limit")
    func interpolationProperty() {
        let p = Self.handles()
        let q = p.enumerated().map { CGPoint(x: $0.element.x + Double($0.offset) * 4 - 8,
                                             y: $0.element.y - Double($0.offset) * 3) }
        let control = MLSDeformation.ControlPoints(source: p, destination: q)
        let options = MLSDeformation.Options(variant: .similarity)
        for i in 0..<p.count {
            let exact = MLSDeformation.evaluate(p[i], control: control, options: options)
            #expect(abs(exact.x - q[i].x) < 1e-9 && abs(exact.y - q[i].y) < 1e-9)
            let near = MLSDeformation.evaluate(
                CGPoint(x: p[i].x + 1e-4, y: p[i].y), control: control, options: options)
            #expect(hypot(near.x - q[i].x, near.y - q[i].y) < 1e-2)
        }
    }

    /// Both variants must reproduce a global rigid motion exactly, everywhere —
    /// this is the property that makes MLS usable for reshape at all, and it is
    /// the strongest available check on the complex-arithmetic derivation.
    @Test("A global rotation + translation is reproduced exactly by both variants")
    func reproducesRigidMotion() {
        let angle = 0.37
        let (c, s) = (cos(angle), sin(angle))
        let t = CGPoint(x: 25, y: -14)
        let p = Self.handles()
        let q = p.map {
            CGPoint(x: c * $0.x - s * $0.y + t.x, y: s * $0.x + c * $0.y + t.y)
        }
        let control = MLSDeformation.ControlPoints(source: p, destination: q)
        for variant in MLSDeformation.Variant.allCases {
            let options = MLSDeformation.Options(variant: variant)
            for v in [CGPoint(x: 5, y: 5), CGPoint(x: 450, y: 220), CGPoint(x: 790, y: 590)] {
                let expected = CGPoint(x: c * v.x - s * v.y + t.x, y: s * v.x + c * v.y + t.y)
                let f = MLSDeformation.evaluate(v, control: control, options: options)
                #expect(hypot(f.x - expected.x, f.y - expected.y) < 1e-8, "\(variant)")
            }
        }
    }

    /// The property that decides which variant a slider may use: "mắt to" is a
    /// uniform enlargement, and only `.similarity` can express one. If `.rigid`
    /// silently reproduced scale the two would be interchangeable and the doc
    /// comment on `Variant` would be wrong.
    @Test("Similarity reproduces a uniform scale; rigid refuses to")
    func similarityScalesRigidDoesNot() {
        let k = 1.25
        let centre = CGPoint(x: 400, y: 300)
        let p = Self.handles()
        let q = p.map {
            CGPoint(x: centre.x + ($0.x - centre.x) * k, y: centre.y + ($0.y - centre.y) * k)
        }
        let control = MLSDeformation.ControlPoints(source: p, destination: q)
        let v = CGPoint(x: 600, y: 200)
        let expected = CGPoint(
            x: centre.x + (v.x - centre.x) * k, y: centre.y + (v.y - centre.y) * k)

        let similarity = MLSDeformation.evaluate(
            v, control: control, options: .init(variant: .similarity))
        #expect(hypot(similarity.x - expected.x, similarity.y - expected.y) < 1e-8)

        let rigid = MLSDeformation.evaluate(v, control: control, options: .init(variant: .rigid))
        #expect(hypot(rigid.x - expected.x, rigid.y - expected.y) > 10)
    }

    @Test("Border anchors are on the border and are identity handles")
    func borderAnchors() {
        let control = MLSDeformation.ControlPoints(source: [CGPoint(x: 400, y: 300)],
                                                   destination: [CGPoint(x: 420, y: 300)])
            .pinningBorder(width: 800, height: 600, perEdge: 4)
        #expect(control.count == 1 + 2 * 5 + 2 * 3)
        for i in 1..<control.count {
            #expect(control.source[i] == control.destination[i])
            let p = control.source[i]
            let onBorder = p.x == 0 || p.y == 0 || p.x == 800 || p.y == 600
            #expect(onBorder, "\(p)")
        }
    }
}

/// Phase 0 spike S3 — the GPU mesh warp: does it compute the same deformation
/// as the CPU reference, and does it put the pixels where the deformation says.
@Suite("Spike S3 MLS mesh warp", .serialized)
struct MLSMeshWarpTests {
    private func withWarp<T>(
        _ body: (MetalContext, MLSMeshWarp) throws -> T
    ) rethrows -> T? {
        guard let context = SpikeS3Support.context else { return nil }
        // The flag store is process-global and suites run concurrently
        // (RPEngineTestFlags): without this lock a Phase 2 suite can switch
        // mlsMeshWarp off between the set above and the construction below.
        let flags = RPEngineTestFlags.enter { RPEngineFeatureFlags.mlsMeshWarp = true }
        defer { flags.leave { RPEngineFeatureFlags.mlsMeshWarp = false } }
        guard let warp = try? MLSMeshWarp(context: context, pixelFormat: .rgba32Float) else {
            return nil
        }
        return try body(context, warp)
    }

    @Test("Constructing the warp with the flag off throws")
    func flagGatesConstruction() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter { RPEngineFeatureFlags.mlsMeshWarp = false }
        defer { flags.leave { RPEngineFeatureFlags.mlsMeshWarp = false } }
        #expect(throws: RPEngineFeatureDisabled.self) { try MLSMeshWarp(context: context) }
    }

    /// The Metal kernel and `MLSDeformation` are two independent transcriptions
    /// of the same formula (float32 SIMD vs Double scalar). If they agree to a
    /// hundredth of a pixel, neither has a term in the wrong place.
    @Test("GPU grid solve agrees with the Double CPU reference")
    func gpuGridMatchesCPU() throws {
        _ = try withWarp { context, warp in
            let imageSize = CGSize(width: 1200, height: 900)
            let p: [CGPoint] = [
                CGPoint(x: 300, y: 250), CGPoint(x: 900, y: 260), CGPoint(x: 600, y: 500),
                CGPoint(x: 350, y: 700), CGPoint(x: 880, y: 690),
            ]
            let q: [CGPoint] = [
                CGPoint(x: 320, y: 245), CGPoint(x: 875, y: 268), CGPoint(x: 600, y: 512),
                CGPoint(x: 372, y: 690), CGPoint(x: 856, y: 682),
            ]
            let control = MLSDeformation.ControlPoints(source: p, destination: q)
                .pinningBorder(width: 1200, height: 900)

            for variant in MLSDeformation.Variant.allCases {
                let options = MLSDeformation.Options(
                    variant: variant, alpha: 2.0, gridWidth: 33, gridHeight: 25)
                let resources = try warp.makeResources(imageSize: imageSize, options: options)
                let commandBuffer = context.commandQueue.makeCommandBuffer()!
                try warp.encodeGridSolve(
                    into: commandBuffer, resources: resources, control: control,
                    options: options, imageSize: imageSize)
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()

                let gpu = warp.readDeformedGrid(resources)
                let cpu = MLSDeformation.grid(
                    control: control, options: options, imageSize: imageSize)
                var worst = 0.0
                for i in 0..<cpu.count {
                    worst = max(worst, hypot(gpu[i].x - cpu[i].x, gpu[i].y - cpu[i].y))
                }
                print("S3 MLS \(variant): max |GPU − CPU| = \(worst) px")
                #expect(worst < 0.01, "\(variant) max \(worst) px")
            }
        }
    }

    /// The same comparison on the **real** handles: the 84 control points
    /// `s3harness controlpoints` derives from S1's 478-point mesh on each a6300
    /// frame, at the two configurations ADR-0007 fixes (2048 px preview / grid
    /// 65, full 24 MP / grid 129). The synthetic case above is 21 handles on a
    /// 1200×900 frame; float32 loses absolute precision with coordinate
    /// magnitude, so a 6000 px frame is a strictly harder case and it is the one
    /// Phase 2 ships. The number quoted in the report and in ADR-0007 comes from
    /// `Research/spikes/S3-guided-filter-mls/results/mls_gpu_vs_cpu.json`, which
    /// `s3harness mlsgpu` writes; this test is the regression guard on it.
    ///
    /// Skips when the fixtures are absent — they are gitignored, like the frames
    /// `SpikeS3BenchTests` needs.
    @Test("GPU grid solve agrees with the Double CPU reference on the real 84-handle reshape")
    func gpuGridMatchesCPUOnRealFaceHandles() throws {
        guard let root = SpikeS3BenchTests.spikeRoot else { return }
        let controlDirectory = root.appendingPathComponent("control")
        let urls = ((try? FileManager.default.contentsOfDirectory(
            at: controlDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !urls.isEmpty else {
            print("S3 MLS real-handle accuracy: SKIP (run `s3harness controlpoints`)")
            return
        }

        _ = try withWarp { context, warp in
            var worstPreview = 0.0
            var worstExport = 0.0
            var handleCounts: Set<Int> = []
            for url in urls {
                let file = try JSONDecoder().decode(
                    SpikeS3BenchTests.ControlPoints.self, from: Data(contentsOf: url))
                handleCounts.insert(file.source.count)
                let longEdge = Double(max(file.imageWidth, file.imageHeight))
                let cases: [(scale: Double, grid: Int)] = [
                    (2048.0 / longEdge, 65), (1.0, 129),
                ]
                for (scale, grid) in cases {
                    let control = file.scaled(by: scale)
                    let imageSize = CGSize(
                        width: (Double(file.imageWidth) * scale).rounded(),
                        height: (Double(file.imageHeight) * scale).rounded())
                    for variant in MLSDeformation.Variant.allCases {
                        let options = MLSDeformation.Options(
                            variant: variant, alpha: 2.0, gridWidth: grid, gridHeight: grid)
                        let resources = try warp.makeResources(
                            imageSize: imageSize, options: options)
                        let commandBuffer = context.commandQueue.makeCommandBuffer()!
                        try warp.encodeGridSolve(
                            into: commandBuffer, resources: resources, control: control,
                            options: options, imageSize: imageSize)
                        commandBuffer.commit()
                        commandBuffer.waitUntilCompleted()

                        let gpu = warp.readDeformedGrid(resources)
                        let cpu = MLSDeformation.grid(
                            control: control, options: options, imageSize: imageSize)
                        var worst = 0.0
                        for i in 0..<cpu.count {
                            worst = max(worst, hypot(gpu[i].x - cpu[i].x, gpu[i].y - cpu[i].y))
                        }
                        if grid == 65 {
                            worstPreview = max(worstPreview, worst)
                        } else {
                            worstExport = max(worstExport, worst)
                        }
                    }
                }
            }
            print(
                "S3 MLS real handles \(handleCounts.sorted()) over \(urls.count) frames: "
                    + "max |GPU − CPU| = \(worstPreview) px (2048 px, grid 65), "
                    + "\(worstExport) px (24 MP, grid 129)")
            // Bound, not the measurement: 0.01 px is 30× the measured worst at
            // 24 MP and still far below anything visible after resampling.
            #expect(worstPreview < 0.01, "preview max \(worstPreview) px")
            #expect(worstExport < 0.01, "export max \(worstExport) px")
        }
    }

    /// The coordinate-space test. A translation-only deformation must move the
    /// image by exactly that many pixels **in that direction**. A y flip, an
    /// x/y swap or an inverted mapping all still produce a plausible-looking
    /// warped image; only this catches them.
    @Test("A pure +x/+y translation moves content right and down by exactly that many pixels")
    func translationMovesContentTheRightWay() throws {
        _ = try withWarp { context, warp in
            let width = 128, height = 96
            let dx = 16.0, dy = 8.0

            // A marker block near the top-left, on an otherwise black field.
            var pixels = [Float](repeating: 0, count: width * height * 4)
            for i in 0..<(width * height) { pixels[i * 4 + 3] = 1 }
            let block = (x: 20, y: 12, w: 8, h: 8)
            for y in block.y..<(block.y + block.h) {
                for x in block.x..<(block.x + block.w) {
                    for c in 0..<3 { pixels[(y * width + x) * 4 + c] = 1 }
                }
            }

            // Every handle moves by the same offset -> f(v) = v + d everywhere.
            let p: [CGPoint] = [
                CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 12), CGPoint(x: 64, y: 48),
                CGPoint(x: 15, y: 80), CGPoint(x: 115, y: 84),
            ]
            let q = p.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            let control = MLSDeformation.ControlPoints(source: p, destination: q)
            let options = MLSDeformation.Options(
                variant: .similarity, alpha: 2.0, gridWidth: 17, gridHeight: 13)

            let source = try SpikeTextureIO.makeTexture(
                fromFloatPixels: pixels, width: width, height: height, device: context.device,
                usage: [.shaderRead])
            let destination = try SpikeTextureIO.makeTexture(
                width: width, height: height, device: context.device, pixelFormat: .rgba32Float,
                usage: [.shaderRead, .renderTarget])
            let resources = try warp.makeResources(imageSize: CGSize(width: width, height: height),
                                                   options: options)
            let commandBuffer = context.commandQueue.makeCommandBuffer()!
            try warp.encode(
                into: commandBuffer, source: source, destination: destination,
                resources: resources, control: control, options: options)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            let output = try SpikeS3Support.readFloat32(destination, queue: context.commandQueue)
            func luma(_ buffer: [Float], _ x: Int, _ y: Int) -> Float {
                buffer[(y * width + x) * 4]
            }
            // The block's new top-left corner.
            #expect(luma(output, block.x + Int(dx), block.y + Int(dy)) > 0.9)
            #expect(luma(output, block.x + Int(dx) + block.w - 1, block.y + Int(dy) + block.h - 1) > 0.9)
            // Where it used to be, and the two "wrong sign" corners.
            #expect(luma(output, block.x, block.y) < 0.1)
            #expect(luma(output, block.x - Int(dx), block.y - Int(dy)) < 0.1)
            // A y flip would land the block near the bottom instead.
            #expect(luma(output, block.x + Int(dx), height - 1 - (block.y + Int(dy))) < 0.1)
            // An x/y swap would land it at (y + dy, x + dx).
            #expect(luma(output, block.y + Int(dy), block.x + Int(dx)) < 0.1)

            // And the whole frame is a clean shift, not just the corner pixels.
            var worst = 0.0
            for y in 0..<height {
                for x in 0..<width {
                    let sx = x - Int(dx), sy = y - Int(dy)
                    let expected: Float =
                        (sx >= 0 && sy >= 0 && sx < width && sy < height)
                        ? pixels[(sy * width + sx) * 4] : 0
                    // The mesh edge is clamped and the outside is cleared to
                    // black, so only the interior is a strict shift.
                    if x >= Int(dx) && y >= Int(dy) {
                        worst = max(worst, abs(Double(luma(output, x, y) - expected)))
                    }
                }
            }
            print("S3 MLS translation warp: max abs interior error = \(worst)")
            #expect(worst < 1e-3, "max \(worst)")
        }
    }

    /// A deformation with q == p must return the source pixel for pixel: it is
    /// the case where the resampler is the only thing that can go wrong.
    @Test("An identity deformation round-trips the image")
    func identityWarpIsLossless() throws {
        _ = try withWarp { context, warp in
            let width = 96, height = 72
            let pixels = SpikeS3Support.syntheticImage(width: width, height: height, seed: 5)
            let quantised = SpikeTextureIO.float16ToFloat32(
                SpikeTextureIO.float32ToFloat16(pixels))
            let p: [CGPoint] = [CGPoint(x: 30, y: 20), CGPoint(x: 70, y: 55)]
            let control = MLSDeformation.ControlPoints(source: p, destination: p)
                .pinningBorder(width: Double(width), height: Double(height))
            let options = MLSDeformation.Options(gridWidth: 33, gridHeight: 25)

            let source = try SpikeTextureIO.makeTexture(
                fromFloatPixels: quantised, width: width, height: height,
                device: context.device, usage: [.shaderRead])
            let destination = try SpikeTextureIO.makeTexture(
                width: width, height: height, device: context.device, pixelFormat: .rgba32Float,
                usage: [.shaderRead, .renderTarget])
            let resources = try warp.makeResources(
                imageSize: CGSize(width: width, height: height), options: options)
            let commandBuffer = context.commandQueue.makeCommandBuffer()!
            try warp.encode(
                into: commandBuffer, source: source, destination: destination,
                resources: resources, control: control, options: options)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            let output = try SpikeS3Support.readFloat32(destination, queue: context.commandQueue)
            let psnr = SpikeTextureIO.psnr(quantised, output)
            print("S3 MLS identity warp PSNR = \(psnr) dB")
            #expect(psnr > 60, "PSNR \(psnr) dB")
        }
    }
}

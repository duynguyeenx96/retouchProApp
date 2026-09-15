import CoreGraphics
import Foundation
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 6.2 "Đầu" — the node half: the flag, the activation rules and the GPU.
///
/// The geometry suite says the handles are right. This one says the *node* does
/// the right thing with them, and it leads with the property every Phase 6 group
/// in this queue has had to prove first: **with the flag off, nothing changed.**
///
/// `.serialized` because `RPEngineFeatureFlags` is process-global (ADR-0006), and
/// every test here takes `RPEngineTestFlags`' lock.
@Suite("Phase 6.2 head reshape node", .serialized)
struct HeadReshapeRenderTests {

    static let allHead = HeadSliders(size: 70, width: 60, volume: 80)

    // MARK: - The flag

    /// The claim: turning ``RPEngineFeatureFlags/headSliders`` off does not
    /// "mostly" restore the old render, it restores it **bit for bit**.
    ///
    /// Measured the only way that means anything: the same node renders the same
    /// picture twice, once from an `EditState` that carries head sliders at full
    /// and once from one that has never heard of them, and the two buffers are
    /// compared exactly. A PSNR would hide a one-bit difference; `==` cannot.
    @Test("Flag off is bit-exact the old render")
    func flagOffIsBitExactTheOldRender() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.enableWarpRenderGraph()
            RPEngineFeatureFlags.headSliders = false
        }
        defer { flags.leave { RPEngineTestFlags.disableHeadAndWarp() } }

        let head = SyntheticHead.make()
        let node = try WarpRenderNode(context: context)
        let face = FaceSliders(slim: 50, chin: 40, eyeSize: 30)

        let withHead = SyntheticHead.request(Self.allHead, face: face, faces: [head.face])
        let without = SyntheticHead.request(HeadSliders(), face: face, faces: [head.face])
        #expect(node.headControlPoints(for: withHead, imageSize: CGSize(width: 384, height: 448)) == nil)

        let a = try Self.run(node, context: context, request: withHead, head: head)
        let b = try Self.run(node, context: context, request: without, head: head)
        #expect(SpikeTextureIO.maxAbsoluteDifference(a.output, b.output) == 0)

        // …and a head-only edit does not even wake the node up.
        let headOnly = SyntheticHead.request(Self.allHead, faces: [head.face])
        #expect(!node.isActive(for: headOnly))
        let (source, output) = try Self.run(
            node, context: context, request: headOnly, head: head)
        #expect(SpikeTextureIO.maxAbsoluteDifference(source, output) == 0)
    }

    @Test("With the flag on, the head sliders change the picture")
    func flagOnChangesThePicture() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterHeadRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableHeadAndWarp() } }

        let head = SyntheticHead.make()
        let node = try WarpRenderNode(context: context)
        let request = SyntheticHead.request(Self.allHead, faces: [head.face])
        #expect(node.isActive(for: request))
        let built = try #require(
            node.headControlPoints(
                for: request,
                imageSize: CGSize(width: CGFloat(head.width), height: CGFloat(head.height))))
        #expect(built.hairHandleCount > 0)
        #expect(built.ringHandleCount > 0)
        #expect(built.maxDisplacement > 1)

        let (source, output) = try Self.run(node, context: context, request: request, head: head)
        #expect(SpikeTextureIO.maxAbsoluteDifference(source, output) > 0.01)
    }

    @Test("Head sliders at 0 leave every pixel bit-exact")
    func zeroHeadSlidersAreBitExactIdentity() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterHeadRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableHeadAndWarp() } }

        let head = SyntheticHead.make()
        let node = try WarpRenderNode(context: context)
        let request = SyntheticHead.request(HeadSliders(), faces: [head.face])
        #expect(!node.isActive(for: request))
        let (source, output) = try Self.run(node, context: context, request: request, head: head)
        #expect(SpikeTextureIO.maxAbsoluteDifference(source, output) == 0)
    }

    /// The hat case, in the shape production actually produces it.
    ///
    /// `FaceAnalysisRenderBridge` attaches a `.hair` `RenderMask` to **every**
    /// face whose parsing succeeded, for every requested kind — so "no hair"
    /// never arrives as a missing key. It arrives as a mask that is present and
    /// whose coverage is entirely below `HairBoundary.coverageThreshold`: a hat
    /// (BiSeNet keeps `hat` as its own class 18), a shaved head, a parsing miss.
    ///
    /// Testing only `masks[.hair] = nil` was therefore false confidence — it
    /// exercised a shape the app cannot produce, and the shape it can produce
    /// scheduled the node and paid for a full-frame `encodeCopy` to return the
    /// picture unchanged.
    @Test("A head-only edit on a present-but-empty hair mask costs nothing")
    func aHeadOnlyEditWithoutAUsableSilhouetteIsInactive() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterHeadRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableHeadAndWarp() } }

        let node = try WarpRenderNode(context: context)
        var hatted = SyntheticHead.make()
        let real = try #require(hatted.face.masks[.hair])
        // Present, correctly sized, correctly placed — and nothing in it reaches
        // the half-coverage isoline. 127 rather than 0 so this is a mask with
        // real content that simply never says "hair", which is what a feathered
        // parse of a hat looks like at the hairline.
        hatted.face.masks[.hair] = RenderMask(
            width: real.width, height: real.height,
            values: [UInt8](repeating: HairBoundary.coverageThreshold - 1, count: real.values.count),
            maskToImage: real.maskToImage)

        let request = SyntheticHead.request(Self.allHead, faces: [hatted.face])
        #expect(!node.isActive(for: request), "an unusable hair mask scheduled the node")
        // …and going through the node anyway is still an exact copy.
        let (source, output) = try Self.run(
            node, context: context, request: request, head: hatted)
        #expect(SpikeTextureIO.maxAbsoluteDifference(source, output) == 0)

        // The answer is memoised like any other: repeated `isActive` during a
        // drag must not re-trace the same mask.
        let before = node.debugTraceCount
        for _ in 0..<10 { _ = node.isActive(for: request) }
        #expect(node.debugTraceCount == before, "isActive re-traced an unusable mask")

        // The missing-key case is still handled, even though the bridge cannot
        // produce it — a `FaceRenderInput` built by hand (or by a future provider
        // that does not ask for `.hair`) must not crash or activate.
        var bald = SyntheticHead.make()
        bald.face.masks[.hair] = nil
        let baldRequest = SyntheticHead.request(Self.allHead, faces: [bald.face])
        #expect(!node.isActive(for: baldRequest))
        let (baldSource, baldOutput) = try Self.run(
            node, context: context, request: baldRequest, head: bald)
        #expect(SpikeTextureIO.maxAbsoluteDifference(baldSource, baldOutput) == 0)

        // A "Mặt" edit on either face is unaffected by the head group being on:
        // it activates on its own sliders and produces no head handles.
        for head in [hatted, bald] {
            let both = SyntheticHead.request(
                Self.allHead, face: FaceSliders(slim: 50), faces: [head.face])
            #expect(node.isActive(for: both))
            let built = try #require(
                node.headControlPoints(
                    for: both,
                    imageSize: CGSize(
                        width: CGFloat(head.width), height: CGFloat(head.height))))
            #expect(built.hairHandleCount == 0)
            #expect(built.ringHandleCount == 0)
            #expect(built.maxDisplacement > 0, "the Mặt group stopped working")
        }
    }

    @Test("The mask requirements ask for hair only when the head group is on")
    func maskRequirementsFollowTheFlag() {
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.enableWarpRenderGraph()
            RPEngineFeatureFlags.headSliders = false
        }
        defer { flags.leave { RPEngineTestFlags.disableHeadAndWarp() } }
        #expect(!RenderMaskRequirements.forEnabledGroups().contains(.hair))
        RPEngineFeatureFlags.headSliders = true
        #expect(RenderMaskRequirements.forEnabledGroups().contains(.hair))
    }

    @Test("Disabling the head group leaves the Mặt group's flags alone")
    func disablingHeadKeepsTheWarpGroup() {
        let flags = RPEngineTestFlags.enterHeadRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableHeadAndWarp() } }
        #expect(RPEngineFeatureFlags.headSliders)
        #expect(RPEngineFeatureFlags.warpSliders)
        #expect(RPEngineFeatureFlags.mlsMeshWarp)
        RPEngineFeatureFlags.disableHeadRenderGraph()
        #expect(!RPEngineFeatureFlags.headSliders)
        #expect(RPEngineFeatureFlags.warpSliders, "the head group took the Mặt group down")
        #expect(RPEngineFeatureFlags.mlsMeshWarp, "the head group cleared a shared kernel flag")
    }

    // MARK: - The cache

    /// A slider drag must not re-trace the hair mask, and a *different* mask
    /// must not be served the previous one's silhouette.
    ///
    /// The second half is the one that matters: a cache that returns a stale
    /// hairline warps this photo with the last photo's head. The key is full
    /// value equality of the mask and the mesh, so this test changes one byte of
    /// the mask and expects a new trace.
    @Test("The silhouette is traced once per mask, not once per frame")
    func theSilhouetteIsTracedOncePerMask() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterHeadRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableHeadAndWarp() } }

        let head = SyntheticHead.make()
        let node = try WarpRenderNode(context: context)
        let imageSize = CGSize(width: CGFloat(head.width), height: CGFloat(head.height))

        for value in stride(from: 10.0, through: 100.0, by: 10.0) {
            let request = SyntheticHead.request(
                HeadSliders(size: value, width: value / 2, volume: value / 3),
                faces: [head.face])
            #expect(node.headControlPoints(for: request, imageSize: imageSize) != nil)
        }
        #expect(node.debugTraceCount == 1, "a drag re-traced the mask")

        // A different mask is a different answer.
        var other = head
        var mask = try #require(other.face.masks[.hair])
        mask.values[mask.values.count / 2] = mask.values[mask.values.count / 2] == 255 ? 0 : 255
        other.face.masks[.hair] = mask
        _ = node.headControlPoints(
            for: SyntheticHead.request(Self.allHead, faces: [other.face]),
            imageSize: imageSize)
        #expect(node.debugTraceCount == 2, "a changed mask was served a stale silhouette")

        // …and so is a different mesh under the same mask.
        var moved = head
        moved.face.landmarks = moved.face.landmarks.map {
            CGPoint(x: $0.x + 3, y: $0.y)
        }
        _ = node.headControlPoints(
            for: SyntheticHead.request(Self.allHead, faces: [moved.face]),
            imageSize: imageSize)
        #expect(node.debugTraceCount == 3, "a changed mesh was served a stale silhouette")

        // `releaseIntermediates` is "forget the last shot", so it forgets this too.
        node.releaseIntermediates()
        _ = node.headControlPoints(
            for: SyntheticHead.request(Self.allHead, faces: [head.face]),
            imageSize: imageSize)
        #expect(node.debugTraceCount == 4)
    }

    // MARK: - The GPU

    /// The production version of spike S3's `mls_gpu_vs_cpu.json`, on the head
    /// group's handles: the float32 SIMD kernel against the `Double` scalar
    /// reference, in pixels, at both mandatory grid sizes.
    @Test("The GPU solves the head lattice to the Double CPU reference")
    func theSolvedLatticeMatchesTheCPUReference() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterHeadRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableHeadAndWarp() } }

        let head = SyntheticHead.make()
        let node = try WarpRenderNode(context: context)
        let imageSize = CGSize(width: CGFloat(head.width), height: CGFloat(head.height))

        for quality in RenderQuality.allCases {
            let request = SyntheticHead.request(
                Self.allHead, face: FaceSliders(slim: 40), faces: [head.face],
                quality: quality)
            _ = try Self.run(node, context: context, request: request, head: head)
            let solved = try #require(node.debugDeformedGrid())
            let built = try #require(node.headControlPoints(for: request, imageSize: imageSize))
            let cpu = MLSDeformation.grid(
                control: built.control, options: FaceReshape.options(for: quality),
                imageSize: imageSize)
            #expect(cpu.count == solved.points.count)
            var worst = 0.0
            for i in 0..<cpu.count {
                worst = max(
                    worst,
                    Double(hypot(solved.points[i].x - cpu[i].x, solved.points[i].y - cpu[i].y)))
            }
            print(
                "P6.2 head grid solve vs Double CPU, \(quality.rawValue) "
                    + "(grid \(quality.meshGrid), \(built.handles.count) handles): \(worst) px")
            #expect(worst < 0.01, "\(quality) grid error \(worst) px")
        }
    }

    /// The whole node against a `Double` CPU rasterisation of the same mesh, on a
    /// **real** a6300 frame with its **real** hair mask. docs/PLAN.md Phase 2's
    /// bar is 45 dB and it applies to every node.
    @Test("The rendered head warp matches the Double CPU reference at ≥ 45 dB")
    func theRenderedHeadWarpMatchesTheCPUReference() throws {
        guard let context = SpikeS3Support.context else { return }
        guard let fixture = try HeadImageFixture.load(side: 640) else {
            print("P6.2 head rendered image: SKIP (a6300 image/parsing fixture absent)")
            return
        }
        let flags = RPEngineTestFlags.enterHeadRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableHeadAndWarp() } }

        let graph = try RenderGraph.standard(context: context)
        let request = SyntheticHead.request(Self.allHead, faces: [fixture.face])
        let (output, report) = try graph.renderPixels(
            fixture.pixels, width: fixture.width, height: fixture.height, request: request)
        #expect(report.nodes == ["warp"])

        let built = try #require(
            HeadReshape.controlPoints(
                faces: [fixture.face], face: FaceSliders(), head: Self.allHead,
                imageSize: CGSize(width: fixture.width, height: fixture.height)))
        let reference = WarpReference.render(
            source: fixture.pixels, width: fixture.width, height: fixture.height,
            control: built.control, options: FaceReshape.options(for: .preview))

        let psnr = SpikeTextureIO.psnr(reference, output)
        print(
            "P6.2 head rendered image vs Double CPU reference (\(fixture.image), "
                + "\(fixture.width)x\(fixture.height), \(built.handles.count) handles "
                + "[\(built.faceMeshHandleCount) mesh / \(built.ringHandleCount) ring / "
                + "\(built.hairHandleCount) hair], max displacement "
                + "\(built.maxDisplacement) px): PSNR = \(psnr) dB")
        #expect(psnr >= 45, "rendered PSNR \(psnr) dB")

        // …and the warp must actually have moved the picture, or an unwarped
        // output would score infinity against an unwarped reference.
        let change = SpikeTextureIO.maxAbsoluteDifference(fixture.pixels, output)
        #expect(change > 0.05, "the head warp changed the picture by only \(change)")
    }

    /// Where does a head slider put its energy? At the hairline, and not at the
    /// frame border — the border anchors are mandatory for exactly this reason
    /// (ADR-0007), and a head warp stresses them harder than a face warp does
    /// because its handles reach much further out.
    @Test("The head warp moves the silhouette and pins the frame")
    func theHeadWarpIsLocalToTheHead() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterHeadRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableHeadAndWarp() } }

        let head = SyntheticHead.make()
        let imageSize = CGSize(width: CGFloat(head.width), height: CGFloat(head.height))
        let built = try #require(
            HeadReshape.controlPoints(
                faces: [head.face], face: FaceSliders(), head: HeadSliders(volume: 100),
                imageSize: imageSize))
        let options = FaceReshape.options(for: .preview)

        // On the silhouette.
        var atTheHairline = 0.0
        for handle in built.handles where handle.role == .hairBoundary {
            let f = MLSDeformation.evaluate(
                handle.source, control: built.control, options: options)
            atTheHairline = max(
                atTheHairline, Double(hypot(f.x - handle.source.x, f.y - handle.source.y)))
        }
        // At the frame's own corners and edge midpoints.
        var atTheBorder = 0.0
        for point in [
            CGPoint(x: 0, y: 0), CGPoint(x: imageSize.width, y: 0),
            CGPoint(x: 0, y: imageSize.height),
            CGPoint(x: imageSize.width, y: imageSize.height),
            CGPoint(x: imageSize.width / 2, y: 0),
            CGPoint(x: imageSize.width / 2, y: imageSize.height),
        ] {
            let f = MLSDeformation.evaluate(point, control: built.control, options: options)
            atTheBorder = max(atTheBorder, Double(hypot(f.x - point.x, f.y - point.y)))
        }
        print(
            "P6.2 head locality, volume=100: |f(v) − v| = \(atTheHairline) px on the "
                + "silhouette, \(atTheBorder) px on the frame border")
        #expect(atTheHairline > 1, "the silhouette barely moved: \(atTheHairline) px")
        #expect(atTheBorder < 0.001, "the frame border moved \(atTheBorder) px")
    }

    @Test("Two heads in one frame are both reshaped")
    func twoHeadsAreBothReshaped() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterHeadRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableHeadAndWarp() } }

        let a = SyntheticHead.make(
            faceWidth: 90, centre: CGPoint(x: 110, y: 130), width: 360, height: 240)
        let b = SyntheticHead.make(
            faceWidth: 70, centre: CGPoint(x: 250, y: 128), width: 360, height: 240)
        let node = try WarpRenderNode(context: context)
        let imageSize = CGSize(width: 360, height: 240)
        let one = try #require(
            node.headControlPoints(
                for: SyntheticHead.request(Self.allHead, faces: [a.face]),
                imageSize: imageSize))
        let two = try #require(
            node.headControlPoints(
                for: SyntheticHead.request(Self.allHead, faces: [a.face, b.face]),
                imageSize: imageSize))
        #expect(two.faceMeshHandleCount == one.faceMeshHandleCount * 2)
        #expect(two.hairHandleCount > one.hairHandleCount)
        #expect(two.borderAnchorCount == one.borderAnchorCount)
    }

    // MARK: - Helper

    /// Encodes the node once over a synthetic image the size of the head fixture
    /// and reads the result back as float32, returning the (quantised) source
    /// alongside so a bit-exactness check compares like with like.
    static func run(
        _ node: WarpRenderNode, context: MetalContext, request: RenderRequest,
        head: SyntheticHead.Head
    ) throws -> (source: [Float], output: [Float]) {
        let pixels = SpikeTextureIO.float16ToFloat32(
            SpikeTextureIO.float32ToFloat16(
                SpikeS3Support.syntheticImage(
                    width: head.width, height: head.height, seed: 41)))
        let source = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: head.width, height: head.height,
            device: context.device, usage: [.shaderRead, .shaderWrite])
        let destination = try SpikeTextureIO.makeTexture(
            width: head.width, height: head.height, device: context.device,
            pixelFormat: .rgba32Float, usage: [.shaderRead, .shaderWrite, .renderTarget])
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw MetalContext.Failure.noCommandQueue
        }
        try node.encode(
            into: commandBuffer, source: source, destination: destination, request: request)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return (pixels, try RenderGraph.readFloat32(destination, queue: context.commandQueue))
    }
}

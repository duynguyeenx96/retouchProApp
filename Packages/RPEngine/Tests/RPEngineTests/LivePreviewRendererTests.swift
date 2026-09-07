import CoreGraphics
import Foundation
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 2 — the live preview path, and specifically **that wiring it up changed
/// nothing about what the graph produces**.
///
/// The reviewer's checklist for this item is coordinate spaces, colour space and
/// bit depth: three ways a UI layer can silently corrupt a pipeline that was
/// already measured correct. So the load-bearing test here is not a PSNR against
/// a new reference — the four slider groups already have those — it is
/// `livePreviewMatchesRenderGraphExactly`, which runs the same `RenderRequest`
/// through `LivePreviewRenderer` and through `RenderGraph.renderPixels` and
/// requires **max abs difference == 0**. If the UI path picked up an extra
/// colour-space conversion, a flip or an 8-bit round trip, that number cannot be
/// zero.
///
/// `.serialized` because `RPEngineFeatureFlags` is process-global (ADR-0006).
@Suite("Phase 2 live preview", .serialized)
struct LivePreviewRendererTests {
    static let width = 160
    static let height = 120

    /// The fixture **as a decoded 8-bit sRGB `CGImage`** — the shape
    /// `ImageDecoder` hands the canvas for a JPEG — because that is the input the
    /// live path really takes. Starting from a float array would skip the CPU
    /// conversion that is exactly where a colour-space bug would hide.
    static let image: CGImage = LivePreviewFixture.sRGBImage(
        width: width, height: height, seed: 9091)

    /// The same image as interleaved RGBA float32, already quantised to
    /// half-float. Both the control and the live path start here, so the
    /// comparison measures the *wiring* and not the decode
    /// (`SkinRenderNodeTests` quantises for the same reason: the GPU source is
    /// rgba16Float and an unquantised reference would be charged 5e-4 of upload
    /// rounding the renderer did not cause).
    static let pixels: [Float] = {
        let converted = try! SpikeTextureIO.floatPixels(
            of: image, space: RenderQuality.preview.pixelSpace)
        return SpikeTextureIO.float16ToFloat32(
            SpikeTextureIO.float32ToFloat16(converted.pixels))
    }()

    static func sourceImage() throws -> CGImage { Self.image }

    /// A `Color`-only edit: it needs no face, so this test does not depend on
    /// RPVision or on a mask fixture, and it exercises a real node rather than
    /// the passthrough branch.
    static var colourEdit: EditState {
        var state = EditState()
        ColorSliders(exposure: 40, contrast: 30, saturation: 55).write(into: &state)
        return state
    }

    // MARK: - The wiring test

    @Test("The live preview's output is bit-identical to RenderGraph.renderPixels")
    func livePreviewMatchesRenderGraphExactly() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let graph = try RenderGraph.standard(context: context)
        #expect(graph.nodes.map(\.name) == ["color"])
        let request = RenderRequest(editState: Self.colourEdit, faces: [], quality: .preview)

        // Control: the path every golden number in ADR-0009…0012 was measured on.
        let (control, controlReport) = try graph.renderPixels(
            Self.pixels, width: Self.width, height: Self.height, request: request)
        #expect(controlReport.nodes == ["color"])

        // The wired path: CGImage -> texture -> graph -> texture -> readback.
        // Same output format as the control (`renderPixels` uses rgba32Float on
        // purpose), so the comparison is of the *wiring* and nothing else.
        let renderer = LivePreviewRenderer(
            context: context, graph: graph, outputPixelFormat: .rgba32Float)
        try renderer.prewarm()
        try renderer.setSource(Self.sourceImage())
        let report = try renderer.render(request)
        #expect(report.nodes == controlReport.nodes)
        let live = try renderer.readOutputPixels()

        let worst = SpikeTextureIO.maxAbsoluteDifference(control, live)
        print("P2 live preview vs RenderGraph.renderPixels: max abs diff = \(worst)")
        // Not "small" — zero. An extra colour-space conversion, a vertical flip
        // or an 8-bit round trip in the UI path all make this non-zero.
        #expect(worst == 0)
    }

    /// The one thing the interactive path does differ by, stated with a number
    /// rather than left implicit: it renders into `rgba16Float`.
    @Test("The interactive 16-bit output differs from float32 only by half-float rounding")
    func sixteenBitOutputCostsOnlyHalfFloatQuantisation() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let graph = try RenderGraph.standard(context: context)
        let request = RenderRequest(editState: Self.colourEdit, faces: [], quality: .preview)
        let (control, _) = try graph.renderPixels(
            Self.pixels, width: Self.width, height: Self.height, request: request)

        let renderer = LivePreviewRenderer(context: context, graph: graph)  // rgba16Float
        try renderer.setSource(Self.sourceImage())
        try renderer.render(request)
        let live = try renderer.readOutputPixels()

        let worst = SpikeTextureIO.maxAbsoluteDifference(control, live)
        let psnr = SpikeTextureIO.psnr(control, live)
        print("P2 live preview 16F vs 32F: max abs diff = \(worst), PSNR = \(psnr) dB")
        // One half-float step near 1.0 is 2^-11 = 4.88e-4; nothing may exceed it.
        #expect(worst <= 4.883e-4)
        // …and the plan's golden bar is still cleared by a wide margin.
        #expect(psnr >= 45)
    }

    @Test("An empty EditState still puts the source on screen, bit-exact")
    func emptyEditStateIsPassthrough() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.colorSliders = false
            RPEngineFeatureFlags.skinSliders = false
            RPEngineFeatureFlags.warpSliders = false
            RPEngineFeatureFlags.eyesTeethSliders = false
        }
        defer { flags.leave { RPEngineFeatureFlags.disableSkinRenderGraph() } }

        let renderer = try LivePreviewRenderer(context: context)
        try renderer.setSource(Self.sourceImage())
        let report = try renderer.render(RenderRequest())
        #expect(report.isPassthrough)
        let out = try renderer.readOutputPixels()
        #expect(SpikeTextureIO.maxAbsoluteDifference(Self.pixels, out) == 0)
    }

    // MARK: - Presentation

    @Test("Presenting at 1:1 into a same-size drawable is exact")
    func presentIsExactAtOneToOne() throws {
        guard let context = SpikeS3Support.context else { return }
        let renderer = try LivePreviewRenderer(context: context)
        try renderer.prewarm()
        try renderer.setSource(Self.sourceImage())
        try renderer.render(RenderRequest())

        // rgba16Float, not bgra8Unorm: this test is about the *sampling*
        // geometry, and an 8-bit drawable would fold 1/255 quantisation into the
        // number. The real drawable's precision is stated in
        // LivePreviewRenderer's doc comment and is a display choice, not a
        // pipeline one.
        let drawable = try SpikeTextureIO.makeTexture(
            width: Self.width, height: Self.height, device: context.device,
            pixelFormat: .rgba16Float, usage: [.shaderRead, .shaderWrite, .renderTarget])
        try renderer.present(
            into: drawable,
            placement: .identity(size: CGSize(width: Self.width, height: Self.height)))

        let shown = try SpikeTextureIO.floatPixels(of: drawable, queue: context.commandQueue)
        // Alpha is forced to 1 by the present pass (a drawable is opaque), so
        // compare the three colour channels.
        var worst = 0.0
        for i in stride(from: 0, to: shown.count, by: 4) {
            for c in 0..<3 {
                worst = max(worst, abs(Double(shown[i + c]) - Double(Self.pixels[i + c])))
            }
        }
        print("P2 live preview present @1:1: max abs diff = \(worst)")
        #expect(worst == 0)
    }

    @Test("Outside the image rectangle the drawable gets the background colour")
    func presentFillsTheBackground() throws {
        guard let context = SpikeS3Support.context else { return }
        let renderer = try LivePreviewRenderer(context: context)
        try renderer.prewarm()
        try renderer.setSource(Self.sourceImage())
        try renderer.render(RenderRequest())

        let side = 64
        let drawable = try SpikeTextureIO.makeTexture(
            width: side, height: side, device: context.device, pixelFormat: .rgba16Float,
            usage: [.shaderRead, .shaderWrite, .renderTarget])
        // Image occupies the top-left quarter; the rest must be background.
        let background = SIMD4<Float>(0.25, 0.5, 0.75, 1)
        try renderer.present(
            into: drawable,
            placement: PreviewPlacement(
                destinationSize: CGSize(width: side, height: side),
                imageRect: CGRect(x: 0, y: 0, width: 32, height: 32),
                background: background))

        let shown = try SpikeTextureIO.floatPixels(of: drawable, queue: context.commandQueue)
        func pixel(_ x: Int, _ y: Int) -> (Float, Float, Float) {
            let i = (y * side + x) * 4
            return (shown[i], shown[i + 1], shown[i + 2])
        }
        let outside = pixel(50, 50)
        #expect(abs(outside.0 - background.x) < 1e-3)
        #expect(abs(outside.1 - background.y) < 1e-3)
        #expect(abs(outside.2 - background.z) < 1e-3)
        // …and inside it is not the background.
        let inside = pixel(10, 10)
        #expect(
            abs(inside.0 - background.x) > 1e-3 || abs(inside.1 - background.y) > 1e-3
                || abs(inside.2 - background.z) > 1e-3)
    }

    @Test("Panning changes only the placement, so no graph work is repeated")
    func panningDoesNotRerunTheGraph() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let renderer = try LivePreviewRenderer(context: context)
        try renderer.prewarm()
        try renderer.setSource(Self.sourceImage())
        let request = RenderRequest(editState: Self.colourEdit, faces: [], quality: .preview)
        try renderer.render(request)
        let first = try renderer.readOutputPixels()

        let drawable = try SpikeTextureIO.makeTexture(
            width: 80, height: 60, device: context.device, pixelFormat: .rgba16Float,
            usage: [.shaderRead, .shaderWrite, .renderTarget])
        for dx in [0, 17, -33] {
            try renderer.present(
                into: drawable,
                placement: PreviewPlacement(
                    destinationSize: CGSize(width: 80, height: 60),
                    imageRect: CGRect(x: dx, y: 0, width: 160, height: 120)))
        }
        // The graph output is untouched by presenting.
        #expect(SpikeTextureIO.maxAbsoluteDifference(first, try renderer.readOutputPixels()) == 0)
    }

    // MARK: - Lifecycle

    @Test("Rendering without a source is an error, not a crash")
    func renderingWithoutASourceThrows() throws {
        guard let context = SpikeS3Support.context else { return }
        let renderer = try LivePreviewRenderer(context: context)
        #expect(renderer.hasSource == false)
        #expect(throws: LivePreviewRenderer.Failure.self) { try renderer.render(RenderRequest()) }
    }

    @Test("Switching shots replaces the source and its output")
    func switchingShotsReplacesTheSource() throws {
        guard let context = SpikeS3Support.context else { return }
        let renderer = try LivePreviewRenderer(context: context)
        try renderer.setSource(Self.sourceImage())
        #expect(renderer.sourceSize == CGSize(width: Self.width, height: Self.height))
        try renderer.render(RenderRequest())
        #expect(renderer.outputTexture != nil)

        let otherImage = LivePreviewFixture.sRGBImage(width: 64, height: 48, seed: 5)
        try renderer.setSource(otherImage)
        #expect(renderer.sourceSize == CGSize(width: 64, height: 48))
        // The old output must be gone, not reused at the wrong size.
        #expect(renderer.outputTexture == nil)
        try renderer.render(RenderRequest())
        #expect(renderer.outputTexture?.width == 64)

        renderer.clearSource()
        #expect(renderer.hasSource == false)
    }

    @Test("The present parameter struct has the layout PreviewShaders.metal declares")
    func presentParamsMatchShaderLayout() {
        // uint2(8) + float2(8) + float2(8) + pad(8) + float4(16) + uint(4) -> 64
        #expect(MemoryLayout<LivePreviewRenderer.PresentParams>.stride == 64)
    }

    @Test("Zoom decides the sampling filter: linear when shrunk, nearest at 1:1")
    func filterFollowsZoom() {
        var shrunk = PreviewPlacement(
            destinationSize: CGSize(width: 100, height: 100),
            imageRect: CGRect(x: 0, y: 0, width: 100, height: 75))
        shrunk.sourceWidth = 200
        #expect(shrunk.wantsLinearFilter)

        var oneToOne = PreviewPlacement.identity(size: CGSize(width: 200, height: 150))
        oneToOne.sourceWidth = 200
        #expect(oneToOne.wantsLinearFilter == false)

        var zoomedIn = PreviewPlacement(
            destinationSize: CGSize(width: 200, height: 200),
            imageRect: CGRect(x: 0, y: 0, width: 400, height: 300))
        zoomedIn.sourceWidth = 200
        #expect(zoomedIn.wantsLinearFilter == false)
    }
}

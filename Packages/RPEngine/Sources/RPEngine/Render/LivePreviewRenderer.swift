import CoreGraphics
import Foundation
import Metal
import RPCore

/// Where the edited picture goes inside the drawable, in **drawable pixels**.
///
/// The canvas owns zoom and pan (`RPUI.CanvasViewport`); this type is the only
/// thing about them the engine is told, so the engine has no opinion about
/// gestures and the UI has no opinion about Metal.
public struct PreviewPlacement: Sendable, Equatable {
    /// Size of the drawable, in pixels (points × screen scale).
    public var destinationSize: CGSize
    /// Rectangle the image occupies inside it, in the same pixels. May be
    /// larger than the drawable (zoomed in) or partly outside it (panned).
    public var imageRect: CGRect
    /// Colour behind the image. sRGB-encoded, matching the value space of the
    /// pipeline (`RenderQuality.pixelSpace`).
    public var background: SIMD4<Float>

    public init(
        destinationSize: CGSize,
        imageRect: CGRect,
        background: SIMD4<Float> = SIMD4<Float>(0.08, 0.08, 0.08, 1)
    ) {
        self.destinationSize = destinationSize
        self.imageRect = imageRect
        self.background = background
    }

    /// Fills the drawable with the image at 1:1 — the placement the golden test
    /// uses, because it is the only one where presentation must be exact.
    public static func identity(size: CGSize) -> PreviewPlacement {
        PreviewPlacement(
            destinationSize: size,
            imageRect: CGRect(origin: .zero, size: size))
    }

    /// `true` when the image is drawn at (or above) 1:1, in which case the
    /// present pass takes nearest-neighbour sampling: at 100 % zoom the user is
    /// pixel-peeping and a bilinear tap would show them a blur that is not in
    /// their file. Below 1:1 it takes the linear filter.
    var wantsLinearFilter: Bool {
        guard imageRect.width > 0, sourceWidth > 0 else { return true }
        return imageRect.width / CGFloat(sourceWidth) < 0.999
    }

    /// Set by ``LivePreviewRenderer`` before the check above; not part of the
    /// value the UI constructs.
    var sourceWidth: Int = 0
}

/// The interactive preview: one decoded shot on the GPU, the real
/// ``RenderGraph`` over it, and the result placed into an `MTKView` drawable.
///
/// ## What this adds to `RenderGraph`, and what it deliberately does not
///
/// `RenderGraph.render(source:destination:request:)` is already the whole
/// pipeline. What it does not have is the two things a live canvas needs:
///
/// 1. **A source texture that outlives the frame.** `renderPixels` uploads and
///    reads back on every call — hundreds of milliseconds for a 24 MP file — and
///    a slider drag issues 30–60 renders a second on the *same* pixels. Here the
///    shot is decoded and uploaded once (``setSource(_:)``), and a redraw is
///    graph-only.
/// 2. **Presentation.** The graph renders into a texture the size of the image;
///    a drawable is the size of the *view* and the image sits inside it wherever
///    zoom and pan put it. That is the `rp_preview_present` pass, which is a
///    placement + resample copy and contains no retouch maths.
///
/// It contains **no** face analysis, no decode policy and no cache: RPEngine
/// still does not import RPVision (docs/ADR-0007), and faces arrive as the plain
/// `FaceRenderInput` value type through ``FaceInputProviding``.
///
/// ## Colour and precision
///
/// The graph's working texture is `rgba16Float` holding **sRGB-encoded** values
/// (`RenderQuality.pixelSpace`, mandated by ADR-0007). The drawable is
/// `bgra8Unorm` with an sRGB colour space — **not** `bgra8Unorm_srgb`, which
/// would encode a second time. So the preview shown on screen is 8-bit; the
/// pipeline behind it is 16-bit float and export (Phase 3) reads the 16-bit
/// texture, never the drawable. `LivePreviewRendererTests` pins both halves:
/// the graph output is bit-identical to `RenderGraph.renderPixels` with the same
/// request, and the present pass at 1:1 is exact.
///
/// Not `@MainActor`: the class is used from the main actor by the SwiftUI canvas
/// but holds only Metal objects, and `MTKView`'s draw callback is where the work
/// happens. It serialises itself with a lock, like ``RenderGraph``.
public final class LivePreviewRenderer: @unchecked Sendable {
    public let context: MetalContext
    public let graph: RenderGraph
    /// Quality the graph runs at. `.preview` — 2048 px long edge,
    /// guided subsample 4, mesh grid 65 (`RenderQuality`, ADR-0007).
    public let quality: RenderQuality
    /// Format of the texture the graph renders into.
    ///
    /// `rgba16Float` on the interaction path: it halves the bandwidth of the
    /// biggest texture in the loop, and the picture goes to an 8-bit drawable
    /// afterwards anyway. `rgba32Float` exists for the golden test, which
    /// compares against `RenderGraph.renderPixels` — that method renders into
    /// float32 precisely so a golden number is not capped by half-float output
    /// quantisation, and matching it is what lets the comparison demand **zero**
    /// difference instead of "under 5e-4". A Phase 3 export renderer would pick
    /// its own format here too.
    public let outputPixelFormat: MTLPixelFormat

    private let lock = NSLock()
    private var source: (any MTLTexture)?
    private var output: (any MTLTexture)?
    /// Last report, so a HUD or a test can read what actually ran.
    private var lastReport = RenderReport()
    /// Bumped whenever ``render(_:)`` produces new pixels in ``output``.
    private var outputGeneration = 0

    public enum Failure: Error, CustomStringConvertible {
        case noSource
        case sourceTooLarge(width: Int, height: Int)

        public var description: String {
            switch self {
            case .noSource: "LivePreviewRenderer has no source image; call setSource first."
            case .sourceTooLarge(let w, let h):
                "A \(w)x\(h) source is larger than this device's maximum texture size."
            }
        }
    }

    public init(
        context: MetalContext, graph: RenderGraph, quality: RenderQuality = .preview,
        outputPixelFormat: MTLPixelFormat = .rgba16Float
    ) {
        self.context = context
        self.graph = graph
        self.quality = quality
        self.outputPixelFormat = outputPixelFormat
    }

    /// The renderer the app ships: `RenderGraph.standard`, i.e. exactly the
    /// nodes whose feature flags are on.
    public convenience init(
        context: MetalContext, quality: RenderQuality = .preview,
        outputPixelFormat: MTLPixelFormat = .rgba16Float
    ) throws {
        self.init(
            context: context, graph: try RenderGraph.standard(context: context),
            quality: quality, outputPixelFormat: outputPixelFormat)
    }

    /// Builds every pipeline the graph can use, plus the present pass.
    ///
    /// Off the interaction path, once. Without it the first slider drag pays the
    /// shader compile — 236 ms on macOS, **1798 ms in the Simulator**
    /// (ADR-0007) — and reads as a frozen UI.
    public func prewarm() throws {
        try graph.prewarm()
        _ = try context.computePipeline("rp_preview_present")
        _ = try context.computePipeline("rp_render_copy")
    }

    // MARK: - Source

    /// Uploads a decoded image as the shot being edited.
    ///
    /// Call once per shot, off the interaction path: this is a CPU float32
    /// conversion plus a blit, tens of milliseconds at preview size. The caller
    /// is expected to have decoded at ``RenderQuality/preferredLongEdge``
    /// already — nothing here resizes, because a resample the engine chose and
    /// the UI did not know about is how a mask ends up half a face out.
    public func setSource(_ image: CGImage) throws {
        let limit = 16384
        guard image.width <= limit, image.height <= limit else {
            throw Failure.sourceTooLarge(width: image.width, height: image.height)
        }
        let converted = try SpikeTextureIO.floatPixels(of: image, space: quality.pixelSpace)
        let texture = try SpikeTextureIO.makeTexture(
            fromFloatPixels: converted.pixels, width: converted.width, height: converted.height,
            device: context.device, usage: [.shaderRead, .shaderWrite])
        lock.lock()
        defer { lock.unlock() }
        source = texture
        output = nil
        lastReport = RenderReport()
        outputGeneration = 0
    }

    /// Drops the shot and every texture that belongs to it.
    public func clearSource() {
        lock.lock()
        defer { lock.unlock() }
        source = nil
        output = nil
        graph.releaseIntermediates()
    }

    /// Pixel size of the uploaded shot, or `nil` when there is none.
    public var sourceSize: CGSize? {
        lock.lock()
        defer { lock.unlock() }
        guard let source else { return nil }
        return CGSize(width: source.width, height: source.height)
    }

    public var hasSource: Bool { sourceSize != nil }

    /// What the last ``render(_:)`` did.
    public var report: RenderReport {
        lock.lock()
        defer { lock.unlock() }
        return lastReport
    }

    // MARK: - Render

    /// Runs the graph over the uploaded shot.
    ///
    /// This is the whole per-slider-change cost: no decode, no upload, no face
    /// analysis. `RenderRequest.faces` must already be scaled to the source
    /// texture (`FaceRenderInput.scaled(by:)`) — the graph's own contract.
    @discardableResult
    public func render(_ request: RenderRequest) throws -> RenderReport {
        lock.lock()
        guard let source else {
            lock.unlock()
            throw Failure.noSource
        }
        let destination: any MTLTexture
        if let output, output.width == source.width, output.height == source.height {
            destination = output
        } else {
            destination = try SpikeTextureIO.makeTexture(
                width: source.width, height: source.height, device: context.device,
                pixelFormat: outputPixelFormat,
                usage: [.shaderRead, .shaderWrite, .renderTarget])
            output = destination
        }
        lock.unlock()

        let report = try graph.render(source: source, destination: destination, request: request)

        lock.lock()
        lastReport = report
        outputGeneration &+= 1
        lock.unlock()
        return report
    }

    /// The graph's output texture — the edited picture at source resolution,
    /// `rgba16Float`, sRGB-encoded values.
    ///
    /// This, not the drawable, is what a golden test and (in Phase 3) the export
    /// path read.
    public var outputTexture: (any MTLTexture)? {
        lock.lock()
        defer { lock.unlock() }
        return output
    }

    /// Reads the output back as interleaved RGBA float32, row 0 at the top.
    /// Test / bench only — it stalls the GPU.
    public func readOutputPixels() throws -> [Float] {
        guard let output = outputTexture else { throw Failure.noSource }
        if output.pixelFormat == .rgba32Float {
            return try RenderGraph.readFloat32(output, queue: context.commandQueue)
        }
        return try SpikeTextureIO.floatPixels(of: output, queue: context.commandQueue)
    }

    // MARK: - Present

    /// Copies the last render into `destination` (an `MTKView` drawable) at
    /// `placement`.
    ///
    /// Separate from ``render(_:)`` on purpose: panning and zooming change the
    /// placement without changing a single slider, and re-running the graph for
    /// a pan would be the whole cost of a frame for none of the benefit.
    public func present(into destination: any MTLTexture, placement: PreviewPlacement) throws {
        lock.lock()
        let picture = output ?? source
        lock.unlock()
        guard let picture else { throw Failure.noSource }

        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw MetalContext.Failure.noCommandQueue
        }
        try encodePresent(
            into: commandBuffer, source: picture, destination: destination, placement: placement)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// The present pass, without committing — so the canvas can put the present
    /// and the drawable's `present()` in one command buffer.
    public func encodePresent(
        into commandBuffer: any MTLCommandBuffer,
        source picture: any MTLTexture,
        destination: any MTLTexture,
        placement: PreviewPlacement
    ) throws {
        let pipeline = try context.computePipeline("rp_preview_present")
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(picture, index: 0)
        encoder.setTexture(destination, index: 1)
        var sized = placement
        sized.sourceWidth = picture.width
        var params = PresentParams(
            destinationSize: SIMD2<UInt32>(
                UInt32(destination.width), UInt32(destination.height)),
            origin: SIMD2<Float>(
                Float(placement.imageRect.origin.x), Float(placement.imageRect.origin.y)),
            size: SIMD2<Float>(
                Float(placement.imageRect.width), Float(placement.imageRect.height)),
            background: placement.background,
            linearFilter: sized.wantsLinearFilter ? 1 : 0)
        encoder.setBytes(&params, length: MemoryLayout<PresentParams>.stride, index: 0)
        let dispatch = MetalContext.threadgroups(
            forWidth: destination.width, height: destination.height, pipeline: pipeline)
        encoder.dispatchThreadgroups(
            dispatch.threadgroups, threadsPerThreadgroup: dispatch.threadsPerThreadgroup)
        encoder.endEncoding()
    }

    /// The drawable's own render + present, in one command buffer. Returns the
    /// command buffer so the caller can add `present(drawable)` and commit.
    public func makePresentCommandBuffer(
        into destination: any MTLTexture, placement: PreviewPlacement
    ) throws -> any MTLCommandBuffer {
        lock.lock()
        let picture = output ?? source
        lock.unlock()
        guard let picture else { throw Failure.noSource }
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw MetalContext.Failure.noCommandQueue
        }
        try encodePresent(
            into: commandBuffer, source: picture, destination: destination, placement: placement)
        return commandBuffer
    }

    /// Must match `RPPreviewPresentParams` in PreviewShaders.metal.
    struct PresentParams {
        var destinationSize: SIMD2<UInt32>
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        var background: SIMD4<Float>
        var linearFilter: UInt32
    }
}

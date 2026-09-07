import CoreGraphics
import Foundation
import Metal
import RPCore

/// Where a node sits in the pipeline docs/PLAN.md §2 fixes:
/// `Decode → Color → Skin → Warp(MLS) → Eyes/Teeth → Makeup → Output`.
///
/// The raw values are the sort key, spaced so a stage can be inserted without
/// renumbering the ones around it.
public enum RenderStage: Int, Sendable, Comparable, CaseIterable {
    case color = 100
    case skin = 200
    case warp = 300
    case eyesTeeth = 400
    case makeup = 500

    public static func < (lhs: RenderStage, rhs: RenderStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Everything a render needs besides the pixels.
public struct RenderRequest: Sendable {
    /// The document. Each node reads its own section out of it.
    public var editState: EditState
    /// Faces **already scaled to the texture being rendered**
    /// (`FaceRenderInput.scaled(by:)`). The graph does not scale them itself: it
    /// never sees the original image size, only the texture it was handed, and
    /// guessing a scale from an aspect ratio is how a mask ends up half a face
    /// out of place.
    public var faces: [FaceRenderInput]
    public var quality: RenderQuality

    public init(
        editState: EditState = EditState(), faces: [FaceRenderInput] = [],
        quality: RenderQuality = .preview
    ) {
        self.editState = editState
        self.faces = faces
        self.quality = quality
    }
}

/// One step of the pipeline.
///
/// A node is a long-lived object: it owns its pipelines and its scratch
/// textures, because a slider drag re-renders the same size 30–60 times a second
/// and re-allocating a 24 MP intermediate per frame is not free.
public protocol RenderNode: AnyObject, Sendable {
    /// Stable identifier, used in ``RenderReport`` and in the bench JSON.
    var name: String { get }
    var stage: RenderStage { get }

    /// `false` when this node cannot change a single pixel for this request, in
    /// which case the graph skips it entirely — no dispatch, no allocation.
    /// **This is where "sliders default 0" is enforced cheaply.**
    func isActive(for request: RenderRequest) -> Bool

    /// Builds every pipeline state the node can use. Called by
    /// ``RenderGraph/prewarm()``.
    func prewarm() throws

    /// Encodes the node. `source` and `destination` are distinct textures of the
    /// same size and format.
    func encode(
        into commandBuffer: any MTLCommandBuffer,
        source: any MTLTexture,
        destination: any MTLTexture,
        request: RenderRequest
    ) throws
}

/// What one `render` call did. Recorded so a bench or a UI overlay never has to
/// guess which nodes ran.
public struct RenderReport: Sendable, Equatable {
    public var nodes: [String] = []
    /// GPU time for the whole command buffer, milliseconds. 0 when the graph had
    /// nothing to do (it still blits, but the caller wants to know it was empty).
    public var gpuMilliseconds: Double = 0
    /// Bytes of intermediate textures the graph itself is holding (node-owned
    /// scratch is reported by the node, not here).
    public var poolBytes: Int = 0
    public var isPassthrough: Bool { nodes.isEmpty }
}

public enum RenderGraphError: Error, CustomStringConvertible {
    case sizeMismatch
    case cannotAllocate(bytes: Int)
    case inconsistentMaskSize

    public var description: String {
        switch self {
        case .sizeMismatch: "Source and destination textures must have the same size."
        case .cannotAllocate(let bytes): "Could not allocate a \(bytes)-byte intermediate texture."
        case .inconsistentMaskSize:
            "All RenderMasks in one request must have the same pixel size (they come from "
                + "one parsing crop size)."
        }
    }
}

/// The editable pipeline: decoded pixels + `FaceAnalysis`-derived masks + slider
/// values in, rendered pixels out.
///
/// **Not itself feature-flagged.** Every node is gated by its own flag
/// (`colorSliders`, `skinSliders`, `warpSliders`, `eyesTeethSliders`, plus the
/// kernels' `guidedFilter` / `mlsMeshWarp`), and with all of them off
/// `standard(context:)` returns a graph
/// with no nodes, which copies the picture through. There used to be an umbrella
/// `RPEngineFeatureFlags.renderGraph` here; it was one stored bit shared by two
/// independently shippable groups, so disabling either group switched the other
/// off. See `RPEngineFeatureFlags.enableSkinRenderGraph()` and docs/ADR-0010.
///
/// ### What this type is for
/// The two Metal kernels spike S3 verified (`GuidedFilter`, `MLSMeshWarp`) are
/// standalone `encode(into:)` calls. Composing them into an *editable* pipeline
/// needs three things they do not have: a rule for which passes run at all
/// (sliders default to 0 and must cost nothing there), somewhere to keep the
/// ping-pong intermediates across frames, and a fixed stage order so a preset
/// renders the same way twice. That is all this class is.
public final class RenderGraph: @unchecked Sendable {
    public let context: MetalContext
    /// Sorted by ``RenderStage``, so registration order cannot change the picture.
    public private(set) var nodes: [any RenderNode]

    private let lock = NSLock()
    private var pool: [any MTLTexture] = []
    private var poolWidth = 0
    private var poolHeight = 0
    private var poolFormat: MTLPixelFormat = .rgba16Float

    public init(context: MetalContext, nodes: [any RenderNode]) {
        self.context = context
        self.nodes = nodes.sorted { $0.stage < $1.stage }
    }

    /// The graph Phase 2 ships so far: the "Color", "Da", "Mặt" and
    /// "Mắt / Răng" groups. Makeup is Phase 5 and is deliberately absent rather
    /// than stubbed — an inert node in the list would still show up in
    /// `RenderReport` and in the bench JSON.
    ///
    /// **Each node is registered only if its own flag is on.** The groups ship
    /// independently (`colorSliders`, `skinSliders`, `warpSliders`,
    /// `eyesTeethSliders`), so a
    /// caller that enabled one of them must not get a throw about the others, and
    /// turning one off must not disturb the others
    /// (`RenderGraphTests.disablingOneGroupLeavesTheOtherRunning`,
    /// `.disablingTheSkinGroupLeavesTheEyesTeethGroupRunning`).
    /// `RenderReport.nodes` says which nodes actually ran, and
    /// `activeNodes(for:)` says which would. With every group flag off this
    /// returns an empty graph: a passthrough copy, not a throw.
    public static func standard(context: MetalContext) throws -> RenderGraph {
        var nodes: [any RenderNode] = []
        if RPEngineFeatureFlags.colorSliders {
            nodes.append(try ColorRenderNode(context: context))
        }
        if RPEngineFeatureFlags.skinSliders {
            nodes.append(try SkinRenderNode(context: context))
        }
        if RPEngineFeatureFlags.warpSliders {
            nodes.append(try WarpRenderNode(context: context))
        }
        if RPEngineFeatureFlags.eyesTeethSliders {
            nodes.append(try EyesTeethRenderNode(context: context))
        }
        return RenderGraph(context: context, nodes: nodes)
    }

    /// Builds every pipeline up front.
    ///
    /// Call this once, off the interaction path. `MetalContext` compiles the
    /// shader source lazily on first use and caches `MTLComputePipelineState` by
    /// name, so without this the *first* slider drag pays 236 ms on macOS and
    /// **1798 ms in the iOS Simulator** (ADR-0007) and reads as a frozen UI.
    public func prewarm() throws {
        for node in nodes { try node.prewarm() }
    }

    /// Which nodes would run. Cheap — no GPU work, no allocation.
    public func activeNodes(for request: RenderRequest) -> [any RenderNode] {
        nodes.filter { $0.isActive(for: request) }
    }

    /// Renders `source` into `destination`.
    ///
    /// With no active node this is a blit, not a no-op: the caller asked for the
    /// picture in `destination` and an empty `EditState` still has to put it
    /// there. `RenderReport.isPassthrough` says which happened.
    @discardableResult
    public func render(
        source: any MTLTexture, destination: any MTLTexture, request: RenderRequest
    ) throws -> RenderReport {
        guard source.width == destination.width, source.height == destination.height else {
            throw RenderGraphError.sizeMismatch
        }
        let active = activeNodes(for: request)
        var report = RenderReport(nodes: active.map(\.name))

        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw MetalContext.Failure.noCommandQueue
        }

        if active.isEmpty {
            try RenderGraph.encodeCopy(
                into: commandBuffer, context: context, source: source, destination: destination)
        } else {
            // Ping-pong. The last node writes straight into `destination`, so an
            // odd node count costs no extra copy; an even one uses a single pool
            // texture. Two pool textures are only needed from three nodes up.
            let intermediates = max(0, min(2, active.count - 1))
            let scratch = try scratchTextures(
                count: intermediates, like: destination)
            var input = source
            for (index, node) in active.enumerated() {
                let output: any MTLTexture =
                    index == active.count - 1 ? destination : scratch[index % max(1, scratch.count)]
                try node.encode(
                    into: commandBuffer, source: input, destination: output, request: request)
                input = output
            }
            report.poolBytes = poolByteCount()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        report.gpuMilliseconds = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000
        return report
    }

    /// CPU-in, CPU-out convenience for tests, the golden harness and the bench.
    ///
    /// Not the interactive path — it uploads and reads back every call. The
    /// destination is **RGBA32Float** so a golden comparison measures the graph
    /// and not the ~5e-4 of half-float output quantisation.
    public func renderPixels(
        _ pixels: [Float], width: Int, height: Int, request: RenderRequest
    ) throws -> (pixels: [Float], report: RenderReport) {
        let source = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: width, height: height, device: context.device,
            usage: [.shaderRead, .shaderWrite])
        let destination = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: context.device, pixelFormat: .rgba32Float,
            usage: [.shaderRead, .shaderWrite, .renderTarget])
        let report = try render(source: source, destination: destination, request: request)
        return (try Self.readFloat32(destination, queue: context.commandQueue), report)
    }

    /// Copies `source` into `destination` with a compute pass.
    ///
    /// **Not a blit.** `MTLBlitCommandEncoder.copy(from:to:)` requires identical
    /// pixel formats, and the graph's destination is not always the source's
    /// format: `renderPixels` renders an rgba16Float source into an rgba32Float
    /// target so a golden PSNR is not capped by half-float output quantisation.
    /// A blit across those two does not raise — it produces garbage, which is how
    /// this was found (the passthrough test read a max absolute difference of
    /// exactly 1.0). The kernel is exact for that pair: every half-float value is
    /// representable in float32, so "passthrough is bit-exact" still holds.
    static func encodeCopy(
        into commandBuffer: any MTLCommandBuffer, context: MetalContext,
        source: any MTLTexture, destination: any MTLTexture
    ) throws {
        let pipeline = try context.computePipeline("rp_render_copy")
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        var params = RenderCopyParams(
            size: SIMD2<UInt32>(UInt32(source.width), UInt32(source.height)))
        encoder.setBytes(&params, length: MemoryLayout<RenderCopyParams>.stride, index: 0)
        let dispatch = MetalContext.threadgroups(
            forWidth: source.width, height: source.height, pipeline: pipeline)
        encoder.dispatchThreadgroups(
            dispatch.threadgroups, threadsPerThreadgroup: dispatch.threadsPerThreadgroup)
        encoder.endEncoding()
    }

    /// Reads an RGBA32Float texture back as interleaved float32, row 0 at the top.
    public static func readFloat32(
        _ texture: any MTLTexture, queue: any MTLCommandQueue
    ) throws -> [Float] {
        let bytesPerRow = texture.width * 16
        guard
            let buffer = texture.device.makeBuffer(
                length: bytesPerRow * texture.height, options: .storageModeShared),
            let commandBuffer = queue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw MetalContext.Failure.noCommandQueue }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * texture.height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var out = [Float](repeating: 0, count: texture.width * texture.height * 4)
        out.withUnsafeMutableBytes { raw in
            raw.copyMemory(
                from: UnsafeRawBufferPointer(
                    start: buffer.contents(), count: bytesPerRow * texture.height))
        }
        return out
    }

    // MARK: - Intermediate pool

    private func scratchTextures(count: Int, like template: any MTLTexture) throws
        -> [any MTLTexture]
    {
        guard count > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        if poolWidth != template.width || poolHeight != template.height
            || poolFormat != template.pixelFormat
        {
            pool.removeAll()
            poolWidth = template.width
            poolHeight = template.height
            poolFormat = template.pixelFormat
        }
        while pool.count < count {
            pool.append(
                try SpikeTextureIO.makeTexture(
                    width: poolWidth, height: poolHeight, device: context.device,
                    pixelFormat: poolFormat,
                    usage: [.shaderRead, .shaderWrite, .renderTarget]))
        }
        return Array(pool.prefix(count))
    }

    private func poolByteCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let bytesPerPixel = poolFormat == .rgba32Float ? 16 : 8
        return pool.count * poolWidth * poolHeight * bytesPerPixel
    }

    /// Must match `RenderCopyParams` in SkinShaders.metal.
    struct RenderCopyParams {
        var size: SIMD2<UInt32>
    }

    /// Drops the ping-pong intermediates. Call on a memory warning or when the
    /// editor closes a project.
    public func releaseIntermediates() {
        lock.lock()
        defer { lock.unlock() }
        pool.removeAll()
        poolWidth = 0
        poolHeight = 0
    }
}

import CoreGraphics
import Foundation
import Metal

/// GPU mesh warp driven by ``MLSDeformation``.
///
/// Two stages:
/// 1. a compute pass evaluates `f(v)` at every vertex of a coarse lattice
///    (`rp_mls_grid`), which is `O(gridVertices × controlPoints)` rather than
///    `O(pixels × controlPoints)`;
/// 2. a render pass draws that lattice as triangles whose **positions** are
///    `f(v)` and whose **texture coordinates** are the undeformed `v`, so the
///    rasteriser performs the inverse mapping and no per-pixel inverse of `f`
///    has to be solved. This is the construction in Schaefer et al. §5.
///
/// Gated by `RPEngineFeatureFlags.mlsMeshWarp`.
public final class MLSMeshWarp {
    /// Per-size, per-grid GPU buffers, allocated once and reused across frames.
    public final class Resources {
        public let gridWidth: Int
        public let gridHeight: Int
        public let indexCount: Int
        let sourceVertices: any MTLBuffer
        let deformedVertices: any MTLBuffer
        let indices: any MTLBuffer
        var controlSource: (any MTLBuffer)?
        var controlDestination: (any MTLBuffer)?
        var controlCapacity: Int = 0

        init(device: any MTLDevice, gridWidth: Int, gridHeight: Int, imageSize: CGSize) throws {
            precondition(gridWidth >= 2 && gridHeight >= 2)
            self.gridWidth = gridWidth
            self.gridHeight = gridHeight

            let cellsX = Float(gridWidth - 1)
            let cellsY = Float(gridHeight - 1)
            var source = [SIMD2<Float>]()
            source.reserveCapacity(gridWidth * gridHeight)
            for y in 0..<gridHeight {
                for x in 0..<gridWidth {
                    source.append(
                        SIMD2<Float>(
                            Float(x) / cellsX * Float(imageSize.width),
                            Float(y) / cellsY * Float(imageSize.height)))
                }
            }
            var triangles = [UInt32]()
            triangles.reserveCapacity((gridWidth - 1) * (gridHeight - 1) * 6)
            for y in 0..<(gridHeight - 1) {
                for x in 0..<(gridWidth - 1) {
                    let a = UInt32(y * gridWidth + x)
                    let b = a + 1
                    let c = UInt32((y + 1) * gridWidth + x)
                    let d = c + 1
                    triangles += [a, b, c, b, d, c]
                }
            }
            self.indexCount = triangles.count

            // Explicit .storageModeShared: on macOS an MTLBuffer's default mode
            // is .managed, and `readDeformedGrid` reads `deformedVertices`
            // straight out of `contents()`.
            let deformedBytes = MemoryLayout<SIMD2<Float>>.stride * gridWidth * gridHeight
            guard
                let sourceBuffer = source.withUnsafeBytes({
                    device.makeBuffer(
                        bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
                }),
                let indexBuffer = triangles.withUnsafeBytes({
                    device.makeBuffer(
                        bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
                }),
                let deformedBuffer = device.makeBuffer(
                    length: deformedBytes, options: .storageModeShared)
            else { throw MetalContext.Failure.cannotMakeBuffer(bytes: deformedBytes) }
            self.sourceVertices = sourceBuffer
            self.indices = indexBuffer
            self.deformedVertices = deformedBuffer
        }

        func ensureControlCapacity(_ count: Int, device: any MTLDevice) throws {
            guard count > controlCapacity else { return }
            let length = MemoryLayout<SIMD2<Float>>.stride * max(count, 16)
            guard
                let p = device.makeBuffer(length: length, options: .storageModeShared),
                let q = device.makeBuffer(length: length, options: .storageModeShared)
            else { throw MetalContext.Failure.cannotMakeBuffer(bytes: length) }
            controlSource = p
            controlDestination = q
            controlCapacity = max(count, 16)
        }
    }

    private let context: MetalContext
    private let gridPipeline: any MTLComputePipelineState
    private let renderPipeline: any MTLRenderPipelineState

    public init(context: MetalContext, pixelFormat: MTLPixelFormat = .rgba16Float) throws {
        guard RPEngineFeatureFlags.mlsMeshWarp else {
            throw RPEngineFeatureDisabled(feature: "mlsMeshWarp")
        }
        self.context = context
        self.gridPipeline = try context.computePipeline("rp_mls_grid")

        guard
            let vertexFunction = context.library.makeFunction(name: "rp_warp_vertex"),
            let fragmentFunction = context.library.makeFunction(name: "rp_warp_fragment")
        else { throw MetalContext.Failure.functionMissing("rp_warp_vertex/rp_warp_fragment") }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        self.renderPipeline = try context.device.makeRenderPipelineState(descriptor: descriptor)
    }

    public func makeResources(imageSize: CGSize, options: MLSDeformation.Options) throws
        -> Resources
    {
        try Resources(
            device: context.device, gridWidth: options.gridWidth,
            gridHeight: options.gridHeight, imageSize: imageSize)
    }

    /// Fills `resources.deformedVertices` on the GPU. Split out from
    /// ``encode(into:source:destination:resources:control:options:)`` so the
    /// benchmark can time the solve and the draw separately — they scale with
    /// completely different things (control points × grid vs pixels).
    public func encodeGridSolve(
        into commandBuffer: any MTLCommandBuffer,
        resources: Resources,
        control: MLSDeformation.ControlPoints,
        options: MLSDeformation.Options,
        imageSize: CGSize
    ) throws {
        try encodeGridSolve(
            into: commandBuffer, output: resources.deformedVertices, resources: resources,
            control: control, options: options, imageSize: imageSize,
            gridWidth: resources.gridWidth, gridHeight: resources.gridHeight)
    }

    /// Same solve, but writing an arbitrary lattice into `output`. Used by the
    /// benchmark to price a *per-pixel* evaluation (grid == image size) as the
    /// control that says what the mesh actually buys.
    public func encodeGridSolve(
        into commandBuffer: any MTLCommandBuffer,
        output: any MTLBuffer,
        resources: Resources,
        control: MLSDeformation.ControlPoints,
        options: MLSDeformation.Options,
        imageSize: CGSize,
        gridWidth: Int,
        gridHeight: Int
    ) throws {
        try resources.ensureControlCapacity(control.count, device: context.device)
        guard let p = resources.controlSource, let q = resources.controlDestination else { return }
        let sourcePoints = control.source.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        let destinationPoints = control.destination.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        sourcePoints.withUnsafeBytes { p.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        destinationPoints.withUnsafeBytes {
            q.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count)
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(gridPipeline)
        encoder.setBuffer(p, offset: 0, index: 0)
        encoder.setBuffer(q, offset: 0, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        var params = MLSParams(
            controlCount: UInt32(control.count),
            alpha: Float(options.alpha),
            rigid: options.variant == .rigid ? 1 : 0,
            _pad: 0,
            gridSize: SIMD2<UInt32>(UInt32(gridWidth), UInt32(gridHeight)),
            imageSize: SIMD2<Float>(Float(imageSize.width), Float(imageSize.height)))
        encoder.setBytes(&params, length: MemoryLayout<MLSParams>.stride, index: 3)
        let dispatch = MetalContext.threadgroups(
            forWidth: gridWidth, height: gridHeight, pipeline: gridPipeline)
        encoder.dispatchThreadgroups(
            dispatch.threadgroups, threadsPerThreadgroup: dispatch.threadsPerThreadgroup)
        encoder.endEncoding()
    }

    /// Draws the deformed mesh. Assumes ``encodeGridSolve`` already ran into the
    /// same command buffer (or an earlier one).
    public func encodeDraw(
        into commandBuffer: any MTLCommandBuffer,
        source: any MTLTexture,
        destination: any MTLTexture,
        resources: Resources
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(renderPipeline)
        encoder.setVertexBuffer(resources.deformedVertices, offset: 0, index: 0)
        encoder.setVertexBuffer(resources.sourceVertices, offset: 0, index: 1)
        var imageSize = SIMD2<Float>(Float(source.width), Float(source.height))
        encoder.setVertexBytes(&imageSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawIndexedPrimitives(
            type: .triangle, indexCount: resources.indexCount, indexType: .uint32,
            indexBuffer: resources.indices, indexBufferOffset: 0)
        encoder.endEncoding()
    }

    /// Solve + draw.
    public func encode(
        into commandBuffer: any MTLCommandBuffer,
        source: any MTLTexture,
        destination: any MTLTexture,
        resources: Resources,
        control: MLSDeformation.ControlPoints,
        options: MLSDeformation.Options
    ) throws {
        let imageSize = CGSize(width: source.width, height: source.height)
        try encodeGridSolve(
            into: commandBuffer, resources: resources, control: control, options: options,
            imageSize: imageSize)
        encodeDraw(
            into: commandBuffer, source: source, destination: destination, resources: resources)
    }

    /// Reads the solved lattice back to the CPU, in image pixels.
    public func readDeformedGrid(_ resources: Resources) -> [CGPoint] {
        let count = resources.gridWidth * resources.gridHeight
        let pointer = resources.deformedVertices.contents().bindMemory(
            to: SIMD2<Float>.self, capacity: count)
        return (0..<count).map { CGPoint(x: Double(pointer[$0].x), y: Double(pointer[$0].y)) }
    }
}

/// Must match `MLSParams` in Shaders.metal.
struct MLSParams {
    var controlCount: UInt32
    var alpha: Float
    var rigid: UInt32
    var _pad: UInt32
    var gridSize: SIMD2<UInt32>
    var imageSize: SIMD2<Float>
}

import CoreGraphics
import Foundation
import Metal
import RPCore

/// The "Color" slider group — ``RenderStage/color`` on ``RenderGraph``, and the
/// **first** stage of the pipeline docs/PLAN.md §2 fixes
/// (`Decode → Color → Skin → Warp(MLS) → Eyes/Teeth → Makeup → Output`).
///
/// docs/PLAN.md Phase 2: *Exposure, Contrast, Highlights, Shadows, WB, Vibrance,
/// Saturation, Curves, HSL, Auto D&B.* Ten names, 18 sliders (WB is two axes,
/// HSL is eight hue bands — see ``ColorSliders``), all 0–100, all default 0, all
/// exact no-ops at 0.
///
/// ## This node has no face input, on purpose
/// Every other Phase 2 node reads `FaceRenderInput`. A colour grade is global:
/// exposure, white balance and a tone curve apply to the whole frame, and none of
/// the 18 sliders here has a per-face meaning. So `isActive(for:)` ignores
/// `request.faces` entirely and the node works on a frame with **no detected
/// face** — a landscape, a product shot, a back-of-head — which is exactly what
/// it should do and what a forced mask dependency would have broken.
///
/// The one slider with a claim on that decision is **Auto D&B**: the panel this
/// group ports it from (`panelpts/RetouchProUXP`) multiplied its dodge/burn masks
/// by the skin mask. Here it runs on the whole frame. That is a deviation and it
/// is stated in "Known limitations" below, not hidden.
///
/// ## Structure
/// One composite pass, one 4 kB LUT, and — only when "Auto D&B" is up — a small
/// analysis pyramid:
///
/// | input | how | what it is |
/// |---|---|---|
/// | `curveLUT` | ``ColorToneCurve/table()``, 256 × 1 RGBA32Float, built once at init | the fixed per-channel film curve behind "Curves" |
/// | `dnbBig` | luminance on a **320-wide** grid, box-blurred at `0.055 × 320` twice | the large modelling blocks, which must survive |
/// | `dnbSmall` | the same luminance, box-blurred at `0.012 × 320` once | pore- and noise-scale detail, which must not drive the correction |
///
/// `small − big` is the local luminance error: negative means "darker than its
/// surroundings" (dodge), positive means "brighter" (burn). Grid width, both
/// fractions and both floors are `dodgeBurnMaps` in `autoskin.js` verbatim
/// (`SMALL_W = 320`, `max(3, …)`, `max(1, …)`), so the port is the panel's
/// numbers and not a re-derivation.
///
/// That grid is also what makes the slider affordable: at 24 MP the analysis is
/// **2.4 MB** of textures, against 384 MB for the two full-resolution RGBA blur
/// layers the naive version would need. It is allocated on first use, so a
/// document that does not set "Auto D&B" pays nothing for it.
///
/// ## Value space
/// Gamma-encoded sRGB (`RenderQuality.pixelSpace`, mandatory per ADR-0007), like
/// every other node. Two steps are the exception and say so in the kernel:
/// **Exposure** and **White Balance** are scalings of light, so they convert to
/// linear, scale, and convert back inside one branch — one transfer function for
/// both. Everything else is display-referred, which is also what Photoshop's
/// Curves and Contrast do and what `commands.js` was written against.
///
/// ## Metal, not a CIFilter chain
/// docs/PLAN.md §1.3 says "Core Image + kernel" for this row. It is a Metal
/// kernel; docs/ADR-0012 records the decision and the measurement. The short
/// version: the plan's other Phase 2 bar is a **golden PSNR ≥ 45 dB against a
/// `Double` reference**, and `CIColorControls` / `CIVibrance` / `CIToneCurve` /
/// `CITemperatureAndTint` have no published formula to write a reference
/// against — a "reference" for them could only be a second call to the same
/// black box, which measures nothing and would move under an OS update.
///
/// ## Known limitations, stated rather than hidden
/// * **Auto D&B is global**, not skin-masked as in `commands.js`. On a portrait
///   it will also even out the local luminance of hair and background. Adding the
///   skin mask means giving the whole colour stage a face dependency it otherwise
///   does not have, and the colour stage runs *before* the skin stage anyway.
/// * Every constant (the stop, the two WB gains, the two window pivots, the two
///   gammas, the contrast mix, the vibrance protection) is argued from what the
///   operation physically is and is **not tuned against a retoucher's eye** — the
///   same disclosure the "Mặt" (ADR-0010) and "Mắt / Răng" (ADR-0011) groups make.
///   What is measured is that the GPU computes the documented formula.
/// * Each slider moves in **one direction** (0–100 is a fixed project decision;
///   see ``ColorSliders``). There is no darken, no cool, no desaturate.
/// * "Curves" is the amount of a fixed film curve, not a knot editor
///   (``ColorToneCurve``), and its per-channel split moves the white balance
///   slightly at high values — that is what the look is.
/// * HSL is per-band **saturation** only; per-band lightness and hue rotation are
///   16 more keys and are not shipped.
///
/// ## Flags
/// Gated by `RPEngineFeatureFlags.colorSliders` alone. **No shared kernel flag**:
/// this node owns all four of its kernels and borrows neither `guidedFilter` nor
/// `mlsMeshWarp`, so `enableColorRenderGraph()` / `disableColorRenderGraph()`
/// touch exactly one bit and cannot take another group down with them (the
/// failure ADR-0010 records and ADR-0011 had to work around).
public final class ColorRenderNode: RenderNode, @unchecked Sendable {
    public let name = "color"
    public let stage = RenderStage.color

    /// Width of the Auto D&B analysis grid, in pixels. `SMALL_W` in
    /// `panelpts/RetouchProUXP/autoskin.js`, unchanged.
    public static let analysisWidth = 320
    /// Large-block blur radius as a fraction of the analysis width
    /// (`dodgeBurnMaps`' `rBig`).
    public static let bigRadiusFraction = 0.055
    /// Noise-scale blur radius as a fraction of the analysis width (`rSmall`).
    public static let smallRadiusFraction = 0.012

    private let context: MetalContext
    private let compositePipeline: any MTLComputePipelineState
    private let downsamplePipeline: any MTLComputePipelineState
    private let boxHPipeline: any MTLComputePipelineState
    private let boxVPipeline: any MTLComputePipelineState

    /// The curve LUT in the exact float32 values that were uploaded, so the
    /// golden reference reads the same numbers the GPU does and the comparison
    /// measures the kernel rather than the table.
    let curveTable: [Float]
    private let curveTexture: any MTLTexture

    private let lock = NSLock()
    private var cache: Cache?

    private final class Cache {
        let width: Int
        let height: Int
        let analysisWidth: Int
        let analysisHeight: Int
        let device: any MTLDevice

        /// Allocated on first use: a document without "Auto D&B" never touches
        /// them. Four r32Float planes on a 320-wide grid — 2.4 MB at 24 MP,
        /// where the equivalent full-resolution pair would be 384 MB.
        private var textures: [any MTLTexture]?

        init(width: Int, height: Int, analysis: (width: Int, height: Int), device: any MTLDevice) {
            self.width = width
            self.height = height
            self.analysisWidth = analysis.width
            self.analysisHeight = analysis.height
            self.device = device
        }

        /// `luma`, `scratch`, `big`, `small`.
        func analysisTextures() throws -> [any MTLTexture] {
            if let textures { return textures }
            var made: [any MTLTexture] = []
            for _ in 0..<4 {
                made.append(
                    try SpikeTextureIO.makeTexture(
                        width: analysisWidth, height: analysisHeight, device: device,
                        pixelFormat: .r32Float, usage: [.shaderRead, .shaderWrite]))
            }
            textures = made
            return made
        }

        /// What the **most recent** encode fed the composite. A texture stays
        /// allocated once used, so "is it allocated" is not the same question as
        /// "did this render bind it" — reporting the former would hand a golden
        /// test a stale layer from an earlier render (the bug ADR-0009 records
        /// for `SkinRenderNode.storedBase`).
        var lastAnalysisUsed = false
        var storedAnalysis: (big: any MTLTexture, small: any MTLTexture)? {
            guard lastAnalysisUsed, let textures else { return nil }
            return (textures[2], textures[3])
        }

        var byteCount: Int {
            (textures?.count ?? 0) * analysisWidth * analysisHeight * 4
        }
    }

    public init(context: MetalContext) throws {
        guard RPEngineFeatureFlags.colorSliders else {
            throw RPEngineFeatureDisabled(feature: "colorSliders")
        }
        self.context = context
        self.compositePipeline = try context.computePipeline("rp_color_composite")
        self.downsamplePipeline = try context.computePipeline("rp_color_luma_downsample")
        self.boxHPipeline = try context.computePipeline("rp_color_box_h")
        self.boxVPipeline = try context.computePipeline("rp_color_box_v")
        let table = ColorToneCurve.table()
        self.curveTable = table
        self.curveTexture = try Self.makeCurveTexture(table, device: context.device)
    }

    public func prewarm() throws {
        _ = try context.computePipeline("rp_render_copy")
        for function in [
            "rp_color_composite", "rp_color_luma_downsample", "rp_color_box_h", "rp_color_box_v",
        ] {
            _ = try context.computePipeline(function)
        }
    }

    /// No face, no mask, no quality dependency: the only question is whether any
    /// slider in the group is off 0.
    public func isActive(for request: RenderRequest) -> Bool {
        !ColorSliders(request.editState).isIdentity
    }

    /// Bytes of GPU memory this node is holding: the 4 kB curve LUT plus the
    /// analysis grid once "Auto D&B" has been used at this size.
    public var allocatedBytes: Int {
        lock.lock()
        let analysis = cache?.byteCount ?? 0
        lock.unlock()
        return analysis + ColorToneCurve.size * 16
    }

    public func releaseIntermediates() {
        lock.lock()
        cache = nil
        lock.unlock()
    }

    /// The analysis layers from the most recent `encode`, so the golden harness
    /// can check the composite against a `Double` reference **fed the same
    /// layers**; otherwise a composite failure and an analysis failure would be
    /// indistinguishable. `nil` before the first encode, and when the last
    /// request did not need them.
    ///
    /// Internal, not public: nothing outside the tests should reach in here.
    func debugAnalysis() -> (big: any MTLTexture, small: any MTLTexture)? {
        lock.lock()
        defer { lock.unlock() }
        return cache?.storedAnalysis
    }

    public func encode(
        into commandBuffer: any MTLCommandBuffer,
        source: any MTLTexture,
        destination: any MTLTexture,
        request: RenderRequest
    ) throws {
        let sliders = ColorSliders(request.editState)
        guard !sliders.isIdentity else {
            // Not reachable through RenderGraph (isActive gates it), but a direct
            // caller must still get the picture rather than an empty texture.
            try RenderGraph.encodeCopy(
                into: commandBuffer, context: context, source: source, destination: destination)
            return
        }

        let width = source.width
        let height = source.height
        var analysis: (big: any MTLTexture, small: any MTLTexture)?
        var analysisSize = SIMD2<UInt32>(UInt32(ColorToneCurve.size), 1)

        if sliders.needsDodgeBurnAnalysis {
            let size = Self.analysisSize(width: width, height: height)
            let cache = try self.cache(width: width, height: height, analysis: size)
            cache.lastAnalysisUsed = true
            let textures = try cache.analysisTextures()
            encodeAnalysis(into: commandBuffer, source: source, textures: textures, cache: cache)
            analysis = (textures[2], textures[3])
            analysisSize = SIMD2<UInt32>(UInt32(size.width), UInt32(size.height))
        } else {
            lock.lock()
            cache?.lastAnalysisUsed = false
            lock.unlock()
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(compositePipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(curveTexture, index: 1)
        // Unused analysis layers are bound to the LUT: a valid, correctly-typed
        // texture the kernel never reads, because `autoDodgeBurn` is 0 and the
        // whole branch is skipped. Binding nothing is undefined.
        encoder.setTexture(analysis?.big ?? curveTexture, index: 2)
        encoder.setTexture(analysis?.small ?? curveTexture, index: 3)
        encoder.setTexture(destination, index: 4)
        var params = ColorParams(sliders, size: (width, height), analysisSize: analysisSize)
        encoder.setBytes(&params, length: MemoryLayout<ColorParams>.stride, index: 0)
        let dispatch = MetalContext.threadgroups(
            forWidth: width, height: height, pipeline: compositePipeline)
        encoder.dispatchThreadgroups(
            dispatch.threadgroups, threadsPerThreadgroup: dispatch.threadsPerThreadgroup)
        encoder.endEncoding()
    }

    // MARK: - Auto D&B analysis

    /// luma → box(rBig) → box(rBig) into `big`; luma → box(rSmall) into `small`.
    ///
    /// `dodgeBurnMaps` used `boxBlur(lum, rBig, 2)` and `boxBlur(lum, rSmall, 1)`,
    /// i.e. two passes for the large scale and one for the small — reproduced
    /// here, with each pass separable (horizontal then vertical).
    private func encodeAnalysis(
        into commandBuffer: any MTLCommandBuffer, source: any MTLTexture,
        textures: [any MTLTexture], cache: Cache
    ) {
        let luma = textures[0]
        let scratch = textures[1]
        let big = textures[2]
        let small = textures[3]
        let size = (cache.analysisWidth, cache.analysisHeight)

        encodeCompute(commandBuffer, downsamplePipeline, width: size.0, height: size.1) { encoder in
            encoder.setTexture(source, index: 0)
            encoder.setTexture(luma, index: 1)
            var params = ColorAnalysisParams(
                sourceSize: SIMD2<UInt32>(UInt32(cache.width), UInt32(cache.height)),
                analysisSize: SIMD2<UInt32>(UInt32(size.0), UInt32(size.1)))
            encoder.setBytes(&params, length: MemoryLayout<ColorAnalysisParams>.stride, index: 0)
        }

        let rBig = Self.bigRadius(analysisWidth: size.0)
        let rSmall = Self.smallRadius(analysisWidth: size.0)
        // Pass 1 of 2 at the large radius: luma -> scratch -> big.
        encodeBox(commandBuffer, input: luma, scratch: scratch, output: big, radius: rBig, size: size)
        // Pass 2 of 2: big -> scratch -> big. Legal in one command buffer —
        // Metal's automatic hazard tracking orders the second pass's reads after
        // the first's writes — and it saves a fifth texture.
        encodeBox(commandBuffer, input: big, scratch: scratch, output: big, radius: rBig, size: size)
        // The single small-radius pass, from the untouched luma plane.
        encodeBox(
            commandBuffer, input: luma, scratch: scratch, output: small, radius: rSmall, size: size)
    }

    private func encodeBox(
        _ commandBuffer: any MTLCommandBuffer, input: any MTLTexture, scratch: any MTLTexture,
        output: any MTLTexture, radius: Int, size: (Int, Int)
    ) {
        var params = ColorBoxParams(
            size: SIMD2<UInt32>(UInt32(size.0), UInt32(size.1)), radius: Int32(radius))
        encodeCompute(commandBuffer, boxHPipeline, width: size.0, height: size.1) { encoder in
            encoder.setTexture(input, index: 0)
            encoder.setTexture(scratch, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<ColorBoxParams>.stride, index: 0)
        }
        encodeCompute(commandBuffer, boxVPipeline, width: size.0, height: size.1) { encoder in
            encoder.setTexture(scratch, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<ColorBoxParams>.stride, index: 0)
        }
    }

    private func encodeCompute(
        _ commandBuffer: any MTLCommandBuffer, _ pipeline: any MTLComputePipelineState,
        width: Int, height: Int, _ configure: (any MTLComputeCommandEncoder) -> Void
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        configure(encoder)
        let dispatch = MetalContext.threadgroups(
            forWidth: width, height: height, pipeline: pipeline)
        encoder.dispatchThreadgroups(
            dispatch.threadgroups, threadsPerThreadgroup: dispatch.threadsPerThreadgroup)
        encoder.endEncoding()
    }

    // MARK: - Geometry

    /// The analysis grid for an image: 320 wide (never upscaled), height in
    /// proportion, both at least 1.
    public static func analysisSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let w = max(1, min(analysisWidth, width))
        let h = max(1, Int((Double(height) * Double(w) / Double(max(1, width))).rounded()))
        return (w, h)
    }

    /// `rBig` in `dodgeBurnMaps`: `max(3, round(0.055 · analysisWidth))` — 18 px
    /// on the 320-wide grid.
    public static func bigRadius(analysisWidth: Int) -> Int {
        max(3, Int((Double(analysisWidth) * bigRadiusFraction).rounded()))
    }

    /// `rSmall`: `max(1, round(0.012 · analysisWidth))` — 4 px on the 320-wide grid.
    public static func smallRadius(analysisWidth: Int) -> Int {
        max(1, Int((Double(analysisWidth) * smallRadiusFraction).rounded()))
    }

    // MARK: - Resources

    private func cache(width: Int, height: Int, analysis: (width: Int, height: Int)) throws -> Cache
    {
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache, existing.width == width, existing.height == height {
            return existing
        }
        let made = Cache(width: width, height: height, analysis: analysis, device: context.device)
        cache = made
        return made
    }

    /// 256 × 1 RGBA32Float, staged through a shared buffer because a `.private`
    /// texture cannot be written from the CPU. Float32 rather than the package's
    /// usual float16: the reference reads these exact numbers, and there is no
    /// reason to spend 2e-4 of the golden budget on a 4 kB table.
    private static func makeCurveTexture(_ table: [Float], device: any MTLDevice) throws
        -> any MTLTexture
    {
        let texture = try SpikeTextureIO.makeTexture(
            width: ColorToneCurve.size, height: 1, device: device, pixelFormat: .rgba32Float,
            usage: [.shaderRead])
        let bytesPerRow = ColorToneCurve.size * 16
        guard
            let staging = table.withUnsafeBytes({
                device.makeBuffer(
                    bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            }),
            let queue = device.makeCommandQueue(),
            let commandBuffer = queue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw MetalContext.Failure.cannotMakeBuffer(bytes: bytesPerRow) }
        blit.copy(
            from: staging, sourceOffset: 0, sourceBytesPerRow: bytesPerRow,
            sourceBytesPerImage: bytesPerRow,
            sourceSize: MTLSize(width: ColorToneCurve.size, height: 1, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
    }
}

// MARK: - Shader parameter structs
//
// Field order and padding must match ColorShaders.metal exactly. The two
// `SIMD4<Float>` come first so both languages' 16-byte alignment lands in the
// same place; `ColorRenderNodeTests.parameterStructsMatchShaderLayout` pins the
// strides.

struct ColorParams {
    var hslA: SIMD4<Float>
    var hslB: SIMD4<Float>
    var size: SIMD2<UInt32>
    var analysisSize: SIMD2<UInt32>
    var exposure: Float
    var contrast: Float
    var highlights: Float
    var shadows: Float
    var wbTemperature: Float
    var wbTint: Float
    var vibrance: Float
    var saturation: Float
    var curves: Float
    var autoDodgeBurn: Float
    var curveLUTSize: UInt32

    init(_ sliders: ColorSliders, size: (Int, Int), analysisSize: SIMD2<UInt32>) {
        func amount(_ band: HueBand) -> Float { Float(sliders[band] / 100) }
        self.hslA = SIMD4<Float>(amount(.red), amount(.orange), amount(.yellow), amount(.green))
        self.hslB = SIMD4<Float>(amount(.aqua), amount(.blue), amount(.purple), amount(.magenta))
        self.size = SIMD2<UInt32>(UInt32(size.0), UInt32(size.1))
        self.analysisSize = analysisSize
        self.exposure = Float(sliders.exposure / 100)
        self.contrast = Float(sliders.contrast / 100)
        self.highlights = Float(sliders.highlights / 100)
        self.shadows = Float(sliders.shadows / 100)
        self.wbTemperature = Float(sliders.wbTemperature / 100)
        self.wbTint = Float(sliders.wbTint / 100)
        self.vibrance = Float(sliders.vibrance / 100)
        self.saturation = Float(sliders.saturation / 100)
        self.curves = Float(sliders.curves / 100)
        self.autoDodgeBurn = Float(sliders.autoDodgeBurn / 100)
        self.curveLUTSize = UInt32(ColorToneCurve.size)
    }
}

struct ColorAnalysisParams {
    var sourceSize: SIMD2<UInt32>
    var analysisSize: SIMD2<UInt32>
}

struct ColorBoxParams {
    var size: SIMD2<UInt32>
    var radius: Int32
}

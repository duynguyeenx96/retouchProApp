import Foundation
import Metal

/// Device, command queue and shader library for the Phase 0 spike S3 kernels.
///
/// **Why the shaders are compiled at run time.** Two build systems, two
/// problems. `swift build` does not compile `.metal` at all: it reports
/// `Shaders.metal` as an "unhandled file" and produces no `default.metallib`, so
/// `MTLDevice.makeDefaultLibrary(bundle: .module)` fails outright — and the
/// spike harness under `Research/` is built with `swift build`. `xcodebuild`
/// does compile it, including when it is declared under `resources:`, but on
/// Xcode 26 `CompileMetalFile` needs the separately downloadable **Metal
/// Toolchain** component (`xcodebuild -downloadComponent MetalToolchain`), and
/// without it the whole `xcodebuild test` run fails to build.
///
/// So the `.metal` file travels inside a copied *directory*
/// (`Spike/MetalSources/`), which neither build system looks into, and is
/// compiled here with `makeLibrary(source:)` — the run-time compiler in the
/// Metal framework, which needs no toolchain. One code path that behaves the
/// same under `swift build`, `xcodebuild -destination 'platform=macOS'` and the
/// iOS Simulator.
///
/// The cost is one compile per process: **236 ms cold, ~0.6 ms once Metal's own
/// on-disk source cache is warm** (`Research/spikes/S3-guided-filter-mls/`). It
/// is paid once, in `shared`, and is excluded from every per-frame number in
/// this spike. Phase 2 should move the kernels into the app target (which does
/// get a `default.metallib`, given the Metal Toolchain component) or cache an
/// `MTLBinaryArchive`; that is a build-system change, not a rewrite.
///
/// ### More than one source file
/// Phase 2's `Render/RenderShaderSources/SkinShaders.metal` is a second copied
/// directory. It is **concatenated** onto the spike source and compiled in the
/// same `makeLibrary(source:)` call rather than producing a second `MTLLibrary`:
/// one library keeps the compile cost at exactly one per process (the thing that
/// is expensive, 1.8 s cold in the Simulator) and keeps one pipeline cache, so
/// `RenderGraph.prewarm()` can guarantee no shader work happens during a slider
/// drag. The order is fixed by ``shaderSources`` so a compile error's line
/// numbers are reproducible.
public final class MetalContext: @unchecked Sendable {
    public let device: any MTLDevice
    public let commandQueue: any MTLCommandQueue
    public let library: any MTLLibrary
    /// Wall-clock cost of the run-time shader compile, milliseconds.
    public let libraryCompileMilliseconds: Double

    private let pipelineLock = NSLock()
    private var computePipelines: [String: any MTLComputePipelineState] = [:]

    public enum Failure: Error, CustomStringConvertible {
        case noDevice
        case noCommandQueue
        case shaderSourceMissing
        case functionMissing(String)
        case cannotMakeBuffer(bytes: Int)

        public var description: String {
            switch self {
            case .noDevice: "No Metal device is available on this machine."
            case .noCommandQueue: "Could not create an MTLCommandQueue."
            case .shaderSourceMissing:
                "Shaders.metal is missing from the RPEngine resource bundle."
            case .functionMissing(let name): "Shader function '\(name)' not found."
            case .cannotMakeBuffer(let bytes): "Could not allocate a \(bytes)-byte MTLBuffer."
            }
        }
    }

    /// Every `.metal` source that goes into ``library``, in compile order.
    ///
    /// `subdirectory` is the *bundle* path, which is the last component of the
    /// `.copy(...)` in Package.swift — hence "MetalSources" for
    /// `Spike/MetalSources` and "RenderShaderSources" for
    /// `Render/RenderShaderSources`. The two must not collide, which is why the
    /// Phase 2 directory is not also called `MetalSources`.
    public static let shaderSources: [(subdirectory: String, name: String)] = [
        ("MetalSources", "Shaders"),  // Phase 0 spike S3: guided filter + MLS warp
        ("RenderShaderSources", "SkinShaders"),  // Phase 2: the "Da" group
        // Phase 2: the "Mắt / Răng" group. Must come after SkinShaders — it uses
        // that file's `kRPLuma` and its `rp_skin_mask` kernel, and the
        // concatenation is one translation unit.
        ("RenderShaderSources", "EyesTeethShaders"),
        // Phase 2: the "Color" group. Also after SkinShaders — it uses that
        // file's `kRPLuma`. Independent of EyesTeethShaders, but the order is
        // fixed so a compile error's line numbers are reproducible.
        ("RenderShaderSources", "ColorShaders"),
        // Phase 2: the live preview's presentation pass (LivePreviewRenderer).
        // Depends on nothing in the four files above — it is a placement +
        // resample copy into an MTKView drawable, with no retouch maths — but is
        // listed last so the line numbers of the earlier files do not move.
        ("RenderShaderSources", "PreviewShaders"),
    ]

    public init(device: (any MTLDevice)? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else { throw Failure.noDevice }
        guard let queue = device.makeCommandQueue() else { throw Failure.noCommandQueue }
        var parts: [String] = []
        for entry in Self.shaderSources {
            guard
                let url = Bundle.module.url(
                    forResource: entry.name, withExtension: "metal",
                    subdirectory: entry.subdirectory)
            else { throw Failure.shaderSourceMissing }
            parts.append(try String(contentsOf: url, encoding: .utf8))
        }
        let source = parts.joined(separator: "\n")
        let start = DispatchTime.now().uptimeNanoseconds
        let library = try device.makeLibrary(source: source, options: nil)
        self.libraryCompileMilliseconds =
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        self.device = device
        self.commandQueue = queue
        self.library = library
    }

    /// Process-wide context. `nil` when this machine has no Metal device, so
    /// callers (and tests) can skip rather than crash.
    public static let shared: MetalContext? = try? MetalContext()

    /// Compute pipeline for `name`, built once and cached.
    public func computePipeline(_ name: String) throws -> any MTLComputePipelineState {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        if let cached = computePipelines[name] { return cached }
        guard let function = library.makeFunction(name: name) else {
            throw Failure.functionMissing(name)
        }
        let pipeline = try device.makeComputePipelineState(function: function)
        computePipelines[name] = pipeline
        return pipeline
    }

    /// Dispatch size helper: threadgroups covering `width × height` with the
    /// pipeline's own preferred threadgroup shape.
    public static func threadgroups(
        forWidth width: Int, height: Int, pipeline: any MTLComputePipelineState
    ) -> (threadgroups: MTLSize, threadsPerThreadgroup: MTLSize) {
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let perGroup = MTLSize(width: w, height: h, depth: 1)
        let groups = MTLSize(
            width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1)
        return (groups, perGroup)
    }
}

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import RPCore
import UniformTypeIdentifiers

#if canImport(Darwin)
    import Darwin
#endif

/// One picture to write, with everything the renderer needs and nothing it does
/// not.
///
/// **Shaped for the batch queue that does not exist yet.** docs/PLAN.md Phase 3
/// has `BatchQueue` running N of these in the background; the only thing that
/// varies per photo is this value, so a queue is a loop over `[ExportJob]` with
/// one `ExportRenderer` and one ``ExportSettings``. Nothing in the renderer
/// holds per-photo state between calls.
public struct ExportJob: Sendable {
    /// The immutable file under `originals/`.
    public var sourceURL: URL
    /// The document to render. Sliders at 0 make this a decode-and-encode.
    public var editState: EditState
    /// Faces **as measured on an image of ``faceReferenceSize``** — normally the
    /// 2048 px preview the canvas analysed. The renderer rescales them to the
    /// size it actually renders at, so the caller never has to know what that
    /// size turned out to be. (`RenderRequest.faces` requires texture-space
    /// faces and explicitly refuses to guess a scale; this is where the guess is
    /// replaced by an arithmetic the caller states.)
    public var faces: [FaceRenderInput]
    public var faceReferenceSize: CGSize
    /// Whole-frame masks — brush, "Khoá nền" subject, body skin — each mapped
    /// into an image of `masks.referenceSize` (normally the canvas's preview).
    /// Rescaled per axis to the render size by the renderer, like ``faces``;
    /// see ``ExportMasks`` for why a missing reference size is an error rather
    /// than "assume render resolution".
    public var masks: ExportMasks
    /// Name the template's `{name}` comes from. Defaults to the source's.
    public var originalFileName: String
    /// 1-based position in the run, for `{n}`.
    public var index: Int
    public var settings: ExportSettings
    /// Folder the file lands in. Created if missing.
    public var destinationDirectory: URL

    public init(
        sourceURL: URL,
        editState: EditState = EditState(),
        faces: [FaceRenderInput] = [],
        faceReferenceSize: CGSize = .zero,
        masks: ExportMasks = .none,
        originalFileName: String? = nil,
        index: Int = 1,
        settings: ExportSettings = ExportSettings(),
        destinationDirectory: URL
    ) {
        self.sourceURL = sourceURL
        self.editState = editState
        self.faces = faces
        self.faceReferenceSize = faceReferenceSize
        self.masks = masks
        self.originalFileName = originalFileName ?? sourceURL.lastPathComponent
        self.index = index
        self.settings = settings
        self.destinationDirectory = destinationDirectory
    }
}

/// Wall-clock milliseconds per stage of one export. Every field is measured, not
/// estimated; `total` is the whole call including the parts not broken out.
public struct ExportTimings: Sendable, Equatable, Codable {
    public var decode: Double = 0
    public var upload: Double = 0
    public var graph: Double = 0
    public var readback: Double = 0
    public var resizeAndSharpen: Double = 0
    public var encode: Double = 0
    public var write: Double = 0
    public var total: Double = 0

    public init() {}
}

/// What one export actually did — including the places where the file on disk
/// is not quite what was asked for.
public struct ExportResult: Sendable, Equatable {
    public var url: URL
    /// Size of the written picture.
    public var pixelSize: CGSize
    /// Size the render graph ran at, before any resize.
    public var renderedSize: CGSize
    public var byteCount: Int
    public var format: ExportSettings.Format
    /// Bits per component the file **actually** carries, read back off the file
    /// rather than assumed. JPEG is always 8; a 16-bit HEIF request does not
    /// come back as 16.
    public var writtenBitsPerComponent: Int
    /// ICC profile name read back off the file, when it has one.
    public var profileName: String?
    /// Stages that ran, in order. Compare with ``ExportPipeline/stageOrder``.
    public var stages: [ExportPipeline.Stage]
    /// Render-graph nodes that ran (`RenderReport.nodes`).
    public var nodes: [String]
    public var timings: ExportTimings
    /// Anything the user or a reviewer would want to know that the numbers above
    /// do not say — a RAW decode that came back as the embedded preview, a
    /// bit-depth request the container cannot hold, a memory cap that forced a
    /// smaller render.
    public var notes: [String]
    /// Whole-frame masks that actually reached the render graph
    /// (`manualMask`, `backgroundLock`, `bodySkin`), after the feature flags and
    /// the document's own switches were applied. Empty for an ungated render.
    public var appliedMasks: [String] = []

    public init(
        url: URL, pixelSize: CGSize, renderedSize: CGSize, byteCount: Int,
        format: ExportSettings.Format, writtenBitsPerComponent: Int, profileName: String?,
        stages: [ExportPipeline.Stage], nodes: [String], timings: ExportTimings,
        notes: [String]
    ) {
        self.url = url
        self.pixelSize = pixelSize
        self.renderedSize = renderedSize
        self.byteCount = byteCount
        self.format = format
        self.writtenBitsPerComponent = writtenBitsPerComponent
        self.profileName = profileName
        self.stages = stages
        self.nodes = nodes
        self.timings = timings
        self.notes = notes
    }
}

public enum ExportError: Error, CustomStringConvertible {
    case cannotReadSource(path: String)
    case cannotCreateDestination(path: String)
    case encodeFailed(format: ExportSettings.Format)
    case renameFailed(destination: String, errno: Int32)
    case cannotCreateContext

    public var description: String {
        switch self {
        case .cannotReadSource(let path): "Could not decode \(path) for export."
        case .cannotCreateDestination(let path): "Could not create the export folder \(path)."
        case .encodeFailed(let format): "Could not encode the picture as \(format.rawValue)."
        case .renameFailed(let destination, let code):
            "Could not move the finished export onto \(destination): "
                + String(cString: strerror(code))
        case .cannotCreateContext: "Could not create the Core Image context for the export."
        }
    }
}

/// The export path: decode at full resolution, run the **same** ``RenderGraph``
/// the canvas runs, resize, sharpen, encode, write.
///
/// ## What makes this different from ``LivePreviewRenderer``
///
/// Only two things, and both of them are about the two ends of the pipe:
///
/// * **Quality.** The graph runs at ``RenderQuality/export`` — mesh grid 129
///   rather than 65, which is the setting `docs/ADR-0007` recorded as worth
///   0.12 ms at 24 MP and a PSNR the preview grid does not reach. Nothing else
///   in the graph changes, which is the point: what the user saw is what they
///   get, at a denser lattice.
/// * **The far end.** The preview ends in a drawable; this ends in a file, and
///   the three things `docs/PLAN.md` Phase 3 asks for there (profile, resize,
///   sharpen-after-resize) are output-referred operations that must not run on
///   the interaction path.
///
/// It deliberately does **not** own: a queue (that is `BatchQueue`, later), a
/// decode cache, or face analysis. Faces arrive in the job, already measured.
///
/// ## Order
/// ``ExportPipeline/stageOrder`` is the contract, and `resize` is before
/// `sharpen` in it for a reason (see that type). The result of every call
/// reports the stages it ran so a caller can assert the order it got.
public final class ExportRenderer: @unchecked Sendable {
    public let context: MetalContext
    public let graph: RenderGraph

    private let lock = NSLock()
    private var ciContextStorage: CIContext?
    private let maskResolver: ExportMaskResolver

    public init(context: MetalContext, graph: RenderGraph) {
        self.context = context
        self.graph = graph
        self.maskResolver = ExportMaskResolver(context: context)
    }

    /// The renderer the app ships: `RenderGraph.standard`, i.e. exactly the
    /// nodes whose feature flags are on — the same set the canvas used, so the
    /// export cannot apply an edit the user never saw.
    public convenience init(context: MetalContext) throws {
        self.init(context: context, graph: try RenderGraph.standard(context: context))
    }

    /// Compiles every pipeline the graph can use. Off the interaction path: the
    /// first shader build is 236 ms on macOS and 1798 ms in the Simulator
    /// (docs/ADR-0007), and paying it inside the user's first export reads as a
    /// hang.
    public func prewarm() throws {
        try graph.prewarm()
    }

    // MARK: - Export

    /// Renders and writes one picture. Blocking: it waits on the GPU and on the
    /// file system, so call it off the main actor.
    @discardableResult
    public func export(_ job: ExportJob) throws -> ExportResult {
        let started = DispatchTime.now().uptimeNanoseconds
        var timings = ExportTimings()
        var stages: [ExportPipeline.Stage] = []
        var notes: [String] = []

        // ---- decode ----
        let decodeStart = DispatchTime.now().uptimeNanoseconds
        let headerSize = ImageDecoder.pixelSize(ofImageAt: job.sourceURL)
        let requestedLongEdge = Self.renderLongEdge(
            headerSize: headerSize, settings: job.settings, notes: &notes)
        let decoded = try ImageDecoder.decode(
            contentsOf: job.sourceURL, maxPixelSize: requestedLongEdge)
        timings.decode = Self.milliseconds(since: decodeStart)
        stages.append(.decode)

        if let headerSize,
            max(decoded.pixelSize.width, decoded.pixelSize.height)
                < max(headerSize.width, headerSize.height) - 1
        {
            notes.append(
                "decoded \(Self.sizeText(decoded.pixelSize)) from a "
                    + "\(Self.sizeText(headerSize)) file — ImageIO handed back the embedded "
                    + "preview (RAW development is docs/PLAN.md spike S4, not this item)")
        } else if Self.isRawExtension(job.sourceURL.pathExtension) {
            // The check above cannot see this case, and a real iPhone run is
            // where it showed up: exporting `DSC05123.ARW` produced 1080×1616,
            // because iOS's ImageIO reports the *embedded preview's* size in the
            // file properties too — header and decode agree, and both are the
            // preview. (macOS develops the same file at 6000×4000.) So a RAW
            // source always says what came out, rather than letting a 24 MP file
            // quietly become a 1.7 MP export on one platform only.
            notes.append(
                "RAW source (.\(job.sourceURL.pathExtension.lowercased())) decoded by ImageIO "
                    + "at \(Self.sizeText(decoded.pixelSize)); full RAW development is "
                    + "docs/PLAN.md spike S4, so this is whatever ImageIO gives on this platform")
        }

        // ---- upload ----
        let uploadStart = DispatchTime.now().uptimeNanoseconds
        let source = try ExportImageBuilder.makeTexture(
            from: decoded.cgImage, space: RenderQuality.export.pixelSpace,
            device: context.device, queue: context.commandQueue)
        timings.upload = Self.milliseconds(since: uploadStart)
        stages.append(.upload)

        let renderedSize = CGSize(width: source.width, height: source.height)

        // ---- graph ----
        let scale =
            job.faceReferenceSize.width > 0
            ? renderedSize.width / job.faceReferenceSize.width : 1
        let faces = job.faces.map { $0.scaled(by: scale) }
        var request = RenderRequest(
            editState: job.editState, allFaces: faces, quality: .export)
        // The canvas's whole-frame masks, mapped from the preview they were
        // built on onto this render, then gated by the same flag/document
        // checks `LivePreviewController.renderRequest` applies.
        let masks = try job.masks.scaled(to: renderedSize)
        let resolvedMasks = try maskResolver.resolve(
            masks, editState: job.editState, width: source.width, height: source.height)
        request.bodySkinMask = resolvedMasks.bodySkinMask
        request.gateMasks += resolvedMasks.gateMasks
        let destination = try SpikeTextureIO.makeTexture(
            width: source.width, height: source.height, device: context.device,
            pixelFormat: .rgba16Float, usage: [.shaderRead, .shaderWrite, .renderTarget])
        let graphStart = DispatchTime.now().uptimeNanoseconds
        let report = try graph.render(
            source: source, destination: destination, request: request)
        timings.graph = Self.milliseconds(since: graphStart)
        stages.append(.graph)

        // ---- read back ----
        let bits = job.settings.effectiveBitDepth.rawValue
        if job.settings.bitDepth == .sixteen, !job.settings.format.supportsDeepColor {
            notes.append("\(job.settings.format.rawValue) is an 8-bit container; wrote 8 bits")
        }
        let readbackStart = DispatchTime.now().uptimeNanoseconds
        let rendered = try ExportImageBuilder.makeCGImage(
            from: destination, queue: context.commandQueue, bitsPerComponent: bits,
            colorSpace: SpikeTextureIO.PixelSpace.sRGBEncoded.cgColorSpace)
        timings.readback = Self.milliseconds(since: readbackStart)
        // The graph's intermediates are up to two full-size rgba16Float
        // textures (384 MB at 24 MP). The picture is in `rendered` now, so
        // nothing needs them until the next export.
        graph.releaseIntermediates()
        maskResolver.releaseIntermediates()

        // ---- resize, then sharpen (never the other way round) ----
        let outputSize = job.settings.resize.outputSize(for: renderedSize)
        let needsResize = outputSize != renderedSize
        let needsProfileConversion = job.settings.colorProfile != .sRGB
        let finishStart = DispatchTime.now().uptimeNanoseconds
        var finished = rendered
        if needsResize || job.settings.sharpensOutput || needsProfileConversion {
            finished = try finish(
                rendered, to: outputSize, settings: job.settings, bits: bits)
            if needsResize { stages.append(.resize) }
            if job.settings.sharpensOutput { stages.append(.sharpen) }
        }
        timings.resizeAndSharpen = Self.milliseconds(since: finishStart)

        // ---- encode + write ----
        try FileManager.default.createDirectory(
            at: job.destinationDirectory, withIntermediateDirectories: true)
        let fileName = ExportNaming.fileName(
            template: job.settings.namingTemplate,
            originalFileName: job.originalFileName,
            index: job.index,
            outputSize: outputSize,
            format: job.settings.format)
        let url = ExportNaming.uniqueURL(in: job.destinationDirectory, fileName: fileName)

        let encodeStart = DispatchTime.now().uptimeNanoseconds
        let temporary = job.destinationDirectory.appendingPathComponent(
            "\(AtomicFileWriter.temporaryPrefix)\(UUID().uuidString).\(job.settings.format.fileExtension)"
        )
        do {
            try Self.encode(finished, to: temporary, settings: job.settings)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        timings.encode = Self.milliseconds(since: encodeStart)
        stages.append(.encode)

        let writeStart = DispatchTime.now().uptimeNanoseconds
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw ExportError.renameFailed(destination: url.path, errno: code)
        }
        timings.write = Self.milliseconds(since: writeStart)
        stages.append(.write)

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let written = Self.writtenProperties(of: url)
        timings.total = Self.milliseconds(since: started)

        var result = ExportResult(
            url: url,
            pixelSize: outputSize,
            renderedSize: renderedSize,
            byteCount: (attributes?[.size] as? NSNumber)?.intValue ?? 0,
            format: job.settings.format,
            writtenBitsPerComponent: written.depth ?? bits,
            profileName: written.profile,
            stages: stages,
            nodes: report.nodes,
            timings: timings,
            notes: notes)
        result.appliedMasks = resolvedMasks.applied
        return result
    }

    // MARK: - Resize / sharpen / profile

    /// Core Image, in the order `docs/PLAN.md` fixes: **Lanczos resize first,
    /// unsharp mask second.**
    ///
    /// Sharpening before a 3× downscale would put detail into frequencies the
    /// resample then throws away, and leave a halo where it does not. This is
    /// the only place in the app where the two exist, so the order lives here
    /// and `ExportPipeline.stageOrder` states it for a test.
    ///
    /// The colour conversion is here too rather than in the CGImage: the buffer
    /// holds sRGB-encoded values, so a Display P3 export has to be *converted*,
    /// not re-tagged. `createCGImage(_:from:format:colorSpace:)` converts out of
    /// Core Image's working space, which is what makes that honest.
    private func finish(
        _ image: CGImage, to outputSize: CGSize, settings: ExportSettings, bits: Int
    ) throws -> CGImage {
        let ciContext = try makeCIContext()
        var ci = CIImage(cgImage: image)
        if outputSize != CGSize(width: image.width, height: image.height) {
            let scale = outputSize.width / CGFloat(image.width)
            let filter = CIFilter(name: "CILanczosScaleTransform")
            filter?.setValue(ci, forKey: kCIInputImageKey)
            filter?.setValue(scale, forKey: kCIInputScaleKey)
            filter?.setValue(1.0, forKey: kCIInputAspectRatioKey)
            if let output = filter?.outputImage { ci = output }
        }
        if settings.sharpensOutput {
            // Output sharpening, applied to the final pixel grid. The constants
            // are conservative and **default off** (`ExportSettings.sharpen` is
            // 0): a 1 px radius is the usual output-sharpening radius, and the
            // 0…100 slider maps to 0…0.8 intensity so 100 is firm rather than
            // crunchy. No number is claimed for them — that is exactly why the
            // default is 0 (working rule 1).
            let filter = CIFilter(name: "CIUnsharpMask")
            filter?.setValue(ci, forKey: kCIInputImageKey)
            filter?.setValue(1.0, forKey: kCIInputRadiusKey)
            filter?.setValue(
                min(1, max(0, settings.sharpen / 100)) * 0.8, forKey: kCIInputIntensityKey)
            if let output = filter?.outputImage { ci = output }
        }
        let format: CIFormat = bits == 16 ? .RGBA16 : .RGBA8
        let rect = CGRect(
            origin: .zero,
            size: CGSize(
                width: outputSize.width.rounded(), height: outputSize.height.rounded()))
        guard
            let out = ciContext.createCGImage(
                ci, from: rect, format: format,
                colorSpace: settings.colorProfile.cgColorSpace)
        else { throw ExportError.cannotCreateContext }
        return out
    }

    private func makeCIContext() throws -> CIContext {
        lock.lock()
        defer { lock.unlock() }
        if let ciContextStorage { return ciContextStorage }
        // Same device as the graph, so the resize runs on the GPU that already
        // holds the picture's memory.
        let created = CIContext(mtlDevice: context.device, options: [.cacheIntermediates: false])
        ciContextStorage = created
        return created
    }

    // MARK: - Encoding

    /// ImageIO, straight to a URL.
    ///
    /// `CGImageDestinationCreateWithData` would put the whole file in memory
    /// first — 190 MB for a 16-bit 24 MP TIFF — for no benefit, because the
    /// caller renames the finished temp file into place anyway
    /// (`AtomicFileWriter`'s recipe, minus the `Data` round trip that type's API
    /// requires).
    ///
    /// The ICC profile is not set as a property: `CGImageDestination` embeds the
    /// colour space the `CGImage` already carries, which after ``finish(_:...)``
    /// is the one the user chose. ``writtenProperties(of:)`` reads it back off
    /// the finished file so the result reports what is in the file, not what was
    /// intended.
    private static func encode(
        _ image: CGImage, to url: URL, settings: ExportSettings
    ) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, settings.format.contentType.identifier as CFString, 1, nil)
        else { throw ExportError.encodeFailed(format: settings.format) }
        var properties: [CFString: Any] = [:]
        if settings.format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = settings.lossyQuality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.encodeFailed(format: settings.format)
        }
    }

    /// Bit depth and profile name **as written**, read back off the file.
    static func writtenProperties(of url: URL) -> (depth: Int?, profile: String?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else { return (nil, nil) }
        let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue
        let profile = properties[kCGImagePropertyProfileName] as? String
        return (depth, profile)
    }

    // MARK: - Helpers

    /// Longest edge to decode at: the file's own, unless
    /// ``ExportSettings/maximumRenderPixels`` says the graph must not be handed
    /// that many pixels.
    static func renderLongEdge(
        headerSize: CGSize?, settings: ExportSettings, notes: inout [String]
    ) -> Int {
        // No header (a format ImageIO will not describe): ask for something
        // larger than any camera and let the decoder cap it.
        guard let headerSize, headerSize.width > 0, headerSize.height > 0 else { return 20000 }
        let longest = Int(max(headerSize.width, headerSize.height).rounded())
        guard let cap = settings.maximumRenderPixels, cap > 0 else { return longest }
        let pixels = Int(headerSize.width.rounded()) * Int(headerSize.height.rounded())
        guard pixels > cap else { return longest }
        let factor = (Double(cap) / Double(pixels)).squareRoot()
        let capped = max(1, Int((Double(longest) * factor).rounded()))
        notes.append(
            "render capped at \(capped) px long edge by maximumRenderPixels=\(cap) "
                + "(file is \(sizeText(headerSize)))")
        return capped
    }

    /// Camera-RAW extensions, for the note above.
    ///
    /// Duplicated from `RPUI.ShotDisplay.rawExtensions` on purpose: RPUI depends
    /// on RPEngine and never the other way round (working rule 3), and the list
    /// that would be shared lives in RPCore only as *all* importable extensions.
    static let rawExtensions: Set<String> = [
        "arw", "dng", "cr2", "cr3", "nef", "raf", "orf", "rw2", "srw", "pef",
    ]

    static func isRawExtension(_ pathExtension: String) -> Bool {
        rawExtensions.contains(pathExtension.lowercased())
    }

    static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    static func sizeText(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
    }
}

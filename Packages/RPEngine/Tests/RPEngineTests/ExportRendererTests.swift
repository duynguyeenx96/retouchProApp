import CoreGraphics
import Foundation
import ImageIO
import Metal
import RPCore
import Testing
import UniformTypeIdentifiers

@testable import RPEngine

/// Phase 3 item 3 — the export path.
///
/// Three groups of claims, in increasing order of how much machine they need:
///
/// 1. **No GPU at all** — the naming template, the resize arithmetic and the
///    fixed stage order. These are the parts a `BatchQueue` will lean on hardest
///    (one template across 200 frames) and they are pure functions.
/// 2. **GPU, synthetic picture** — a real export end to end: a file exists, it
///    has the size, depth and profile that were asked for, and with an empty
///    `EditState` the pixels that come back out are the pixels that went in.
/// 3. **Honesty** — the places where the file cannot be what was asked for
///    (a 16-bit JPEG) are reported in `ExportResult.notes` rather than silently
///    wrong.
@Suite("Phase 3 export renderer")
struct ExportRendererTests {

    // MARK: - 1. No GPU

    @Test("The naming template substitutes every token and never invents an extension")
    func namingTokens() {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 11
        components.hour = 14
        components.minute = 5
        components.second = 7
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: components)!

        let name = ExportNaming.fileName(
            template: "{name}_{nnn}_{date}-{time}_{w}x{h}_{format}",
            originalFileName: "DSC05123.ARW", index: 7, date: date,
            outputSize: CGSize(width: 4000, height: 2667), format: .tiff,
            timeZone: TimeZone(identifier: "UTC")!)
        #expect(name == "DSC05123_007_20260911-140507_4000x2667_tiff.tif")
    }

    @Test("The default template is the original name plus a suffix")
    func defaultTemplate() {
        let name = ExportNaming.fileName(
            template: ExportNaming.defaultTemplate, originalFileName: "DSC05123.ARW",
            format: .jpeg)
        #expect(name == "DSC05123_retouch.jpg")
    }

    @Test("A template that would escape the folder is sanitised, not obeyed")
    func namingSanitises() {
        let name = ExportNaming.fileName(
            template: "../../{name}/evil", originalFileName: "a.jpg", format: .jpeg)
        #expect(!name.contains("/"))
        #expect(name.hasSuffix(".jpg"))
    }

    @Test("An empty template falls back to the original name rather than to nothing")
    func namingEmptyTemplate() {
        let name = ExportNaming.fileName(
            template: "", originalFileName: "DSC05123.ARW", format: .heif)
        #expect(name == "DSC05123_retouch.heic")
    }

    @Test("uniqueURL never hands back a path that already has a file on it")
    func uniqueURLAvoidsOverwriting() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ExportNaming.uniqueURL(in: directory, fileName: "shot.jpg")
        try Data([0]).write(to: first)
        let second = ExportNaming.uniqueURL(in: directory, fileName: "shot.jpg")
        #expect(first.lastPathComponent == "shot.jpg")
        #expect(second.lastPathComponent == "shot-1.jpg")
    }

    @Test("Resize scales down to the long edge and never up")
    func resizeArithmetic() {
        let landscape = CGSize(width: 6000, height: 4000)
        #expect(
            ExportSettings.Resize.longestEdge(4000).outputSize(for: landscape)
                == CGSize(width: 4000, height: 2667))
        #expect(
            ExportSettings.Resize.longestEdge(2048).outputSize(for: landscape)
                == CGSize(width: 2048, height: 1365))
        // Upscaling is not a thing an export does on its own.
        #expect(
            ExportSettings.Resize.longestEdge(9000).outputSize(for: landscape) == landscape)
        #expect(ExportSettings.Resize.original.outputSize(for: landscape) == landscape)
        // Portrait: the *long* edge is the height.
        let portrait = CGSize(width: 4000, height: 6000)
        #expect(
            ExportSettings.Resize.longestEdge(3000).outputSize(for: portrait)
                == CGSize(width: 2000, height: 3000))
    }

    @Test("Sharpen runs after resize — the order docs/PLAN.md fixes")
    func sharpenComesAfterResize() {
        #expect(
            ExportPipeline.position(of: .sharpen) > ExportPipeline.position(of: .resize))
        #expect(ExportPipeline.position(of: .resize) > ExportPipeline.position(of: .graph))
        #expect(ExportPipeline.position(of: .encode) > ExportPipeline.position(of: .sharpen))
        #expect(ExportPipeline.position(of: .write) == ExportPipeline.stageOrder.count - 1)
    }

    @Test("JPEG is 8-bit whatever the caller asks for; TIFF is not")
    func effectiveBitDepth() {
        var settings = ExportSettings(format: .jpeg, bitDepth: .sixteen)
        #expect(settings.effectiveBitDepth == .eight)
        settings.format = .tiff
        #expect(settings.effectiveBitDepth == .sixteen)
    }

    @Test("maximumRenderPixels caps the decode; nil does not")
    func renderCap() {
        var notes: [String] = []
        let size = CGSize(width: 6000, height: 4000)
        #expect(
            ExportRenderer.renderLongEdge(
                headerSize: size, settings: ExportSettings(), notes: &notes) == 6000)
        #expect(notes.isEmpty)
        let capped = ExportRenderer.renderLongEdge(
            headerSize: size,
            settings: ExportSettings(maximumRenderPixels: 6_000_000), notes: &notes)
        #expect(capped == 3000)
        #expect(notes.count == 1)
    }

    // MARK: - 2. GPU, a real file

    @Test("Exports a file whose pixels are the source's when nothing is edited")
    func exportRoundTrip() throws {
        guard let context = SpikeS3Support.context else { return }
        let fixture = try Self.Fixture(width: 192, height: 128, context: context)
        defer { fixture.cleanUp() }

        let renderer = try ExportRenderer(context: context)
        try renderer.prewarm()
        let result = try renderer.export(
            ExportJob(
                sourceURL: fixture.sourceURL,
                settings: ExportSettings(format: .tiff, bitDepth: .sixteen),
                destinationDirectory: fixture.directory))

        #expect(FileManager.default.fileExists(atPath: result.url.path))
        #expect(result.byteCount > 0)
        #expect(result.pixelSize == CGSize(width: 192, height: 128))
        #expect(result.renderedSize == result.pixelSize)
        #expect(result.writtenBitsPerComponent == 16)
        #expect(result.stages == [.decode, .upload, .graph, .encode, .write])
        #expect(result.notes.isEmpty)
        #expect(result.timings.total > 0)

        // The picture that came back is the picture that went in. Not
        // "bit-exact": the pipeline is rgba16Float, whose ~5e-4 quantisation is
        // the whole error budget here, so this lands far above the plan's 45 dB
        // golden bar rather than at infinity.
        let written = try Self.decode(result.url)
        let psnr = SpikeTextureIO.psnr(fixture.pixels, written)
        #expect(psnr > 45, "passthrough export PSNR \(psnr) dB")
    }

    @Test("Resizing to a long edge produces exactly that long edge")
    func exportResizes() throws {
        guard let context = SpikeS3Support.context else { return }
        let fixture = try Self.Fixture(width: 256, height: 128, context: context)
        defer { fixture.cleanUp() }

        let renderer = try ExportRenderer(context: context)
        let result = try renderer.export(
            ExportJob(
                sourceURL: fixture.sourceURL,
                settings: ExportSettings(
                    format: .jpeg, quality: 100, resize: .longestEdge(64)),
                destinationDirectory: fixture.directory))
        #expect(result.pixelSize == CGSize(width: 64, height: 32))
        #expect(result.renderedSize == CGSize(width: 256, height: 128))
        #expect(result.stages.contains(.resize))
        #expect(!result.stages.contains(.sharpen))
        let written = try Self.decodeSize(result.url)
        #expect(written == CGSize(width: 64, height: 32))
    }

    @Test("Sharpen is off by default and only runs when asked for")
    func sharpenIsOptIn() throws {
        guard let context = SpikeS3Support.context else { return }
        let fixture = try Self.Fixture(width: 128, height: 128, context: context)
        defer { fixture.cleanUp() }
        let renderer = try ExportRenderer(context: context)

        #expect(ExportSettings().sharpen == 0)
        let plain = try renderer.export(
            ExportJob(sourceURL: fixture.sourceURL, destinationDirectory: fixture.directory))
        #expect(!plain.stages.contains(.sharpen))

        let sharpened = try renderer.export(
            ExportJob(
                sourceURL: fixture.sourceURL,
                settings: ExportSettings(quality: 100, sharpen: 100),
                destinationDirectory: fixture.directory))
        #expect(sharpened.stages.contains(.sharpen))
        // Two different files, not one overwritten.
        #expect(sharpened.url != plain.url)
    }

    @Test("Every format writes a file with an embedded profile")
    func formatsAndProfiles() throws {
        guard let context = SpikeS3Support.context else { return }
        let fixture = try Self.Fixture(width: 96, height: 96, context: context)
        defer { fixture.cleanUp() }
        let renderer = try ExportRenderer(context: context)

        for format in ExportSettings.Format.allCases {
            for profile in ExportSettings.ColorProfile.allCases {
                let result = try renderer.export(
                    ExportJob(
                        sourceURL: fixture.sourceURL,
                        settings: ExportSettings(format: format, colorProfile: profile),
                        destinationDirectory: fixture.directory))
                #expect(
                    result.url.pathExtension == format.fileExtension,
                    "\(format) wrote \(result.url.lastPathComponent)")
                #expect(result.byteCount > 0)
                #expect(
                    result.profileName != nil,
                    "\(format)/\(profile) wrote no ICC profile")
                if profile == .displayP3 {
                    #expect(
                        result.profileName?.localizedCaseInsensitiveContains("P3") == true,
                        "\(format) P3 profile name was \(result.profileName ?? "nil")")
                }
            }
        }
    }

    // MARK: - 3. Honesty

    @Test("A 16-bit JPEG request is written as 8 bits and says so")
    func sixteenBitJPEGIsReported() throws {
        guard let context = SpikeS3Support.context else { return }
        let fixture = try Self.Fixture(width: 64, height: 64, context: context)
        defer { fixture.cleanUp() }
        let renderer = try ExportRenderer(context: context)
        let result = try renderer.export(
            ExportJob(
                sourceURL: fixture.sourceURL,
                settings: ExportSettings(format: .jpeg, bitDepth: .sixteen),
                destinationDirectory: fixture.directory))
        #expect(result.writtenBitsPerComponent == 8)
        #expect(result.notes.contains { $0.contains("8-bit container") })
    }

    @Test("A RAW source says what ImageIO actually decoded")
    func rawSourceIsReported() throws {
        // No GPU needed for the classification itself.
        #expect(ExportRenderer.isRawExtension("ARW"))
        #expect(ExportRenderer.isRawExtension("cr3"))
        #expect(!ExportRenderer.isRawExtension("jpg"))

        guard let context = SpikeS3Support.context else { return }
        // A PNG that *claims* to be a RAW by its extension: enough to prove the
        // note fires on the extension rather than on a lucky size comparison,
        // and it needs no 24 MB fixture in the repo. The real case it was
        // written for is a device run where an `.ARW` decoded to its 1080×1616
        // embedded preview with the file's own properties agreeing.
        let fixture = try Self.Fixture(width: 64, height: 64, context: context)
        defer { fixture.cleanUp() }
        let raw = fixture.directory.appendingPathComponent("DSC05123.ARW")
        try FileManager.default.copyItem(at: fixture.sourceURL, to: raw)

        let renderer = try ExportRenderer(context: context)
        let result = try renderer.export(
            ExportJob(sourceURL: raw, destinationDirectory: fixture.directory))
        #expect(result.notes.contains { $0.contains("RAW source (.arw)") })
        #expect(result.notes.contains { $0.contains("64×64") })
        // A non-RAW export of the same pixels stays quiet.
        let plain = try renderer.export(
            ExportJob(sourceURL: fixture.sourceURL, destinationDirectory: fixture.directory))
        #expect(plain.notes.isEmpty)
    }

    @Test("Two exports of the same shot do not overwrite each other")
    func exportsDoNotOverwrite() throws {
        guard let context = SpikeS3Support.context else { return }
        let fixture = try Self.Fixture(width: 64, height: 64, context: context)
        defer { fixture.cleanUp() }
        let renderer = try ExportRenderer(context: context)
        let job = ExportJob(
            sourceURL: fixture.sourceURL, destinationDirectory: fixture.directory)
        let first = try renderer.export(job)
        let second = try renderer.export(job)
        #expect(first.url != second.url)
        #expect(FileManager.default.fileExists(atPath: first.url.path))
        #expect(FileManager.default.fileExists(atPath: second.url.path))
        // No `.rp-tmp-` debris left behind.
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: fixture.directory.path)
        #expect(!contents.contains { $0.hasPrefix(AtomicFileWriter.temporaryPrefix) })
    }

    @Test("An unreadable source throws instead of writing an empty file")
    func missingSourceThrows() throws {
        guard let context = SpikeS3Support.context else { return }
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = try ExportRenderer(context: context)
        #expect(throws: (any Error).self) {
            try renderer.export(
                ExportJob(
                    sourceURL: directory.appendingPathComponent("nope.jpg"),
                    destinationDirectory: directory))
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.isEmpty)
    }

    // MARK: - Fixture

    /// A real PNG on disk plus the float32 pixels it was made from, so an export
    /// can be compared against its own input.
    ///
    /// PNG rather than JPEG on purpose: the comparison above is meant to measure
    /// the *export*, and a lossy source would fold the source encoder's error
    /// into the number.
    struct Fixture {
        let directory: URL
        let sourceURL: URL
        /// Interleaved RGBA float32 of the source, as `SpikeTextureIO` reads it.
        let pixels: [Float]

        init(width: Int, height: Int, context: MetalContext) throws {
            directory = try ExportRendererTests.makeTemporaryDirectory()
            sourceURL = directory.appendingPathComponent("DSC05123.png")
            let floats = SpikeS3Support.syntheticImage(width: width, height: height)
            let image = try ExportRendererTests.makeCGImage(
                floats, width: width, height: height)
            guard
                let destination = CGImageDestinationCreateWithURL(
                    sourceURL as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { throw ExportError.encodeFailed(format: .tiff) }
            CGImageDestinationAddImage(destination, image, nil)
            _ = CGImageDestinationFinalize(destination)
            // Read the file back rather than keeping `floats`: the 8-bit PNG is
            // what the exporter will actually decode.
            pixels = try ExportRendererTests.decode(sourceURL)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An 8-bit sRGB `CGImage` from interleaved RGBA float32.
    static func makeCGImage(_ pixels: [Float], width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            for c in 0..<3 {
                bytes[i * 4 + c] = UInt8(min(255, max(0, (pixels[i * 4 + c] * 255).rounded())))
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let provider = CGDataProvider(data: Data(bytes) as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else { throw ExportError.cannotCreateContext }
        return image
    }

    /// Interleaved RGBA float32 of a file on disk, in sRGB-encoded values.
    static func decode(_ url: URL) throws -> [Float] {
        let image = try ImageDecoder.decode(contentsOf: url, maxPixelSize: 20000)
        return try SpikeTextureIO.floatPixels(of: image.cgImage, space: .sRGBEncoded).pixels
    }

    static func decodeSize(_ url: URL) throws -> CGSize {
        try ImageDecoder.decode(contentsOf: url, maxPixelSize: 20000).pixelSize
    }
}

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Everything about *how* a finished picture is written, with no reference to
/// which picture it is.
///
/// Kept separate from ``ExportJob`` on purpose: a batch run (docs/PLAN.md
/// Phase 3, `BatchQueue`) has one `ExportSettings` and N jobs, so the settings
/// have to be a value the queue can hold once and hand to every job unchanged.
///
/// ### What is and is not "taste" here
/// `quality`, `resize` and `colorProfile` are the user's choice and come
/// straight from the export sheet. `sharpen` **defaults to 0 (off)**, which is
/// the "measure before ship" rule applied to the one genuinely new image
/// operation in this file: output sharpening has no number attached yet, so it
/// cannot be on by default. The order it runs in (after the resize, never
/// before) is fixed by ``ExportPipeline/stageOrder`` and pinned by a test.
public struct ExportSettings: Sendable, Equatable, Codable {

    /// Container the file is written in.
    public enum Format: String, Sendable, CaseIterable, Codable {
        case jpeg, heif, tiff

        public var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .heif: "heic"
            case .tiff: "tif"
            }
        }

        public var contentType: UTType {
            switch self {
            case .jpeg: .jpeg
            case .heif: .heic
            case .tiff: .tiff
            }
        }

        /// `false` for JPEG, which is an 8-bit-per-channel container full stop.
        /// A 16-bit request is therefore not an error — it is silently 8 bits,
        /// and ``ExportResult/notes`` says so rather than the app pretending.
        public var supportsDeepColor: Bool { self != .jpeg }

        /// `true` when the container is lossy and `quality` means something.
        public var isLossy: Bool { self != .tiff }
    }

    /// Bits per colour channel asked for. What was actually written is read back
    /// off the file into ``ExportResult/writtenBitsPerComponent`` — the encoders
    /// do not all honour 16.
    public enum BitDepth: Int, Sendable, CaseIterable, Codable {
        case eight = 8
        case sixteen = 16
    }

    /// Output size. The resize happens **after** the render graph and **before**
    /// the sharpen (``ExportPipeline/stageOrder``).
    public enum Resize: Sendable, Equatable, Codable {
        /// Whatever the decode produced — for a JPEG/HEIF original that is the
        /// full frame.
        case original
        /// Longest edge in pixels. Only ever scales **down**: asking for 4000 on
        /// a 2000 px file returns the 2000 px file rather than an upscale nobody
        /// asked for.
        case longestEdge(Int)

        /// The output size for a given rendered size.
        public func outputSize(for size: CGSize) -> CGSize {
            guard case .longestEdge(let edge) = self, edge > 0 else { return size }
            let longest = max(size.width, size.height)
            guard longest > CGFloat(edge) else { return size }
            let scale = CGFloat(edge) / longest
            return CGSize(
                width: max(1, (size.width * scale).rounded()),
                height: max(1, (size.height * scale).rounded()))
        }
    }

    /// The ICC profile written into the file.
    public enum ColorProfile: String, Sendable, CaseIterable, Codable {
        case sRGB
        case displayP3

        public var cgColorSpace: CGColorSpace {
            switch self {
            case .sRGB: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            case .displayP3:
                CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
            }
        }
    }

    public var format: Format
    public var bitDepth: BitDepth
    /// 0…100, JPEG/HEIF only (TIFF ignores it). Matches the export sheet's
    /// 80 / 92 / 100 pills.
    public var quality: Int
    public var resize: Resize
    /// 0…100 like every slider in the app. **0 means the pass does not run at
    /// all**, which is the default.
    public var sharpen: Double
    public var colorProfile: ColorProfile
    /// See ``ExportNaming``.
    public var namingTemplate: String
    /// Hard ceiling on the pixel count handed to the `RenderGraph`, or `nil` for
    /// "render whatever the file is".
    ///
    /// The graph keeps up to two full-size `rgba16Float` intermediates plus the
    /// source and the destination — 768 MB at 24 MP — and docs/ADR-0011 records
    /// that this has never been measured on a real iPhone. `nil` is the honest
    /// default (do what was asked); a caller that knows it is memory-bound sets
    /// a number and gets a downscale-before-render, recorded in
    /// ``ExportResult/notes``.
    public var maximumRenderPixels: Int?

    public init(
        format: Format = .jpeg,
        bitDepth: BitDepth = .eight,
        quality: Int = 92,
        resize: Resize = .original,
        sharpen: Double = 0,
        colorProfile: ColorProfile = .sRGB,
        namingTemplate: String = ExportNaming.defaultTemplate,
        maximumRenderPixels: Int? = nil
    ) {
        self.format = format
        self.bitDepth = bitDepth
        self.quality = quality
        self.resize = resize
        self.sharpen = sharpen
        self.colorProfile = colorProfile
        self.namingTemplate = namingTemplate
        self.maximumRenderPixels = maximumRenderPixels
    }

    /// The depth the pixel buffer is built at: 8 for JPEG whatever was asked.
    public var effectiveBitDepth: BitDepth {
        format.supportsDeepColor ? bitDepth : .eight
    }

    /// 0…1 for `kCGImageDestinationLossyCompressionQuality`.
    public var lossyQuality: Double {
        min(1, max(0, Double(quality) / 100))
    }

    /// `true` when the sharpen pass runs.
    public var sharpensOutput: Bool { sharpen > 0 }
}

/// The fixed order of an export, as data rather than as a comment.
///
/// docs/PLAN.md Phase 3 spells out "resize, sharpen **sau** resize". That is not
/// a preference: sharpening first and resampling afterwards throws away exactly
/// the high-frequency detail the sharpen added, and at a 3× downscale it is
/// visible. Keeping the order in a static array lets
/// `ExportPipelineTests.sharpenComesAfterResize` fail if anyone reorders the
/// code, without a GPU and without an image.
public enum ExportPipeline {
    public static let stageOrder: [Stage] = [
        .decode, .upload, .graph, .resize, .sharpen, .encode, .write,
    ]

    public enum Stage: String, Sendable, CaseIterable, Codable {
        case decode, upload, graph, resize, sharpen, encode, write
    }

    /// Index of a stage in the fixed order.
    public static func position(of stage: Stage) -> Int {
        stageOrder.firstIndex(of: stage) ?? -1
    }
}

/// Turns a template plus one shot's facts into a file name.
///
/// Tokens (anything else is copied through literally):
///
/// | token | meaning |
/// |---|---|
/// | `{name}` | original file name without its extension |
/// | `{n}` `{nn}` `{nnn}` | 1-based index in the run, zero-padded to 1/2/3 digits |
/// | `{date}` | `yyyyMMdd` of the export |
/// | `{time}` | `HHmmss` of the export |
/// | `{w}` `{h}` | output pixel size |
/// | `{format}` | `jpeg` / `heif` / `tiff` |
///
/// The extension is **not** part of the template — it comes from
/// ``ExportSettings/Format/fileExtension``, so a user cannot write a `.jpg`
/// template and get a TIFF called `.jpg`.
public enum ExportNaming {
    /// Evoto's default shape, in the app's language-neutral form.
    public static let defaultTemplate = "{name}_retouch"

    /// Characters a file name cannot carry. `:` is included because it is the
    /// HFS path separator and still confuses `NSURL` on macOS.
    static let forbidden = CharacterSet(charactersIn: "/\\:\0")

    public static func fileName(
        template: String,
        originalFileName: String,
        index: Int = 1,
        date: Date = Date(),
        outputSize: CGSize = .zero,
        format: ExportSettings.Format = .jpeg,
        calendar: Calendar = Calendar(identifier: .gregorian),
        timeZone: TimeZone = .current
    ) -> String {
        let base = (originalFileName as NSString).deletingPathExtension
        var components = calendar
        components.timeZone = timeZone
        let parts = components.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)

        var out = template.isEmpty ? defaultTemplate : template
        let replacements: [(String, String)] = [
            ("{name}", base),
            ("{nnn}", String(format: "%03d", index)),
            ("{nn}", String(format: "%02d", index)),
            ("{n}", String(index)),
            (
                "{date}",
                String(
                    format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            ),
            (
                "{time}",
                String(
                    format: "%02d%02d%02d", parts.hour ?? 0, parts.minute ?? 0,
                    parts.second ?? 0)
            ),
            ("{w}", String(Int(outputSize.width.rounded()))),
            ("{h}", String(Int(outputSize.height.rounded()))),
            ("{format}", format.rawValue),
        ]
        for (token, value) in replacements {
            out = out.replacingOccurrences(of: token, with: value)
        }
        let cleaned = out.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = cleaned.isEmpty ? base : cleaned
        return "\(safe).\(format.fileExtension)"
    }

    /// A URL inside `directory` that no file occupies yet.
    ///
    /// An export must never silently replace a file the user already has, and a
    /// batch of frames that all resolve to the same template must not collapse
    /// into one file. The suffix is `-1`, `-2`, … before the extension, which is
    /// what Finder does.
    public static func uniqueURL(
        in directory: URL, fileName: String,
        fileManager: FileManager = .default
    ) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var suffix = 1
        while fileManager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            candidate = directory.appendingPathComponent(name)
            suffix += 1
            if suffix > 9999 { break }
        }
        return candidate
    }
}

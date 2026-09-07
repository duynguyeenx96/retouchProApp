import CoreGraphics
import Foundation
import RPCore

/// A decoded image handed to the UI.
///
/// `@unchecked Sendable` is safe here because every stored property is
/// immutable and `CGImage` itself is an immutable value once created — the
/// only mutation risk would be a caller drawing *into* it, which the API does
/// not allow.
public struct PreviewImage: @unchecked Sendable, Equatable {
    /// The decoded pixels, EXIF orientation already applied.
    public let cgImage: CGImage
    /// Size of `cgImage` in pixels.
    public let pixelSize: CGSize
    /// Size of the full-resolution source, when it could be read cheaply.
    /// The canvas uses it to show a truthful zoom percentage.
    public let sourcePixelSize: CGSize?

    public init(cgImage: CGImage, sourcePixelSize: CGSize? = nil) {
        self.cgImage = cgImage
        self.pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        self.sourcePixelSize = sourcePixelSize
    }

    public static func == (lhs: PreviewImage, rhs: PreviewImage) -> Bool {
        lhs.cgImage === rhs.cgImage
    }
}

/// What the UI asks the engine for: one shot's file, one `EditState`, and the
/// longest edge it wants back.
public struct PreviewRequest: Hashable, Sendable {
    /// The immutable file under `originals/`.
    public var originalURL: URL
    /// The edits to apply. Ignored by ``PassthroughPreviewRenderer`` (Phase 1).
    public var editState: EditState
    /// Longest edge in pixels of the returned image.
    public var maxPixelSize: Int

    public init(originalURL: URL, editState: EditState = EditState(), maxPixelSize: Int = 2048) {
        self.originalURL = originalURL
        self.editState = editState
        self.maxPixelSize = maxPixelSize
    }

    /// The same request with every slider back at its default — i.e. the
    /// "before" side of a before/after comparison.
    public var original: PreviewRequest {
        PreviewRequest(originalURL: originalURL, editState: EditState(), maxPixelSize: maxPixelSize)
    }
}

/// The **decode** seam: a shot's file to a `CGImage`, on the CPU.
///
/// Phase 1 introduced it expecting Phase 2 to swap in a `RenderGraph`-backed
/// conformance. That is **not** what happened, and the reason is worth stating
/// here rather than only in docs/ADR-0013: the edited canvas is now an `MTKView`
/// driven by ``LivePreviewRenderer``, which keeps the picture on the GPU instead
/// of round-tripping it through a `CGImage` on every slider tick (the upload
/// alone is 11–37 ms; a whole redraw is ~7 ms).
///
/// So this protocol keeps the two jobs that genuinely want the *untouched* file:
/// filmstrip thumbnails, and the "before" side of the before/after comparison.
/// ``PassthroughPreviewRenderer`` is the right conformance for both, and it is
/// still the only one.
public protocol PreviewRendering: Sendable {
    /// `false` while the renderer ignores `PreviewRequest.editState`.
    ///
    /// Two callers depend on it: `PreviewImageCache` folds the `EditState`
    /// fingerprint into its key only when this is `true` (otherwise every
    /// thumbnail would be re-decoded on every slider tick), and a UI presenting
    /// this renderer's output as an "after" image would be lying.
    var appliesEditState: Bool { get }

    /// Longest edge the renderer prefers for interactive preview
    /// (docs/PLAN.md §1.4: 1536–2048 px on an A-series iPad).
    var preferredPreviewPixelSize: Int { get }

    func renderPreview(_ request: PreviewRequest) async throws -> PreviewImage
}

extension PreviewRendering {
    public var preferredPreviewPixelSize: Int { 2048 }
}

public enum RPEngineError: Error, Equatable, CustomStringConvertible {
    case cannotOpenImage(path: String)
    case cannotDecodeImage(path: String)

    public var description: String {
        switch self {
        case .cannotOpenImage(let path):
            "Cannot open \(path) as an image."
        case .cannotDecodeImage(let path):
            "Cannot decode \(path); the file may be truncated or an unsupported format."
        }
    }
}

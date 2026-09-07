import Foundation
import RPCore

/// Knobs shared by every importer.
///
/// Defaults are chosen for the plan's workflow (PLAN §1.1: "chụp một loạt →
/// cắm → đổ vào project → auto preset"): the user plugs in a card that may
/// already be half-imported, so de-duplication is on, and RAW must survive
/// untouched, so nothing here can cause a re-encode.
public struct ImportOptions: Sendable, Hashable {
    /// Compute a SHA-256 of each file and store it as `Shot.contentHash`.
    ///
    /// Costs one extra full read of the source — measured 0.65 s/GB warm on
    /// the dev Mac, `Research/bench/rpimport-hash.json`; on an A-series iPad
    /// reading from a card the card, not SHA-256, is the bottleneck. Turn it
    /// off for the fastest
    /// possible ingest; `skipDuplicates` then has nothing to match on and is
    /// ignored.
    public var computeContentHash: Bool

    /// Skip a file whose content hash already belongs to a shot in the project.
    ///
    /// This is what makes re-plugging a card idempotent: the second import of
    /// the same 400 shots adds nothing. Requires `computeContentHash`.
    public var skipDuplicates: Bool

    /// Read EXIF into `Shot.capture` via ImageIO (header only, no decode).
    public var readCaptureMetadata: Bool

    /// Recurse into directories in the input list.
    ///
    /// On by default because dropping a folder of a shoot onto the Mac window
    /// is the obvious gesture, and because a DCIM tree from a card is
    /// `DCIM/100MSDCF/…`.
    public var expandDirectories: Bool

    /// How deep ``expandDirectories`` goes. `DCIM/100MSDCF/DSC01234.ARW` is
    /// depth 2, so 8 leaves a lot of room while still bounding a symlinked
    /// tree.
    public var maximumDirectoryDepth: Int

    /// Wrap each source URL in `startAccessingSecurityScopedResource()`.
    ///
    /// Required for URLs that came from a document picker or a drop into a
    /// sandboxed app (the app is sandboxed — see ADR-0001 §4). Harmless for
    /// URLs that are not security-scoped: the call simply returns `false` and
    /// we carry on.
    public var usesSecurityScopedAccess: Bool

    public init(
        computeContentHash: Bool = true,
        skipDuplicates: Bool = true,
        readCaptureMetadata: Bool = true,
        expandDirectories: Bool = true,
        maximumDirectoryDepth: Int = 8,
        usesSecurityScopedAccess: Bool = true
    ) {
        self.computeContentHash = computeContentHash
        self.skipDuplicates = skipDuplicates
        self.readCaptureMetadata = readCaptureMetadata
        self.expandDirectories = expandDirectories
        self.maximumDirectoryDepth = maximumDirectoryDepth
        self.usesSecurityScopedAccess = usesSecurityScopedAccess
    }

    public static let `default` = ImportOptions()

    /// No hashing, no EXIF: the cheapest possible ingest.
    public static let fastest = ImportOptions(
        computeContentHash: false,
        skipDuplicates: false,
        readCaptureMetadata: false
    )

    var wantsContentHash: Bool { computeContentHash }
    var wantsDeduplication: Bool { computeContentHash && skipDuplicates }
}

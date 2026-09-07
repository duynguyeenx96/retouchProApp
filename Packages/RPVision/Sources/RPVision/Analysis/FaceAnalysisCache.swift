import CoreGraphics
import CryptoKit
import Foundation

/// Cache key for one image's analysis: **what** was analysed plus **how**.
///
/// `docs/PLAN.md` §1.4 and §3: "landmark/parsing chạy 1 lần/ảnh, cache theo hash".
/// `contentHash` is meant to be `RPCore.Shot.contentHash`, the SHA-256 `RPImport`
/// already computes for every file at import time (`RPImport/ContentHash.swift`
/// says so in its own doc comment). RPVision cannot import RPImport — the layering
/// audit forbids it — so the hash arrives as a string, which also means an
/// in-memory image with no file can supply one via `pixelHash(of:)`.
///
/// `optionsFingerprint` is in the key because a result produced with parsing off,
/// or with a different ROI scale, is a *different* answer, and serving it would be
/// a silent wrong result rather than a miss.
public struct FaceAnalysisKey: Hashable, Sendable {
    public let contentHash: String
    public let optionsFingerprint: String

    public init(contentHash: String, options: FaceAnalyzerOptions) {
        self.contentHash = contentHash
        self.optionsFingerprint = options.fingerprint
    }

    public init(contentHash: String, optionsFingerprint: String) {
        self.contentHash = contentHash
        self.optionsFingerprint = optionsFingerprint
    }

    /// SHA-256 over an image's raw pixels, for callers that have no file hash.
    ///
    /// **Prefer `Shot.contentHash`.** This has to touch every byte: a 24 MP frame
    /// is ~96 MB of RGBA and the measured cost is in
    /// `Research/bench/p2-face-analyzer-macos.json` (`pixel_hash_ms`). At preview
    /// sizes it is cheap; at full resolution it is not free, and paying it on every
    /// render would defeat the point of the cache.
    public static func pixelHash(of image: CGImage) -> String {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return "unhashable:\(width)x\(height)" }
        var hasher = SHA256()
        hasher.update(data: Data(bytes))
        // Dimensions are in the digest as well: two different images cannot have
        // the same pixel bytes, but a 100x50 and a 50x100 buffer can.
        hasher.update(data: Data("\(width)x\(height)".utf8))
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Fixed-capacity LRU of `FaceAnalysis` values.
///
/// Deliberately a plain value-semantics box rather than an actor: it is owned by
/// the `FaceAnalyzer` actor, so actor isolation already serialises access, and
/// keeping it synchronous means the eviction policy can be unit-tested with no
/// concurrency at all (`FaceAnalysisCacheTests`).
///
/// Capacity is counted in entries, not bytes. One entry is 478 points + a 512x512
/// byte mask per face, i.e. ~262 KB per face — a 24-entry cache of single-face
/// portraits is ~6 MB, which is the size of the filmstrip window the editor keeps
/// warm, and is why the default is small rather than "as much as fits".
public struct FaceAnalysisCache: Sendable {
    public private(set) var capacity: Int
    private var entries: [FaceAnalysisKey: FaceAnalysis] = [:]
    /// Most recently used last.
    private var order: [FaceAnalysisKey] = []
    public private(set) var hits = 0
    public private(set) var misses = 0
    public private(set) var evictions = 0

    public init(capacity: Int = 24) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { entries.count }

    public mutating func value(for key: FaceAnalysisKey) -> FaceAnalysis? {
        guard let value = entries[key] else {
            misses += 1
            return nil
        }
        hits += 1
        touch(key)
        return value
    }

    /// Look-up that does not count as a hit or a miss; for diagnostics.
    public func peek(_ key: FaceAnalysisKey) -> FaceAnalysis? { entries[key] }

    public mutating func store(_ value: FaceAnalysis, for key: FaceAnalysisKey) {
        if entries[key] == nil, entries.count >= capacity, let oldest = order.first {
            entries.removeValue(forKey: oldest)
            order.removeFirst()
            evictions += 1
        }
        entries[key] = value
        touch(key)
    }

    public mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    public mutating func resetStatistics() {
        hits = 0
        misses = 0
        evictions = 0
    }

    private mutating func touch(_ key: FaceAnalysisKey) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}

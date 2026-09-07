import CryptoKit
import Foundation

/// Streaming SHA-256 of a file, used for `Shot.contentHash`.
///
/// `Shot.contentHash` is documented in RPCore as "hook for content-addressed
/// caching … and import de-duplication. Filled by `RPImport`." This is that
/// fill. The hash is over the **whole file**, so a RAW re-imported from a
/// second card is recognised even after a rename, and Phase 2's `FaceAnalysis`
/// cache can key on it.
///
/// Reading is chunked (`chunkBytes`, default 4 MiB) so a 24 MP ARW never sits
/// in memory in full; a 400-shot card import stays flat in RSS.
public enum ContentHash {
    /// Read size per iteration.
    ///
    /// Measured, not guessed: `Research/bench/hash-chunk-bench.swift` hashes a
    /// 48 MiB file (≈ two a6300 ARW frames) at 256 KiB / 1 MiB / 4 MiB / 16 MiB
    /// with a read-only control, median of 5. On the dev Mac all four land
    /// within ~10 % of each other and 1 MiB is fastest at **1566 MB/s
    /// (0.65 s/GB)**; 256 KiB is the clear loser at 1404 MB/s. Numbers in
    /// `Research/bench/rpimport-hash.json`.
    public static let chunkBytes = 1024 * 1024

    /// Lowercase hex SHA-256 of the file at `url`, prefixed with the algorithm
    /// so a future switch is not silently ambiguous: `"sha256:1f3a…"`.
    public static func of(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkBytes)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return format(hasher.finalize())
    }

    public static func of(_ data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: data)
        return format(hasher.finalize())
    }

    static func format(_ digest: SHA256.Digest) -> String {
        "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

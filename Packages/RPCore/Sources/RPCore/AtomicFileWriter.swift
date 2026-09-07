import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Writes a file so that a reader never sees a half-written one.
///
/// The recipe is write-temp → fsync → `rename(2)` → fsync the directory.
/// `rename` within one directory is atomic on APFS: the destination path
/// switches from the old inode to the new one in a single step, so a crash or a
/// pulled cable leaves either the complete old file or the complete new file,
/// never a truncated mixture. `Data.write(options: .atomic)` does the rename but
/// not the fsyncs, and gives no way to observe the temp file — this type is
/// explicit about both because Phase 4's tethered import has to survive the
/// camera being unplugged mid-write (docs/PLAN.md Phase 4: "Ghi file atomic +
/// fsync").
public struct AtomicFileWriter: Sendable {
    /// `fsync` the temp file before the rename, and the directory after it.
    /// Only turn this off in throughput tests.
    public var synchronizesToDisk: Bool

    /// Test hook, called with the temp file's URL after it is fully written and
    /// **before** the rename. Throwing from it simulates an interruption at the
    /// worst possible moment.
    public var beforeCommit: (@Sendable (URL) throws -> Void)?

    public init(
        synchronizesToDisk: Bool = true,
        beforeCommit: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.synchronizesToDisk = synchronizesToDisk
        self.beforeCommit = beforeCommit
    }

    /// Prefix of the temp files this writer creates. Anything left behind with
    /// this prefix is debris from a crash and is safe to delete.
    public static let temporaryPrefix = ".rp-tmp-"

    public enum Failure: Error, CustomStringConvertible {
        case renameFailed(destination: String, errno: Int32)
        case openFailed(path: String, errno: Int32)

        public var description: String {
            switch self {
            case .renameFailed(let destination, let code):
                "Atomic rename onto \(destination) failed: \(String(cString: strerror(code)))"
            case .openFailed(let path, let code):
                "Could not open \(path): \(String(cString: strerror(code)))"
            }
        }
    }

    /// Atomically replaces the file at `url` with `data`.
    ///
    /// The temp file is created in the *same directory* as the destination, so
    /// the rename never crosses a volume boundary (which would silently degrade
    /// to a copy). On any failure the temp file is removed and the destination
    /// is left exactly as it was.
    public func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            "\(Self.temporaryPrefix)\(UUID().uuidString)"
        )

        do {
            try data.write(to: temporary, options: [.withoutOverwriting])
            if synchronizesToDisk {
                try Self.fsyncFile(at: temporary)
            }
            try beforeCommit?(temporary)

            guard rename(temporary.path, url.path) == 0 else {
                throw Failure.renameFailed(destination: url.path, errno: errno)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }

        if synchronizesToDisk {
            try? Self.fsyncDirectory(at: directory)
        }
    }

    /// Atomically writes `value` as JSON using ``RPJSON/encoder``.
    public func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try write(try RPJSON.encoder.encode(value), to: url)
    }

    private static func fsyncFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        guard fsync(handle.fileDescriptor) == 0 else {
            throw Failure.openFailed(path: url.path, errno: errno)
        }
    }

    /// Makes the rename itself durable. Without this, the *contents* are on
    /// disk but the directory entry pointing at them may not be.
    private static func fsyncDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw Failure.openFailed(path: url.path, errno: errno)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw Failure.openFailed(path: url.path, errno: errno)
        }
    }
}

/// The single JSON encoder/decoder configuration for every RPCore document.
///
/// - `sortedKeys` + `prettyPrinted`: files are diffable and reviewable, and two
///   saves of the same value produce byte-identical output — which is what lets
///   tests assert "nothing changed" instead of eyeballing it.
/// - ISO-8601 dates *with fractional seconds*: readable in a text editor and
///   stable across platforms. Precision is milliseconds, so a decoded `Date` can
///   differ from the original by up to 1 ms; compare dates with a tolerance.
public enum RPJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = dateFormatter.date(from: text) ?? fallbackFormatter.date(from: text)
            else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "\"\(text)\" is not an ISO-8601 date."
                )
            }
            return date
        }
        return decoder
    }

    /// Milliseconds of tolerance when comparing a decoded date to its original.
    public static let dateResolution: TimeInterval = 0.001

    // ISO8601DateFormatter is documented as safe to use from multiple threads
    // once configured; both formatters are configured here and never mutated.
    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Accepts whole-second timestamps too, e.g. hand-written fixtures.
    nonisolated(unsafe) private static let fallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

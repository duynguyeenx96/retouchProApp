import Foundation
import OSLog

/// File logging for the app.
///
/// Logs are written under the app's own Library directory, which on a
/// sandboxed macOS build resolves to
/// `~/Library/Containers/<bundle-id>/Data/Library/Logs/RetouchPro/`
/// so they can be opened directly without Console.app filtering
/// (see docs/PLAN.md §5).
enum AppLog {
    static let logger = Logger(subsystem: bundleIdentifier, category: "app")

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.duynguyen.RetouchPro"
    }

    /// `<container>/Library/Logs/RetouchPro/`, created on first access.
    /// Returns `nil` only if the directory cannot be created.
    static var directory: URL? {
        guard
            let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = library.appendingPathComponent("Logs/RetouchPro", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            logger.error("Cannot create log directory: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Appends a line to `session.log`, creating the file if needed.
    static func write(_ message: String) {
        logger.log("\(message, privacy: .public)")
        guard let file = directory?.appendingPathComponent("session.log") else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Records one launch, so the log path is proven to work on every run.
    static func startSession() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        write("launch RetouchPro \(version) (\(build)) — logs at \(directory?.path ?? "unavailable")")
    }
}

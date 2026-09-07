import Foundation

/// Static source-level audit of the package layering rules from docs/PLAN.md §2.
///
/// This reads the repo's own `.swift` files off disk rather than inspecting a
/// built binary, so it catches a bad `import` the moment it is written even if
/// the offending code is never executed. It is a harness, not a heuristic:
/// every violation it reports names a file and a line.
public enum SourceAudit {
    public struct Violation: Sendable, Hashable, CustomStringConvertible {
        public let file: String
        public let line: Int
        public let importedModule: String
        public let reason: String

        public init(file: String, line: Int, importedModule: String, reason: String) {
            self.file = file
            self.line = line
            self.importedModule = importedModule
            self.reason = reason
        }

        public var description: String {
            "\(file):\(line): imports \(importedModule) — \(reason)"
        }
    }

    /// Walks up from `startPath` looking for the repo's `Packages/` directory.
    /// Returns `nil` when the sources are not reachable (e.g. the build was
    /// relocated), so callers can skip instead of failing spuriously.
    public static func packagesRoot(from startPath: String = #filePath) -> URL? {
        var dir = URL(fileURLWithPath: startPath).deletingLastPathComponent()
        for _ in 0..<12 {
            if dir.lastPathComponent == "Packages",
                FileManager.default.fileExists(atPath: dir.path)
            {
                return dir
            }
            let candidate = dir.appendingPathComponent("Packages")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
                isDir.boolValue
            {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// All `import X` module names in a Swift file, paired with 1-based line numbers.
    /// Lines inside `//` comments are ignored; `@testable import` counts too.
    public static func imports(inSwiftFileAt url: URL) throws -> [(module: String, line: Int)] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var result: [(String, Int)] = []
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
        {
            var line = String(rawLine)
            if let commentRange = line.range(of: "//") {
                line = String(line[line.startIndex..<commentRange.lowerBound])
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let prefixes = ["import ", "@testable import ", "@_exported import ", "public import "]
            guard let prefix = prefixes.first(where: { trimmed.hasPrefix($0) }) else { continue }
            let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            // Drop submodule paths (`import Foundation.NSURL`) and trailing tokens.
            let module = rest.split(whereSeparator: { $0 == "." || $0 == " " }).first.map(String.init)
            if let module, !module.isEmpty {
                result.append((module, index + 1))
            }
        }
        return result
    }

    /// Every `.swift` file under `directory`.
    public static func swiftFiles(under directory: URL) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted {
            $0.path < $1.path
        }
    }

    /// Audits `Packages/<package>/Sources` for imports of `forbidden` modules.
    /// `packagesRoot` should come from ``packagesRoot(from:)``.
    public static func auditSources(
        package: String,
        packagesRoot: URL,
        forbidden: Set<String>,
        reason: String
    ) -> [Violation] {
        let sources = packagesRoot.appendingPathComponent("\(package)/Sources")
        guard FileManager.default.fileExists(atPath: sources.path) else { return [] }
        var violations: [Violation] = []
        for file in swiftFiles(under: sources) {
            guard let found = try? imports(inSwiftFileAt: file) else { continue }
            for entry in found where forbidden.contains(entry.module) {
                violations.append(
                    Violation(
                        file: file.path.replacingOccurrences(
                            of: packagesRoot.path + "/", with: ""),
                        line: entry.line,
                        importedModule: entry.module,
                        reason: reason
                    )
                )
            }
        }
        return violations
    }
}

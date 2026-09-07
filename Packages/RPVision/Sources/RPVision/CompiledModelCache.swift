import CoreML
import Foundation

/// Compiles `.mlpackage` / `.mlmodel` files once per process and caches the
/// `.mlmodelc` in the temporary directory.
///
/// Extracted from `FaceLandmark478Model` (spike S1) when spike S2 added a second
/// Core ML wrapper that needs exactly the same behaviour; the logic and the cache
/// key are unchanged.
enum CompiledModelCache {
    /// Serialises compilation: two suites building the same model concurrently
    /// would otherwise both write the cache entry and one would read a half-written
    /// `coremldata.bin`.
    private static let lock = NSLock()

    /// Compiles `.mlpackage` inputs; passes `.mlmodelc` through untouched.
    static func compiledURL(for url: URL) throws -> URL {
        guard url.pathExtension == "mlpackage" || url.pathExtension == "mlmodel" else {
            return url
        }
        lock.lock()
        defer { lock.unlock() }
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("RPVisionCompiledModels", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        // The cache key carries the source's newest mtime so that recompiling the
        // .mlpackage during a spike does not silently keep serving a stale build.
        var newest = Date.distantPast
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        if let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys))
        {
            for case let item as URL in walker {
                if let date = try? item.resourceValues(forKeys: keys).contentModificationDate {
                    newest = max(newest, date)
                }
            }
        }
        let stamp = String(UInt64(max(0, newest.timeIntervalSince1970)), radix: 36)
        let destination = cache
            .appendingPathComponent(
                "\(url.deletingPathExtension().lastPathComponent)-\(stamp)")
            .appendingPathExtension("mlmodelc")
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        let temp = try MLModel.compileModel(at: url)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            // Another process won the race; its copy is complete, use that.
            guard FileManager.default.fileExists(atPath: destination.path) else { throw error }
        }
        return destination
    }
}

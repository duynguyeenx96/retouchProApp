// Chunk-size benchmark for RPImport's ContentHash.
//
// Answers one question with a number instead of a guess: what read size should
// `ContentHash.chunkBytes` be, and what does hashing cost per GB — because
// `ImportOptions.computeContentHash` adds a full extra read of every imported
// file and the docs claim a figure for it.
//
// Run:  swift Research/bench/hash-chunk-bench.swift [outputPath]
// Writes JSON to Research/bench/rpimport-hash.json by default.
//
// The control is `noHash`: the same file read with the same chunk size and
// thrown away, so the reported hashing cost excludes I/O.

import CryptoKit
import Foundation

let outputPath =
    CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/Research/bench/rpimport-hash.json"

let chunkSizes = [256 * 1024, 1024 * 1024, 4 * 1024 * 1024, 16 * 1024 * 1024]
// 48 MiB ≈ two uncompressed a6300 24 MP ARW frames.
let fileBytes = 48 * 1024 * 1024
let repeats = 5

let workingDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("rp-hash-bench-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workingDirectory) }

let sampleURL = workingDirectory.appendingPathComponent("sample.ARW")
var sample = Data(count: fileBytes)
sample.withUnsafeMutableBytes { raw in
    guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
    var state: UInt64 = 0x2545_F491_4F6C_DD1D
    for index in 0..<fileBytes {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        base[index] = UInt8(truncatingIfNeeded: state)
    }
}
try sample.write(to: sampleURL)

func timeIt(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

func hash(chunk: Int) throws {
    let handle = try FileHandle(forReadingFrom: sampleURL)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: chunk), !data.isEmpty {
        hasher.update(data: data)
    }
    _ = hasher.finalize()
}

/// Control: identical read pattern, no hashing.
func readOnly(chunk: Int) throws {
    let handle = try FileHandle(forReadingFrom: sampleURL)
    defer { try? handle.close() }
    var total = 0
    while let data = try handle.read(upToCount: chunk), !data.isEmpty {
        total &+= data.count
    }
    precondition(total == fileBytes)
}

struct Measurement: Codable {
    var chunkBytes: Int
    var hashMillisecondsMedian: Double
    var readOnlyMillisecondsMedian: Double
    var megabytesPerSecond: Double
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

var measurements: [Measurement] = []
for chunk in chunkSizes {
    _ = try timeIt { try hash(chunk: chunk) }  // warm the page cache
    let hashTimes = try (0..<repeats).map { _ in try timeIt { try hash(chunk: chunk) } }
    let readTimes = try (0..<repeats).map { _ in try timeIt { try readOnly(chunk: chunk) } }
    let hashMedian = median(hashTimes)
    measurements.append(
        Measurement(
            chunkBytes: chunk,
            hashMillisecondsMedian: hashMedian,
            readOnlyMillisecondsMedian: median(readTimes),
            megabytesPerSecond: (Double(fileBytes) / 1_048_576) / (hashMedian / 1000)
        ))
}

struct Report: Codable {
    var benchmark = "RPImport.ContentHash chunk size"
    var generatedAt: String
    var host: String
    var fileBytes: Int
    var repeats: Int
    var note: String
    var measurements: [Measurement]
    var fastestChunkBytes: Int
    var secondsPerGigabyteAtFastest: Double
}

let best = measurements.min { $0.hashMillisecondsMedian < $1.hashMillisecondsMedian }!
let formatter = ISO8601DateFormatter()
let report = Report(
    generatedAt: formatter.string(from: Date()),
    host: ProcessInfo.processInfo.operatingSystemVersionString,
    fileBytes: fileBytes,
    repeats: repeats,
    note:
        "Median of \(repeats) runs after one warm-up, page cache warm. `readOnly` is the control: "
        + "same read pattern, no SHA-256, so the difference is the hashing cost.",
    measurements: measurements,
    fastestChunkBytes: best.chunkBytes,
    secondsPerGigabyteAtFastest: 1024 / best.megabytesPerSecond
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(report).write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
for measurement in measurements {
    print(
        String(
            format: "chunk %7d KiB  hash %7.1f ms  read %7.1f ms  %6.0f MB/s",
            measurement.chunkBytes / 1024,
            measurement.hashMillisecondsMedian,
            measurement.readOnlyMillisecondsMedian,
            measurement.megabytesPerSecond))
}
print(String(format: "fastest chunk %d bytes, %.2f s/GB", best.chunkBytes, report.secondsPerGigabyteAtFastest))

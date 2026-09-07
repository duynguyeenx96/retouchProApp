import Foundation
import Testing

@testable import RPCore

/// A scratch directory that removes itself when the test ends.
final class TemporaryDirectory {
    let url: URL

    init(_ label: String = "rpcore") throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Names of everything directly inside `url`, including dot-files.
    func entries(at subpath: String = "") throws -> [String] {
        let directory = subpath.isEmpty ? url : url.appendingPathComponent(subpath)
        return try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .sorted()
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite("AtomicFileWriter")
struct AtomicFileWriterTests {
    @Test("Writes the file and leaves no temp debris")
    func writesCleanly() throws {
        let temp = try TemporaryDirectory("atomic")
        let target = temp.url.appendingPathComponent("doc.json")

        try AtomicFileWriter().write(Data("hello".utf8), to: target)

        #expect(try String(contentsOf: target, encoding: .utf8) == "hello")
        #expect(try temp.entries() == ["doc.json"])
    }

    @Test("Overwriting replaces the contents, still with no debris")
    func overwrites() throws {
        let temp = try TemporaryDirectory("atomic")
        let target = temp.url.appendingPathComponent("doc.json")
        let writer = AtomicFileWriter()

        try writer.write(Data("first".utf8), to: target)
        try writer.write(Data("second, much longer".utf8), to: target)

        #expect(try String(contentsOf: target, encoding: .utf8) == "second, much longer")
        #expect(try temp.entries() == ["doc.json"])
    }

    @Test("The temp file really exists before the rename, in the same directory")
    func temporaryFileIsExercised() throws {
        let temp = try TemporaryDirectory("atomic")
        let target = temp.url.appendingPathComponent("doc.json")

        // Captured from inside the write, so this asserts the actual code path
        // rather than the absence of an observable side effect.
        final class Box: @unchecked Sendable {
            var observedPath: String?
            var contentsAtCommit: String?
            var targetExistedAtCommit: Bool?
        }
        let box = Box()
        let writer = AtomicFileWriter(beforeCommit: { url in
            box.observedPath = url.path
            box.contentsAtCommit = try? String(contentsOf: url, encoding: .utf8)
            box.targetExistedAtCommit = FileManager.default.fileExists(atPath: target.path)
        })

        try writer.write(Data("payload".utf8), to: target)

        let observed = try #require(box.observedPath)
        #expect(
            observed.hasPrefix(temp.url.path + "/" + AtomicFileWriter.temporaryPrefix),
            "temp file must be a sibling of the destination so rename(2) stays on one volume")
        #expect(box.contentsAtCommit == "payload", "temp file is complete before the rename")
        #expect(box.targetExistedAtCommit == false)
        #expect(try temp.entries() == ["doc.json"])
    }

    @Test("An interruption before the commit leaves the previous file untouched")
    func interruptionPreservesOldContents() throws {
        let temp = try TemporaryDirectory("atomic")
        let target = temp.url.appendingPathComponent("doc.json")
        struct Interrupted: Error {}

        try AtomicFileWriter().write(Data("original".utf8), to: target)

        let crashing = AtomicFileWriter(beforeCommit: { _ in throw Interrupted() })
        #expect(throws: Interrupted.self) {
            try crashing.write(Data("replacement that never lands".utf8), to: target)
        }

        #expect(
            try String(contentsOf: target, encoding: .utf8) == "original",
            "a failed write must not corrupt or truncate the previous version")
        #expect(try temp.entries() == ["doc.json"], "the temp file must be cleaned up")
    }

    @Test("An interruption on a first write leaves no file at all")
    func interruptionLeavesNoPartialFile() throws {
        let temp = try TemporaryDirectory("atomic")
        let target = temp.url.appendingPathComponent("doc.json")
        struct Interrupted: Error {}

        let crashing = AtomicFileWriter(beforeCommit: { _ in throw Interrupted() })
        #expect(throws: Interrupted.self) {
            try crashing.write(Data("never lands".utf8), to: target)
        }

        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try temp.entries().isEmpty, "no half-written file, no temp debris")
    }

    @Test("writeJSON produces the same bytes as the shared encoder")
    func writesJSON() throws {
        let temp = try TemporaryDirectory("atomic")
        let target = temp.url.appendingPathComponent("state.json")
        var state = EditState()
        state.setSlider("smooth", in: "skin", to: 40)

        try AtomicFileWriter().writeJSON(state, to: target)

        #expect(try Data(contentsOf: target) == (try RPJSON.encoder.encode(state)))
    }
}

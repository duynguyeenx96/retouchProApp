import Foundation
import Testing

@testable import RPCore

/// The Share Extension → app contract (docs/ADR-0017). Every case here is
/// reachable from another process: the URL is untrusted input.
@Suite("ShareHandoff")
struct ShareHandoffTests {
    @Test("A built URL parses back to the same names")
    func roundTrip() throws {
        let url = try #require(ShareHandoff.makeOpenURL(fileNames: ["IMG_0042.HEIC"]))
        #expect(url.scheme == "retouchpro")
        #expect(url.host == "open")
        let request = try #require(ShareHandoff.parse(url))
        #expect(request.fileNames == ["IMG_0042.HEIC"])
    }

    @Test("Names needing escaping survive the round trip")
    func roundTripEscaping() throws {
        let name = "Ảnh cưới 01 (bản gốc).jpg"
        let url = try #require(ShareHandoff.makeOpenURL(fileNames: [name]))
        #expect(url.absoluteString.contains("%"))
        #expect(ShareHandoff.parse(url)?.fileNames == [name])
    }

    @Test("Several files keep their order")
    func multipleFiles() throws {
        let names = ["a.jpg", "b.png", "c.arw"]
        let url = try #require(ShareHandoff.makeOpenURL(fileNames: names))
        #expect(ShareHandoff.parse(url)?.fileNames == names)
    }

    @Test(
        "Path-like and non-image names are rejected",
        arguments: [
            "../../../../etc/passwd",
            "../secrets.jpg",
            "sub/dir/photo.jpg",
            "/absolute/photo.jpg",
            ".hidden.jpg",
            "photo.exe",
            "photo",
            "",
            ".",
            "..",
            "back\\slash.jpg",
        ])
    func unsafeNames(name: String) {
        #expect(ShareHandoff.isSafeFileName(name) == false)
        #expect(ShareHandoff.makeOpenURL(fileNames: [name]) == nil)
    }

    @Test("Importable extensions are accepted", arguments: ["a.jpg", "B.HEIC", "raw.arw", "x.tiff"])
    func safeNames(name: String) {
        #expect(ShareHandoff.isSafeFileName(name))
    }

    @Test("A URL that is not ours is not parsed")
    func foreignURLs() {
        #expect(ShareHandoff.parse(URL(string: "https://example.com/open?file=a.jpg")!) == nil)
        #expect(ShareHandoff.parse(URL(string: "retouchpro://delete?file=a.jpg")!) == nil)
        #expect(ShareHandoff.parse(URL(string: "retouchpro://open")!) == nil)
        #expect(ShareHandoff.parse(URL(string: "retouchpro://open?file=")!) == nil)
    }

    @Test("An unknown payload version is refused rather than guessed")
    func unknownVersion() {
        let url = URL(string: "retouchpro://open?v=99&file=a.jpg")!
        #expect(ShareHandoff.parse(url) == nil)
    }

    @Test("A URL with no version is accepted as version 1")
    func missingVersion() {
        let url = URL(string: "retouchpro://open?file=a.jpg")!
        #expect(ShareHandoff.parse(url)?.fileNames == ["a.jpg"])
    }

    @Test("Unsafe names inside an otherwise valid URL are dropped")
    func mixedNames() throws {
        let url = URL(string: "retouchpro://open?file=ok.jpg&file=..%2Fescape.jpg")!
        #expect(ShareHandoff.parse(url)?.fileNames == ["ok.jpg"])
    }

    @Test("Resolve keeps only names that exist in the inbox")
    func resolveExisting() throws {
        let inbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ShareHandoffTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: inbox) }
        try Data([0x1]).write(to: inbox.appendingPathComponent("there.jpg"))

        let request = ShareHandoff.OpenRequest(fileNames: ["there.jpg", "gone.jpg"])
        let resolved = ShareHandoff.resolve(request, inboxURL: inbox)
        #expect(resolved.map(\.lastPathComponent) == ["there.jpg"])

        ShareHandoff.discard(resolved)
        #expect(ShareHandoff.resolve(request, inboxURL: inbox).isEmpty)
    }

    @Test("Resolve with no container yields nothing rather than trapping")
    func resolveWithoutContainer() {
        let request = ShareHandoff.OpenRequest(fileNames: ["a.jpg"])
        #expect(ShareHandoff.resolve(request, inboxURL: nil).isEmpty)
    }

    @Test("Unique names keep the readable stem and never collide")
    func uniqueNames() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ShareHandoffNames-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = ShareHandoff.uniqueFileName(
            suggested: "IMG_0042.HEIC", fallbackExtension: "jpg", in: dir)
        #expect(first == "IMG_0042.heic")
        try Data([0x1]).write(to: dir.appendingPathComponent(first))

        let second = ShareHandoff.uniqueFileName(
            suggested: "IMG_0042.HEIC", fallbackExtension: "jpg", in: dir)
        #expect(second == "IMG_0042-2.heic")
        #expect(ShareHandoff.isSafeFileName(second))
    }

    @Test("A hostile suggested name is scrubbed into a safe one")
    func hostileSuggestedName() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ShareHandoffNames-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let name = ShareHandoff.uniqueFileName(
            suggested: "../../etc/passwd", fallbackExtension: "jpg", in: dir)
        #expect(ShareHandoff.isSafeFileName(name))
        #expect(name.contains("/") == false)

        let empty = ShareHandoff.uniqueFileName(suggested: nil, fallbackExtension: "heic", in: dir)
        #expect(empty == "Shared.heic")
    }

    @Test("An unusable extension falls back rather than producing a rejected name")
    func extensionFallback() {
        #expect(ShareHandoff.normalisedExtension(of: "HEIC", fallback: "jpg") == "heic")
        #expect(ShareHandoff.normalisedExtension(of: "exe", fallback: "png") == "png")
        #expect(ShareHandoff.normalisedExtension(of: "", fallback: "") == "jpg")
    }
}

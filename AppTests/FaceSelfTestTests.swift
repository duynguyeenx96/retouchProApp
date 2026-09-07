import Foundation
import RPCore
import Testing

/// `FaceSelfTest` (docs/ADR-0015) is the env-var-gated launch-time face run that
/// makes a real iPhone checkable without tapping it. The run itself needs a
/// device; the *choice of file* is a pure function and is tested here, because
/// "the self-test silently analysed the wrong photo" would be worse than no
/// self-test at all.
@Suite("Face self-test target resolution")
struct FaceSelfTestTests {

    /// A project library with one `.rpproj` holding the named originals.
    private func makeLibrary(originals: [String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rp-selftest-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("Shoot.rpproj", isDirectory: true)
        let store = ProjectStore(bundleURL: bundle)
        try store.createDirectories()
        var project = Project(name: "Shoot")
        for name in originals {
            let file = bundle.appendingPathComponent(ProjectBundle.originalsDirectory)
                .appendingPathComponent(name)
            try Data("not a real image".utf8).write(to: file)
            try store.addShot(existingOriginalRelativePath: "originals/\(name)", into: &project)
        }
        try store.save(project)
        return root
    }

    @Test("The environment value picks the mode")
    func targetParsing() {
        #expect(FaceSelfTest.target(environment: [:]) == nil)
        #expect(FaceSelfTest.target(environment: ["RP_FACE_SELFTEST": ""]) == nil)
        if case .firstShot? = FaceSelfTest.target(environment: ["RP_FACE_SELFTEST": "1"]) {
        } else {
            Issue.record("\"1\" should mean the first shot")
        }
        if case .path(let url)? = FaceSelfTest.target(environment: ["RP_FACE_SELFTEST": "/tmp/a.jpg"])
        {
            #expect(url.path == "/tmp/a.jpg")
        } else {
            Issue.record("an absolute path should be taken literally")
        }
        if case .fileName(let name)? = FaceSelfTest.target(
            environment: ["RP_FACE_SELFTEST": "DSC05259.jpg"])
        {
            #expect(name == "DSC05259.jpg")
        } else {
            Issue.record("a bare name should be looked up in the library")
        }
    }

    /// The case the device run actually uses: a file pushed into `originals/`
    /// with `devicectl`, named on the command line.
    @Test("A bare file name resolves inside the project library")
    func resolvesByName() throws {
        let root = try makeLibrary(originals: ["a.jpg", "DSC05259.jpg"])
        defer { try? FileManager.default.removeItem(at: root) }

        guard case .file(let url) = FaceSelfTest.resolve(
            .fileName("DSC05259.jpg"), libraryRoot: root)
        else {
            Issue.record("should have found DSC05259.jpg")
            return
        }
        #expect(url.lastPathComponent == "DSC05259.jpg")

        // …and a name that is not there names the ones that are, rather than
        // failing with nothing to go on.
        guard case .failure(let reason) = FaceSelfTest.resolve(
            .fileName("nope.jpg"), libraryRoot: root)
        else {
            Issue.record("should not have found nope.jpg")
            return
        }
        #expect(reason.contains("DSC05259.jpg"))
    }

    @Test("first-shot takes the first original, and says so when there is none")
    func resolvesFirstShot() throws {
        let root = try makeLibrary(originals: ["b.jpg", "a.jpg"])
        defer { try? FileManager.default.removeItem(at: root) }

        guard case .file(let url) = FaceSelfTest.resolve(.firstShot, libraryRoot: root) else {
            Issue.record("should have found an original")
            return
        }
        #expect(url.lastPathComponent == "a.jpg")

        let empty = try makeLibrary(originals: [])
        defer { try? FileManager.default.removeItem(at: empty) }
        guard case .failure = FaceSelfTest.resolve(.firstShot, libraryRoot: empty) else {
            Issue.record("an empty library has no first shot")
            return
        }
        guard case .failure = FaceSelfTest.resolve(.firstShot, libraryRoot: nil) else {
            Issue.record("no library at all is a failure, not a crash")
            return
        }
    }

    @Test("An absolute path that is not there fails instead of guessing")
    func missingPath() {
        guard case .failure(let reason) = FaceSelfTest.resolve(
            .path(URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID()).jpg")),
            libraryRoot: nil)
        else {
            Issue.record("a missing file should not resolve")
            return
        }
        #expect(reason.contains("no file at"))
    }
}

import Foundation
import RPCore
import RPUI
import Testing

/// `App/ShareHandoffRouter.swift` — the app half of the Share Extension
/// hand-off (docs/ADR-0017).
///
/// Like the other bundles in this target it has **no TEST_HOST** and compiles
/// the app file into itself, so this runs on macOS and on the Simulator with no
/// app launch and no Share Sheet. The inbox is injected, which is what makes the
/// untrusted-URL cases testable at all: the real one is an App Group container
/// that only exists on a signed, entitled build.
@MainActor
@Suite("Share handoff router")
struct ShareHandoffRouterTests {
    /// A temporary stand-in for the App Group inbox.
    private struct Inbox {
        let url: URL

        init() throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("share-inbox-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        @discardableResult
        func write(_ name: String) throws -> URL {
            let file = url.appendingPathComponent(name)
            try Data([0xFF, 0xD8, 0xFF]).write(to: file)
            return file
        }

        func cleanUp() { try? FileManager.default.removeItem(at: url) }
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(line)
        }
        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        var joined: String { all.joined(separator: "\n") }
    }

    private func makeRouter(inbox: URL?, lines: Lines) -> ShareHandoffRouter {
        ShareHandoffRouter(inboxURL: { inbox }, log: { lines.append($0) })
    }

    @Test("A real hand-off becomes a pending open request")
    func handsOver() throws {
        let inbox = try Inbox()
        defer { inbox.cleanUp() }
        try inbox.write("IMG_0042.heic")

        let lines = Lines()
        let coordinator = ExternalOpenCoordinator()
        let router = makeRouter(inbox: inbox.url, lines: lines)
        let url = try #require(ShareHandoff.makeOpenURL(fileNames: ["IMG_0042.heic"]))

        #expect(router.handle(url, with: coordinator))
        let pending = try #require(coordinator.pending)
        #expect(pending.fileURLs.map(\.lastPathComponent) == ["IMG_0042.heic"])
        // The inbox is a hand-off buffer, so the app owns deleting it after
        // ingest — the request has to say so.
        #expect(pending.removesSourcesAfterImport)
        // …and the project it will create is named like every other project.
        #expect(pending.projectName == ProjectLibrary.suggestedProjectName())
        #expect(lines.joined.contains("share handoff: 1 file"))
    }

    @Test("A URL from another app cannot escape the inbox")
    func pathTraversalIsRefused() throws {
        let inbox = try Inbox()
        defer { inbox.cleanUp() }
        // Something worth stealing, one level up from the inbox.
        let outside = inbox.url.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).jpg")
        try Data([0x1]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let lines = Lines()
        let coordinator = ExternalOpenCoordinator()
        let router = makeRouter(inbox: inbox.url, lines: lines)
        let escape = "../\(outside.lastPathComponent)"
        let url = try #require(
            URL(
                string: "retouchpro://open?file="
                    + escape.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!))

        // Parsing refuses the name outright, so this is not even "our" URL.
        #expect(router.handle(url, with: coordinator) == false)
        #expect(coordinator.pending == nil)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("A name that is not in the inbox opens nothing")
    func missingFile() throws {
        let inbox = try Inbox()
        defer { inbox.cleanUp() }

        let lines = Lines()
        let coordinator = ExternalOpenCoordinator()
        let router = makeRouter(inbox: inbox.url, lines: lines)
        let url = try #require(ShareHandoff.makeOpenURL(fileNames: ["never-written.jpg"]))

        // Still "ours" — it is a well-formed request — but there is nothing to
        // open, and the user is told rather than being dropped in an empty
        // editor.
        #expect(router.handle(url, with: coordinator))
        #expect(coordinator.pending == nil)
        #expect(coordinator.lastMessage != nil)
        #expect(lines.joined.contains("nothing to open"))
    }

    @Test("URLs that are not ours are passed over")
    func foreignURL() throws {
        let inbox = try Inbox()
        defer { inbox.cleanUp() }
        let lines = Lines()
        let coordinator = ExternalOpenCoordinator()
        let router = makeRouter(inbox: inbox.url, lines: lines)

        #expect(router.handle(URL(string: "https://example.com")!, with: coordinator) == false)
        #expect(router.handle(URL(string: "file:///tmp/a.jpg")!, with: coordinator) == false)
        #expect(coordinator.pending == nil)
    }

    @Test("A build with no App Group says so in the log instead of failing quietly")
    func missingContainerIsReported() throws {
        let lines = Lines()
        let coordinator = ExternalOpenCoordinator()
        let router = makeRouter(inbox: nil, lines: lines)
        let url = try #require(ShareHandoff.makeOpenURL(fileNames: ["IMG_0042.heic"]))

        #expect(router.handle(url, with: coordinator))
        #expect(coordinator.pending == nil)
        #expect(lines.joined.contains("NO App Group container"))
        #expect(router.containerReport.contains("UNAVAILABLE"))
    }

    @Test("The startup report names the container when there is one")
    func containerReport() throws {
        let inbox = try Inbox()
        defer { inbox.cleanUp() }
        let router = makeRouter(inbox: inbox.url, lines: Lines())
        #expect(router.containerReport.contains(inbox.url.path))
    }

    // MARK: - The launch-time inbox scan

    @Test("A share left in the inbox is opened at the next launch")
    func inboxScan() throws {
        let inbox = try Inbox()
        defer { inbox.cleanUp() }
        try inbox.write("IMG_0042.heic")
        try inbox.write("IMG_0043.jpg")

        let lines = Lines()
        let coordinator = ExternalOpenCoordinator()
        let router = makeRouter(inbox: inbox.url, lines: lines)

        #expect(router.handleInbox(with: coordinator))
        #expect(
            coordinator.pending?.fileURLs.map(\.lastPathComponent) == [
                "IMG_0042.heic", "IMG_0043.jpg",
            ])
        #expect(lines.joined.contains("still in the inbox at launch"))
    }

    @Test("An empty inbox, or none at all, opens nothing")
    func inboxScanFindsNothing() throws {
        let inbox = try Inbox()
        defer { inbox.cleanUp() }
        let coordinator = ExternalOpenCoordinator()
        #expect(makeRouter(inbox: inbox.url, lines: Lines()).handleInbox(with: coordinator) == false)
        #expect(makeRouter(inbox: nil, lines: Lines()).handleInbox(with: coordinator) == false)
        #expect(coordinator.pending == nil)
    }

    @Test("Files that are not importable images are left where they are")
    func inboxScanIgnoresJunk() throws {
        let inbox = try Inbox()
        defer { inbox.cleanUp() }
        try inbox.write("notes.txt")
        let coordinator = ExternalOpenCoordinator()
        #expect(makeRouter(inbox: inbox.url, lines: Lines()).handleInbox(with: coordinator) == false)
        #expect(coordinator.pending == nil)
    }

    /// The cold-start case where both entry points fire: the URL arrives *and*
    /// the launch scan sees the same file. One project, not two.
    @Test("The URL and the launch scan cannot both open the same photo")
    func urlAndScanDoNotDoubleUp() throws {
        let inbox = try Inbox()
        defer { inbox.cleanUp() }
        try inbox.write("IMG_0042.heic")

        let coordinator = ExternalOpenCoordinator()
        let router = makeRouter(inbox: inbox.url, lines: Lines())
        let url = try #require(ShareHandoff.makeOpenURL(fileNames: ["IMG_0042.heic"]))

        #expect(router.handle(url, with: coordinator))
        let first = try #require(coordinator.take())
        #expect(first.fileURLs.count == 1)

        // The scan runs afterwards and finds the file still there, because
        // ingest has not finished yet. It must not queue anything: the URL
        // hand-off already claimed this launch.
        #expect(router.handleInbox(with: coordinator) == false)
        #expect(coordinator.pending == nil)
    }

    // MARK: - The device hook

    @Test("The self test is off unless RP_SHARE_SELFTEST names a file")
    func selfTestIsOptIn() {
        #expect(ShareHandoffSelfTest.target(environment: [:]) == nil)
        #expect(
            ShareHandoffSelfTest.target(
                environment: [ShareHandoffSelfTest.environmentKey: ""]) == nil)
        #expect(
            ShareHandoffSelfTest.target(
                environment: [ShareHandoffSelfTest.environmentKey: " , "]) == nil)
    }

    @Test("Its target is the file names plus an optional delay")
    func selfTestTarget() {
        let cold = ShareHandoffSelfTest.target(
            environment: [ShareHandoffSelfTest.environmentKey: "DSC05259.jpg"])
        #expect(cold == ShareHandoffSelfTest.Target(fileNames: ["DSC05259.jpg"], delay: 0))

        let warm = ShareHandoffSelfTest.target(environment: [
            ShareHandoffSelfTest.environmentKey: " a.jpg , b.heic ",
            ShareHandoffSelfTest.delayEnvironmentKey: "6",
        ])
        #expect(warm == ShareHandoffSelfTest.Target(fileNames: ["a.jpg", "b.heic"], delay: 6))

        // A nonsense delay is 0, not a crash and not a hang.
        let odd = ShareHandoffSelfTest.target(environment: [
            ShareHandoffSelfTest.environmentKey: "a.jpg",
            ShareHandoffSelfTest.delayEnvironmentKey: "soon",
        ])
        #expect(odd?.delay == 0)
    }

    @Test("It delivers the same URL the extension would have opened")
    func selfTestDelivers() async throws {
        let lines = Lines()
        let target = ShareHandoffSelfTest.Target(fileNames: ["IMG_0042.heic"], delay: 0)
        let delivered = Lines()
        await ShareHandoffSelfTest.run(target: target, log: { lines.append($0) }) { url in
            delivered.append(url.absoluteString)
        }
        let string = try #require(delivered.all.first)
        let url = try #require(URL(string: string))
        // Parsing it back is the assertion that matters: whatever the hook
        // hands over has to be a URL the router accepts.
        let parsed = try #require(ShareHandoff.parse(url))
        #expect(parsed.fileNames == ["IMG_0042.heic"])
    }
}

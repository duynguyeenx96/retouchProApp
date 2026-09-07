import Foundation
import Testing

@testable import RPCore

/// `ProjectSession` moved here from RPImport in the Phase 1 review: it is
/// project *ownership*, not importing, and RPUI / the Phase 3 batch queue /
/// the Phase 4 tether daemon all need it without linking PhotoKit and
/// ImageCaptureCore. These tests import nothing but RPCore, which is the
/// property being asserted as much as anything in the bodies.
@Suite("ProjectSession — serialised project ownership")
struct ProjectSessionTests {
    private func makeSession(name: String = "Shoot") throws -> (URL, ProjectSession, ProjectStore) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rpcore-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let created = try ProjectStore.create(name: name, in: root)
        return (root, ProjectSession(store: created.store, project: created.project), created.store)
    }

    @Test("Concurrent read-modify-writes all land — no lost update")
    func concurrentWritersDoNotLoseEachOther() async throws {
        let (root, session, _) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    await session.withProject { project, _ in
                        // Read-modify-write on a value type: without the actor
                        // serialising it, writers overwrite each other and the
                        // count comes out short.
                        project.presetOrder.append(PresetID("p-\(index)")!)
                    }
                }
            }
        }

        let order = await session.current.presetOrder
        #expect(order.count == 40)
        #expect(Set(order.map(\.rawValue)).count == 40)
    }

    @Test("replace(with:) saves, and the manifest on disk agrees")
    func replacePersists() async throws {
        let (root, session, store) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = await session.current
        project.name = "Renamed Shoot"
        try await session.replace(with: project)

        #expect(await session.current.name == "Renamed Shoot")
        #expect(try store.load().project.name == "Renamed Shoot")
    }

    @Test("A throwing body propagates and does not wedge the session")
    func throwingBodyIsRethrown() async throws {
        struct Boom: Error {}
        let (root, session, _) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: Boom.self) {
            try await session.withProject { _, _ in throw Boom() }
        }

        await session.withProject { project, _ in project.presetOrder = [PresetID("p-ok")!] }
        #expect(await session.current.presetOrder.map(\.rawValue) == ["p-ok"])
    }
}

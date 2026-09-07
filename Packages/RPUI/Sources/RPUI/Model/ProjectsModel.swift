import Foundation
import Observation
import RPCore

/// Backs ``ProjectsView``: the list of `.rpproj` bundles in the library folder,
/// plus create / open.
///
/// The scan and the create both run off the main actor — a library folder on an
/// external volume can block for seconds — but the published state is
/// main-actor only.
@MainActor
@Observable
public final class ProjectsModel {
    public private(set) var entries: [ProjectEntry] = []
    public private(set) var isLoading = false
    public private(set) var lastErrorMessage: String?
    public let library: ProjectLibrary

    public init(library: ProjectLibrary) {
        self.library = library
    }

    /// Uses the default library folder, falling back to a temporary directory
    /// so the projects list can still render (with an error) if Documents is
    /// unreachable.
    public convenience init() {
        do {
            self.init(library: try ProjectLibrary.default())
        } catch {
            self.init(library: ProjectLibrary(rootURL: URL(fileURLWithPath: NSTemporaryDirectory())))
            lastErrorMessage = "Could not open the projects folder: \(error)"
        }
    }

    public func reload() async {
        isLoading = true
        defer { isLoading = false }
        let library = self.library
        do {
            entries = try await Task.detached { try library.entries() }.value
        } catch {
            entries = []
            lastErrorMessage = "Could not list projects: \(error)"
        }
    }

    /// Creates a project and returns its bundle URL so the caller can navigate
    /// straight into the editor. `nil` on failure, with `lastErrorMessage` set.
    public func createProject(named name: String) async -> URL? {
        let library = self.library
        do {
            let created = try await Task.detached { try library.createProject(named: name) }.value
            await reload()
            return created.store.bundleURL
        } catch {
            lastErrorMessage = "Could not create \"\(name)\": \(error)"
            return nil
        }
    }

    /// Adopts a bundle the user picked from anywhere on disk by listing it in
    /// the library. Phase 1 only *reads* it in place; it is not copied or moved.
    public func entry(forBundleAt url: URL) -> ProjectEntry {
        library.entry(forBundleAt: url)
    }

    public func dismissError() { lastErrorMessage = nil }

    public var suggestedProjectName: String { ProjectLibrary.suggestedProjectName() }
}

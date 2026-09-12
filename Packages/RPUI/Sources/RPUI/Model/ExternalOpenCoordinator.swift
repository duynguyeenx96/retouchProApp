import Foundation
import Observation
import RPCore

/// A request to open the app on a photo that came from **outside** it — today
/// the iOS Share Extension ("Mở với RetouchPro", docs/PLAN.md §Phase 3B), later
/// anything else that can hand over a file.
///
/// The point of routing this through a value instead of calling into the editor
/// directly is that the two cases the feature has to get right — the app was not
/// running (cold start) and the app was already in the background (warm start) —
/// then differ only in *when* ``ExternalOpenCoordinator/request(fileURLs:projectName:)``
/// is called. The view reacts to the pending request the same way either time.
public struct ExternalOpenRequest: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// Files to ingest, already resolved to somewhere this process can read.
    public var fileURLs: [URL]
    /// Name for the project that will be created for them. Defaults to
    /// `ProjectLibrary.suggestedProjectName()` — the same "Shoot yyyy-MM-dd" the
    /// "New project" button uses, deliberately, so a project made by the Share
    /// Extension is indistinguishable from one made by hand.
    public var projectName: String
    /// Delete the sources once they are copied into the project.
    ///
    /// True for the Share Extension: its inbox is a hand-off buffer inside the
    /// App Group container, not storage. It would be wrong for a file the user
    /// picked in Files, which is why it is a field and not a constant.
    public var removesSourcesAfterImport: Bool

    public init(
        id: UUID = UUID(),
        fileURLs: [URL],
        projectName: String = ProjectLibrary.suggestedProjectName(),
        removesSourcesAfterImport: Bool = false
    ) {
        self.id = id
        self.fileURLs = fileURLs
        self.projectName = projectName
        self.removesSourcesAfterImport = removesSourcesAfterImport
    }
}

/// The seam between "something outside the app handed us a photo" and the
/// navigation that shows it.
///
/// Held by the app container for the whole process lifetime, so a URL that
/// arrives before any view exists (cold start) is not dropped: it sits in
/// ``pending`` until ``RetouchProRootView`` appears and takes it.
@MainActor
@Observable
public final class ExternalOpenCoordinator {
    /// The request waiting to be handled, if any. One at a time: a second share
    /// while the first is still opening replaces it rather than queueing, which
    /// matches what the user sees — the last thing they shared is the thing they
    /// expect to land in.
    public private(set) var pending: ExternalOpenRequest?

    /// What happened to the last request, for the status banner.
    public private(set) var lastMessage: String?

    /// Where a line about each step goes. The app points it at `AppLog` so a
    /// hand-off that fails on a real device leaves a trace in `session.log`
    /// (docs/PLAN.md §5) rather than only on screen.
    @ObservationIgnored public var log: (@Sendable (String) -> Void)?

    public init(log: (@Sendable (String) -> Void)? = nil) {
        self.log = log
    }

    /// Files this process has already accepted, so the same photo cannot be
    /// opened twice.
    ///
    /// There are deliberately two ways in — the `retouchpro://` URL and the
    /// launch-time inbox scan that covers a hand-off the extension could not
    /// deliver — and on a cold start both can name the same file. Without this,
    /// that is two projects for one share.
    private var acceptedPaths: Set<String> = []

    /// Whether anything has been handed over yet this launch. The launch-time
    /// inbox scan asks before it runs: a share that arrived as a URL is the one
    /// the user just made, and must not be replaced by whatever else is still
    /// lying in the inbox.
    public var hasAcceptedAnything: Bool { !acceptedPaths.isEmpty }

    public func request(
        fileURLs: [URL],
        projectName: String = ProjectLibrary.suggestedProjectName(),
        removesSourcesAfterImport: Bool = true
    ) {
        guard !fileURLs.isEmpty else {
            note("external open: ignored, no readable file in the request")
            return
        }
        let fresh = fileURLs.filter { !acceptedPaths.contains($0.standardizedFileURL.path) }
        guard !fresh.isEmpty else {
            note(
                "external open: ignored, already opened "
                    + "[\(fileURLs.map(\.lastPathComponent).joined(separator: ", "))] this launch")
            return
        }
        let fileURLs = fresh
        acceptedPaths.formUnion(fileURLs.map(\.standardizedFileURL.path))
        let request = ExternalOpenRequest(
            fileURLs: fileURLs,
            projectName: projectName,
            removesSourcesAfterImport: removesSourcesAfterImport)
        pending = request
        note(
            "external open: queued \(fileURLs.count) file(s) → new project \"\(projectName)\" "
                + "[\(fileURLs.map(\.lastPathComponent).joined(separator: ", "))]")
    }

    /// Hands the pending request to the caller and clears it, so a view that
    /// re-appears does not create a second project for the same photo.
    public func take() -> ExternalOpenRequest? {
        defer { pending = nil }
        return pending
    }

    public func report(_ message: String) {
        lastMessage = message
        note("external open: \(message)")
    }

    public func dismissMessage() { lastMessage = nil }

    private func note(_ line: String) { log?(line) }
}

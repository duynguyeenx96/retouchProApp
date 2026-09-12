import Foundation
import RPCore
import RPUI

/// Turns a `retouchpro://open?file=…` URL from the Share Extension into a
/// request the UI can act on (docs/PLAN.md §Phase 3B item 4, docs/ADR-0017).
///
/// It lives in the app target, not in a package, for the same reason
/// `RPImportShotImporter` does: it joins two things that must not import each
/// other — RPCore's hand-off contract and RPUI's `ExternalOpenCoordinator` —
/// and the app is the one place that links both.
///
/// Everything here is a pure function of `(url, what is in the inbox)`, so both
/// halves of the feature are testable without a Share Sheet: `AppTests/
/// ShareHandoffRouterTests.swift` drives it with a fake inbox.
struct ShareHandoffRouter: Sendable {
    /// Where the extension left the file. Injected so a test can point it at a
    /// temporary directory instead of the real App Group container.
    var inboxURL: @Sendable () -> URL?
    var log: @Sendable (String) -> Void

    init(
        inboxURL: @escaping @Sendable () -> URL? = { ShareHandoff.inboxURL() },
        log: @escaping @Sendable (String) -> Void = { AppLog.write($0) }
    ) {
        self.inboxURL = inboxURL
        self.log = log
    }

    /// Handles one URL. Returns `false` for a URL that is not ours, so the
    /// caller can fall through to whatever else might want it.
    ///
    /// **The URL is untrusted.** Any app on the phone can open `retouchpro://`.
    /// Nothing from it is ever used as a path: `ShareHandoff.parse` keeps only
    /// plain, importable file names and `ShareHandoff.resolve` looks them up
    /// *inside* our own App Group inbox, so a hostile caller can at most name a
    /// file that is not there — which is the "nothing to open" branch below.
    @MainActor
    @discardableResult
    func handle(_ url: URL, with coordinator: ExternalOpenCoordinator) -> Bool {
        guard let request = ShareHandoff.parse(url) else {
            log("share handoff: ignored a URL that is not a valid retouchpro://open — \(url.scheme ?? "?")")
            return false
        }
        let inbox = inboxURL()
        if inbox == nil {
            log(
                "share handoff: NO App Group container for \(ShareHandoff.appGroupIdentifier) — "
                    + "this build is not entitled to it")
        }
        let files = ShareHandoff.resolve(request, inboxURL: inbox)
        guard !files.isEmpty else {
            log(
                "share handoff: nothing to open — asked for "
                    + "\(request.fileNames.joined(separator: ", ")), none of them is in the inbox")
            coordinator.report("Không tìm thấy ảnh vừa chia sẻ.")
            return true
        }
        log("share handoff: \(files.count) file(s) from the App Group inbox")
        coordinator.request(fileURLs: files, removesSourcesAfterImport: true)
        return true
    }

    /// Picks up anything the extension left in the inbox but could not hand
    /// over, and opens it exactly as a `retouchpro://` URL would.
    ///
    /// **Why this exists.** The extension's only way to bring the app forward is
    /// `UIApplication.openURL:options:completionHandler:` through the responder
    /// chain (`ShareExtension/ShareViewController.swift` says why the documented
    /// `NSExtensionContext.open` does not work). That is not a promise from
    /// Apple, so the feature must not lose the user's photo when it stops
    /// working: the file is already in the App Group inbox, and this makes the
    /// next launch — by hand or otherwise — land in the editor on it anyway.
    ///
    /// It is also the belt to `onOpenURL`'s braces on a cold start: the
    /// coordinator refuses a file it has already accepted this launch, so the
    /// URL and the scan cannot both create a project for the same photo.
    @MainActor
    @discardableResult
    func handleInbox(with coordinator: ExternalOpenCoordinator) -> Bool {
        // A `retouchpro://` URL already arrived: that is the share the user just
        // made. Anything else still in the inbox is an older hand-off and must
        // not push it aside — it waits for a launch that has no URL.
        guard !coordinator.hasAcceptedAnything else {
            log("share handoff: inbox scan skipped, a URL hand-off is already in flight")
            return false
        }
        guard let inbox = inboxURL() else { return false }
        let names =
            ((try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? [])
            .filter(ShareHandoff.isSafeFileName)
            .sorted()
        guard !names.isEmpty else { return false }
        let files = ShareHandoff.resolve(
            ShareHandoff.OpenRequest(fileNames: names), inboxURL: inbox)
        guard !files.isEmpty else { return false }
        log("share handoff: \(files.count) file(s) still in the inbox at launch")
        coordinator.request(fileURLs: files, removesSourcesAfterImport: true)
        return true
    }

    /// One line for the startup log saying whether the App Group is actually
    /// there. The failure mode this guards against is the one that already bit
    /// this project once (docs/ADR-0015): something that works on macOS and the
    /// Simulator and silently does not on a real device's sandbox, with no line
    /// in the log to show for it.
    var containerReport: String {
        guard let url = inboxURL() else {
            return
                "share handoff: App Group \(ShareHandoff.appGroupIdentifier) UNAVAILABLE — "
                + "\"Mở với RetouchPro\" will not work in this build"
        }
        return "share handoff: App Group ready at \(url.path)"
    }
}

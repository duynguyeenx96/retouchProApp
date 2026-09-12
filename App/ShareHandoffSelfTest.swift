import Foundation
import RPCore

/// A launch-time "Mở với RetouchPro" hand-off, driven by an environment
/// variable, so the Share Extension's *routing* can be checked on a real device
/// (docs/ADR-0017 §5).
///
/// ## Why this exists
///
/// The rest of the feature can be unit-tested; the two things that can only be
/// wrong on a device cannot:
///
/// 1. the **App Group container** — a build that lost the entitlement resolves
///    `nil` on the phone and works fine on macOS and the Simulator, which is
///    the exact shape of the bug that made this project require device runs at
///    all (docs/ADR-0015);
/// 2. the **cold-start / warm-start race** — whether a `retouchpro://` URL that
///    lands before the first screen exists still ends in the editor.
///
/// A Share Extension has no independently launchable bundle id, so
/// `devicectl … process launch` cannot start one, and there is no
/// `devicectl device open url`. This hook is the only way to deliver the URL to
/// a device build from a script. It delivers the *same* URL the extension
/// builds, into the *same* `AppContainer.open(url:)` the scene's `onOpenURL`
/// calls — everything downstream is the product path.
///
/// ```
/// # stage a real photo in the App Group inbox, then:
/// xcrun devicectl device process launch --console --device <udid> \
///   --environment-variables '{"RP_SHARE_SELFTEST":"DSC05259.jpg"}' \
///   com.duynguyen.RetouchPro                       # cold start
/// xcrun devicectl device process launch --console --device <udid> \
///   --environment-variables '{"RP_SHARE_SELFTEST":"DSC05259.jpg","RP_SHARE_SELFTEST_DELAY":"6"}' \
///   com.duynguyen.RetouchPro                       # warm: URL arrives with the UI already up
/// ```
///
/// Off unless `RP_SHARE_SELFTEST` is set. It never writes to the inbox itself:
/// staging the file is the caller's job (`devicectl device copy to
/// --domain-type appGroupDataContainer`), so what is exercised here is exactly
/// what the extension would have left behind.
enum ShareHandoffSelfTest {
    static let environmentKey = "RP_SHARE_SELFTEST"
    /// Seconds to wait before delivering the URL. 0 (the default) is the
    /// cold-start case; a few seconds is the warm-start one — the root view is
    /// on screen and possibly inside a project by then.
    static let delayEnvironmentKey = "RP_SHARE_SELFTEST_DELAY"

    struct Target: Equatable {
        /// File names expected to already be in the App Group inbox.
        var fileNames: [String]
        /// How long to wait before handing the URL over.
        var delay: TimeInterval
    }

    static func target(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Target? {
        guard let raw = environment[environmentKey] else { return nil }
        let names =
            raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        let delay = (environment[delayEnvironmentKey]).flatMap(TimeInterval.init) ?? 0
        return Target(fileNames: names, delay: max(0, delay))
    }

    /// Waits, then hands `deliver` the very URL the extension would have opened.
    ///
    /// `deliver` is `AppContainer.open(url:)`; nothing here shortcuts past the
    /// router, so a hand-off that fails because the inbox is empty or the App
    /// Group is missing fails here in exactly the same way and logs the same
    /// lines.
    static func run(
        target: Target,
        log: @escaping @Sendable (String) -> Void,
        deliver: @escaping @Sendable @MainActor (URL) -> Void
    ) async {
        log(
            "share selftest: \(target.fileNames.joined(separator: ", ")) "
                + "after \(target.delay)s — inbox \(ShareHandoff.inboxURL()?.path ?? "UNAVAILABLE")")
        if let inbox = ShareHandoff.inboxURL() {
            let listing = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
            log("share selftest: inbox holds [\(listing.joined(separator: ", "))]")
        }
        if target.delay > 0 {
            try? await Task.sleep(for: .seconds(target.delay))
        }
        guard let url = ShareHandoff.makeOpenURL(fileNames: target.fileNames) else {
            log(
                "share selftest: FAILED — no usable file name in "
                    + "\(target.fileNames.joined(separator: ", "))")
            return
        }
        log("share selftest: delivering \(url.absoluteString)")
        await MainActor.run { deliver(url) }
    }
}

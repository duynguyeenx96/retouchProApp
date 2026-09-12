import OSLog
import RPCore
import UIKit
import UniformTypeIdentifiers

/// "Mở với RetouchPro" — the iOS Share Extension (docs/PLAN.md §Phase 3B,
/// docs/ADR-0017).
///
/// It has no editing UI on purpose: the whole point of the feature is to turn
/// "open the app, tap Import, pick the photo" into one tap, so this controller
/// does the smallest possible amount of work — copy the shared image into the
/// App Group inbox, ask the system to open `retouchpro://open?file=…`, and get
/// out of the way. Everything else (project creation, ingest, the editor) is the
/// containing app's job, running the same code the ordinary import path runs.
///
/// **Why `NSExtensionContext.open(_:completionHandler:)`.** It is the supported
/// way for an app extension to hand control to its containing app. `NSUserActivity`
/// is *not* an alternative here — that is cross-device continuity, a different
/// mechanism with different requirements (docs/PLAN.md §Phase 3B item 3).
final class ShareViewController: UIViewController {
    private static let log = Logger(
        subsystem: "com.duynguyen.RetouchPro.ShareExtension", category: "handoff")

    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private lazy var closeButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.title = "Đóng"
        return UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.cancel()
        })
    }()

    private var hasRun = false

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // `open(_:)` is only honoured once the extension is actually on screen,
        // and `viewDidAppear` can fire again after the app switch, so guard it.
        guard !hasRun else { return }
        hasRun = true
        Task { await run() }
    }

    // MARK: - The hand-off

    private func run() async {
        do {
            let inbox = try ShareHandoff.createInbox()
            let names = try await stageSharedImages(into: inbox)
            guard let url = ShareHandoff.makeOpenURL(fileNames: names) else {
                throw ShareHandoffError.noImageInShareItem
            }
            Self.log.log("staged \(names.joined(separator: ", "), privacy: .public)")

            let opened = await open(url)
            if opened {
                Self.log.log("opened \(ShareHandoff.urlScheme, privacy: .public)://open")
                extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            } else {
                // Leave the staged file: `ShareHandoffRouter.handleInbox` opens
                // it on the app's next launch, so the photo is not lost.
                Self.log.error("neither UIApplication nor NSExtensionContext would open the URL")
                fail(with: "Đã lưu ảnh. Mở Retouch Pro để chỉnh — ảnh sẽ có sẵn trong đó.")
            }
        } catch {
            Self.log.error("hand-off failed: \(String(describing: error), privacy: .public)")
            fail(with: String(describing: error))
        }
    }

    /// Copies every image in the share item into `inbox`, returning their names.
    ///
    /// `loadFileRepresentation` hands back the file the provider already has on
    /// disk, so an HEIC stays an HEIC and a RAW stays a RAW — nothing in this
    /// path re-encodes, exactly like the ordinary import (docs/ADR-0003).
    private func stageSharedImages(into inbox: URL) async throws -> [String] {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        guard !providers.isEmpty else { throw ShareHandoffError.noImageInShareItem }

        var names: [String] = []
        for provider in providers {
            let suggested = provider.suggestedName
            let name = try await Self.stage(provider, suggestedName: suggested, into: inbox)
            names.append(name)
        }
        guard !names.isEmpty else { throw ShareHandoffError.noImageInShareItem }
        return names
    }

    /// One provider → one file in the inbox.
    ///
    /// `nonisolated static` and taking only `Sendable` values across the
    /// continuation so the completion handler captures nothing that belongs to
    /// the main actor. The copy happens **inside** the completion: the URL the
    /// provider hands over is only valid until it returns.
    private nonisolated static func stage(
        _ provider: NSItemProvider,
        suggestedName: String?,
        into inbox: URL
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) {
                url, error in
                if let error {
                    continuation.resume(
                        throwing: ShareHandoffError.couldNotWriteToInbox(String(describing: error)))
                    return
                }
                guard let url else {
                    continuation.resume(throwing: ShareHandoffError.noImageInShareItem)
                    return
                }
                let name = ShareHandoff.uniqueFileName(
                    suggested: suggestedName ?? url.lastPathComponent,
                    fallbackExtension: url.pathExtension,
                    in: inbox)
                do {
                    try FileManager.default.copyItem(
                        at: url, to: inbox.appendingPathComponent(name, isDirectory: false))
                    continuation.resume(returning: name)
                } catch {
                    continuation.resume(
                        throwing: ShareHandoffError.couldNotWriteToInbox(String(describing: error)))
                }
            }
        }
    }

    /// Asks the system to open the containing app on `url`.
    ///
    /// **Two paths, and the documented one does not work.**
    /// `NSExtensionContext.open(_:completionHandler:)` is documented for Today
    /// widgets only; from a Share Extension it returns `false` without opening
    /// anything. Measured here, not assumed: on the iOS 26 Simulator it logged
    /// "NSExtensionContext.open refused the URL" while the file had already been
    /// staged in the App Group inbox.
    ///
    /// So the primary path is the one every app with this feature uses: walk the
    /// responder chain to the `UIApplication` the extension is hosted by and
    /// call its `openURL:options:completionHandler:`. `UIApplication.open` is
    /// marked unavailable to extensions, hence the selector; the call is guarded
    /// by `responds(to:)` and falls back, so a future OS that removes it degrades
    /// to "the photo is staged, open the app" instead of crashing.
    ///
    /// This would be an App Store review risk. It is not one here: this app is
    /// Development-signed and never goes to the Store (docs/ADR-0017, PLAN §0).
    /// And even when both paths fail the photo is not lost — the app scans the
    /// inbox at launch (`ShareHandoffRouter.handleInbox`).
    private func open(_ url: URL) async -> Bool {
        if openViaResponderChain(url) { return true }
        guard let context = extensionContext else { return false }
        return await withCheckedContinuation { continuation in
            context.open(url) { success in
                continuation.resume(returning: success)
            }
        }
    }

    private func openViaResponderChain(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        var chain: [String] = []
        while let current = responder {
            if current.responds(to: selector), current.isKind(of: UIApplication.self) {
                typealias OpenURL = @convention(c) (
                    NSObject, Selector, NSURL, NSDictionary, Any?
                ) -> Void
                guard
                    let method = class_getInstanceMethod(type(of: current), selector),
                    let object = current as? NSObject
                else { return false }
                let implementation = method_getImplementation(method)
                let open = unsafeBitCast(implementation, to: OpenURL.self)
                // The completion only reports; the decision to dismiss is made
                // on the return value, because a block that never fires would
                // otherwise hang the sheet.
                let completion: @convention(block) (Bool) -> Void = { success in
                    Self.log.log("UIApplication.open reported \(success, privacy: .public)")
                }
                open(object, selector, url as NSURL, NSDictionary(), completion)
                Self.log.log("asked UIApplication to open the containing app")
                return true
            }
            chain.append(String(describing: type(of: current)))
            responder = current.next
        }
        // Only on the way out: the chain is the one thing that explains *why*
        // the app was not opened, and it is useless noise when it works.
        Self.log.error(
            "no UIApplication in the responder chain — \(chain.joined(separator: " → "), privacy: .public)"
        )
        return false
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: ShareHandoffError.noImageInShareItem)
    }

    // MARK: - UI

    private func buildUI() {
        // The same ground as the app's shell (`RPTheme.canvas`, `#0c0d0f`),
        // hard-coded because RPUI is SwiftUI and this sheet is a single label.
        view.backgroundColor = UIColor(red: 0.047, green: 0.051, blue: 0.059, alpha: 1)

        statusLabel.text = "Đang mở Retouch Pro…"
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)

        spinner.color = .white
        spinner.startAnimating()
        closeButton.isHidden = true
        closeButton.tintColor = .white

        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel, closeButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    private func fail(with message: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        statusLabel.text = message
        closeButton.isHidden = false
    }
}

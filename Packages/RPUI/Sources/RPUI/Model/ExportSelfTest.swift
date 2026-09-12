import Foundation
import RPCore
import RPEngine

/// A launch-time **export** run against a real photo already in the device's
/// project library, driven by the same objects the Export button drives.
///
/// ## Why this exists
///
/// Same reason as `App/FaceSelfTest` (docs/ADR-0015): the failures this project
/// has actually shipped were sandbox-shaped — a path that resolves on macOS and
/// in the Simulator because both share the Mac's filesystem, and does not exist
/// inside a real device's container. Export is exactly that kind of surface: it
/// decodes a file, allocates a 24 MP `rgba16Float` pair on a phone GPU, and
/// **writes** somewhere. None of those three risks is visible in a unit test.
///
/// A device run cannot be automated the usual way (no `TEST_HOST` on a device
/// destination, and a test bundle's `Bundle.main` is the runner, not the app),
/// and nobody can tap the Export button from a script. So this is one
/// env-var-gated path through the *product* objects:
/// ``ExportController/exportActiveShot(of:options:)`` over a real
/// ``EditorModel`` — literally the button's action minus the tap.
///
/// ```
/// xcrun devicectl device process launch --console --device <udid> \
///   --environment-variables '{"RP_EXPORT_SELFTEST":"1"}' com.duynguyen.RetouchPro
/// ```
///
/// It is **off unless the variable is set**, it writes only into the app's own
/// export folder (``ExportDestination``), and it runs after the UI is on screen
/// so it cannot delay launch.
public enum ExportSelfTest {
    public static let environmentKey = "RP_EXPORT_SELFTEST"

    /// What `RP_EXPORT_SELFTEST` may hold.
    public enum Target: Equatable, Sendable {
        /// `1` / `first-shot`: the first shot of the most recently modified
        /// project in the library.
        case firstShot
        /// A bare original file name (`DSC05259.jpg`), looked up across projects.
        case fileName(String)

        public init?(_ raw: String) {
            let value = raw.trimmingCharacters(in: .whitespaces)
            switch value {
            case "": return nil
            case "1", "first-shot", "first": self = .firstShot
            default: self = .fileName(value)
            }
        }
    }

    public static func target(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Target? {
        environment[environmentKey].flatMap(Target.init)
    }

    /// Which project bundle to open and which shot in it to export.
    public struct Resolution: Equatable, Sendable {
        public var bundleURL: URL
        /// `nil` means "whichever shot the project opens on", i.e. the first.
        public var originalFileName: String?

        public init(bundleURL: URL, originalFileName: String?) {
            self.bundleURL = bundleURL
            self.originalFileName = originalFileName
        }
    }

    /// Either the shot to export, or the sentence saying why there is none —
    /// the same shape `App/FaceSelfTest.Resolution` uses, and for the same
    /// reason: a self-test that cannot run must say so in one line rather than
    /// throw an error nobody reads.
    public enum Outcome: Equatable, Sendable {
        case resolved(Resolution)
        case failure(String)
    }

    /// Resolves a target against a library root, or explains why it cannot.
    ///
    /// Pure enough to unit-test: the root is a parameter, so a test points it at
    /// a temporary directory instead of the device's Documents.
    public static func resolve(
        _ target: Target, libraryRoot: URL?, fileManager: FileManager = .default
    ) -> Outcome {
        guard let libraryRoot else { return .failure("no project library on this device") }
        let library = ProjectLibrary(rootURL: libraryRoot)
        let entries = ((try? library.entries(fileManager: fileManager)) ?? [])
            .filter { $0.shotCount > 0 }
        guard !entries.isEmpty else {
            return .failure("no project with a shot under \(libraryRoot.path)")
        }
        switch target {
        case .firstShot:
            return .resolved(
                Resolution(bundleURL: entries[0].bundleURL, originalFileName: nil))
        case .fileName(let name):
            for entry in entries {
                let originals = entry.bundleURL.appendingPathComponent(
                    ProjectBundle.originalsDirectory)
                let path = originals.appendingPathComponent(name).path
                if fileManager.fileExists(atPath: path) {
                    return .resolved(
                        Resolution(bundleURL: entry.bundleURL, originalFileName: name))
                }
            }
            return .failure(
                "no \(name) in any project under \(libraryRoot.path); have "
                    + entries.map(\.name).joined(separator: ", "))
        }
    }

    /// Opens the project, selects the shot and exports it through
    /// ``ExportController``, reporting every step through `log`.
    ///
    /// Never throws at the caller and never changes what the user sees: it opens
    /// its *own* `EditorModel` rather than the one on screen, so a self-test run
    /// cannot move the user's selection.
    @MainActor
    public static func run(
        target: Target,
        options: ExportOptions = ExportOptions(),
        controller: ExportController? = nil,
        log: @escaping (String) -> Void
    ) async {
        let libraryRoot = try? ProjectLibrary.defaultRoot()
        let resolution: Resolution
        switch resolve(target, libraryRoot: libraryRoot) {
        case .resolved(let value): resolution = value
        case .failure(let reason):
            log("export-selftest: cannot run — \(reason)")
            return
        }

        let model: EditorModel
        do {
            model = try await EditorModel.open(bundleURL: resolution.bundleURL)
        } catch {
            log("export-selftest: cannot open \(resolution.bundleURL.lastPathComponent): \(error)")
            return
        }
        if let name = resolution.originalFileName,
            let shot = model.shots.first(where: { $0.originalFileName == name })
        {
            await model.select(shotID: shot.id)
        }
        guard let shot = model.activeShot else {
            log("export-selftest: \(resolution.bundleURL.lastPathComponent) has no active shot")
            return
        }

        let exporter = controller ?? ExportController.standard()
        guard exporter.isAvailable else {
            log("export-selftest: no Metal device, nothing to export")
            return
        }
        log(
            "export-selftest: exporting \(shot.originalFileName) from "
                + "\(resolution.bundleURL.lastPathComponent) as \(options.format.title) "
                + "\(options.size.title) \(options.colorSpace.title) → "
                + ExportDestination.resolve(options).path)

        await exporter.exportActiveShot(of: model, options: options)

        if let summary = exporter.lastSummary {
            log("export-selftest: OK \(summary.url.path) — \(summary.detailText)")
            for note in summary.notes { log("export-selftest: note — \(note)") }
        } else {
            log("export-selftest: FAILED — \(exporter.lastErrorMessage ?? "no summary, no error")")
        }
    }
}

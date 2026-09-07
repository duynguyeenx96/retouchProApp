import CoreGraphics
import Foundation
import RPCore
import RPEngine
import RPUI

/// A launch-time face-analysis run against a real photo, written to
/// `session.log` — the way a real iPhone can be checked without tapping it.
///
/// ## Why this exists (docs/ADR-0015)
///
/// The bug this file was added with — Core ML models that were never in the app
/// bundle — did not reproduce on macOS or in the Simulator, because both share
/// the Mac's filesystem and the old `#filePath`-derived fallback found the
/// models under `Research/spikes/`. It only showed up on a device. So the
/// coder workflow now requires a real-device run for anything touching app
/// wiring or resources, and that run has to *exercise* the feature, not just
/// launch the app.
///
/// Doing that by hand means opening a project and tapping a thumbnail. It cannot
/// be automated the usual way either: the app-target and package test bundles
/// have no `TEST_HOST`, and `xcodebuild` refuses them on a device destination
/// ("Tool-hosted testing is unavailable on device destinations"). Even if it
/// did, their `Bundle.main` is the test runner, not `RetouchPro.app`, so they
/// can never see the embedded models — the exact thing that needs checking.
///
/// Hence one env-var-gated path through the *product* objects: the same
/// `PreviewRendering` decode, the same `FaceInputProviding`, the same models
/// from `Bundle.main`.
///
/// ```
/// xcrun devicectl device process launch --console --device <udid> \
///   --environment-variables '{"RP_FACE_SELFTEST":"DSC05259.jpg"}' \
///   com.duynguyen.RetouchPro
/// xcrun devicectl device copy from --device <udid> \
///   --domain-type appDataContainer --domain-identifier com.duynguyen.RetouchPro \
///   --source Library/Logs/RetouchPro/session.log --destination ./session.log
/// ```
///
/// It is **off unless the variable is set**, it only reads, and it runs after
/// the UI is on screen so it cannot delay launch.
enum FaceSelfTest {
    static let environmentKey = "RP_FACE_SELFTEST"

    /// What `RP_FACE_SELFTEST` may hold.
    enum Target {
        /// `first-shot`: the first shot of the newest project in the library.
        case firstShot
        /// An absolute path to an image file.
        case path(URL)
        /// A bare file name, looked up in every project's `originals/`.
        case fileName(String)

        init?(_ raw: String) {
            let value = raw.trimmingCharacters(in: .whitespaces)
            switch value {
            case "": return nil
            case "1", "first-shot", "first": self = .firstShot
            default:
                if value.hasPrefix("/") {
                    self = .path(URL(fileURLWithPath: value))
                } else {
                    self = .fileName(value)
                }
            }
        }
    }

    static func target(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Target? {
        environment[environmentKey].flatMap(Target.init)
    }

    /// Either the file to analyse, or the sentence saying why there is none.
    enum Resolution {
        case file(URL)
        case failure(String)
    }

    /// Resolves the target to a file on disk, or explains why it could not.
    ///
    /// Pure enough to test: the library root is a parameter, so a unit test can
    /// point it at a temporary directory instead of the app's Documents.
    static func resolve(
        _ target: Target, libraryRoot: URL?, fileManager: FileManager = .default
    ) -> Resolution {
        func originals(inProjectsUnder root: URL) -> [URL] {
            let library = ProjectLibrary(rootURL: root)
            let entries = (try? library.entries(fileManager: fileManager)) ?? []
            return entries.flatMap { entry -> [URL] in
                let dir = entry.bundleURL.appendingPathComponent(ProjectBundle.originalsDirectory)
                let files =
                    (try? fileManager.contentsOfDirectory(
                        at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
                    ?? []
                return files.filter { ProjectBundle.isImportableExtension($0.pathExtension) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
        }

        switch target {
        case .path(let url):
            guard fileManager.fileExists(atPath: url.path) else {
                return .failure("no file at \(url.path)")
            }
            return .file(url)

        case .firstShot:
            guard let libraryRoot else { return .failure("no project library on this device") }
            guard let first = originals(inProjectsUnder: libraryRoot).first else {
                return .failure("no importable file under \(libraryRoot.path)")
            }
            return .file(first)

        case .fileName(let name):
            guard let libraryRoot else { return .failure("no project library on this device") }
            let all = originals(inProjectsUnder: libraryRoot)
            guard let match = all.first(where: { $0.lastPathComponent == name }) else {
                let names = all.map(\.lastPathComponent).joined(separator: ", ")
                return .failure("no \(name) in the project library; have: [\(names)]")
            }
            return .file(match)
        }
    }

    /// Decodes the file the way the canvas does and runs one face analysis.
    /// Everything it learns goes to `session.log`; it never throws at the caller
    /// and never changes what the user sees.
    @MainActor
    static func run(
        target: Target,
        renderer: any PreviewRendering,
        faceProvider: (any FaceInputProviding)?
    ) async {
        let libraryRoot = try? ProjectLibrary.defaultRoot()
        let url: URL
        switch resolve(target, libraryRoot: libraryRoot) {
        case .file(let resolved): url = resolved
        case .failure(let reason):
            AppLog.write("selftest: cannot run — \(reason)")
            return
        }
        guard let faceProvider else {
            AppLog.write("selftest: \(url.lastPathComponent) — no face provider, nothing to run")
            return
        }

        do {
            let decodeStart = ContinuousClock.now
            let image = try await renderer.renderPreview(
                PreviewRequest(
                    originalURL: url, maxPixelSize: renderer.preferredPreviewPixelSize))
            AppLog.write(
                "selftest: decoded \(url.lastPathComponent) to "
                    + "\(Int(image.pixelSize.width))x\(Int(image.pixelSize.height)) in "
                    + milliseconds(since: decodeStart))
            // Same mask set the canvas asks for, so the timing is the real one.
            _ = try await faceProvider.faceInputs(
                for: image,
                contentHash: "selftest-\(url.lastPathComponent)",
                kinds: RenderMaskRequirements.forEnabledGroups())
            // `FaceAnalyzerFaceInputProvider` already logged the count, the
            // duration and the first face's box.
        } catch {
            AppLog.write("selftest: FAILED on \(url.lastPathComponent): \(error)")
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> String {
        let ms = Double(start.duration(to: .now).components.attoseconds) / 1e15
        return String(format: "%.1f ms", ms)
    }
}

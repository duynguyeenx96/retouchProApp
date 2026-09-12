import CoreGraphics
import Foundation
import OSLog
import Observation
import RPCore
import RPEngine

/// The seam between the export UI and `RPEngine.ExportRenderer`, in the same
/// shape as ``ShotImporting`` (docs/ADR-0014): a protocol so the wiring can be
/// tested with no GPU, no Metal and no 24 MP file.
///
/// It is deliberately the **whole** job, not a stream of callbacks: one export is
/// one blocking call that either produces a file or throws, and the batch queue
/// docs/PLAN.md Phase 3 asks for next is a loop over jobs around this same call.
public protocol ExportRunning: Sendable {
    /// Blocking. Callers run it off the main actor.
    func run(_ job: ExportJob) throws -> ExportResult
}

/// The shipping runner: one `ExportRenderer` per process, built on first use.
///
/// Lazy on purpose. Building it compiles the Metal library and prewarms every
/// pipeline the graph can use (236 ms on macOS, 1798 ms in the Simulator —
/// docs/ADR-0007), and an app that pays that at launch for a user who never
/// exports has simply made launch slower. Paying it inside the first export is
/// the right place: that call is already off the main actor and already shows a
/// progress row.
public final class MetalExportRunner: ExportRunning, @unchecked Sendable {
    private let context: MetalContext
    private let lock = NSLock()
    private var storage: ExportRenderer?

    public init(context: MetalContext) {
        self.context = context
    }

    public func run(_ job: ExportJob) throws -> ExportResult {
        try renderer().export(job)
    }

    private func renderer() throws -> ExportRenderer {
        lock.lock()
        defer { lock.unlock() }
        if let storage { return storage }
        let created = try ExportRenderer(context: context)
        try created.prewarm()
        storage = created
        return created
    }
}

/// Where a finished file goes.
///
/// **The default is the app's own Documents folder, not `~/Pictures`.** Both
/// builds are sandboxed (`App/RetouchPro*.entitlements`) and neither carries
/// `com.apple.security.assets.pictures.read-write`, so a write to `~/Pictures`
/// fails on macOS; on iOS there is no such folder at all. `FileManager`'s
/// `.documentDirectory` resolves to the container on both, which is a path the
/// app can actually write to — and on macOS the user can still point the export
/// somewhere else with the dialog's folder row, whose `NSOpenPanel` URL comes
/// with its own sandbox extension.
public enum ExportDestination {
    /// Folder name inside Documents. Plain ASCII: it ends up in a path the user
    /// may type.
    public static let folderName = "RetouchPro Exports"

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let documents =
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return documents.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The folder an export with these options writes to.
    public static func resolve(
        _ options: ExportOptions, fileManager: FileManager = .default
    ) -> URL {
        options.destinationFolder ?? defaultDirectory(fileManager: fileManager)
    }

    /// Tilde-shortened path for the dialog's folder row — of the folder that
    /// will actually be written to, not of a placeholder.
    public static func displayPath(_ url: URL?, fileManager: FileManager = .default) -> String {
        let resolved = url ?? defaultDirectory(fileManager: fileManager)
        let home = NSHomeDirectory()
        guard home.count > 1, resolved.path.hasPrefix(home) else { return resolved.path }
        return "~" + resolved.path.dropFirst(home.count)
    }
}

/// What the last finished export produced, for the row the dialog shows
/// afterwards.
public struct ExportSummary: Hashable, Sendable {
    public var url: URL
    public var byteCount: Int
    public var pixelSize: CGSize
    public var milliseconds: Double
    /// `ExportResult.notes` — the places the file is not quite what was asked
    /// for (a 16-bit JPEG, a RAW that came back as its embedded preview).
    public var notes: [String]

    public init(
        url: URL, byteCount: Int, pixelSize: CGSize, milliseconds: Double, notes: [String]
    ) {
        self.url = url
        self.byteCount = byteCount
        self.pixelSize = pixelSize
        self.milliseconds = milliseconds
        self.notes = notes
    }

    public var fileName: String { url.lastPathComponent }

    /// "4.2 MB · 4000×6000 · 3.1 s"
    public var detailText: String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        let size = "\(Int(pixelSize.width.rounded()))×\(Int(pixelSize.height.rounded()))"
        let seconds = String(format: "%.1f s", milliseconds / 1000)
        return "\(bytes) · \(size) · \(seconds)"
    }
}

/// Runs **one** export for the shot the editor has open, and holds the three
/// things the sheet and the dialog need to draw: is it running, what did it
/// produce, what went wrong.
///
/// ## Deliberately one photo at a time
///
/// docs/PLAN.md Phase 3 also asks for a `BatchQueue`. This is not it, and it is
/// not a half-built one either: there is no queue, no cancellation and no
/// thermal policy here. What there *is* is the per-photo call a queue needs —
/// ``ExportRunning/run(_:)`` over a plain `ExportJob` — so the queue, when it
/// lands, loops over jobs and reuses this runner rather than replacing it.
///
/// ## Why the work leaves the main actor
///
/// `ExportRenderer.export` blocks on the GPU and on the file system; at 24 MP
/// that is seconds. It runs in a detached task and only the three observable
/// properties come back to the main actor.
@MainActor
@Observable
public final class ExportController {

    /// `nil` on a machine with no Metal device — the export button is then
    /// disabled and says why, the same rule ``LivePreviewController`` follows
    /// for the canvas.
    @ObservationIgnored
    private let runner: (any ExportRunning)?

    /// Unified-log channel, so a real-device export can be followed with
    /// `devicectl device process launch --console` (docs/ADR-0015: a message
    /// that only exists inside a SwiftUI overlay is a message nobody reads).
    @ObservationIgnored
    nonisolated static let log = Logger(
        subsystem: "com.duynguyen.RetouchPro", category: "export")

    /// Non-nil while an export is running. Drives the dialog's progress card,
    /// which already existed with nothing behind it.
    public private(set) var progress: ExportProgress?
    public private(set) var lastSummary: ExportSummary?
    public private(set) var lastErrorMessage: String?

    public init(runner: (any ExportRunning)?) {
        self.runner = runner
    }

    /// The app's controller. `MetalContext.shared` is `nil` only where there is
    /// no GPU at all (a headless CI box); RPUITests and SwiftUI previews take
    /// that path and get a controller that refuses politely.
    public static func standard(context: MetalContext? = MetalContext.shared)
        -> ExportController
    {
        ExportController(runner: context.map { MetalExportRunner(context: $0) })
    }

    public var isExporting: Bool { progress != nil }
    /// `false` when there is no renderer behind the button at all.
    public var isAvailable: Bool { runner != nil }

    // MARK: - Running one export

    /// Renders and writes the editor's active shot.
    ///
    /// Everything the job needs is read from `model` on the main actor **before**
    /// the work is detached, so a slider moved mid-export cannot change the file
    /// half way through: what is exported is what was on screen when the button
    /// was pressed.
    public func exportActiveShot(of model: EditorModel, options: ExportOptions) async {
        guard !isExporting else { return }
        guard let shot = model.activeShot, let sourceURL = model.activeOriginalURL else {
            lastErrorMessage = "Chưa có ảnh nào được chọn để xuất."
            return
        }
        guard let runner else {
            lastErrorMessage = "Máy này không có GPU Metal nên chưa xuất được."
            return
        }

        // Faces were measured on the canvas's preview texture, not on the file.
        // `ExportJob` rescales them with `faceReferenceSize`, which is why that
        // size is carried rather than guessed.
        let job = ExportJob(
            sourceURL: sourceURL,
            editState: model.activeEditState,
            faces: model.live?.faces ?? [],
            faceReferenceSize: model.live?.sourceSize ?? .zero,
            originalFileName: shot.originalFileName,
            index: 1,
            settings: options.engineSettings,
            destinationDirectory: ExportDestination.resolve(options))

        lastErrorMessage = nil
        lastSummary = nil
        progress = ExportProgress(
            currentFileName: shot.originalFileName, completed: 0, total: 1)
        defer { progress = nil }

        // The unedited document is still saved first: `commitEditState` is a
        // no-op when nothing changed, and when something did the file on disk
        // must agree with the pixels that were just exported.
        await model.commitEditState()

        let folder = job.destinationDirectory
        // An `NSOpenPanel` URL carries its own sandbox extension; bracketing is
        // what makes it survive into the detached task, and is a no-op for the
        // container folder (docs/ADR-0003 §5, the same bracket RPImport uses on
        // picked files).
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try runner.run(job)
            }.value
            lastSummary = ExportSummary(
                url: result.url, byteCount: result.byteCount, pixelSize: result.pixelSize,
                milliseconds: result.timings.total, notes: result.notes)
            Self.log.log(
                """
                export wrote \(result.url.path, privacy: .public) \
                (\(result.byteCount, privacy: .public) B, \
                \(Int(result.pixelSize.width), privacy: .public)×\
                \(Int(result.pixelSize.height), privacy: .public), \
                \(result.writtenBitsPerComponent, privacy: .public)-bit, \
                nodes \(result.nodes.joined(separator: "→"), privacy: .public)) in \
                \(String(format: "%.0f", result.timings.total), privacy: .public) ms \
                [decode \(String(format: "%.0f", result.timings.decode), privacy: .public) \
                upload \(String(format: "%.0f", result.timings.upload), privacy: .public) \
                graph \(String(format: "%.0f", result.timings.graph), privacy: .public) \
                readback \(String(format: "%.0f", result.timings.readback), privacy: .public) \
                finish \(String(format: "%.0f", result.timings.resizeAndSharpen), privacy: .public) \
                encode \(String(format: "%.0f", result.timings.encode), privacy: .public) \
                write \(String(format: "%.0f", result.timings.write), privacy: .public)]
                """)
            for note in result.notes {
                Self.log.log("export note: \(note, privacy: .public)")
            }
        } catch {
            lastErrorMessage = String(describing: error)
            Self.log.error(
                "export failed for \(shot.originalFileName, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    public func dismissSummary() { lastSummary = nil }
    public func dismissError() { lastErrorMessage = nil }
}

// MARK: - The sheet's pills, as engine settings

extension ExportOptions {
    /// The four pill rows, translated into what `ExportRenderer` takes.
    ///
    /// Two choices the pills do not offer and this makes for them:
    ///
    /// * **Bit depth follows the container.** There is no depth row in the
    ///   mockup, and the only format that can hold 16 bits *and* is chosen for
    ///   that reason is TIFF. JPEG is 8 bits by definition; HEIF stays 8 because
    ///   a 16-bit request there is not honoured by the encoder anyway and would
    ///   only produce a note saying so.
    /// * **Output sharpening is off.** `ExportSettings.sharpen` defaults to 0 and
    ///   nothing here raises it: the constants behind it have no measured number
    ///   (working rule 1), so it stays a parameter the API exposes and the UI
    ///   does not.
    public var engineSettings: ExportSettings {
        ExportSettings(
            format: engineFormat,
            bitDepth: engineFormat == .tiff ? .sixteen : .eight,
            quality: quality.rawValue,
            resize: engineResize,
            sharpen: 0,
            colorProfile: colorSpace == .displayP3 ? .displayP3 : .sRGB,
            namingTemplate: ExportNaming.defaultTemplate)
    }

    private var engineFormat: ExportSettings.Format {
        switch format {
        case .jpeg: .jpeg
        case .heif: .heif
        case .tiff: .tiff
        }
    }

    private var engineResize: ExportSettings.Resize {
        switch size {
        case .original: .original
        case .long4000: .longestEdge(4000)
        case .long2048: .longestEdge(2048)
        }
    }
}

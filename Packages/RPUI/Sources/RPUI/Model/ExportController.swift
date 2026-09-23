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
/// one blocking call that either produces a file or throws, and ``BatchQueue`` is
/// a loop over jobs around this same call.
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

/// Which photos the export dialog's button acts on.
public enum ExportScope: String, CaseIterable, Hashable, Sendable {
    /// The filmstrip's batch selection (`FilmstripSelection.selectedShotIDs`),
    /// which always contains the open photo — so with nothing extra selected
    /// this is exactly the old one-photo export.
    case selection
    /// Every shot in the project.
    case allShots

    public var title: String {
        switch self {
        case .selection: "Ảnh đã chọn"
        case .allShots: "Cả project"
        }
    }

    /// The shots this scope covers, in **project order** (reproducible file
    /// order, and the order `{n}` numbers them in).
    @MainActor
    public func shots(in model: EditorModel) -> [Shot] {
        switch self {
        case .selection: model.selection.selectedShots(in: model.shots)
        case .allShots: model.shots
        }
    }
}

/// Faces for a shot that is **not** open on the canvas.
///
/// The canvas's faces come from `LivePreviewController`, which measured them on
/// the 2048 px preview it decoded. A batch has to produce the same faces for
/// every other shot, and the only way to get *the same* numbers is the same
/// input: decode the preview at the same size, hand it to the same
/// `FaceInputProviding` under the same content hash (the provider caches by
/// hash + size, so a shot the user already looked at costs nothing).
public protocol ExportFaceSource: Sendable {
    /// Faces in the returned image's pixel grid, and that grid's size — which
    /// is what `ExportJob.faceReferenceSize` wants. Throws only when the
    /// preview itself cannot be decoded; an analysis failure is an empty list
    /// plus a note, the same thing the canvas falls back to.
    func faces(for shot: Shot, originalURL: URL) async throws -> ExportFaces
}

public struct ExportFaces: Sendable {
    public var faces: [FaceRenderInput]
    public var referenceSize: CGSize
    public var notes: [String]

    public init(faces: [FaceRenderInput], referenceSize: CGSize, notes: [String] = []) {
        self.faces = faces
        self.referenceSize = referenceSize
        self.notes = notes
    }

    public static let none = ExportFaces(faces: [], referenceSize: .zero)
}

/// The shipping ``ExportFaceSource``: the canvas's own decode + provider.
public struct PreviewFaceSource: ExportFaceSource {
    public let provider: any FaceInputProviding
    /// `RenderQuality.preview.preferredLongEdge` — the size the canvas decodes
    /// at, so the faces agree with what the user saw.
    public let longEdge: Int

    public init(
        provider: any FaceInputProviding,
        longEdge: Int = RenderQuality.preview.preferredLongEdge ?? 2048
    ) {
        self.provider = provider
        self.longEdge = longEdge
    }

    public func faces(for shot: Shot, originalURL: URL) async throws -> ExportFaces {
        let image = try ImageDecoder.decode(contentsOf: originalURL, maxPixelSize: longEdge)
        do {
            let faces = try await provider.faceInputs(
                for: image, contentHash: shot.contentHash ?? shot.id.rawValue,
                kinds: RenderMaskRequirements.forEnabledGroups())
            return ExportFaces(faces: faces, referenceSize: image.pixelSize)
        } catch {
            return ExportFaces(
                faces: [], referenceSize: image.pixelSize,
                notes: ["face analysis failed, exported without faces: \(error)"])
        }
    }
}

/// Runs exports — one photo or a batch — and holds what the sheet and the
/// dialog draw: is it running (and how far), what did it produce, what went
/// wrong.
///
/// ## One path for one photo and for N
///
/// ``exportActiveShot(of:options:)`` is a batch of one through ``BatchQueue``,
/// the same loop ``export(_:of:options:)`` runs for a selection or the whole
/// project. That queue owns the policy (sequential through the one runner =
/// the GPU memory bound, thermal pause, stop-after-current); this type owns
/// the part that needs `EditorModel`: turning shots into jobs.
///
/// ## What a batch-exported photo carries — and what it does not
///
/// Each job is the shot's `EditState` (the open shot's is committed first and
/// taken from memory; every other shot's is read from `edits/<id>.json` when
/// its turn comes) plus its faces (``ExportFaceSource``). It carries **no**
/// whole-frame masks — no painted brush mask, no "Khoá nền" subject gate, no
/// whole-body skin mask — because `ExportJob` has no field for them and the
/// single-photo export never passed them either. A batch photo therefore
/// matches exporting that photo alone; both differ from the canvas wherever
/// one of those masks is active. (The painted mask is not even persisted — it
/// lives only in the open shot's GPU session — so a non-open shot has none to
/// give.)
///
/// ## Why the work leaves the main actor
///
/// `ExportRenderer.export` blocks on the GPU and on the file system; at 24 MP
/// that is seconds. ``BatchQueue`` runs each photo in a detached task and only
/// the observable properties come back to the main actor.
@MainActor
@Observable
public final class ExportController {

    /// `nil` on a machine with no Metal device — the export button is then
    /// disabled and says why, the same rule ``LivePreviewController`` follows
    /// for the canvas.
    @ObservationIgnored
    private let runner: (any ExportRunning)?
    @ObservationIgnored
    private let queue: BatchQueue?
    /// Overrides the face source derived from `model.live`. Tests only.
    @ObservationIgnored
    private let faceSourceOverride: (any ExportFaceSource)?

    /// Unified-log channel, so a real-device export can be followed with
    /// `devicectl device process launch --console` (docs/ADR-0015: a message
    /// that only exists inside a SwiftUI overlay is a message nobody reads).
    @ObservationIgnored
    nonisolated static let log = Logger(
        subsystem: "com.duynguyen.RetouchPro", category: "export")

    /// Non-nil while an export is running. Drives the dialog's progress card.
    public private(set) var progress: ExportProgress?
    /// The last file written by the last run (the single-photo row).
    public private(set) var lastSummary: ExportSummary?
    /// The whole last run: counts, failures, folder.
    public private(set) var lastBatch: BatchExportSummary?
    public private(set) var lastErrorMessage: String?

    public init(
        runner: (any ExportRunning)?,
        thermal: any ThermalStateProviding = SystemThermalState(),
        thermalPollInterval: Duration = .seconds(5),
        faceSource: (any ExportFaceSource)? = nil
    ) {
        self.runner = runner
        self.queue = runner.map {
            BatchQueue(runner: $0, thermal: thermal, thermalPollInterval: thermalPollInterval)
        }
        self.faceSourceOverride = faceSource
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
    /// `true` from ``cancel()`` until the photo in flight is written and the
    /// batch returns. Stored (not read through to the queue) so SwiftUI sees it.
    public private(set) var isCancelling = false

    // MARK: - Running

    /// Renders and writes the editor's active shot — a batch of one.
    public func exportActiveShot(of model: EditorModel, options: ExportOptions) async {
        guard let shot = model.activeShot else {
            guard !isExporting else { return }
            lastErrorMessage = "Chưa có ảnh nào được chọn để xuất."
            return
        }
        await export([shot], of: model, options: options)
    }

    /// Exports what `scope` covers in `model`.
    public func export(
        scope: ExportScope, of model: EditorModel, options: ExportOptions
    ) async {
        let shots = scope.shots(in: model)
        guard !shots.isEmpty else {
            guard !isExporting else { return }
            lastErrorMessage = "Chưa có ảnh nào được chọn để xuất."
            return
        }
        await export(shots, of: model, options: options)
    }

    /// Exports `shots` in the order given; `{n}` is the 1-based position.
    ///
    /// The open shot's document is read from `model` on the main actor
    /// **before** anything is detached, so a slider moved mid-export cannot
    /// change the file half way through: what is exported is what was on screen
    /// when the button was pressed. Every other shot's is read from disk when
    /// its turn comes.
    public func export(_ shots: [Shot], of model: EditorModel, options: ExportOptions) async {
        guard !isExporting else { return }
        guard !shots.isEmpty else {
            lastErrorMessage = "Chưa có ảnh nào được chọn để xuất."
            return
        }
        guard let queue else {
            lastErrorMessage = "Máy này không có GPU Metal nên chưa xuất được."
            return
        }

        lastErrorMessage = nil
        lastSummary = nil
        lastBatch = nil
        progress = ExportProgress(
            currentFileName: shots[0].originalFileName, completed: 0, total: shots.count)
        defer {
            progress = nil
            isCancelling = false
        }

        // The open document is still saved first: `commitEditState` is a
        // no-op when nothing changed, and when something did the file on disk
        // must agree with the pixels that were just exported.
        await model.commitEditState()

        let folder = ExportDestination.resolve(options)
        // Stop pressed while the document was being saved: the queue was not
        // running yet, so it never saw the request.
        guard !isCancelling else {
            lastBatch = BatchExportSummary(
                exported: [], failures: [], notStarted: shots.count, total: shots.count,
                folder: folder, milliseconds: 0)
            return
        }
        let items = makeItems(shots, of: model, settings: options.engineSettings, folder: folder)

        // An `NSOpenPanel` URL carries its own sandbox extension; bracketing is
        // what makes it survive into the detached tasks, and is a no-op for the
        // container folder (docs/ADR-0003 §5, the same bracket RPImport uses on
        // picked files). Held for the whole batch, not per photo.
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let summary = await queue.run(items, folder: folder) { [weak self] update in
            self?.progress = update
        }
        lastBatch = summary
        lastSummary = summary.exported.last
        // One photo that failed keeps the old single-export behaviour: the
        // reason is the message. A larger batch shows its failures in the
        // summary card instead, next to what did succeed.
        if summary.total == 1, let failure = summary.failures.first {
            lastErrorMessage = failure.reason
        }
    }

    /// Stops the running batch after the photo currently being rendered.
    public func cancel() {
        guard isExporting, let queue else { return }
        isCancelling = true
        queue.cancel()
    }

    public func dismissSummary() {
        lastSummary = nil
        lastBatch = nil
    }
    public func dismissError() { lastErrorMessage = nil }

    // MARK: - Shots → jobs

    private func makeItems(
        _ shots: [Shot], of model: EditorModel, settings: ExportSettings, folder: URL
    ) -> [BatchExportItem] {
        let store = model.store
        let faceSource = faceSourceOverride ?? Self.faceSource(for: model.live)
        let activeID = model.activeShot?.id
        let activeState = model.activeEditState
        // The canvas's faces, when they are for the shot being exported and
        // analysis actually finished; otherwise the face source measures them
        // the same way the canvas would have.
        var liveFaces: ExportFaces?
        if let live = model.live, live.faceAnalysisRan,
            let shot = model.activeShot,
            live.openContentHash == (shot.contentHash ?? shot.id.rawValue)
        {
            liveFaces = ExportFaces(faces: live.faces, referenceSize: live.sourceSize)
        }

        return shots.map { shot in
            let sourceURL = store.originalURL(for: shot)
            let isActive = shot.id == activeID
            let knownState: EditState? = isActive ? activeState : nil
            let knownFaces: ExportFaces? = isActive ? liveFaces : nil
            return BatchExportItem(shotID: shot.id, fileName: shot.originalFileName) { index in
                let editState = try knownState ?? store.loadEditState(for: shot.id)
                let faces: ExportFaces
                let origin: String
                if let knownFaces {
                    faces = knownFaces
                    origin = "canvas"
                } else if let faceSource {
                    faces = try await faceSource.faces(for: shot, originalURL: sourceURL)
                    origin = "analysed"
                } else {
                    faces = .none
                    origin = "no face source"
                }
                Self.log.log(
                    """
                    export [\(index, privacy: .public)] \(shot.originalFileName, privacy: .public): \
                    \(faces.faces.count, privacy: .public) face(s) on \
                    \(Int(faces.referenceSize.width), privacy: .public)×\
                    \(Int(faces.referenceSize.height), privacy: .public) (\(origin, privacy: .public))
                    """)
                for note in faces.notes {
                    Self.log.error(
                        "export \(shot.originalFileName, privacy: .public): \(note, privacy: .public)")
                }
                return ExportJob(
                    sourceURL: sourceURL,
                    editState: editState,
                    faces: faces.faces,
                    faceReferenceSize: faces.referenceSize,
                    originalFileName: shot.originalFileName,
                    index: index,
                    settings: settings,
                    destinationDirectory: folder)
            }
        }
    }

    /// `nil` when there is no provider or it is the "no faces, ever" one —
    /// then decoding a preview per photo would buy nothing.
    private static func faceSource(for live: LivePreviewController?) -> (any ExportFaceSource)? {
        guard let provider = live?.faceProvider, !(provider is NoFaceInputProvider) else {
            return nil
        }
        return PreviewFaceSource(provider: provider)
    }

    // MARK: - Logging

    nonisolated static func logResult(_ result: ExportResult, position: Int, total: Int) {
        log.log(
            """
            export [\(position, privacy: .public)/\(total, privacy: .public)] wrote \
            \(result.url.path, privacy: .public) \
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
            log.log("export note: \(note, privacy: .public)")
        }
    }
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

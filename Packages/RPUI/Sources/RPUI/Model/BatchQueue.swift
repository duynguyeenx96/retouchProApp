import CoreGraphics
import Foundation
import RPCore
import RPEngine

// MARK: - Thermal state

/// `ProcessInfo.ThermalState`, as a value the queue can be tested against.
///
/// Its own enum rather than `ProcessInfo.ThermalState` itself so a test can hand
/// the queue any sequence of states without touching the real sensor.
public enum ThermalLevel: Int, Comparable, Sendable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }

    /// `.serious` and `.critical` are where Apple's guidance says to cut work
    /// the user did not ask to see right now — a background batch is exactly
    /// that. `.fair` is normal under sustained load and pausing there would
    /// make every batch longer than a few photos stall for nothing.
    public var requiresPause: Bool { self >= .serious }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where the queue reads the device's temperature. Injectable so tests can
/// drive the pause/resume path without heating anything.
public protocol ThermalStateProviding: Sendable {
    var thermalLevel: ThermalLevel { get }
}

/// The shipping source: `ProcessInfo.thermalState`. On a Mac it is `.nominal`
/// practically always, so the policy costs nothing there; on an iPhone it is
/// the only signal the OS gives before it starts throttling the GPU itself.
public struct SystemThermalState: ThermalStateProviding {
    public init() {}
    public var thermalLevel: ThermalLevel { ThermalLevel(ProcessInfo.processInfo.thermalState) }
}

// MARK: - Items and summary

/// One photo in a batch.
///
/// The job is built **when its turn comes**, not when the batch starts:
/// reading the edit state from disk, decoding the 2048 px preview and running
/// face analysis for a shot that is not open all happen inside ``makeJob``, so
/// a 300-photo batch never holds 300 decoded previews or 300 face lists at
/// once, and a shot whose file vanished fails on its own without stopping the
/// ones before it from being prepared.
public struct BatchExportItem: Sendable {
    public var shotID: ShotID
    public var fileName: String
    /// `index` is the 1-based position in the batch (the naming template's
    /// `{n}`).
    public var makeJob: @Sendable (_ index: Int) async throws -> ExportJob

    public init(
        shotID: ShotID, fileName: String,
        makeJob: @escaping @Sendable (_ index: Int) async throws -> ExportJob
    ) {
        self.shotID = shotID
        self.fileName = fileName
        self.makeJob = makeJob
    }
}

/// One photo that did not export, and why — in words the dialog can show.
public struct BatchExportFailure: Hashable, Sendable {
    public var fileName: String
    public var reason: String

    public init(fileName: String, reason: String) {
        self.fileName = fileName
        self.reason = reason
    }
}

/// What a finished (or stopped) batch did.
public struct BatchExportSummary: Hashable, Sendable {
    /// Files written, in batch order.
    public var exported: [ExportSummary]
    public var failures: [BatchExportFailure]
    /// Photos never started because the user pressed stop.
    public var notStarted: Int
    public var total: Int
    public var folder: URL
    public var milliseconds: Double

    public init(
        exported: [ExportSummary], failures: [BatchExportFailure], notStarted: Int, total: Int,
        folder: URL, milliseconds: Double
    ) {
        self.exported = exported
        self.failures = failures
        self.notStarted = notStarted
        self.total = total
        self.folder = folder
        self.milliseconds = milliseconds
    }

    public var succeededCount: Int { exported.count }
    public var wasCancelled: Bool { notStarted > 0 }

    /// "Đã xuất 3/3 ảnh" · "Đã xuất 2/3 ảnh · 1 lỗi" · "Đã dừng — xuất 2/5 ảnh"
    public var headline: String {
        var text =
            wasCancelled
            ? "Đã dừng — xuất \(succeededCount)/\(total) ảnh"
            : "Đã xuất \(succeededCount)/\(total) ảnh"
        if !failures.isEmpty { text += " · \(failures.count) lỗi" }
        return text
    }
}

// MARK: - The queue

/// docs/PLAN.md Phase 3: `BatchQueue` — export in the background, bounded by
/// GPU memory, thermal-aware on iPhone.
///
/// ## Sequential, on purpose — that *is* the GPU memory bound
///
/// Every photo goes through the **one** shared ``ExportRunning`` (in the app,
/// one `MetalExportRunner` → one `ExportRenderer` → one `RenderGraph`), one at
/// a time. A 24 MP render holds the source plus up to two full-size
/// `rgba16Float` intermediates (≈ 384 MB, see `ExportRenderer.export`, which
/// releases them after readback), and Da + Mắt/Răng together were measured at
/// ~936 MB of scratch (docs/ADR-0011). Two of those in flight is past what an
/// iPhone will give a foreground app, and the GPU is saturated by one anyway —
/// running two would not finish sooner, it would only raise the peak. So the
/// limit is "one render in flight", enforced by the loop's shape rather than by
/// a counter that could be tuned into an OOM.
///
/// ## Failures, cancellation, heat
///
/// * A photo that throws is recorded (file name + reason) and the loop moves on.
/// * ``cancel()`` stops **after the current photo**: a render already on the
///   GPU is not abandoned half way (there is nothing useful to salvage from it,
///   and `ExportRenderer` writes atomically, so no half file appears either).
/// * Before each photo the thermal source is read; at `.serious` / `.critical`
///   the queue waits, re-reading it every ``thermalPollInterval``, and reports
///   ``ExportProgress/isThermalPaused`` so the dialog can say so.
///
/// Main-actor bound because its progress drives SwiftUI; the heavy work
/// (preparing a job, rendering it) runs in a detached task per photo.
@MainActor
public final class BatchQueue {
    public let runner: any ExportRunning
    public let thermal: any ThermalStateProviding
    public let thermalPollInterval: Duration

    public private(set) var isRunning = false
    private var cancelRequested = false

    public init(
        runner: any ExportRunning,
        thermal: any ThermalStateProviding = SystemThermalState(),
        thermalPollInterval: Duration = .seconds(5)
    ) {
        self.runner = runner
        self.thermal = thermal
        self.thermalPollInterval = thermalPollInterval
    }

    /// Asks the running batch to stop once the current photo is written.
    public func cancel() {
        guard isRunning else { return }
        cancelRequested = true
    }

    public var isCancelling: Bool { isRunning && cancelRequested }

    /// Runs `items` in order. Never throws: per-photo failures end up in the
    /// summary. Returns immediately with an empty summary if a batch is
    /// already running.
    public func run(
        _ items: [BatchExportItem],
        folder: URL,
        onProgress: (ExportProgress) -> Void = { _ in }
    ) async -> BatchExportSummary {
        let clock = ContinuousClock()
        let started = clock.now
        guard !isRunning else {
            return BatchExportSummary(
                exported: [], failures: [], notStarted: items.count, total: items.count,
                folder: folder, milliseconds: 0)
        }
        isRunning = true
        cancelRequested = false
        defer {
            isRunning = false
            cancelRequested = false
        }

        let total = items.count
        var exported: [ExportSummary] = []
        var failures: [BatchExportFailure] = []
        var notStarted = 0

        ExportController.log.log(
            "batch export: \(total, privacy: .public) photo(s) → \(folder.path, privacy: .public)")

        for (offset, item) in items.enumerated() {
            let completed = offset
            // Heat first: a pause is between photos, never inside one.
            await waitWhileHot(
                fileName: item.fileName, completed: completed, total: total,
                onProgress: onProgress)
            if cancelRequested || Task.isCancelled {
                notStarted = total - offset
                break
            }

            onProgress(
                ExportProgress(
                    currentFileName: item.fileName, completed: completed, total: total))

            let index = offset + 1
            let runner = self.runner
            let makeJob = item.makeJob
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let job = try await makeJob(index)
                    return try runner.run(job)
                }.value
                let summary = ExportSummary(
                    url: result.url, byteCount: result.byteCount, pixelSize: result.pixelSize,
                    milliseconds: result.timings.total, notes: result.notes)
                exported.append(summary)
                ExportController.logResult(result, position: index, total: total)
            } catch {
                let reason = String(describing: error)
                failures.append(BatchExportFailure(fileName: item.fileName, reason: reason))
                ExportController.log.error(
                    """
                    export [\(index, privacy: .public)/\(total, privacy: .public)] failed for \
                    \(item.fileName, privacy: .public): \(reason, privacy: .public)
                    """)
            }
            onProgress(
                ExportProgress(
                    currentFileName: item.fileName, completed: completed + 1, total: total))
        }

        let milliseconds = Self.milliseconds(clock.now - started)
        let summary = BatchExportSummary(
            exported: exported, failures: failures, notStarted: notStarted, total: total,
            folder: folder, milliseconds: milliseconds)
        ExportController.log.log(
            """
            batch export done: \(summary.succeededCount, privacy: .public) ok, \
            \(failures.count, privacy: .public) failed, \(notStarted, privacy: .public) not started \
            of \(total, privacy: .public) in \(String(format: "%.0f", milliseconds), privacy: .public) ms
            """)
        return summary
    }

    private func waitWhileHot(
        fileName: String, completed: Int, total: Int, onProgress: (ExportProgress) -> Void
    ) async {
        var level = thermal.thermalLevel
        guard level.requiresPause else { return }
        ExportController.log.log(
            "batch export paused: thermal state \(String(describing: level), privacy: .public)")
        while level.requiresPause, !cancelRequested, !Task.isCancelled {
            onProgress(
                ExportProgress(
                    currentFileName: fileName, completed: completed, total: total,
                    isThermalPaused: true))
            do {
                try await Task.sleep(for: thermalPollInterval)
            } catch {
                break
            }
            level = thermal.thermalLevel
        }
        ExportController.log.log(
            "batch export resumed: thermal state \(String(describing: level), privacy: .public)")
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}

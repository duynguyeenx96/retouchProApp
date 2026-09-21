import CoreGraphics
import Foundation
import RPEngine

/// The canvas's half of "Cọ mask thủ công" (docs/PLAN.md §6.1, docs/ADR-0019):
/// the calls a touch handler makes, and the one rule they all share — **after
/// the session's `generation` moves, the canvas has to redraw.**
///
/// ## Why the redraw is driven by `generation` and not by the call
///
/// `ManualMaskSession` bumps `generation` on every mutation and documents it as
/// *the* signal that the painted pixels changed (`ManualMaskCoverage.generation`
/// / `RenderGateMask.gateGeneration`). Some calls move it and some do not — an
/// `extendStroke` whose point produced no new stamp paints nothing, `undo()` on
/// an empty history does nothing — so these methods compare it around the call
/// and only then bump ``LivePreviewController/version``. Redrawing
/// unconditionally would run the whole graph for a finger that moved two points,
/// and *not* redrawing would leave the last stamp of every stroke invisible
/// until the next slider move.
///
/// ## Why the paint API is here rather than in a brush controller of its own
///
/// The session is per shot and so is this class; it already owns every other
/// per-shot mask (`bodySkinMask`, `subjectMask`, `backgroundLockGate`) and it is
/// the object that assembles `RenderRequest`. A second owner would have to be
/// kept in step with `open`/`close` — which is exactly the bug class
/// `openContentHash` exists to prevent.
///
/// It is an extension in its own file so the paint surface can grow without
/// growing `LivePreviewController.swift`, which several Phase 6 features write
/// into.
extension LivePreviewController {

    // MARK: - State the brush UI reads

    /// `true` when this shot can be painted on: the feature flag is on and a
    /// session was built for the picture that is on screen.
    public var canPaintManualMask: Bool { observingPaint { manualMask != nil } }

    /// Finished strokes, oldest first. The brush overlay draws these; the
    /// in-flight one belongs to the view that is capturing the drag, because
    /// only it knows where the finger is between two events.
    public var manualMaskStrokes: [BrushStroke] { observingPaint { manualMask?.strokes ?? [] } }

    public var canUndoManualMask: Bool { observingPaint { manualMask?.canUndo ?? false } }
    public var canRedoManualMask: Bool { observingPaint { manualMask?.canRedo ?? false } }
    /// `true` once anything is painted — the same condition that decides whether
    /// a gate reaches `RenderRequest.gateMasks`.
    public var hasManualMask: Bool {
        observingPaint {
            guard let manualMask else { return false }
            return !manualMask.isEmpty
        }
    }
    public var manualMaskStrokeCount: Int { observingPaint { manualMask?.strokeCount ?? 0 } }

    /// Reads ``version`` before answering, and that read is the whole point.
    ///
    /// ``ManualMaskSession`` is a plain class, not `@Observable`: it is driven
    /// from a touch handler and is deliberately lock-based rather than
    /// observation-based (an `@Observable` mutation per touch-moved event would
    /// invalidate the whole editor hierarchy sixty times a second). So SwiftUI
    /// cannot see a stroke land by watching the session — but every call that
    /// changes it goes through ``paint(_:)`` or ``endManualMaskStroke()``, both
    /// of which bump `version`, which *is* observed. Touching it here is what
    /// re-evaluates the brush bar's undo button and the canvas's overlay.
    private func observingPaint<T>(_ body: () -> T) -> T {
        _ = version
        return body()
    }

    // MARK: - Painting

    /// Starts a stroke at `point` (mask pixels).
    public func beginManualMaskStroke(at point: CGPoint, settings: ManualMaskBrushSettings) {
        paint { session in
            session.beginStroke(
                radius: settings.radiusInMaskPixels,
                hardness: settings.hardnessFraction,
                flow: settings.flowFraction,
                mode: settings.mode,
                at: BrushPoint(location: point))
        }
    }

    /// Extends the in-flight stroke. Ignored when there is none, which is what
    /// makes a stray move event after a cancelled gesture harmless.
    public func extendManualMaskStroke(to point: CGPoint) {
        paint { $0.extendStroke(to: BrushPoint(location: point)) }
    }

    /// Ends the in-flight stroke.
    ///
    /// This one redraws even though the **pixels** did not move — the last stamp
    /// was already painted by the final `extendStroke` — because what moved is
    /// the *history*: the stroke went onto the undo stack, so "Hoàn tác" has to
    /// light up and the overlay has to start drawing the stroke from the session
    /// instead of from the view's in-flight copy.
    @discardableResult
    public func endManualMaskStroke() -> BrushStroke? {
        guard let manualMask else { return nil }
        let finished = manualMask.endStroke()
        invalidate()
        return finished
    }

    /// For a gesture the system took away mid-drag (a call arriving, a window
    /// deactivating). The stroke is thrown away and the mask repainted without
    /// it, rather than left half-drawn.
    public func cancelManualMaskStroke() {
        paint { $0.cancelStroke() }
    }

    public func undoManualMaskStroke() {
        paint { _ = $0.undo() }
    }

    public func redoManualMaskStroke() {
        paint { _ = $0.redo() }
    }

    /// "Xoá mask": every stroke **and** any mask loaded from disk. Not undoable —
    /// the session says so, and the button asks nothing extra of the user here
    /// because nothing has been written to disk yet in this phase.
    public func clearManualMask() {
        paint { $0.clearAll() }
    }

    /// One line per finished stroke, for the device console.
    ///
    /// This is how the brush gets the measurement ADR-0019 asked for and the
    /// session it landed in could not take (*"no per-frame device benchmark …
    /// a ms/frame on an A-series part is required before it is turned on"*):
    /// `paintMilliseconds` is the main-thread cost of the whole drag — every
    /// `begin`/`extend` call the finger produced — and ``medianRenderMilliseconds``
    /// is what the canvas actually redrew at **while a gate was attached**, next
    /// to the same number taken before the first stroke as the control.
    ///
    /// It logs rather than accumulating a statistic, because the file that gets
    /// filed is `Research/bench/p6-manual-mask-device.json`, written from the
    /// console output, not from a number the app kept in memory
    /// (docs/PLAN.md §5: never conclude from a screenshot).
    public func logManualMaskStroke(points: Int, paintMilliseconds: Double) {
        let paint = String(format: "%.2f", paintMilliseconds)
        let perPoint = String(format: "%.3f", points > 0 ? paintMilliseconds / Double(points) : 0)
        let render = String(format: "%.2f", medianRenderMilliseconds)
        Self.log.log(
            """
            manual mask stroke: \(points, privacy: .public) points, \
            paint \(paint, privacy: .public) ms (\(perPoint, privacy: .public) ms/point), \
            strokes \(self.manualMaskStrokeCount, privacy: .public), \
            gated redraw median \(render, privacy: .public) ms, \
            nodes \(self.lastNodes.joined(separator: "→"), privacy: .public)
            """)
    }

    /// Runs `body` on the session, then redraws **only if the pixels moved**.
    private func paint(_ body: (ManualMaskSession) -> Void) {
        guard let manualMask else { return }
        let before = manualMask.generation
        body(manualMask)
        guard manualMask.generation != before else { return }
        invalidate()
    }
}

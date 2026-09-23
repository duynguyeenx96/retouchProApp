import CoreGraphics
import Foundation
import Metal
import RPCore

/// One shot's hand-painted mask while it is being painted: the stroke list, the
/// coverage texture the strokes are rasterised into, and undo
/// (docs/PLAN.md §6.1).
///
/// ## Undo is a replay, not a snapshot
///
/// The plan is explicit: *"Undo = replay lại danh sách stroke từ đầu (rẻ ở độ
/// phân giải mask, không cần snapshot texture)"*. So the truth is
/// ``strokes`` — a plain array of value types — and ``coverage`` is derived from
/// it. Undo drops the last stroke and re-rasterises the rest.
///
/// The alternative, one texture snapshot per stroke, costs 2.8 MB of GPU memory
/// *per undo step* at a 2048 px preview (20 steps = 56 MB, on a phone that is
/// already holding 550 MB of skin-node scratch at export size), and it is not
/// even faster here: a replay of 20 strokes is 20 × a handful of batch
/// dispatches over a 2.8 MB texture, which the measurement in
/// `ManualMaskBenchTests` puts in single-digit milliseconds — below one frame,
/// and undo is not a per-frame operation.
///
/// The replay is **exact**, not merely close, because the splat kernel combines
/// stamps with `max`/`min` rather than accumulating alpha: those are idempotent
/// and order-independent, so "rasterise the 3 stamps that just arrived" and
/// "rasterise all 43 from scratch" agree bit for bit. `ManualMaskTests`
/// asserts it (`liveDragMatchesAReplay`), because the whole design rests on it.
///
/// ## No baseline: the strokes are the document (2026-09-23)
///
/// Until 2026-09-23 a mask reopened from `masks/<shot id>/brush.png` became a
/// pixel *baseline* that undo could not walk past. The project now stores the
/// strokes themselves (docs/ADR-0019 addendum, docs/ADR-0025), so reopening a
/// shot is ``replaceStrokes(_:)`` — a replay from nothing — and there is no
/// state in this session that the stroke list does not describe.
///
/// ## Threading
///
/// Called from the main actor by RPUI (a touch handler), so it is not an actor
/// itself — an `await` per touch-moved event would put the stroke behind a hop
/// and the brush behind the finger. It takes a lock for the same reason
/// ``RenderGraph`` does.
public final class ManualMaskSession: @unchecked Sendable {
    /// The pixels. Goes into ``RenderRequest/gateMasks`` (it is a
    /// ``RenderGateMask``); the nodes only read it.
    public let coverage: ManualMaskCoverage

    private let context: MetalContext
    private let rasteriser: ManualMaskRasteriser
    private let lock = NSLock()

    /// Finished strokes, oldest first. The document of this session.
    private var committed: [BrushStroke] = []
    /// Strokes ``undo()`` took off, newest last. Cleared by any new stroke — the
    /// usual rule, and the only one that keeps a redo meaningful.
    private var undone: [BrushStroke] = []
    /// The stroke the finger is currently drawing, if any.
    private var active: BrushStroke?
    private var stamper: BrushStroke.Stamper?

    /// Bumped whenever the painted pixels change. A canvas redraws when it
    /// moves; nothing compares mask pixels.
    public private(set) var generation: Int = 0

    /// - Parameters:
    ///   - width: mask width in pixels. Pass the size of the texture being
    ///     edited (the decoded preview) so ``ManualMaskCoverage/maskToImage``
    ///     stays the identity and a brush point needs no rescaling.
    /// - Throws: ``RPEngineFeatureDisabled`` when `RPEngineFeatureFlags.manualMask`
    ///   is off — the producer-side gate, see that flag's note.
    public init(context: MetalContext, width: Int, height: Int) throws {
        guard RPEngineFeatureFlags.manualMask else {
            throw RPEngineFeatureDisabled(feature: "manualMask")
        }
        self.context = context
        self.coverage = try ManualMaskCoverage(context: context, width: width, height: height)
        self.rasteriser = try ManualMaskRasteriser(context: context)
        try clearCoverage()
    }

    /// Builds the three pipelines up front, off the interaction path.
    public static func prewarm(context: MetalContext) throws {
        try ManualMaskRasteriser.prewarm(context: context)
    }

    public var width: Int { coverage.width }
    public var height: Int { coverage.height }

    // MARK: - State

    /// Finished strokes. The in-flight one is not in here until ``endStroke()``.
    public var strokes: [BrushStroke] {
        lock.lock()
        defer { lock.unlock() }
        return committed
    }

    public var strokeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return committed.count
    }

    public var canUndo: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !committed.isEmpty
    }

    public var canRedo: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !undone.isEmpty
    }

    /// `true` when a finger is down.
    public var isDrawing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active != nil
    }

    /// `true` when there is no finished stroke and none in flight — the test
    /// the canvas uses to decide whether this mask gates a render at all
    /// (an all-zero gate would switch every mask-driven slider off, ADR-0019 §5).
    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return committed.isEmpty && active == nil
    }

    // MARK: - Drawing

    /// Starts a stroke at `point` (mask pixels) and paints its first stamp, so a
    /// tap leaves a dot.
    ///
    /// A stroke already in flight is committed first rather than dropped: a
    /// second finger landing mid-drag must not delete what the first one painted.
    public func beginStroke(
        radius: Double, hardness: Double = 0.5, flow: Double = 1, mode: BrushMode = .add,
        at point: BrushPoint
    ) {
        lock.lock()
        if let running = active, !running.isEmpty { committed.append(running) }
        var stroke = BrushStroke(radius: radius, hardness: hardness, flow: flow, mode: mode)
        stroke.points = [point]
        var stamper = BrushStroke.Stamper(stroke: stroke)
        let stamps = stamper.append(point)
        active = stroke
        self.stamper = stamper
        // A new stroke invalidates the redo stack — the usual editor rule.
        undone.removeAll()
        lock.unlock()
        splat(stamps, of: stroke)
    }

    /// Extends the in-flight stroke and rasterises **only the stamps this point
    /// added**.
    ///
    /// That is the whole point of ``BrushStroke/Stamper`` being incremental: a
    /// drag over a 2048 px preview produces hundreds of points, and
    /// re-rasterising the stroke from its start on each one would be quadratic.
    /// Ignored when no stroke is in flight.
    public func extendStroke(to point: BrushPoint) {
        lock.lock()
        guard var stroke = active, var stamper else {
            lock.unlock()
            return
        }
        let stamps = stamper.append(point)
        stroke.points.append(point)
        active = stroke
        self.stamper = stamper
        lock.unlock()
        splat(stamps, of: stroke)
    }

    /// Ends the in-flight stroke and pushes it onto the undo list.
    ///
    /// - Returns: the finished stroke, or `nil` when there was nothing in flight.
    @discardableResult
    public func endStroke() -> BrushStroke? {
        lock.lock()
        defer { lock.unlock() }
        guard let stroke = active else { return nil }
        active = nil
        stamper = nil
        guard !stroke.isEmpty else { return nil }
        committed.append(stroke)
        return stroke
    }

    /// Throws the in-flight stroke away and repaints without it — for a gesture
    /// the system cancelled (a call arriving mid-drag).
    public func cancelStroke() {
        lock.lock()
        let hadStroke = active != nil
        active = nil
        stamper = nil
        lock.unlock()
        guard hadStroke else { return }
        try? replay()
    }

    // MARK: - Undo

    /// Removes the last finished stroke and re-rasterises the rest.
    @discardableResult
    public func undo() -> Bool {
        lock.lock()
        guard !committed.isEmpty else {
            lock.unlock()
            return false
        }
        undone.append(committed.removeLast())
        lock.unlock()
        try? replay()
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        lock.lock()
        guard !undone.isEmpty else {
            lock.unlock()
            return false
        }
        committed.append(undone.removeLast())
        lock.unlock()
        try? replay()
        return true
    }

    /// Throws away every stroke: the mask goes back to nothing painted. The
    /// app's "Xoá mask" goes through ``replaceStrokes(_:)`` with `[]` instead,
    /// so the document's history can undo it (docs/ADR-0025).
    public func clearAll() {
        lock.lock()
        committed.removeAll()
        undone.removeAll()
        active = nil
        stamper = nil
        lock.unlock()
        try? clearCoverage()
    }

    /// Makes `strokes` the whole mask and re-rasterises it from nothing.
    ///
    /// This is how the app drives the session since the stroke list became the
    /// document (2026-09-23): reopening a shot, and every undo / redo / clear,
    /// hand the session the list the document now says, rather than asking the
    /// session to keep its own history. A stroke in flight is dropped (a
    /// document change mid-drag wins), and this session's own redo list is
    /// cleared because it no longer describes anything.
    ///
    /// Waits for the GPU, like every replay. Cost is linear in stamps and, since
    /// stamps are dispatched over their own bounding box
    /// (``ManualMaskRasteriser``), proportional to the painted area rather than
    /// to the whole frame — see ADR-0019's 2026-09-23 addendum for the numbers.
    public func replaceStrokes(_ strokes: [BrushStroke]) throws {
        lock.lock()
        committed = strokes.filter { !$0.isEmpty }
        undone.removeAll()
        active = nil
        stamper = nil
        lock.unlock()
        try replay()
    }

    // MARK: - Read-back

    /// The raw coverage, for a caller that needs it on the CPU (a test, a
    /// bench). Stalls the GPU; not for the interaction path.
    public func readValues() throws -> [UInt8] {
        try coverage.readValues()
    }

    /// Rasterises a stored stroke list at `width` × `height` into a fresh
    /// coverage — the export's path (docs/ADR-0019 addendum 2026-09-23): the
    /// brush is drawn at the render's own resolution from its metadata rather
    /// than a preview-sized mask being upsampled.
    ///
    /// - Throws: ``RPEngineFeatureDisabled`` while `manualMask` is off, like
    ///   every other producer of a painted mask.
    public static func rasterize(
        _ strokes: [ManualMaskStroke], width: Int, height: Int, context: MetalContext
    ) throws -> ManualMaskCoverage {
        let session = try ManualMaskSession(context: context, width: width, height: height)
        let size = CGSize(width: width, height: height)
        try session.replaceStrokes(strokes.map { BrushStroke($0, imageSize: size) })
        return session.coverage
    }

    // MARK: - Rasterising

    /// One batch of stamps into the coverage, on its own command buffer.
    ///
    /// Committed without `waitUntilCompleted`: the drag must not block the main
    /// thread on the GPU, and a later command buffer on the same queue — the
    /// canvas's own render — is ordered after this one and sees the new pixels
    /// (Metal hazard-tracks the texture, which is not a heap resource).
    private func splat(_ stamps: [BrushStamp], of stroke: BrushStroke) {
        guard !stamps.isEmpty, let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            return
        }
        rasteriser.encodeSplat(
            into: commandBuffer, coverage: coverage, stamps: stamps,
            hardness: stroke.hardness, flow: stroke.flow, mode: stroke.mode)
        commandBuffer.commit()
        bump()
    }

    /// Re-rasterises the whole stroke list from nothing, in **one** command
    /// buffer after the clear: every stroke's stamps in order.
    ///
    /// Waits, unlike ``splat(_:of:)``: undo is a discrete action, not a drag
    /// frame, and an export reads the result straight back.
    private func replay() throws {
        lock.lock()
        let strokes = committed
        lock.unlock()

        try clearCoverage()

        guard !strokes.isEmpty else {
            bump()
            return
        }
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw MetalContext.Failure.noCommandQueue
        }
        for stroke in strokes {
            rasteriser.encodeSplat(
                into: commandBuffer, coverage: coverage, stamps: stroke.stamps,
                hardness: stroke.hardness, flow: stroke.flow, mode: stroke.mode)
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        bump()
    }

    private func clearCoverage() throws {
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw MetalContext.Failure.noCommandQueue
        }
        rasteriser.encodeClear(into: commandBuffer, coverage: coverage, value: 0)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        bump()
    }

    private func bump() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }
}

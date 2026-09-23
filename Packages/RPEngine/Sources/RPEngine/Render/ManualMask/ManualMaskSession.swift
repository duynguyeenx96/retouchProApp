import CoreGraphics
import Foundation
import Metal

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
/// ## The baseline
///
/// A mask loaded from `masks/<shot id>/<mask id>.png` has no strokes behind it —
/// it was painted in an earlier session, possibly on another machine. Those
/// pixels become ``baseline``: the state a replay starts from, and the floor
/// undo can walk back to. Undo does not reach into a previous session's strokes,
/// which is the same thing every raster editor does with a document it just
/// opened.
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
    /// Coverage a replay starts from — a mask loaded from disk. `nil` means
    /// "start from nothing painted".
    private var baseline: [UInt8]?

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

    /// `true` when nothing has ever been painted — no strokes this session and
    /// no mask loaded from disk. A caller uses it to decide whether the shot
    /// needs a `masks/<shot id>/<mask id>.png` at all.
    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return committed.isEmpty && active == nil && baseline == nil
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

    /// Throws away every stroke **and** the loaded baseline: the mask goes back
    /// to nothing painted, which is what the "Xoá mask" control means. Not
    /// undoable — the caller deletes the PNG at the same time.
    public func clearAll() {
        lock.lock()
        committed.removeAll()
        undone.removeAll()
        active = nil
        stamper = nil
        baseline = nil
        lock.unlock()
        try? clearCoverage()
    }

    // MARK: - Storage (docs/PLAN.md §6.1 — the PNG, not the JSON)

    /// The mask as an 8-bit grayscale PNG, for
    /// ``RPCore/ProjectStore/saveMask(_:for:maskID:fileManager:)``.
    public func pngData() throws -> Data {
        try coverage.pngData()
    }

    /// The raw coverage, for a caller that wants both the PNG and an on-screen
    /// overlay out of one read-back (the read-back is the expensive half).
    public func readValues() throws -> [UInt8] {
        try coverage.readValues()
    }

    /// Encodes coverage from ``readValues()`` as the same 8-bit device-gray PNG
    /// ``pngData()`` writes — split out so a caller can read back on the thread
    /// that owns the session and encode on another.
    public static func pngData(values: [UInt8], width: Int, height: Int) throws -> Data {
        try ManualMaskImage.pngData(values: values, width: width, height: height)
    }

    /// Adopts a saved mask as the ``baseline`` and drops the stroke history.
    ///
    /// The history is dropped rather than kept because it no longer describes
    /// these pixels: undoing a stroke from *this* session on top of a mask
    /// loaded from disk is meaningful, undoing past the load is not — there is
    /// nothing behind it to go back to.
    public func load(pngData data: Data) throws {
        let decoded = try ManualMaskImage.decode(pngData: data)
        guard decoded.width == width, decoded.height == height else {
            throw ManualMaskError.sizeMismatch(
                expected: CGSize(width: width, height: height),
                found: CGSize(width: decoded.width, height: decoded.height))
        }
        lock.lock()
        committed.removeAll()
        undone.removeAll()
        active = nil
        stamper = nil
        baseline = decoded.values
        lock.unlock()
        try coverage.upload(decoded.values)
        bump()
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

    /// Re-rasterises the whole stroke list from the baseline, in **one** command
    /// buffer: clear, then every stroke's stamps in order.
    ///
    /// Waits, unlike ``splat(_:of:)``: undo is a discrete action, not a drag
    /// frame, and the caller immediately reads the result back to write the PNG
    /// and refresh the on-screen overlay.
    private func replay() throws {
        lock.lock()
        let strokes = committed
        let base = baseline
        lock.unlock()

        if let base {
            try coverage.upload(base)
        } else {
            try clearCoverage()
        }

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

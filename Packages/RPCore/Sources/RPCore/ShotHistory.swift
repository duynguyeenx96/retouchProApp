import Foundation

/// Everything about one shot that undo can change: its slider document and its
/// brush strokes. Both are metadata; neither is pixels (docs/ADR-0025).
public struct ShotSnapshot: Sendable, Hashable {
    public var editState: EditState
    public var strokes: [ManualMaskStroke]

    public init(editState: EditState = EditState(), strokes: [ManualMaskStroke] = []) {
        self.editState = editState
        self.strokes = strokes
    }
}

/// One step of a shot's undo/redo history, stored as the **operation that
/// takes the snapshot back** (for the undo stack) or forward again (for the redo
/// stack). Applying a step returns its inverse, which goes on the other stack.
///
/// Stroke steps are deliberately small: painting a stroke records
/// ``removeLastStroke`` (no data — the stroke is already the last entry of
/// `edits/<id>.strokes.json`); only the redo side carries the one stroke it has
/// to put back. The one step that must hold a whole list is undoing "Xoá mask"
/// (``replaceStrokes(_:)`` with what was cleared), because that list exists
/// nowhere else any more.
public enum ShotHistoryStep: Sendable, Hashable {
    /// Replace the slider document wholesale with this one.
    case edit(EditState)
    /// Drop the newest stroke.
    case removeLastStroke
    /// Append this stroke.
    case appendStroke(ManualMaskStroke)
    /// Replace the stroke list wholesale (undo/redo of "Xoá mask").
    case replaceStrokes([ManualMaskStroke])

    /// Applies the step and returns the step that undoes it, or `nil` when the
    /// step does not apply to this snapshot (``removeLastStroke`` with no
    /// strokes — only possible when the history and the strokes file were
    /// written by different sessions and disagree; the step is then skipped).
    public func apply(to snapshot: inout ShotSnapshot) -> ShotHistoryStep? {
        switch self {
        case .edit(let state):
            let inverse = ShotHistoryStep.edit(snapshot.editState)
            snapshot.editState = state
            return inverse
        case .removeLastStroke:
            guard let removed = snapshot.strokes.popLast() else { return nil }
            return .appendStroke(removed)
        case .appendStroke(let stroke):
            snapshot.strokes.append(stroke)
            return .removeLastStroke
        case .replaceStrokes(let strokes):
            let inverse = ShotHistoryStep.replaceStrokes(snapshot.strokes)
            snapshot.strokes = strokes
            return inverse
        }
    }
}

extension ShotHistoryStep: Codable {
    private enum CodingKeys: String, CodingKey { case kind, editState, stroke, strokes }
    private enum Kind: String, Codable {
        case edit, removeLastStroke, appendStroke, replaceStrokes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .edit:
            self = .edit(try container.decode(EditState.self, forKey: .editState))
        case .removeLastStroke:
            self = .removeLastStroke
        case .appendStroke:
            self = .appendStroke(try container.decode(ManualMaskStroke.self, forKey: .stroke))
        case .replaceStrokes:
            self = .replaceStrokes(
                try container.decode([ManualMaskStroke].self, forKey: .strokes))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .edit(let state):
            try container.encode(Kind.edit, forKey: .kind)
            try container.encode(state, forKey: .editState)
        case .removeLastStroke:
            try container.encode(Kind.removeLastStroke, forKey: .kind)
        case .appendStroke(let stroke):
            try container.encode(Kind.appendStroke, forKey: .kind)
            try container.encode(stroke, forKey: .stroke)
        case .replaceStrokes(let strokes):
            try container.encode(Kind.replaceStrokes, forKey: .kind)
            try container.encode(strokes, forKey: .strokes)
        }
    }
}

/// One shot's undo/redo history — **one timeline** for slider edits and brush
/// strokes together, persisted as `history/<shot id>.json` (docs/ADR-0025).
///
/// One timeline rather than one per tool, because undo answers "take back the
/// last thing I did", and on this shot the last thing may have been a stroke or
/// a slider; two stacks would make ⌘Z skip over whichever one it does not own.
///
/// Capped at ``maximumSteps`` per stack: the oldest undo step is dropped first.
/// 100 matches Lightroom's practical depth and bounds the file (an `edit` step
/// is one small `EditState`, ~0.3–2 KB).
public struct ShotHistory: Sendable, Hashable {
    public static let currentFormatVersion = 1
    public static let maximumSteps = 100

    public private(set) var undoSteps: [ShotHistoryStep]
    public private(set) var redoSteps: [ShotHistoryStep]

    public init(undoSteps: [ShotHistoryStep] = [], redoSteps: [ShotHistoryStep] = []) {
        self.undoSteps = Array(undoSteps.suffix(Self.maximumSteps))
        self.redoSteps = Array(redoSteps.suffix(Self.maximumSteps))
    }

    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }
    public var isEmpty: Bool { undoSteps.isEmpty && redoSteps.isEmpty }

    /// Records a new user action, given the step that undoes it. Clears redo —
    /// a new edit is exactly what makes whatever was in redo stale.
    public mutating func record(_ undoStep: ShotHistoryStep) {
        undoSteps.append(undoStep)
        redoSteps.removeAll()
        if undoSteps.count > Self.maximumSteps {
            undoSteps.removeFirst(undoSteps.count - Self.maximumSteps)
        }
    }

    /// Steps back once. Returns `false` when there was nothing that applied.
    @discardableResult
    public mutating func undo(_ snapshot: inout ShotSnapshot) -> Bool {
        while let step = undoSteps.popLast() {
            if let inverse = step.apply(to: &snapshot) {
                redoSteps.append(inverse)
                return true
            }
        }
        return false
    }

    /// The exact inverse of ``undo(_:)``.
    @discardableResult
    public mutating func redo(_ snapshot: inout ShotSnapshot) -> Bool {
        while let step = redoSteps.popLast() {
            if let inverse = step.apply(to: &snapshot) {
                undoSteps.append(inverse)
                return true
            }
        }
        return false
    }
}

extension ShotHistory: Codable {
    private enum CodingKeys: String, CodingKey { case formatVersion, undo, redo }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .formatVersion)
        guard version <= Self.currentFormatVersion else {
            throw ProjectStoreError.unsupportedFormatVersion(
                found: version, supported: Self.currentFormatVersion)
        }
        self.init(
            undoSteps: try container.decodeIfPresent([ShotHistoryStep].self, forKey: .undo) ?? [],
            redoSteps: try container.decodeIfPresent([ShotHistoryStep].self, forKey: .redo) ?? [])
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentFormatVersion, forKey: .formatVersion)
        try container.encode(undoSteps, forKey: .undo)
        try container.encode(redoSteps, forKey: .redo)
    }
}

import Foundation
import RPCore

/// Where one shot's hand-painted mask is kept between sessions
/// (docs/ADR-0019 §8, filled in 2026-09-23).
///
/// A protocol so `LivePreviewController` can be tested without a project on
/// disk; the app hands it ``ProjectManualMaskStore``.
public protocol ManualMaskStoring: Sendable {
    /// The PNG, or `nil` when nothing is saved for the shot.
    func loadManualMask() throws -> Data?
    func saveManualMask(_ png: Data) throws
    /// "No mask". Not an error when there is nothing to delete.
    func deleteManualMask() throws
}

/// The shipping store: `masks/<shot id>/brush.png` inside the `.rpproj`
/// bundle, through `ProjectStore.saveMask` (i.e. `AtomicFileWriter` — a crash
/// mid-write leaves the previous mask, never half a PNG).
///
/// ## The format, and what is deliberately *not* written
///
/// * **The PNG is the whole document.** 8-bit device-gray coverage, painted on
///   the canvas's preview and covering the whole frame, so its own pixel size
///   is its reference size — the export maps it onto any render size per axis
///   (`RPEngine.ExportMasks`), and nothing else needs recording beside it.
///   ADR-0019 §8 already fixed this format and `ManualMaskStorageTests` pins its
///   path; the only thing missing was a writer.
/// * **File present ⇔ the canvas has a mask.** It is written whenever the
///   session is non-empty after a stroke / undo / redo, and deleted when the
///   session becomes empty (undo back to nothing, "Xoá mask"). That is the same
///   test the canvas uses to decide whether a gate reaches the render
///   (`ManualMaskSession.isEmpty`), so the file and the canvas cannot disagree
///   about whether a shot is masked.
/// * **No `perImage["manualMask"]` reference is written into `edits/<id>.json`.**
///   ADR-0019 §8 planned one, but the document now has its own undo stack
///   (`EditorModel.undo`, 2026-09-22) while the brush has *another* (stroke
///   replay). A reference in the JSON would be rolled back by the slider undo
///   without the pixels following it, and the canvas (which reads the session)
///   and the export (which would read the reference) would then disagree —
///   precisely the bug this file exists to close. One fixed mask id per shot
///   makes the file itself the reference.
/// * **Strokes are not persisted.** Reopening a shot loads the PNG as the
///   session's baseline (`ManualMaskSession.load(pngData:)`), so the mask is
///   back but this session's undo starts at it — ADR-0019's documented "undo
///   does not reach into a previous session" rule.
public struct ProjectManualMaskStore: ManualMaskStoring {
    /// One brush mask per shot.
    public static let maskID = MaskID("brush")!

    public let store: ProjectStore
    public let shotID: ShotID

    public init(store: ProjectStore, shotID: ShotID) {
        self.store = store
        self.shotID = shotID
    }

    public func loadManualMask() throws -> Data? {
        try store.loadMaskData(for: shotID, maskID: Self.maskID)
    }

    public func saveManualMask(_ png: Data) throws {
        try store.saveMask(png, for: shotID, maskID: Self.maskID)
    }

    public func deleteManualMask() throws {
        try store.deleteMask(for: shotID, maskID: Self.maskID)
    }
}

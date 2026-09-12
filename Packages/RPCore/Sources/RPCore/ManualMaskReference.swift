import Foundation

/// Which hand-painted mask a shot is using, as a **reference only**
/// (docs/PLAN.md §6.1).
///
/// ## The storage decision this type encodes
///
/// The plan is explicit: *"**không** nhét bitmap vào `EditState` JSON … ghi PNG
/// nén vào `masks/<shot id>/<mask id>.png` …, `EditState.perImage` chỉ giữ id
/// tham chiếu"*. So the document holds one string:
///
/// ```json
/// { "perImage": { "manualMask": "5a1c…" } }
/// ```
///
/// and the pixels live at ``ProjectStore/maskURL(for:maskID:)``. Three reasons
/// this is not a matter of taste:
///
/// * `edits/<shot id>.json` is rewritten on **every slider release**
///   (`ProjectStore.saveEditState`). A base64 bitmap in it would turn a 200-byte
///   write into a multi-megabyte one, tens of times per edit session.
/// * `EditState` is `Hashable` and compared on the interaction path
///   (`LivePreviewController.update(editState:)` returns early when it is
///   unchanged). Hashing a few megabytes of mask per slider tick is not free.
/// * A PNG is ~30–60× smaller than the same coverage as JSON text, and is
///   readable by anything.
///
/// ## Why `perImage` and not `sections`
///
/// Exactly the reason `FaceSelection` gives for the `"selectedFace"` key it
/// added next to this one (docs/ADR-0013): `Preset.make` **drops** `perImage`,
/// and a mask painted around *this* person's jaw on *this* frame means nothing on
/// the next frame. A mask id travelling inside a preset would silently point
/// every shot the preset is applied to at one shot's `masks/` folder — or, worse,
/// at a file that does not exist, which is why ``init(_:)`` treats an unreadable
/// value as "no mask" rather than as an error.
///
/// ## Semantics
///
/// * absent key ⇒ no manual mask ⇒ every mask-driven node behaves exactly as it
///   did before Phase 6.1, so no saved document changes meaning;
/// * a value that is not a valid ``MaskID`` (a number, a path, something with a
///   slash in it) reads as *absent*. An id is a file name; refusing to decode a
///   malformed one here is what keeps a corrupt document from steering a read or
///   a write out of the bundle.
public struct ManualMaskReference: Sendable, Equatable, Hashable {

    /// The parameter name inside ``EditState/perImage``.
    public static let key = "manualMask"

    /// `nil` when the shot has no hand-painted mask.
    public var maskID: MaskID?

    public init(maskID: MaskID? = nil) {
        self.maskID = maskID
    }

    /// Reads the reference out of a document.
    public init(_ state: EditState) {
        guard let raw = state.perImage[Self.key]?.stringValue else {
            self.maskID = nil
            return
        }
        self.maskID = MaskID(raw)
    }

    /// Writes the reference into a document, *removing* the key when there is no
    /// mask.
    ///
    /// Same rule as `EditSection.setSlider` and `FaceSelection.write`: the
    /// default state is an absent key, so an untouched document stays empty and
    /// `EditState.isDefault` keeps meaning "untouched".
    public func write(into state: inout EditState) {
        if let maskID {
            state.perImage[Self.key] = .string(maskID.rawValue)
        } else {
            state.perImage[Self.key] = nil
        }
    }

    public var hasMask: Bool { maskID != nil }
}

import Foundation
import RPCore

/// Which detected face the face-dependent slider groups act on.
///
/// ## The state-model decision (docs/ADR-0013)
///
/// A shot can contain several faces (`RenderRequest.faces` is an array, and
/// `FaceAnalysis.faces` has been plural since ADR-0008). Three shapes were
/// possible and only one of them is consistent with the decisions already fixed:
///
/// 1. **One slider set per face** — `EditState.sections` would become
///    `[faceIndex: sections]`. Rejected: `Preset` is defined as "EditState minus
///    the per-image fields" (docs/PLAN.md §2), and a per-face slider set cannot
///    transfer to another photo, which may have a different number of faces in a
///    different order. It would also mean every existing group
///    (`SkinSliders(state)`, `ColorSliders(state)`, …) changes shape.
/// 2. **Sliders stay global-per-shot, plus one selected-face index.** What this
///    type is.
/// 3. **No selection at all — every group always applies to every face.** The
///    behaviour before this type existed, and still the default here.
///
/// So: **the sliders stay exactly as they are — one set per shot, applied to the
/// selected face (or to all of them)** — and the only new state is *which* face,
/// stored as a single integer.
///
/// ## Why it lives in `EditState.perImage`
///
/// `PerImageState`'s own doc comment (written in Phase 1, RPCore/EditState.swift)
/// names this exact case as one of its future owners: *"per-face-instance
/// bindings when an image has several faces"*. That is not a coincidence to lean
/// on lightly — it is the right bucket for a hard reason: `Preset.make` **drops**
/// `perImage`, and a face index must not travel in a preset. "Face 2" on a
/// two-person portrait means nothing on the next frame, where face 2 may be a
/// different person or may not exist. Putting the index in `sections` would let
/// a preset silently retarget every reshape slider onto the wrong person.
///
/// ## Semantics
///
/// * absent key ⇒ ``Target/allFaces`` ⇒ identical to the behaviour before this
///   type existed, so no saved document changes meaning;
/// * an index that no longer exists (the shot was re-analysed and found fewer
///   faces) falls back to ``Target/allFaces`` rather than rendering nothing —
///   see ``resolved(faceCount:)``. A stale index must not make the sliders
///   silently stop working.
///
/// ## What it does *not* do
///
/// It does not filter inside the nodes. Selection is applied when the request is
/// built (``select(from:)``), so `RenderGraph`, `SkinRenderNode`,
/// `WarpRenderNode` and `EyesTeethRenderNode` are untouched by this feature and
/// keep their measured behaviour: they render every face they are handed.
public struct FaceSelection: Sendable, Equatable, Hashable {

    /// The parameter name inside ``RPCore/EditState/perImage``.
    public static let key = "selectedFace"

    public enum Target: Sendable, Equatable, Hashable {
        /// Face-dependent sliders act on every detected face. The default.
        case allFaces
        /// They act only on `FaceAnalysis.faces[index]` — highest-confidence
        /// face first, the order RPVision documents and the UI shows.
        case face(index: Int)
    }

    public var target: Target

    public init(target: Target = .allFaces) {
        self.target = target
    }

    /// Reads the selection out of a document. Anything unexpected in the JSON
    /// (a string, a negative number, a fractional number) reads as
    /// ``Target/allFaces``: an unreadable selection must not stop the sliders.
    public init(_ state: EditState) {
        guard let value = state.perImage[Self.key]?.numberValue,
            value.isFinite, value >= 0, value == value.rounded()
        else {
            self.target = .allFaces
            return
        }
        self.target = .face(index: Int(value))
    }

    /// Writes the selection into a document, *removing* the key for
    /// ``Target/allFaces``.
    ///
    /// Same rule as `EditSection.setSlider`: the default state is an absent key,
    /// so an untouched document stays empty and `EditState.isDefault` keeps
    /// meaning "untouched".
    public func write(into state: inout EditState) {
        switch target {
        case .allFaces:
            state.perImage[Self.key] = nil
        case .face(let index):
            state.perImage[Self.key] = .number(Double(index))
        }
    }

    /// The index, or `nil` for "all faces".
    public var selectedIndex: Int? {
        switch target {
        case .allFaces: nil
        case .face(let index): index
        }
    }

    /// The selection as it applies to a shot that actually has `faceCount`
    /// faces: an out-of-range index becomes ``Target/allFaces``.
    public func resolved(faceCount: Int) -> FaceSelection {
        guard let index = selectedIndex, index >= 0, index < faceCount else {
            return FaceSelection(target: .allFaces)
        }
        return FaceSelection(target: .face(index: index))
    }

    /// The faces a `RenderRequest` built from this selection should carry.
    ///
    /// The array keeps its order, so `faces[0]` of the result is the selected
    /// face and the nodes see exactly one face — they cannot tell the difference
    /// between "this photo has one face" and "one face is selected", which is
    /// why no node changed for this feature.
    public func select(from faces: [FaceRenderInput]) -> [FaceRenderInput] {
        switch resolved(faceCount: faces.count).target {
        case .allFaces: faces
        case .face(let index): [faces[index]]
        }
    }
}

extension RenderRequest {
    /// Builds a request whose `faces` are already narrowed to the shot's face
    /// selection.
    ///
    /// The one call site the UI needs, so "read the selection" and "apply the
    /// selection" cannot drift apart.
    public init(
        editState: EditState,
        allFaces: [FaceRenderInput],
        quality: RenderQuality = .preview
    ) {
        self.init(
            editState: editState,
            faces: FaceSelection(editState).select(from: allFaces),
            quality: quality)
    }
}

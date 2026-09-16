import Foundation
import RPCore

/// "Khoá nền" as a document value: one on/off lock, not a slider
/// (docs/PLAN.md §6.1, docs/ADR-0018).
///
/// ## Why a lock and not a 0–100 amount
///
/// Every retouch parameter in this project is a 0–100 slider whose 0 is neutral
/// (`RPCore.Slider`). This is not one of those. It does not change *how much* a
/// node does; it changes *where* the node is allowed to act, by intersecting one
/// more coverage mask into `RenderRequest.gateMasks`. "50 % locked background"
/// would have to mean "half the effect leaks onto the wall", which is not a
/// thing a user asks for — and the cross-fade that could express it already
/// exists one level down (`GateMaskCompositor.encode(amount:)`) if it is ever
/// wanted. So: a boolean.
///
/// ## Where it is stored, and why there
///
/// `EditState.sections["mask"]["backgroundLock"] = true`, with **absent meaning
/// off**, which is the same "the default state is an absent key" rule
/// `EditSection.setSlider` and ``FaceSelection`` both follow: an untouched
/// document stays empty and `EditState.isDefault` keeps meaning "untouched".
///
/// A *section* rather than `EditState.perImage`, because it transfers. The rule
/// `PerImageState` states is "meaningful only for the image they were made on";
/// a face index is (face 2 of this photo is a different person in the next one),
/// a background lock is not — applying it to a frame with no person in it simply
/// finds no subject mask and gates nothing, which is the documented reading of
/// `SubjectMaskProviding` returning `nil`.
///
/// ## What it does **not** do yet
///
/// Nothing in the shipping UI can set it: the rail's "Khoá nền" item is locked
/// (`RPUI.RailLayout`), because `RPEngineFeatureFlags.backgroundLock` is off by
/// default and stays off until someone measures
/// `VNGeneratePersonSegmentationRequest` on a real iPhone — docs/ADR-0018's
/// still-open blocker, restated here so the next person to read this type does
/// not mistake "the value exists" for "the feature is on".
public struct BackgroundLock: Sendable, Equatable, Hashable {
    /// The `EditState` namespace this lives in.
    public static let section = EditState.SectionKey.mask
    /// The parameter name inside that section.
    public static let key = "backgroundLock"

    /// `true` when the user has asked to keep effects off the background.
    public var isOn: Bool

    public init(isOn: Bool = false) {
        self.isOn = isOn
    }

    /// Reads the lock out of a document.
    ///
    /// Anything unexpected in the JSON (a number, a string, a missing section)
    /// reads as **off**, for the same reason ``FaceSelection`` falls back to
    /// "all faces": an unreadable value must not silently gate a user's sliders
    /// down to nothing.
    public init(_ state: EditState) {
        self.isOn = state[section: Self.section][Self.key]?.boolValue ?? false
    }

    /// Writes the lock into a document, *removing* the key when it is off.
    ///
    /// Removing rather than storing `false` is what keeps an untouched document
    /// byte-identical to an empty one — `EditState[section:]` drops a section
    /// that has become empty, so turning the lock on and off again leaves no
    /// trace.
    public func write(into state: inout EditState) {
        var section = state[section: Self.section]
        section[Self.key] = isOn ? .bool(true) : nil
        state[section: Self.section] = section
    }

    /// What this document contributes to ``RenderRequest/gateMasks``.
    ///
    /// Three conditions, all of which must hold, and **an empty array when any
    /// of them does not** — never an all-zero mask. `RenderGateMask`'s "An empty
    /// array is not an all-zero mask" section is the load-bearing invariant
    /// here: with no gates a node renders exactly the pixels it rendered before
    /// Phase 6.1, so every golden number in ADR-0009…ADR-0012 still describes
    /// the shipping build.
    ///
    /// 1. `RPEngineFeatureFlags.backgroundLock` — off by default (ADR-0018), and
    ///    re-read on **every** request rather than captured when the gate was
    ///    built, so switching the flag off mid-session stops the gating on the
    ///    next frame;
    /// 2. the document's own toggle;
    /// 3. a subject gate actually exists. `nil` here is the honest "no person in
    ///    this frame" answer `SubjectMaskProviding` documents — a landscape, a
    ///    product shot — and it means *there is nothing to lock*, not *lock
    ///    everything*.
    ///
    /// - Parameter subjectGate: the rasterised whole-frame subject coverage,
    ///   already at the size of the texture being rendered
    ///   (`BackgroundLockMaskSource.encode` produces exactly that, wrapped in a
    ///   `TextureGateMask`).
    /// - Returns: `[subjectGate]` or `[]`. Appended to, never assigned over, by
    ///   a caller that has other gates (a painted brush) — gates intersect.
    public static func gateMasks(
        for editState: EditState, subjectGate: (any RenderGateMask)?
    ) -> [any RenderGateMask] {
        guard RPEngineFeatureFlags.backgroundLock else { return [] }
        guard BackgroundLock(editState).isOn else { return [] }
        guard let subjectGate else { return [] }
        return [subjectGate]
    }
}

import Foundation
import RPCore

/// "Sửa da" as a document value: one on/off switch that widens the eight "Da"
/// sliders from the per-face mask onto the whole-body one
/// (docs/PLAN.md §6.2, docs/ADR-0021).
///
/// ## Why a switch and not a slider, and not a build flag alone
///
/// docs/PLAN.md §6.2 settled the shape on 2026-09-11 — *"Không phải bộ slider
/// mới … UI: một toggle"* — and the reason is the same one ``BackgroundLock``
/// gives: this does not change *how much* the skin node does, it changes *where*
/// it is allowed to act. "50 % whole-body" would have to mean "smooth half of
/// the neck", which is not a thing anyone asks for.
///
/// It is a **document** value rather than only `RPEngineFeatureFlags.bodySkinSync`
/// because the two answer different questions, and both have to be asked:
///
/// * the flag is *"does this build ship the effect at all"* — a process global
///   the app sets at launch, still `false` (docs/ADR-0021 "the flag stays off":
///   no iPhone measurement exists for the ~35 ms/shot of Vision + classifier
///   work, the same bar ADR-0018 and ADR-0020 are held to);
/// * this value is *"does the user want it on this picture"* — per project,
///   saved in `edits/<id>.json`, carried by a preset.
///
/// A build-time flag alone could not express the second, and would mean the
/// feature is either on for every shot or absent — neither of which is a toggle.
///
/// ## Where it is stored, and why there
///
/// `EditState.sections["mask"]["bodySkinSync"] = true`, with **absent meaning
/// off** — the identical arrangement ``BackgroundLock`` uses one key over, and
/// for the identical reasons. `EditState.SectionKey.mask` is RPCore's namespace
/// for *"where an effect is allowed to act … not a set of sliders"*, which is
/// exactly what this is; an untouched document stays empty, so
/// `EditState.isDefault` keeps meaning "untouched"; and it is a section rather
/// than `EditState.perImage` because it transfers — "also fix the skin on the
/// neck and arms" says nothing about which photo it was said on. A frame with no
/// body skin in it simply finds no coverage, which the user is told about
/// (``SkinRenderNode/detectionNotice(for:)``) instead of being left to guess.
public struct BodySkinSync: Sendable, Equatable, Hashable {
    /// The `EditState` namespace this lives in — shared with ``BackgroundLock``.
    public static let section = EditState.SectionKey.mask
    /// The parameter name inside that section.
    public static let key = "bodySkinSync"

    /// `true` when the user has asked for the "Da" sliders to reach body skin.
    public var isOn: Bool

    public init(isOn: Bool = false) {
        self.isOn = isOn
    }

    /// Reads the switch out of a document.
    ///
    /// Anything unexpected in the JSON (a number, a string, a missing section)
    /// reads as **off**, the same fallback ``BackgroundLock`` takes: an
    /// unreadable value must not silently widen where a user's sliders act.
    public init(_ state: EditState) {
        self.isOn = state[section: Self.section][Self.key]?.boolValue ?? false
    }

    /// Writes the switch into a document, *removing* the key when it is off, so
    /// turning it on and off again leaves no trace and an untouched document
    /// stays byte-identical to an empty one.
    public func write(into state: inout EditState) {
        var values = state[section: Self.section]
        values[Self.key] = isOn ? .bool(true) : nil
        state[section: Self.section] = values
    }

    /// What this document contributes to ``RenderRequest/bodySkinMask``.
    ///
    /// The mirror of ``BackgroundLock/gateMasks(for:subjectGate:)``, and it is
    /// deliberately the *request assembly* that applies the switch rather than
    /// ``SkinRenderNode``: the node's union, its kernel and ADR-0009's 79.0 dB
    /// are untouched by this feature's UI, and "no mask" is a state the node has
    /// always known how to render (it binds the per-face coverage byte for byte).
    ///
    /// Three conditions, all of which must hold:
    ///
    /// 1. `RPEngineFeatureFlags.bodySkinSync` — off in the shipping build, and
    ///    re-read per request rather than captured, so flipping it mid-session
    ///    takes effect on the next frame;
    /// 2. the document's own switch;
    /// 3. a mask was actually computed. `nil` here means "not computed" — the
    ///    flag was off when the shot opened, the classifier threw, or the shot
    ///    is still opening — and never "found nothing", which is a *coverage*
    ///    of ~0 and is what `SkinRenderNode.detectionNotice(for:)` reports to
    ///    the user.
    ///
    /// - Returns: `mask` when the feature is live for this document, else `nil`.
    public static func mask(for editState: EditState, bodySkinMask: RenderMask?) -> RenderMask? {
        guard RPEngineFeatureFlags.bodySkinSync else { return nil }
        guard BodySkinSync(editState).isOn else { return nil }
        return bodySkinMask
    }
}

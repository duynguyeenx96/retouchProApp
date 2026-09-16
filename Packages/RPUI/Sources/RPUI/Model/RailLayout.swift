import Foundation
import RPCore

/// One entry of the tool rail — the phone's bottom scroll row and the Mac's
/// far-right vertical rail (docs/design/SPEC.md §"Turn 3 — expanded toolset
/// rail", screens 3a-3f).
///
/// The rail is **navigation, not taxonomy**: it is a second, longer list drawn
/// on top of the six real slider groups in ``SliderPanelLayout``, taken from the
/// design canvas's `RAIL` const. Three consequences, all deliberate:
///
/// * **More rail items than sections.** Nineteen entries point at six sections,
///   so "Mắt", "Bọng mắt" and "Răng" all open the one Mắt & Răng panel and
///   "Mịn da" and "Kiềm dầu" both open the Da panel — SPEC's wiring table says
///   so in as many words (*"Two rail entries intentionally point at the same
///   real panel — do not build separate eye-bag logic"*). Two entries lighting
///   up together is the correct behaviour, not a bug.
/// * **Most entries have nothing behind them.** ``sectionKey`` is `nil` for the
///   ten tools with no engine slider at all (Mẫu, Tự động, Thu gọn, Cơ thể,
///   Sửa da, Săn chắc, Căng mọng, Mụn, Đầu, Tạo khối — deferred to Phase 5/6,
///   see `docs/PLAN.md` §Phase 2 "Turn 3 canvas"). They are drawn dimmed and
///   inert rather than hidden, the same rule the locked slider groups already
///   follow (docs/design/SPEC.md cross-cutting rule 4).
///   **"Xoá vật thể" (object removal) is not one of these** — it was cut from
///   scope entirely on 2026-09-11 (`docs/design/SPEC.md` §Turn 3 "Cut from
///   scope"), not merely locked, so it has no descriptor below at all.
/// * **No new render capability.** This file adds names and icons; it adds no
///   `RenderGraph` node, no `EditState.SectionKey`, and no per-tool grid /
///   subtab / single-intensity-slider chrome — that micro-UX is itself locked
///   per SPEC.
///
/// Labels are Vietnamese and are the mockup's literal strings (cross-cutting
/// rule 6). Icons are SF Symbols: an item that points at a section reuses **that
/// section's** `systemImage`, so the rail icon and the panel it opens look like
/// the same thing; the locked ones are approximations of the canvas's hand-drawn
/// vector glyphs, which have no SF Symbol equivalent.
public struct RailItemDescriptor: Identifiable, Hashable, Sendable {
    /// Stable slug, e.g. `"templates"`, `"teeth"`, `"auto"`. Not an
    /// `EditState.SectionKey` and never written to disk — several items share
    /// one section key, so the section key cannot identify a row.
    public let id: String
    /// What the user reads, e.g. "Kiềm dầu".
    public let label: String
    public let systemImage: String
    /// `nil` = no working section behind this item yet (locked). Non-nil points
    /// at an `EditState.SectionKey` — which may itself still be locked
    /// (Trang điểm / Tóc are Phase 5), so ``isLocked`` checks both.
    public let sectionKey: String?
    /// The screen this item opens instead of a slider group.
    ///
    /// Only "Mẫu" has one (Phase 3, docs/PLAN.md §Phase 3 *"dùng lại UI rail
    /// 'Mẫu' đã khoá … làm màn preset"*): it is a **library**, not a set of
    /// sliders, so it has no `EditState` namespace and cannot be expressed as a
    /// ``sectionKey``. An item with a presentation is not locked.
    public let presentation: RailPresentation?
    /// Overrides the generic ``lockedHint`` for an item whose lock has a
    /// *specific* reason worth telling the user.
    ///
    /// "chưa khả dụng" is the honest answer for a tool nobody has started; it is
    /// not the honest answer for one whose engine is built and deliberately held
    /// back. "Khoá nền" is the first of those: its mask, rasteriser and gate slot
    /// all ship, and the only thing missing is a measurement on a real iPhone
    /// (docs/ADR-0018 — *"Both flags stay off and no default `qualityLevel` is
    /// declared anywhere"*). Saying so is the difference between "we forgot" and
    /// "we are not shipping a number we have not measured".
    ///
    /// `nil` on every other item, which keeps the derived wording below.
    public let lockedReason: String?

    public init(
        id: String, label: String, systemImage: String, sectionKey: String? = nil,
        presentation: RailPresentation? = nil, lockedReason: String? = nil
    ) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
        self.sectionKey = sectionKey
        self.presentation = presentation
        self.lockedReason = lockedReason
    }

    /// `true` when tapping this item can do nothing: no section *and* no screen
    /// behind it, or the section behind it is one of the Phase 5 groups.
    public var isLocked: Bool {
        if presentation != nil { return false }
        guard let sectionKey else { return true }
        return SliderPanelLayout.section(forKey: sectionKey)?.isLocked ?? true
    }

    /// The tooltip / VoiceOver hint for a locked item. Where a section exists
    /// and is itself locked it can name the phase ("Phase 5 · chưa khả dụng",
    /// matching the panel's own caption); an item with no section at all has no
    /// phase to name, because which phase picks it up is still open
    /// (`docs/PLAN.md` §Phase 6 "Turn 3 canvas").
    public var lockedHint: String {
        if presentation != nil { return "" }
        if let lockedReason { return lockedReason }
        guard let sectionKey,
            let section = SliderPanelLayout.section(forKey: sectionKey)
        else { return "chưa khả dụng" }
        return section.isLocked ? "\(section.phase) · chưa khả dụng" : ""
    }
}

/// A rail item that opens a **screen** rather than selecting a slider group.
///
/// One case today, and it is deliberately an enum anyway: the two other rail
/// items that will eventually open something rather than select something ("Tự
/// động" is a one-tap formula, Phase 6.5) should land here instead of growing a
/// second boolean on ``RailItemDescriptor``.
public enum RailPresentation: Hashable, Sendable {
    /// The preset library (docs/PLAN.md §Phase 3). The associated value is which
    /// half of it opens — the full template gallery, or the colour-only Looks
    /// picker.
    case presetLibrary(PresetLibraryKind)
}

/// The nineteen-item tool rail, in **the user's workflow order**.
///
/// It is data, not view code, for the same reason ``SliderPanelLayout`` is: the
/// order is a product decision and a test can assert the wiring table
/// (docs/design/SPEC.md §Turn 3) instead of a reviewer counting icons on a
/// screenshot. Six items are active — Mặt, Mắt, Mịn da, Răng, Kiềm dầu,
/// Bọng mắt — and the other thirteen are locked.
///
/// **The membership is no longer exactly the canvas's `RAIL` const**: one member
/// was cut and one was added, both on the record.
///
/// * **Cut — "Xoá vật thể"**, entirely out of scope on 2026-09-11, not locked;
///   see `docs/design/SPEC.md` §Turn 3 "Cut from scope" for why (no
///   face/landmark pipeline reuse for free-form object selection, unlike every
///   other locked item here).
/// * **Added — "Khoá nền"** (docs/PLAN.md §6.1), which the canvas never drew
///   because it is a scope switch rather than a tool. It is appended last and
///   ships locked; the descriptor below says why at length.
///
/// So: nineteen, the same count as the canvas by coincidence, not the same set.
///
/// **The order is no longer the design canvas's `RAIL` const.** The canvas order
/// buried the three tools the user actually opens first (Mặt was 5th, Mịn da
/// 8th, Mắt 16th — off-screen on a phone until you scrolled) behind locked
/// placeholders. The user's real sequence is **Mặt → Mắt → Mịn da**, then
/// everything else, with **Màu last** (``colorItem``, pinned at the trailing
/// end). So those three lead, and the remaining sixteen keep their canvas
/// relative order underneath. The *membership* and the wiring table are still
/// the canvas's; only the sequence moved.
public enum RailLayout {
    public static let items: [RailItemDescriptor] = [
        // The user's first three steps, in the order they do them.
        RailItemDescriptor(
            id: "face", label: "Mặt", systemImage: "face.smiling",
            sectionKey: EditState.SectionKey.face),
        RailItemDescriptor(
            id: "eyes", label: "Mắt", systemImage: "eye",
            sectionKey: EditState.SectionKey.eyesTeeth),
        RailItemDescriptor(
            id: "smooth", label: "Mịn da", systemImage: "sparkles",
            sectionKey: EditState.SectionKey.skin),

        // …then the other sixteen, in the canvas's relative order.
        // Template gallery — **unlocked in Phase 3** (docs/PLAN.md §Phase 3,
        // "dùng lại UI rail 'Mẫu' đã khoá … làm màn preset thay vì xây UI preset
        // riêng"). It is the one rail item that opens a screen instead of
        // selecting a slider group, so it carries a ``RailPresentation`` and no
        // `sectionKey`; the Looks picker is the same screen with a different
        // ``PresetLibraryKind`` and is reached from inside it, because the
        // canvas's rail has no Looks entry to unlock.
        RailItemDescriptor(
            id: "templates", label: "Mẫu", systemImage: "square.stack",
            presentation: .presetLibrary(.templates)),
        RailItemDescriptor(
            id: "teeth", label: "Răng", systemImage: "eye",
            sectionKey: EditState.SectionKey.eyesTeeth),
        // One-tap auto retouch: a fixed preset formula, not a new node — the
        // formula has to be agreed first (docs/PLAN.md §Phase 6).
        RailItemDescriptor(id: "auto", label: "Tự động", systemImage: "wand.and.stars"),
        RailItemDescriptor(
            id: "makeup", label: "Trang điểm", systemImage: "paintbrush.pointed",
            sectionKey: EditState.SectionKey.makeup),
        RailItemDescriptor(
            id: "slim", label: "Thu gọn", systemImage: "arrow.down.right.and.arrow.up.left"),
        RailItemDescriptor(id: "body", label: "Cơ thể", systemImage: "figure.stand"),
        // "Sửa da" is resolved (2026-09-11, docs/PLAN.md §Phase 6.2): not a new
        // slider set, but a toggle that extends the existing 8 Da sliders'
        // effect from the face-only mask onto a whole-body skin mask, so a
        // beauty-retouched face doesn't visibly mismatch untouched neck/arm/
        // chest skin in the same frame. No engine work yet — still locked.
        RailItemDescriptor(id: "skinFix", label: "Sửa da", systemImage: "bandage"),
        RailItemDescriptor(id: "firm", label: "Săn chắc", systemImage: "dumbbell"),
        RailItemDescriptor(id: "plump", label: "Căng mọng", systemImage: "drop"),
        RailItemDescriptor(id: "acne", label: "Mụn", systemImage: "circle.dotted"),
        RailItemDescriptor(id: "head", label: "Đầu", systemImage: "person.crop.circle"),
        RailItemDescriptor(id: "contour", label: "Tạo khối", systemImage: "circle.lefthalf.filled"),
        // Second entry onto the Da panel: "Khử bóng dầu" already lives there.
        RailItemDescriptor(
            id: "shine", label: "Kiềm dầu", systemImage: "sparkles",
            sectionKey: EditState.SectionKey.skin),
        // Third entry onto Mắt & Răng. No eye-bag key exists; SPEC says to point
        // it at the same panel rather than invent one.
        RailItemDescriptor(
            id: "eyeBags", label: "Bọng mắt", systemImage: "eye",
            sectionKey: EditState.SectionKey.eyesTeeth),
        RailItemDescriptor(
            id: "hair", label: "Tóc", systemImage: "comb",
            sectionKey: EditState.SectionKey.hair),

        // **Not from the design canvas's `RAIL` const** — the nineteenth entry,
        // appended after the canvas's own members so their relative order is
        // untouched.
        //
        // "Khoá nền" (docs/PLAN.md §6.1) is not another tool: it is a scope
        // switch that narrows whatever the other tools do, which is why it sits
        // at the end of the list rather than among them, and why it has no
        // ``sectionKey`` — it owns no slider panel. Its document value is
        // `RPEngine.BackgroundLock` (one boolean in `EditState`), and the engine
        // behind it is finished: `PersonSegmenter` → `SubjectMaskProviding` →
        // `BackgroundLockMaskSource` → `RenderRequest.gateMasks`.
        //
        // It ships **locked anyway**, and that is the whole point of the entry:
        // `RPEngineFeatureFlags.backgroundLock` is off and stays off until
        // `VNGeneratePersonSegmentationRequest` has been measured on a real
        // iPhone (docs/ADR-0018 — the macOS numbers are 5.5/17.2/54.5 ms per
        // quality level and the Simulator cannot run the request at all, so
        // there is no A-series figure and no defensible `qualityLevel` default).
        // The structure is in place so that turning it on is a flag flip plus a
        // control, not a UI project.
        RailItemDescriptor(
            id: "backgroundLock", label: "Khoá nền",
            systemImage: "person.and.background.dotted",
            lockedReason: "Phase 6.1 · cần đo trên iPhone thật trước"),
    ]

    /// The one tool that is **not** in the canvas's rail and still has to be
    /// reachable: **Màu**.
    ///
    /// ``items`` is the mockup's `RAIL` const verbatim, and that const has no
    /// colour entry — but `EditState.SectionKey.color` is eighteen working
    /// sliders (docs/ADR-0012, docs/ADR-0016) and the six-group rail this
    /// replaced was the only way into them. `docs/design/SPEC.md` §"macOS panel
    /// (3f) structural note" says exactly what to do about that: *"confirm this
    /// replacement doesn't orphan Màu … keep a way to reach the Color panel —
    /// e.g. keep it as an always-visible top-level tab alongside the rail rather
    /// than dropping it."*
    ///
    /// So it is **pinned outside the scroll view** in both shells — visibly not
    /// one of the nineteen, and impossible to scroll off. Label and icon are
    /// read from the section itself, so the affordance cannot drift from the
    /// panel it opens; the literals are only the unreachable fallback for a
    /// missing section, which would make the item locked and inert anyway.
    ///
    /// It sits at the **trailing end** (right of the phone row, bottom of the
    /// Mac rail) because colour is the user's *last* step — the same reason
    /// Mặt/Mắt/Mịn da lead ``items``. Pinned-and-last, not merely appended to
    /// the scrolling list: being outside the scroll view is what guarantees the
    /// Color panel cannot be scrolled out of reach.
    public static let colorItem: RailItemDescriptor = {
        let section = SliderPanelLayout.section(forKey: EditState.SectionKey.color)
        return RailItemDescriptor(
            id: "color",
            label: section?.title ?? "Màu",
            systemImage: section?.systemImage ?? "camera.filters",
            sectionKey: EditState.SectionKey.color)
    }()

    /// Everything the rail offers, in the order it is drawn: the scrolling
    /// nineteen, then the pinned Màu chip. Use this — not ``items`` — to ask
    /// "can the user get anywhere from here".
    public static var allItems: [RailItemDescriptor] { items + [colorItem] }

    /// The items a tap actually moves the panel for.
    public static var activeItems: [RailItemDescriptor] { allItems.filter { !$0.isLocked } }

    /// The slider sections a user can actually open from the rail. A working
    /// section missing from this set is orphaned UI — `RailLayoutTests` fails on
    /// it rather than leaving it to be noticed on a device.
    public static var reachableSectionKeys: Set<String> {
        Set(activeItems.compactMap(\.sectionKey))
    }
}

import Foundation
import RPCore

/// One entry of the tool rail — the phone's bottom scroll row and the Mac's
/// far-right vertical rail (docs/design/SPEC.md §"Turn 3 — expanded toolset
/// rail", screens 3a-3f).
///
/// The rail is **navigation, not taxonomy**: it is a second list drawn on top of
/// the real slider panels in ``SliderPanelLayout``, taken from the design
/// canvas's `RAIL` const. Four consequences, all deliberate:
///
/// * **It is two levels deep since 2026-09-18** (docs/design/SPEC.md §Turn 3,
///   third dated note). It used to be a flat nineteen, on the theory that two
///   entries opening the same panel says "these are the same body part". Three
///   rounds of user feedback killed that: "Răng" opening the eye panel, then
///   "Mắt"/"Bọng mắt" being two doors into one place with nothing to tell them
///   apart, then "Mịn da"/"Kiềm dầu" carrying the same `sparkles` glyph onto the
///   same unfiltered panel. The decision taken was structural rather than another
///   pairwise patch: **body part (parent) → sub-feature (child)**. So "Mặt" and
///   "Cơ thể" are now parents with ``children``, everything under them is a leaf
///   with its own panel, and the duplicate "Bọng mắt" entry is gone outright —
///   one door per thing.
/// * **Most entries have nothing behind them.** ``sectionKey`` is `nil` for the
///   tools with no engine slider at all (Tự động, Thu gọn, Săn chắc, Sửa da,
///   Căng mọng, Mụn, Đầu, Tạo khối, Khoá nền — deferred to Phase 5/6, see
///   `docs/PLAN.md` §Phase 2 "Turn 3 canvas"). They are drawn dimmed and inert
///   rather than hidden, the same rule the locked slider groups already follow
///   (docs/design/SPEC.md cross-cutting rule 4). A **parent** is locked only when
///   every one of its children is ("Cơ thể" today).
///   **"Xoá vật thể" (object removal) is not one of these** — it was cut from
///   scope entirely on 2026-09-11 (`docs/design/SPEC.md` §Turn 3 "Cut from
///   scope"), not merely locked, so it has no descriptor below at all.
/// * **No new render capability.** This file adds names, icons and one level of
///   grouping; it adds no `RenderGraph` node, no `EditState.SectionKey`, and no
///   per-tool grid / subtab / single-intensity-slider chrome — that micro-UX is
///   itself locked per SPEC.
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
    /// `nil` = no working section behind this item yet (locked), **or** this item
    /// is a parent and its ``children`` carry the panels. Non-nil points at a
    /// `SliderSectionDescriptor.key` — a **panel**, which is an
    /// `EditState.SectionKey` for four of the eight and a UI-only
    /// `SliderPanelLayout.PanelKey` for the four that share a namespace with
    /// another panel (2026-09-18 splits). The panel may itself still be locked
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
    /// The sub-features of a **body part**, or `nil` for a leaf (which is most of
    /// the rail and every item the rail had before 2026-09-18).
    ///
    /// A parent carries no ``sectionKey`` and no ``presentation`` of its own: a
    /// body part is not a panel, so tapping it opens its ``defaultChild`` and
    /// shows the children as a second-level strip inside the panel. Exactly one
    /// level deep, on purpose — the canvas's own third level (the per-tool grid +
    /// single "Cường độ" slider) is locked per SPEC and this is not it.
    public let children: [RailItemDescriptor]?

    public init(
        id: String, label: String, systemImage: String, sectionKey: String? = nil,
        presentation: RailPresentation? = nil, lockedReason: String? = nil,
        children: [RailItemDescriptor]? = nil
    ) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
        self.sectionKey = sectionKey
        self.presentation = presentation
        self.lockedReason = lockedReason
        self.children = children
    }

    /// `true` for a body part rather than a tool.
    public var isParent: Bool { children != nil }

    /// `true` when tapping this item can do nothing: no section *and* no screen
    /// behind it, or the section behind it is one of the Phase 5 groups — and,
    /// for a parent, when *every* child is locked. A parent is not a second
    /// concept of "locked": it is the same question asked of its children, so a
    /// group unlocks itself the moment any one tool inside it does.
    public var isLocked: Bool {
        if let children { return children.allSatisfy(\.isLocked) }
        if presentation != nil { return false }
        guard let sectionKey else { return true }
        return SliderPanelLayout.section(forKey: sectionKey)?.isLocked ?? true
    }

    /// What a tap on a parent opens: the first child that works, or — when the
    /// whole group is locked — the first child, so the panel still shows the
    /// group's own dimmed taxonomy instead of nothing (the treatment a fully
    /// locked group already gets). `nil` for a leaf.
    public var defaultChild: RailItemDescriptor? {
        guard let children, !children.isEmpty else { return nil }
        return children.first { !$0.isLocked } ?? children.first
    }

    /// Every panel reachable through this item — itself for a leaf, all of its
    /// children's for a parent.
    ///
    /// This is what the two rails highlight off: a parent is "active" whenever
    /// the open panel is one of its children's, which is the one-level-deeper
    /// form of the old `item.sectionKey == chrome.activeGroupKey` rule.
    public var sectionKeys: [String] {
        if let children { return children.flatMap(\.sectionKeys) }
        return sectionKey.map { [$0] } ?? []
    }

    /// `true` when `key` is the panel this item opens, or one its children open.
    public func opensPanel(_ key: String?) -> Bool {
        guard let key else { return false }
        return sectionKeys.contains(key)
    }

    /// The tooltip / VoiceOver hint for a locked item. Where a section exists
    /// and is itself locked it can name the phase ("Phase 5 · chưa khả dụng",
    /// matching the panel's own caption); an item with no section at all has no
    /// phase to name, because which phase picks it up is still open
    /// (`docs/PLAN.md` §Phase 6 "Turn 3 canvas"). A locked parent borrows the
    /// hint of the child a tap would have opened.
    public var lockedHint: String {
        if let children {
            guard isLocked else { return "" }
            return children.first?.lockedHint ?? "chưa khả dụng"
        }
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

/// The tool rail: **eight top-level entries plus the pinned "Màu" chip**, two
/// levels deep, in the user's workflow order.
///
/// It is data, not view code, for the same reason ``SliderPanelLayout`` is: the
/// order is a product decision and a test can assert the wiring table
/// (docs/design/SPEC.md §Turn 3) instead of a reviewer counting icons on a
/// screenshot.
///
/// **The hierarchy (2026-09-18).** The rail was a flat nineteen until three
/// rounds of user feedback said the flatness itself was the bug — "Răng" opening
/// the eye panel, "Mắt"/"Bọng mắt" being two indistinguishable doors into one
/// place, "Mịn da"/"Kiềm dầu" sharing a glyph *and* a panel. Rather than patch a
/// fourth pair, the structure is now **body part → sub-feature**:
///
/// * **Mặt** → Hình dáng mặt · Mắt · Răng · Đầu · Tạo khối · Căng mọng · Mụn
/// * **Da** → Mịn da · Kiềm dầu · Sửa da
/// * **Cơ thể** → Thu gọn · Săn chắc
/// * everything else stays a top-level leaf, in the relative order it already
///   had: Mẫu, Tự động, Trang điểm, Tóc, Khoá nền.
///
/// **"Da" is its own parent, not a sub-feature of "Mặt"** (user's correction,
/// 2026-09-18): skin smoothing is a *whole-body* concept even though today's
/// engine only reaches it through a face mask — extending it to the rest of the
/// body is exactly what the still-locked "Sửa da" (`bodySkinSync`) does, so
/// "Sửa da" is a child **here** rather than a top-level odd one out.
///
/// Two items changed identity in the move and nothing else did: the old
/// top-level "Mặt" leaf is the child **"Hình dáng mặt"** (same fifteen sliders,
/// same `EditState.SectionKey.face`) so that a parent and a child are not both
/// called "Mặt", and **"Bọng mắt" is deleted outright** rather than repointed —
/// it was a second door into "Mắt" with no distinguishing feature, which is
/// exactly what the restructuring exists to stop.
///
/// **The membership is not the canvas's `RAIL` const**: one member was cut, one
/// added and one deleted, all on the record.
///
/// * **Cut — "Xoá vật thể"**, entirely out of scope on 2026-09-11, not locked;
///   see `docs/design/SPEC.md` §Turn 3 "Cut from scope" for why (no
///   face/landmark pipeline reuse for free-form object selection, unlike every
///   other locked item here).
/// * **Added — "Khoá nền"** (docs/PLAN.md §6.1), which the canvas never drew
///   because it is a scope switch rather than a tool. It is last and ships
///   locked; the descriptor below says why at length.
/// * **Deleted — "Bọng mắt"** (2026-09-18), as above.
///
/// **The order is not the canvas's either.** The canvas order buried the tools
/// the user actually opens first behind locked placeholders; the user's real
/// sequence is **Mặt → Da first**, everything else after them in the canvas's
/// relative order, and **Màu last** (``colorItem``, pinned at the trailing end).
/// Inside each parent the children run in workflow order — reshape, eyes, teeth,
/// then the locked ones.
public enum RailLayout {
    /// The seven sub-features of the face, in workflow order. Written out here
    /// rather than inline so the parent below reads as one line.
    private static let faceChildren: [RailItemDescriptor] = [
        // The old top-level "Mặt" leaf, renamed. The panel, its fifteen sliders
        // and its `EditState.SectionKey.face` namespace are untouched — only the
        // rail label moved, because a child called "Mặt" inside a parent called
        // "Mặt" is the confusion this restructuring is about.
        RailItemDescriptor(
            id: "face", label: "Hình dáng mặt", systemImage: "face.smiling",
            sectionKey: EditState.SectionKey.face),
        // The three eye sliders. There is exactly **one** entry into this panel
        // now: "Bọng mắt" pointed at the same place with the same `eye` glyph
        // and was deleted rather than kept as a duplicate door.
        RailItemDescriptor(
            id: "eyes", label: "Mắt", systemImage: "eye",
            sectionKey: SliderPanelLayout.PanelKey.eyes),
        // Its own panel and its own icon since 2026-09-18 — one slider, "Trắng
        // răng". It shared the eye panel until a user reported the obvious
        // consequence: "Răng" opened Sáng mắt / Trắng lòng trắng / Nét mắt and
        // lit "Mắt" up at the same time. `mouth` rather than a tooth glyph
        // because SF Symbols has no tooth on macOS 15 / iOS 18; the icon is the
        // panel's own, as ``iconsMatchTheirSection`` requires.
        RailItemDescriptor(
            id: "teeth", label: "Răng", systemImage: "mouth",
            sectionKey: SliderPanelLayout.PanelKey.teeth),
        // Locked, unchanged by the restructuring: head reshape has an engine
        // (`HeadReshape`) but no slider section wired to the UI yet.
        RailItemDescriptor(id: "head", label: "Đầu", systemImage: "person.crop.circle"),
        // Locked, unchanged: Phase 6.2 shipped the contour *render* behind
        // `RPEngineFeatureFlags.contourSliders` (default off, docs/ADR-0020), so
        // there is still no panel to open.
        RailItemDescriptor(id: "contour", label: "Tạo khối", systemImage: "circle.lefthalf.filled"),
        // Lip plumping — a face feature, not a body one (user's call,
        // 2026-09-18), so it sits here rather than under "Cơ thể". The label is
        // still the canvas's literal (cross-cutting rule 6); it is locked.
        RailItemDescriptor(id: "plump", label: "Căng mọng", systemImage: "drop"),
        RailItemDescriptor(id: "acne", label: "Mụn", systemImage: "circle.dotted"),
    ]

    /// The three sub-features of the skin — **not** filed under "Mặt", because
    /// skin is a whole-body concept (user's correction, 2026-09-18). Today's
    /// engine only applies the two working panels through a face mask, and the
    /// third child is precisely the switch that lifts that limit.
    private static let skinChildren: [RailItemDescriptor] = [
        // Seven of the eight Da sliders. Its own panel since 2026-09-18 — it and
        // "Kiềm dầu" used to be two `sparkles` icons opening the same unfiltered
        // eight-slider panel.
        RailItemDescriptor(
            id: "smooth", label: "Mịn da", systemImage: "sparkles",
            sectionKey: SliderPanelLayout.PanelKey.smooth),
        // The eighth: "Khử bóng dầu", alone, under its own icon.
        RailItemDescriptor(
            id: "shine", label: "Kiềm dầu", systemImage: "humidity",
            sectionKey: SliderPanelLayout.PanelKey.shine),
        // "Sửa da" is resolved (2026-09-11, docs/PLAN.md §Phase 6.2): not a new
        // slider set, but a toggle that extends the two panels above from the
        // face-only mask onto a whole-body skin mask, so a beauty-retouched face
        // doesn't visibly mismatch untouched neck/arm/chest skin in the same
        // frame. That is why it belongs **here** and not at the top level: it is
        // this group's own scope switch. No engine work yet — still locked.
        RailItemDescriptor(id: "skinFix", label: "Sửa da", systemImage: "bandage"),
    ]

    /// The two sub-features of the body. Both locked today, which makes the
    /// parent locked too — see ``RailItemDescriptor/isLocked``.
    private static let bodyChildren: [RailItemDescriptor] = [
        RailItemDescriptor(
            id: "slim", label: "Thu gọn", systemImage: "arrow.down.right.and.arrow.up.left"),
        RailItemDescriptor(id: "firm", label: "Săn chắc", systemImage: "dumbbell"),
    ]

    public static let items: [RailItemDescriptor] = [
        // The parent the user opens first. `face.dashed` rather than
        // `face.smiling`: the child "Hình dáng mặt" borrows `face.smiling` from
        // its panel (``iconsMatchTheirSection``), and a parent drawn with its own
        // child's glyph at the same time is the duplicate-icon complaint again,
        // one level up.
        RailItemDescriptor(
            id: "faceGroup", label: "Mặt", systemImage: "face.dashed",
            children: Self.faceChildren),
        // The second parent, right after it: the user's workflow is Mặt → Da.
        // `circle.hexagongrid` reads as pores/texture and is not any child's
        // glyph (`sparkles` / `humidity` / `bandage`), the same rule as above.
        RailItemDescriptor(
            id: "skinGroup", label: "Da", systemImage: "circle.hexagongrid",
            children: Self.skinChildren),

        // …then the other leaves, in the canvas's relative order.
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
        // One-tap auto retouch: a fixed preset formula, not a new node — the
        // formula has to be agreed first (docs/PLAN.md §Phase 6).
        RailItemDescriptor(id: "auto", label: "Tự động", systemImage: "wand.and.stars"),
        RailItemDescriptor(
            id: "makeup", label: "Trang điểm", systemImage: "paintbrush.pointed",
            sectionKey: EditState.SectionKey.makeup),
        // The third parent, in the slot "Cơ thể" already held.
        RailItemDescriptor(
            id: "body", label: "Cơ thể", systemImage: "figure.stand",
            children: Self.bodyChildren),
        RailItemDescriptor(
            id: "hair", label: "Tóc", systemImage: "comb",
            sectionKey: EditState.SectionKey.hair),

        // **Not from the design canvas's `RAIL` const** — appended after the
        // canvas's own members so their relative order is untouched.
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
    /// one of the eight, and impossible to scroll off. Label and icon are
    /// read from the section itself, so the affordance cannot drift from the
    /// panel it opens; the literals are only the unreachable fallback for a
    /// missing section, which would make the item locked and inert anyway.
    ///
    /// It sits at the **trailing end** (right of the phone row, bottom of the
    /// Mac rail) because colour is the user's *last* step — the same reason
    /// "Mặt" leads ``items``. Pinned-and-last, not merely appended to
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

    /// Everything the rail draws at the top level, in the order it is drawn: the
    /// scrolling eight, then the pinned Màu chip. **Not** the children — those
    /// are drawn one level in, by the panel's own strip.
    public static var allItems: [RailItemDescriptor] { items + [colorItem] }

    /// Every item a tap can land on: the top-level eight, each parent's children
    /// spliced in after it, then the pinned Màu chip. Use this — not
    /// ``allItems`` — to ask "can the user get anywhere from here".
    public static var leafItems: [RailItemDescriptor] {
        allItems.flatMap { $0.children ?? [$0] }
    }

    /// The leaves a tap actually moves the panel for (or opens a screen from).
    /// A parent is not here: it has no destination of its own, it forwards to
    /// ``RailItemDescriptor/defaultChild``.
    public static var activeItems: [RailItemDescriptor] { leafItems.filter { !$0.isLocked } }

    /// The slider sections a user can actually open from the rail. A working
    /// section missing from this set is orphaned UI — `RailLayoutTests` fails on
    /// it rather than leaving it to be noticed on a device.
    public static var reachableSectionKeys: Set<String> {
        Set(activeItems.compactMap(\.sectionKey))
    }

    /// The parent whose child strip belongs on screen while `key` is the open
    /// panel, or `nil` when the open panel belongs to a top-level leaf (Trang
    /// điểm, Tóc, the pinned Màu).
    ///
    /// Derived from the open panel rather than stored in ``EditorChrome``: there
    /// is then no second piece of state that can disagree with the panel about
    /// where the user is.
    public static func parent(ofPanelKey key: String?) -> RailItemDescriptor? {
        guard let key else { return nil }
        return items.first { $0.isParent && $0.opensPanel(key) }
    }
}

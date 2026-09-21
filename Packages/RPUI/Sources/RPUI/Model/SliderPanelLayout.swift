import Foundation
import RPCore
import RPEngine

/// One working slider in the panel.
///
/// `key` is **not** written here — it comes from the engine's own key list
/// (`SkinSliders.Key.all`, `FaceSliders.Key.all`, `EyesTeethSliders.Key.all`,
/// `ColorSliders.Key.all`), so a slider renamed in RPEngine cannot leave a dead
/// control in the UI writing an ignored JSON key. `SliderPanelLayoutTests`
/// checks the two lists are the same set, in the same order.
///
/// The **label** is the UI's business and is Vietnamese, matching
/// `docs/design/SPEC.md`'s mapping table. Where the mockup's label and the
/// engine's semantics disagree the engine wins (docs/design/SPEC.md: *"keep
/// engine key order authoritative; only the display label is a UI concern"*) —
/// e.g. the mockup lists the nose as Sống/Cánh/Đầu, the engine's order is
/// `noseShrink, noseBridge, noseTip`, so the labels are reordered onto the keys
/// rather than the keys onto the labels.
public struct SliderParameter: Identifiable, Hashable, Sendable {
    /// Parameter name inside the section, i.e. the JSON key in `edits/<id>.json`.
    public let key: String
    /// What the user reads.
    public let label: String
    /// One line saying which way the slider goes: "Vùng sáng" pulls highlights
    /// down, "Cằm" shortens. Required of every slider (`LivePreviewWiringTests`)
    /// — a control whose direction is not stated is a guess, whether it is
    /// one-directional (Da / Mặt / Mắt / Răng, docs/ADR-0010) or signed (Màu,
    /// docs/ADR-0016, where the line names **both** ends).
    ///
    /// The mockup's row has no room for a third line, so this is the macOS
    /// tooltip and the VoiceOver hint instead of a caption.
    public let direction: String
    /// What the track spans. `0...100` for every group except "Màu", where
    /// sixteen of the eighteen sliders are `-100...100` centred on 0
    /// (docs/ADR-0016). Read from `RPCore.Slider.range(for:in:)` rather than
    /// written here, for the same reason ``key`` is read from the engine: the
    /// panel must not be able to offer a value the document would clamp away.
    public let range: ClosedRange<Double>

    public var id: String { key }

    public init(
        key: String, label: String, direction: String,
        range: ClosedRange<Double> = Slider.range
    ) {
        self.key = key
        self.label = label
        self.direction = direction
        self.range = range
    }

    /// `true` for a slider whose neutral position is the middle of its track.
    public var isBidirectional: Bool { range.lowerBound < Slider.defaultValue }
}

/// One on/off row in a panel — a switch, not an amount.
///
/// The second kind of control the panel can draw (2026-09-21, "Sửa da",
/// docs/ADR-0021), and it exists because the first kind cannot express what
/// §6.2 settled: *"Không phải bộ slider mới … UI: một toggle"*. A 0–100 amount
/// whose 0 is neutral (`RPCore.Slider`) is the right shape for "how much"; this
/// is the shape for "where", which is either the face or the whole body and has
/// no middle.
///
/// ## Storage, which is the same rule as a slider's
/// ``key`` is the JSON key inside the panel's `storageKey` namespace, and
/// **absent means off** — the rule `EditSection.setSlider`, `RPEngine.FaceSelection`
/// and `RPEngine.BackgroundLock` all already follow, so an untouched document
/// stays empty and `EditState.isDefault` keeps meaning "untouched". The key is
/// read from the engine's own type (`BodySkinSync.key`) rather than written
/// here, for the same reason ``SliderParameter/key`` is: a value renamed in
/// RPEngine must not leave a dead control writing JSON nothing reads.
public struct PanelToggleDescriptor: Identifiable, Hashable, Sendable {
    /// Parameter name inside the section, i.e. the JSON key in `edits/<id>.json`.
    public let key: String
    /// What the user reads on the row.
    public let label: String
    /// One line under the label saying what turning it on does — the toggle's
    /// counterpart to ``SliderParameter/direction``. A switch has more to
    /// explain than a slider does (a slider's direction is visible in the
    /// track), so this is drawn rather than hidden in a tooltip.
    public let detail: String

    public var id: String { key }

    public init(key: String, label: String, detail: String) {
        self.key = key
        self.label = label
        self.detail = detail
    }
}

/// One group: a tab on the phone, a rail icon and a panel on the Mac.
public struct SliderSectionDescriptor: Identifiable, Hashable, Sendable {
    /// **The panel's own identity** — what `EditorChrome.activeGroupKey` holds,
    /// what a rail item's `sectionKey` points at, and what
    /// ``SliderPanelLayout/section(forKey:)`` looks up.
    ///
    /// Usually the same string as ``storageKey``, and for four of the eleven
    /// panels it is. It is a separate concept because a panel is a *UI* grouping
    /// and the namespace is a *storage* one, and since 2026-09-18 they are no
    /// longer 1:1 — see ``storageKey``.
    public let key: String
    /// The `EditState.SectionKey` namespace this group reads and writes.
    ///
    /// "Mắt" and "Răng" are **two panels over the one `eyesTeeth` namespace**
    /// (2026-09-18, docs/design/SPEC.md §Turn 3, "Răng opens an eye panel" bug):
    /// tapping "Răng" used to open a four-slider panel with three eye sliders in
    /// it, which the user reported as a functional error. The split is UI-only —
    /// `EditState.SectionKey.eyesTeeth`, `EyesTeethSliders` and
    /// `EyesTeethRenderNode` are untouched, so nothing on disk moved and every
    /// preset written before the split still applies unchanged.
    ///
    /// "Hình dáng mặt", "Đầu" and "Tạo khối" are three panels over `face` for a
    /// different reason (2026-09-21, docs/ADR-0020, docs/ADR-0022): not a split,
    /// but two further tools whose keys were put in the *face* namespace so a
    /// preset carries them (§5 of ADR-0020, §2 of ADR-0022). `EditState`,
    /// `Slider` and `FaceSliders` are untouched.
    ///
    /// "Mịn da" and "Kiềm dầu" are the same arrangement over `skin`, split later
    /// the same day for the same reason: the two rail entries carried the *same*
    /// `sparkles` icon and opened the *same* unfiltered eight-slider panel, so
    /// "Kiềm dầu" answered a question about oil with seven controls that are not
    /// about oil. "Kiềm dầu" is now the single `SkinSliders.Key.shine`; "Mịn da"
    /// is the other seven. Again UI-only — `SkinRenderNode` still reads all eight
    /// keys out of the one namespace.
    ///
    /// Everything that talks to the document goes through **this**, never
    /// ``key``; everything that identifies a panel goes through ``key``, never
    /// this.
    public let storageKey: String
    /// Short tab label — "Da", "Mặt", "Mắt", "Răng", "Màu", "Trang điểm", "Tóc".
    public let title: String
    /// The panel header's longer title — "Làm mịn da", "Tạo hình khuôn mặt".
    public let panelTitle: String
    /// The uppercase caption above the slider list — "Da mặt", "Hình học · 478
    /// điểm". Locked groups show "Phase 5 · chưa khả dụng".
    public let sectionCaption: String
    public let systemImage: String
    /// The phase that implements this group.
    public let phase: String
    /// Working sliders. Empty for a group whose render node does not exist yet
    /// (Trang điểm and Tóc are Phase 5) **and** for a group whose controls are
    /// all switches ("Sửa da" — see ``toggles``).
    public let parameters: [SliderParameter]

    /// Working on/off rows, drawn under the sliders.
    ///
    /// Empty for every panel but "Sửa da", which is the reverse: one toggle and
    /// no sliders. A panel is therefore *working* when it has either kind of
    /// control, which is what ``isLocked`` asks — before 2026-09-21 "no
    /// parameters" and "nothing to offer" were the same statement, and they are
    /// not any more.
    public let toggles: [PanelToggleDescriptor]
    /// `true` when the group's sliders need a detected face. With no face in the
    /// picture — or with the Core ML models absent — they cannot do anything,
    /// and the UI says so instead of offering a control that silently no-ops.
    public let needsFace: Bool

    /// The `RenderNode.name` whose ``RPEngine/RenderNode/detectionNotice(for:)``
    /// this group should also show, or `nil` for a group that has no detection
    /// behind it.
    ///
    /// ``needsFace`` answers one detection question — "is there a face at all" —
    /// and it is the only one the panel could ask before Phase 6. The groups
    /// added since depend on *further* detections that can fail independently of
    /// the face: the whole-body skin classifier ("Sửa da", `"skin"`), the hair
    /// silhouette trace ("Đầu", `"warp"`). Rather than teach the panel each of
    /// those, the group names the node and the node says, in one end-user
    /// sentence, what it could not find (`GroupAvailability.blockedReason`). The
    /// treatment is identical to the no-face case: the same `info.circle` line in
    /// `RPTheme.textTertiary`, the same disabled sliders.
    ///
    /// `nil` for every group whose sliders cannot fail this way, and that is not
    /// a "not yet" — "Cọ mask thủ công" is user input and "Tạo khối" is pure
    /// landmark geometry, so neither has anything to detect.
    ///
    /// **It is scoped to the panel, not to the node.** `"warp"` is the node
    /// behind *both* "Hình dáng mặt" and "Đầu", and only "Đầu" names it: the
    /// fifteen reshape sliders are landmarks only and keep working on a subject
    /// in a hat, where the hair trace the head group needs finds nothing. A
    /// notice disables the group it is attached to, so attaching this one to the
    /// reshape panel as well would take fifteen working sliders down with it —
    /// the same reasoning that gave "Sửa da" its own panel rather than a row
    /// inside "Mịn da" (docs/ADR-0021 §UI, docs/ADR-0022 §UI).
    public let notifiesFromNodeNamed: String?

    /// The build-time feature flag this group's sliders need, or `nil` for a
    /// group that works in every build — which is every group that shipped
    /// before "Tạo khối".
    ///
    /// A gated group is **wired and visible, not locked**: its keys, labels and
    /// ranges are real, the rail opens it, and the panel says in one sentence
    /// that this build has the effect switched off (``PanelFeatureGate/offReason``)
    /// while the rows are disabled. That is the same treatment
    /// ``GroupAvailability`` already gives "no face detected" — a standing fact
    /// about why the group cannot do anything *right now* — rather than the
    /// Phase 5 lock, which means "these sliders do not exist".
    ///
    /// The alternative, locking the rail item the way "Cọ mask" does
    /// (`RailPresentation.isAvailable`), is for an item with no panel behind it
    /// at all. Here there is a panel, so hiding it behind a dimmed icon would
    /// orphan a working panel that a flag flip is supposed to light up with no
    /// further wiring.
    public let gatedBy: PanelFeatureGate?

    public var id: String { key }

    /// `true` for the Phase 5 groups. They are drawn dimmed and inert rather
    /// than hidden, so the shell shows the full future taxonomy
    /// (docs/design/SPEC.md cross-cutting rule 4).
    ///
    /// "Has no control of **either** kind", not "has no slider": "Sửa da" is one
    /// toggle and no sliders, and calling it locked would tell the user its
    /// control does not exist when it does (docs/ADR-0021 §UI).
    public var isLocked: Bool { parameters.isEmpty && toggles.isEmpty }

    /// Labels only, kept because the Phase 1 panel and its tests are written
    /// against it and because the Phase 5 groups still have nothing else.
    public var plannedParameters: [String] {
        isLocked ? plannedNames : parameters.map(\.label) + toggles.map(\.label)
    }
    private let plannedNames: [String]

    /// How many of **this panel's own** controls the document has moved off
    /// their default — a slider off 0, or a toggle switched on.
    ///
    /// Not `state[section: storageKey].values.count`: two panels can share a
    /// namespace, and "Răng" must not claim the eye sliders' dot. The same
    /// reasoning is why the toggles are counted here rather than by namespace:
    /// "Sửa da" shares `mask` with "Khoá nền"'s own boolean and must not light
    /// its dot.
    public func activeParameterCount(in state: EditState) -> Int {
        let values = state[section: storageKey]
        let sliders = parameters.reduce(into: 0) { count, parameter in
            if values.slider(parameter.key) != Slider.defaultValue { count += 1 }
        }
        return toggles.reduce(into: sliders) { count, toggle in
            if values[toggle.key]?.boolValue == true { count += 1 }
        }
    }

    /// `true` when this panel has nothing of its own to reset.
    ///
    /// A locked group has no control to count, so it falls back to "is the
    /// namespace empty" — the check this replaced, and the only one available
    /// for a group whose sliders do not exist yet.
    public func isNeutral(in state: EditState) -> Bool {
        isLocked
            ? state[section: storageKey].isEmpty
            : activeParameterCount(in: state) == 0
    }

    public init(
        key: String,
        storageKey: String? = nil,
        title: String,
        panelTitle: String,
        sectionCaption: String,
        systemImage: String,
        phase: String,
        parameters: [SliderParameter] = [],
        toggles: [PanelToggleDescriptor] = [],
        plannedParameters: [String] = [],
        needsFace: Bool = false,
        notifiesFromNodeNamed: String? = nil,
        gatedBy: PanelFeatureGate? = nil
    ) {
        self.notifiesFromNodeNamed = notifiesFromNodeNamed
        self.gatedBy = gatedBy
        self.toggles = toggles
        self.key = key
        self.storageKey = storageKey ?? key
        self.title = title
        self.panelTitle = panelTitle
        self.sectionCaption = sectionCaption
        self.systemImage = systemImage
        self.phase = phase
        self.parameters = parameters
        self.plannedNames = plannedParameters
        self.needsFace = needsFace
    }
}

/// A `RPEngineFeatureFlags` bit a slider group's effect depends on.
///
/// The mirror of ``RailPresentation/isAvailable`` for panels: the rail already
/// had one item ("Cọ mask") whose usability follows a process-global flag, and
/// this is the same idea for a group that *does* have sliders behind it. Read at
/// call time, never captured — the app sets the flags at launch
/// (`AppEngineSetup`) and a test flips them around a case, so the panel has to
/// answer the question *now*.
///
/// Three cases today. It is an enum rather than a `KeyPath` so that the reason
/// the flag is off travels with it: "chưa khả dụng" would be a lie about a
/// feature whose engine, kernel and numbers all shipped (docs/ADR-0020,
/// docs/ADR-0021, docs/ADR-0022).
public enum PanelFeatureGate: Hashable, Sendable {
    /// "Tạo khối" — docs/ADR-0020. The lobes, the kernel branch and the golden /
    /// selectivity / speed numbers are all merged and measured on a Mac; the
    /// flag stays off until there is an iPhone figure, which is the same bar
    /// "Khoá nền" is held to (docs/ADR-0018).
    case contourSliders

    /// "Sửa da" — docs/ADR-0021. The classifier, the union kernel, the subject
    /// intersection and the tone-ladder numbers are all merged; the flag stays
    /// off for the same iPhone reason as the other two, and here it is sharper:
    /// `VNGeneratePersonSegmentationRequest` has **no Simulator implementation
    /// at all**, so the ~35 ms/shot this feature spends (17 ms segmentation +
    /// 17.8 ms classifier at a 2048 px preview, macOS) has never been measured
    /// on an A-series chip.
    case bodySkinSync

    /// "Đầu" — docs/ADR-0022. The hair trace, the expanded ring, the MLS
    /// handles and the golden / round-trip / speed numbers are all merged and
    /// measured on a Mac and on the Simulator; the flag stays off for the same
    /// reason as the other two, the standing "no number from a real iPhone"
    /// blocker (docs/ADR-0018).
    case headSliders

    /// Whether this build has the effect switched on.
    public var isOn: Bool {
        switch self {
        case .contourSliders: RPEngineFeatureFlags.contourSliders
        case .bodySkinSync: RPEngineFeatureFlags.bodySkinSync
        case .headSliders: RPEngineFeatureFlags.headSliders
        }
    }

    /// The sentence the panel shows while ``isOn`` is `false` — same shape as
    /// every other ``GroupAvailability`` reason: one Vietnamese line stating a
    /// standing fact, no phase placeholder, nothing dismissible.
    public var offReason: String {
        switch self {
        case .contourSliders:
            "Tạo khối đang tắt trong bản dựng này — chưa đo tốc độ trên iPhone thật."
        case .bodySkinSync:
            "Sửa da đang tắt trong bản dựng này — chưa đo tốc độ trên iPhone thật."
        case .headSliders:
            "Đầu đang tắt trong bản dựng này — chưa đo tốc độ trên iPhone thật."
        }
    }
}

/// The slider taxonomy: **eleven panels over seven `EditState` namespaces**,
/// nine of the panels working.
///
/// It is data, not view code, for two reasons: the order and grouping is the
/// thing the render graph has to honour, and a test can assert that the panels
/// cover exactly `EditState.SectionKey.all` (``storageKeys``) — so adding a
/// namespace in RPCore without giving it a home in the UI fails a test instead
/// of silently disappearing.
///
/// **Eight, not six, since 2026-09-18**, from two splits made the same day for
/// the same reason — a rail entry that names one thing must open that thing and
/// nothing else:
///
/// * "Mắt" (3 sliders) / "Răng" (1) over `eyesTeeth`. The user reported the
///   shared "Mắt & Răng" panel as a functional error — a tap on "Răng" opened
///   three eye sliders — and the previous SPEC call that this was "intentional
///   and permanent" is reversed there.
/// * "Mịn da" (7 sliders) / "Kiềm dầu" (1, `shine`) over `skin`, after the user
///   reported the second instance of the same bug class: two rail entries with
///   the same `sparkles` icon opening the same unfiltered panel.
///
/// Both splits are **UI-only**: the namespaces, `SkinSliders` /
/// `EyesTeethSliders` and their render nodes all still handle their keys
/// together, so nothing on disk changed and no preset migrated.
///
/// **Nine since 2026-09-21**, for a different reason: "Tạo khối" is a third
/// panel over `EditState.SectionKey.face`, not a split of the second. Contour
/// and reshape are separate tools that happen to share a namespace because both
/// are per-face and measured in `faceWidth` (docs/ADR-0020 §5), and putting
/// three dodge/burn amounts at the bottom of the fifteen reshape sliders is the
/// same mistake "Răng opens an eye panel" was.
///
/// **Ten the same day**: "Sửa da" (docs/ADR-0021 §UI), the first panel whose
/// control is a switch rather than an amount and the first over
/// `EditState.SectionKey.mask`.
///
/// **Eleven, and the last of the Phase 6.2 queue**: "Đầu" (docs/ADR-0022 §UI),
/// one more panel over `face` — three amounts that warp the whole head by its
/// traced hair silhouette, which the 478-point mesh cannot express. It, "Sửa da"
/// and "Tạo khối" are the three panels with a
/// ``SliderSectionDescriptor/gatedBy`` flag, and it is the second to name a
/// render node (``SliderSectionDescriptor/notifiesFromNodeNamed``).
public enum SliderPanelLayout {
    /// Panel identities that are **not** an `EditState.SectionKey`, because two
    /// panels share one namespace. Every other panel's ``SliderSectionDescriptor/key``
    /// is its namespace.
    public enum PanelKey {
        /// "Mắt" — the three eye sliders of `EditState.SectionKey.eyesTeeth`.
        public static let eyes = "eyes"
        /// "Răng" — the one teeth slider of `EditState.SectionKey.eyesTeeth`.
        public static let teeth = "teeth"
        /// "Mịn da" — the seven non-shine sliders of `EditState.SectionKey.skin`.
        public static let smooth = "smooth"
        /// "Kiềm dầu" — the one `SkinSliders.Key.shine` slider of that namespace.
        public static let shine = "shine"
        /// "Tạo khối" — the three `ContourSliders.Key` amounts of
        /// `EditState.SectionKey.face` (docs/ADR-0020). The other panel over
        /// that namespace is "Hình dáng mặt", the fifteen reshape sliders, whose
        /// panel key is still the namespace itself.
        public static let contour = "contour"
        /// "Đầu" — the three `HeadSliders.Key` amounts of
        /// `EditState.SectionKey.face` (docs/ADR-0022). Same namespace as the
        /// reshape and contour panels, and for the same reason: the group is
        /// per-face and every magnitude it uses is a fraction of `faceWidth`, so
        /// a preset carries it between images unchanged.
        public static let head = "head"
        /// "Sửa da" — the one `BodySkinSync` switch of
        /// `EditState.SectionKey.mask` (docs/ADR-0021). The **only** panel with
        /// no slider in it, and the only one over the `mask` namespace, which
        /// RPCore keeps out of `EditState.SectionKey.all` precisely because it
        /// is not a set of sliders.
        public static let skinFix = "skinFix"
    }

    /// Which of `EyesTeethSliders.Key.all` belong to the "Răng" panel. Everything
    /// else in that list is an eye slider, derived rather than listed twice, so a
    /// fifth key added to the engine lands in a panel instead of vanishing
    /// (`SliderPanelLayoutTests.theEyesAndTeethPanelsCoverTheEngineList`).
    private static let teethKeys: Set<String> = [EyesTeethSliders.Key.teethWhiten]

    /// The same idea for `SkinSliders.Key.all`: "Kiềm dầu" is exactly `shine`,
    /// "Mịn da" is everything else, so a ninth skin key lands in "Mịn da" rather
    /// than falling out of the UI.
    private static let shineKeys: Set<String> = [SkinSliders.Key.shine]

    /// Labels and direction lines for `EditState.SectionKey.skin`, written once
    /// and read by both panels over it — the split is a filter on the engine's
    /// key list, not a second copy of the wording.
    private static let skinLabels: [String: (String, String)] = [
        SkinSliders.Key.smooth: ("Mịn da", "mịn hơn"),
        SkinSliders.Key.keepTexture: ("Giữ texture", "giữ lỗ chân lông (ở 100 triệt tiêu Mịn da)"),
        SkinSliders.Key.evenTone: ("Đều màu da", "đều màu hơn"),
        SkinSliders.Key.redness: ("Khử đỏ", "bớt đỏ"),
        SkinSliders.Key.shine: ("Khử bóng dầu", "bớt bóng"),
        SkinSliders.Key.brighten: ("Sáng da", "sáng hơn"),
        SkinSliders.Key.darkCircle: ("Quầng thâm", "sáng vùng thâm"),
        SkinSliders.Key.wrinkle: ("Nếp nhăn", "mờ nếp nhăn"),
    ]

    public static let sections: [SliderSectionDescriptor] = [
        // Two panels, one `skin` namespace (2026-09-18) — see the type's note.
        SliderSectionDescriptor(
            key: PanelKey.smooth,
            storageKey: EditState.SectionKey.skin,
            title: "Mịn da",
            panelTitle: "Làm mịn da",
            sectionCaption: "Da mặt",
            systemImage: "sparkles",
            phase: "Phase 2",
            parameters: Self.parameters(
                in: EditState.SectionKey.skin,
                keys: SkinSliders.Key.all.filter { !Self.shineKeys.contains($0) },
                labels: Self.skinLabels),
            needsFace: true
        ),
        // The icon is **not** `sparkles`: sharing it with "Mịn da" is half of
        // what the user reported (the rail said "Kiềm dầu" with the "Mịn da"
        // glyph and opened the "Mịn da" panel). `humidity` is the closest real
        // SF Symbol for oil/shine on the skin and is pinned by
        // `RailLayoutTests.everySymbolExists` on both platforms.
        SliderSectionDescriptor(
            key: PanelKey.shine,
            storageKey: EditState.SectionKey.skin,
            title: "Kiềm dầu",
            panelTitle: "Kiềm dầu",
            sectionCaption: "Vùng da bóng dầu",
            systemImage: "humidity",
            phase: "Phase 2",
            parameters: Self.parameters(
                in: EditState.SectionKey.skin,
                keys: SkinSliders.Key.all.filter { Self.shineKeys.contains($0) },
                labels: Self.skinLabels),
            needsFace: true
        ),
        // The third "Da" panel, and the only panel in the app with no slider in
        // it (2026-09-21, docs/ADR-0021 §UI). "Sửa da" is a *scope* switch for
        // the two panels above — the same eight slider values, applied to a
        // whole-body skin mask instead of the per-face one — so it owns no
        // amount of its own and docs/PLAN.md §6.2 fixed it as "một toggle".
        //
        // **Its own panel rather than a row inside "Mịn da" / "Kiềm dầu"**, for
        // a reason that is not layout: `notifiesFromNodeNamed` disables the
        // group it is attached to, and "Không phát hiện được da." must not
        // disable the seven face-smoothing sliders — those keep working on the
        // face exactly as before when the *body* classifier finds nothing. The
        // notice belongs on the control it is about, which is the toggle. (It is
        // also what the rail already says: "Sửa da" has been a leaf under "Da"
        // since the rail was written, described there as this group's own scope
        // switch.)
        //
        // `storageKey` is the `mask` namespace, next to "Khoá nền"'s boolean:
        // RPCore documents it as "where an effect is allowed to act … not a set
        // of sliders", which is this exactly.
        SliderSectionDescriptor(
            key: PanelKey.skinFix,
            storageKey: EditState.SectionKey.mask,
            title: "Sửa da",
            panelTitle: "Sửa da toàn thân",
            sectionCaption: "Phạm vi của nhóm Da",
            systemImage: "bandage",
            phase: "Phase 6",
            toggles: [
                PanelToggleDescriptor(
                    key: BodySkinSync.key,
                    label: "Đồng bộ da toàn thân",
                    // Both halves of the truth in one line: what it does, and
                    // that it depends on a detection which can fail. When it
                    // does fail, the panel says so on its own line
                    // (`notifiesFromNodeNamed`) — docs/ADR-0021 §UI.
                    detail:
                        "Áp 8 thanh trượt Da lên cả da cổ / vai / tay, không chỉ trong khuôn mặt. "
                        + "Cần nhận được vùng da ngoài mặt; với tông da rất đậm máy thường không "
                        + "nhận ra và sẽ báo ở đây.")
            ],
            needsFace: true,
            // `SkinRenderNode.detectionNotice(for:)`: "Không phát hiện được da."
            // when the whole-frame classifier came back at ~0 coverage. This is
            // the honest surface for docs/ADR-0021's unfixed gap — tone VI
            // always, tone IV on a cluttered frame — which is the condition the
            // reviewer ruling set for this toggle shipping at all: the failure
            // is visible instead of silent.
            notifiesFromNodeNamed: "skin",
            gatedBy: .bodySkinSync
        ),
        SliderSectionDescriptor(
            key: EditState.SectionKey.face,
            title: "Mặt",
            panelTitle: "Tạo hình khuôn mặt",
            sectionCaption: "Hình học · 478 điểm",
            systemImage: "face.smiling",
            phase: "Phase 2",
            parameters: Self.parameters(
                in: EditState.SectionKey.face,
                keys: FaceSliders.Key.all,
                labels: [
                    FaceSliders.Key.slim: ("Bóp mặt", "mặt thon lại"),
                    FaceSliders.Key.cheekbone: ("Gò má", "gò má hẹp lại"),
                    FaceSliders.Key.jaw: ("Hàm", "hàm hẹp lại"),
                    FaceSliders.Key.chin: ("Cằm", "cằm ngắn lại"),
                    FaceSliders.Key.forehead: ("Trán", "trán thấp lại"),
                    FaceSliders.Key.temple: ("Thái dương", "thái dương đầy ra"),
                    FaceSliders.Key.noseShrink: ("Cánh mũi", "mũi nhỏ lại"),
                    FaceSliders.Key.noseBridge: ("Sống mũi", "sống mũi thon lại"),
                    FaceSliders.Key.noseTip: ("Đầu mũi", "đầu mũi hếch lên"),
                    FaceSliders.Key.eyeSize: ("To mắt", "mắt to hơn"),
                    FaceSliders.Key.eyeSpacing: ("Khoảng cách mắt", "hai mắt xa nhau hơn"),
                    FaceSliders.Key.eyeTilt: ("Nghiêng mắt", "đuôi mắt nâng lên"),
                    FaceSliders.Key.mouthSize: ("Rộng miệng", "miệng rộng hơn"),
                    FaceSliders.Key.mouthSmile: ("Cười", "khoé miệng nâng lên"),
                    FaceSliders.Key.lipFullness: ("Môi đầy", "môi dày hơn"),
                ]),
            needsFace: true
        ),
        // The head group (2026-09-21, docs/ADR-0022 §UI), between the reshape
        // panel and the contour one because that is its slot in the rail. Three
        // amounts the fifteen reshape sliders cannot express: they move the
        // 478-point mesh, and the mesh stops at the face — moving it alone
        // slides a face around inside hair that stays where it was. This group's
        // extra control points come from the **traced hair silhouette**
        // (`HairBoundary`) plus the face oval expanded out to meet it, which is
        // why it is the one face-namespace panel that depends on a detection.
        //
        // The labels are ADR-0022 §2's own names for the three, and the
        // direction lines say what each one does *and* what it deliberately does
        // not touch — "Hẹp đầu" in particular is not "Bóp mặt" (jaw and below)
        // and not "Thái dương" (which pushes the temples out); it narrows the
        // cranium, where the mesh is one thin arc and the hair is everything.
        //
        // **Live drag, like every other group — a decision, not an oversight**
        // (user, 2026-09-21, recorded in docs/ADR-0022 §UI). ADR-0022 measured
        // the preview lattice's MLS round trip at **2.3 % of face width** for
        // this group against < 1 % for "Mặt", because round-trip error grows
        // with the displacement per lattice cell and a head edit moves an order
        // of magnitude further than a reshape slider. The export grid (129)
        // halves the cell and lands back at 0.8 %, so the *exported* picture is
        // as accurate as every other group's — what wobbles is the preview
        // during the drag, up to ~14 px on a 600 px face. The alternatives were
        // a denser preview lattice (a change to `RenderQuality.meshGrid`, which
        // "Mặt" shares and ADR-0007 fixed on its own measurement) or a
        // commit-on-release special case for these three rows. Both were
        // rejected in favour of shipping: no debounce, no deferred commit, no
        // per-group quality override — these sliders are wired exactly like the
        // fifteen next to them.
        SliderSectionDescriptor(
            key: PanelKey.head,
            storageKey: EditState.SectionKey.face,
            title: "Đầu",
            panelTitle: "Tạo hình khung đầu",
            sectionCaption: "Khung đầu · viền tóc",
            systemImage: "person.crop.circle",
            phase: "Phase 6",
            parameters: Self.parameters(
                in: EditState.SectionKey.face,
                keys: HeadSliders.Key.all,
                labels: [
                    HeadSliders.Key.size: (
                        "Thu nhỏ đầu", "cả đầu nhỏ lại — mặt, viền tóc cùng một tỉ lệ"
                    ),
                    HeadSliders.Key.width: (
                        "Hẹp đầu", "hộp sọ hẹp lại từ ngang mắt lên, không đụng hàm / má"
                    ),
                    HeadSliders.Key.volume: (
                        "Phồng tóc", "tóc phồng ra phía đỉnh đầu, khuôn mặt giữ nguyên"
                    ),
                ]),
            needsFace: true,
            // `WarpRenderNode.detectionNotice(for:)`: "Không phát hiện được viền
            // tóc." when no face in the frame has a traceable hairline — a hat,
            // a shaved head, a parsing miss (docs/ADR-0022 §"A subject in a hat").
            // In that state the group really does nothing, and ADR-0022 named
            // "decide what the UI says when there is no hair" as a condition of
            // this panel existing at all. This is that answer.
            //
            // The node is `"warp"`, which is *also* the reshape panel's node —
            // and the reshape panel deliberately does **not** name it. See
            // `SliderSectionDescriptor.notifiesFromNodeNamed`.
            notifiesFromNodeNamed: "warp",
            gatedBy: .headSliders
        ),
        // The third panel over `face` (2026-09-21, docs/ADR-0020): three
        // dodge/burn amounts, not three more reshape sliders. They share the
        // namespace because contour is per-face and every length it draws is a
        // fraction of `faceWidth` — the property that makes "Mặt" transferable
        // through a preset — but they are a different tool, so they get their
        // own panel rather than a fourth block at the bottom of the fifteen.
        //
        // The labels are the ADR's own names for the three regions. "Gò má" and
        // "Hàm" repeat the reshape panel's labels on purpose: the reshape
        // sliders *narrow* the cheekbone and the jaw, these two *shade* them, and
        // the two panels are what tells them apart (each panel header says which
        // one you are in). The direction lines say which of the two it is.
        //
        // `gatedBy` is what makes this panel honest while
        // `RPEngineFeatureFlags.contourSliders` is off: the rail opens it, the
        // three rows draw with their real keys and ranges, and the panel says
        // the build has the effect switched off instead of offering three
        // sliders that would write JSON no kernel reads.
        SliderSectionDescriptor(
            key: PanelKey.contour,
            storageKey: EditState.SectionKey.face,
            title: "Tạo khối",
            panelTitle: "Tạo khối",
            sectionCaption: "Khối sáng / tối theo mesh",
            systemImage: "circle.lefthalf.filled",
            phase: "Phase 6",
            parameters: Self.parameters(
                in: EditState.SectionKey.face,
                keys: ContourSliders.Key.all,
                labels: [
                    ContourSliders.Key.cheek: (
                        "Gò má", "sáng trên gò má, tối ở hõm má (không bóp mặt)"
                    ),
                    ContourSliders.Key.nose: ("Sống mũi", "sáng dọc sống mũi"),
                    ContourSliders.Key.jaw: ("Hàm", "tối dọc viền hàm"),
                ]),
            needsFace: true,
            gatedBy: .contourSliders
        ),
        // Two panels, one namespace (2026-09-18). "Mắt" keeps the three eye
        // sliders; "Răng" is the single Trắng răng. Both write into
        // `EditState.SectionKey.eyesTeeth` through `storageKey`, so the document
        // format, the engine's `EyesTeethSliders` and every saved preset are
        // exactly as they were.
        SliderSectionDescriptor(
            key: PanelKey.eyes,
            storageKey: EditState.SectionKey.eyesTeeth,
            title: "Mắt",
            panelTitle: "Chi tiết mắt",
            sectionCaption: "Vùng mắt",
            systemImage: "eye",
            phase: "Phase 2",
            parameters: Self.parameters(
                in: EditState.SectionKey.eyesTeeth,
                keys: EyesTeethSliders.Key.all.filter { !Self.teethKeys.contains($0) },
                labels: [
                    EyesTeethSliders.Key.eyeBrighten: ("Sáng mắt", "mắt sáng hơn"),
                    EyesTeethSliders.Key.scleraWhiten: ("Trắng lòng trắng", "lòng trắng trắng hơn"),
                    EyesTeethSliders.Key.eyeDefinition: ("Nét mắt", "tương phản cục bộ vùng mắt"),
                ]),
            needsFace: true
        ),
        // The icon is **not** `eye`: SF Symbols has no tooth glyph on macOS 15 /
        // iOS 18 (checked — `tooth`, `teeth` and `lips` do not resolve), and
        // reusing `eye` here is what made the rail say "Răng" and open an eye
        // panel. `mouth` is the closest real symbol and is also where the
        // whitening happens — `EyesTeethRenderNode` reads the mouth *interior*
        // mask, there is no teeth parsing class.
        SliderSectionDescriptor(
            key: PanelKey.teeth,
            storageKey: EditState.SectionKey.eyesTeeth,
            title: "Răng",
            panelTitle: "Làm trắng răng",
            sectionCaption: "Vùng răng",
            systemImage: "mouth",
            phase: "Phase 2",
            parameters: Self.parameters(
                in: EditState.SectionKey.eyesTeeth,
                keys: EyesTeethSliders.Key.all.filter { Self.teethKeys.contains($0) },
                labels: [
                    EyesTeethSliders.Key.teethWhiten: ("Trắng răng", "răng trắng hơn")
                ]),
            needsFace: true
        ),
        SliderSectionDescriptor(
            key: EditState.SectionKey.color,
            title: "Màu",
            panelTitle: "Màu & ánh sáng",
            sectionCaption: "Cơ bản",
            systemImage: "camera.filters",
            phase: "Phase 2",
            // 18 sliders for the plan's ten names: "WB" ships as two axes and
            // "HSL" as eight hue bands, the same way "Mũi" above ships as three.
            // See `RPEngine.ColorSliders` and docs/ADR-0012.
            //
            // The only **bidirectional** group (docs/ADR-0016): sixteen of the
            // eighteen span −100…100 with 0 in the middle of the track, so the
            // direction line names both ends. `Curves` and `Dodge & Burn tự
            // động` keep one end and say nothing about the other, because they
            // are still 0…100 — the range comes from RPCore, so the two cannot
            // drift apart.
            parameters: Self.parameters(
                in: EditState.SectionKey.color,
                keys: ColorSliders.Key.all,
                labels: [
                    ColorSliders.Key.exposure: ("Phơi sáng", "+ sáng hơn (+5 EV) · − tối hơn (−5 EV)"),
                    ColorSliders.Key.contrast: ("Tương phản", "+ tương phản mạnh · − phẳng lại"),
                    ColorSliders.Key.highlights: ("Vùng sáng", "+ kéo vùng sáng xuống · − đẩy lên"),
                    ColorSliders.Key.shadows: ("Vùng tối", "+ nâng vùng tối lên · − dìm xuống"),
                    ColorSliders.Key.wbTemperature: (
                        "Nhiệt độ", "+ ấm hơn (tới 50000K) · − lạnh hơn (tới 2000K)"
                    ),
                    ColorSliders.Key.wbTint: ("Sắc độ", "+ ngả magenta · − ngả lục"),
                    ColorSliders.Key.vibrance: ("Rực rỡ", "+ đậm · − nhạt, mạnh nhất ở màu nhạt"),
                    ColorSliders.Key.saturation: ("Bão hoà", "+ đậm đều · − nhạt đều (−100 = trắng đen)"),
                    ColorSliders.Key.curves: ("Curves", "đường cong film rõ hơn (chỉ một chiều)"),
                    ColorSliders.Key.autoDodgeBurn: (
                        "Dodge & Burn tự động", "đều sáng tối hơn (chỉ một chiều)"
                    ),
                ].merging(
                    Dictionary(
                        uniqueKeysWithValues: HueBand.allCases.map {
                            ($0.key, ("HSL · \($0.vietnameseName)", "+ đậm · − nhạt ở dải màu này"))
                        }
                    ), uniquingKeysWith: { a, _ in a })
            ),
            needsFace: false
        ),
        SliderSectionDescriptor(
            key: EditState.SectionKey.makeup,
            title: "Trang điểm",
            panelTitle: "Trang điểm",
            sectionCaption: "Phase 5 · chưa khả dụng",
            systemImage: "paintbrush.pointed",
            phase: "Phase 5",
            plannedParameters: [
                "Nền", "Má hồng", "Son môi", "Phấn mắt", "Kẻ mắt", "Lông mày",
            ],
            needsFace: true
        ),
        SliderSectionDescriptor(
            key: EditState.SectionKey.hair,
            title: "Tóc",
            panelTitle: "Tóc",
            sectionCaption: "Phase 5 · chưa khả dụng",
            systemImage: "comb",
            phase: "Phase 5",
            plannedParameters: ["Bóng tóc", "Tối / sáng", "Màu tóc", "Tóc con bay"],
            needsFace: true
        ),
    ]

    /// Builds the parameter list **in the engine's key order**, so the panel and
    /// `EditState` cannot disagree about what exists — and with each row's range
    /// read from RPCore, so it cannot disagree about what they accept either.
    private static func parameters(
        in section: String, keys: [String], labels: [String: (String, String)]
    ) -> [SliderParameter] {
        keys.map { key in
            let entry = labels[key] ?? (key, "")
            return SliderParameter(
                key: key, label: entry.0, direction: entry.1,
                range: Slider.range(for: key, in: section))
        }
    }

    /// Total number of sliders the panel carries or plans.
    public static var plannedParameterCount: Int {
        sections.reduce(0) { $0 + $1.plannedParameters.count }
    }

    /// Sliders that actually work today.
    public static var workingParameterCount: Int {
        sections.reduce(0) { $0 + $1.parameters.count }
    }

    /// Looks a **panel** up by its own key — `"eyes"`, `"teeth"`, `"smooth"`, …
    ///
    /// Not a namespace lookup: `section(forKey: EditState.SectionKey.eyesTeeth)`
    /// and `section(forKey: EditState.SectionKey.skin)` are both `nil` on purpose
    /// since the 2026-09-18 splits, because those namespaces have two panels each
    /// and picking one of them silently would be a guess. Ask
    /// ``sections(forStorageKey:)`` when you mean the namespace.
    public static func section(forKey key: String) -> SliderSectionDescriptor? {
        sections.first { $0.key == key }
    }

    /// Every panel over one `EditState.SectionKey`, in panel order. One entry for
    /// every namespace except `skin` and `eyesTeeth`, which have two each.
    public static func sections(forStorageKey key: String) -> [SliderSectionDescriptor] {
        sections.filter { $0.storageKey == key }
    }

    /// The namespaces the panel covers, in panel order and without repeats.
    ///
    /// `SliderPanelLayoutTests` pins the **slider** namespaces among these to
    /// `EditState.SectionKey.all`, in that order — the invariant the 2026-09-18
    /// splits had to keep, and it is "every declared namespace has a panel", not
    /// "one panel per namespace". Since 2026-09-21 this list carries one more
    /// entry than `all` does: `EditState.SectionKey.mask` ("Sửa da"), which
    /// RPCore deliberately keeps out of `all` because it holds switches rather
    /// than sliders and several callers read `all` as "every slider group".
    public static var storageKeys: [String] {
        sections.reduce(into: [String]()) { keys, section in
            if !keys.contains(section.storageKey) { keys.append(section.storageKey) }
        }
    }

    /// The panels a stored document actually touches, in panel order.
    ///
    /// Filtered **by parameter**, not by namespace, so a preset carrying only
    /// `teethWhiten` summarises as "Răng" and not as "Mắt · Răng". A locked group
    /// has no parameters to match, so it falls back to "the namespace is
    /// non-empty" — the behaviour this replaced.
    public static func sections(touchedBy stored: [String: EditSection])
        -> [SliderSectionDescriptor]
    {
        sections.filter { section in
            guard let values = stored[section.storageKey], !values.isEmpty else { return false }
            guard !section.isLocked else { return true }
            return section.parameters.contains { values.values[$0.key] != nil }
                || section.toggles.contains { values.values[$0.key] != nil }
        }
    }

    /// The group a freshly opened editor starts on: the first working one
    /// ("Mịn da" since the skin split — the same sliders the old "Da" panel
    /// opened on, minus Khử bóng dầu).
    public static var defaultSectionKey: String {
        sections.first { !$0.isLocked }?.key ?? PanelKey.smooth
    }
}

extension HueBand {
    /// Display name for the eight HSL bands, matching the mockup's
    /// "HSL · Đỏ/Cam/Vàng/Lục/Lam/Lơ/Tím/Hồng".
    var vietnameseName: String {
        switch self {
        case .red: "Đỏ"
        case .orange: "Cam"
        case .yellow: "Vàng"
        case .green: "Lục"
        case .aqua: "Lơ"
        case .blue: "Lam"
        case .purple: "Tím"
        case .magenta: "Hồng"
        }
    }

    /// Kept for anything English-facing (logs, tests).
    var name: String {
        switch self {
        case .red: "red"
        case .orange: "orange"
        case .yellow: "yellow"
        case .green: "green"
        case .aqua: "aqua"
        case .blue: "blue"
        case .purple: "purple"
        case .magenta: "magenta"
        }
    }
}

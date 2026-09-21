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

/// One group: a tab on the phone, a rail icon and a panel on the Mac.
public struct SliderSectionDescriptor: Identifiable, Hashable, Sendable {
    /// **The panel's own identity** — what `EditorChrome.activeGroupKey` holds,
    /// what a rail item's `sectionKey` points at, and what
    /// ``SliderPanelLayout/section(forKey:)`` looks up.
    ///
    /// Usually the same string as ``storageKey``, and for four of the eight
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
    /// (Trang điểm and Tóc are Phase 5).
    public let parameters: [SliderParameter]
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
    public let notifiesFromNodeNamed: String?

    public var id: String { key }

    /// `true` for the Phase 5 groups. They are drawn dimmed and inert rather
    /// than hidden, so the shell shows the full future taxonomy
    /// (docs/design/SPEC.md cross-cutting rule 4).
    public var isLocked: Bool { parameters.isEmpty }

    /// Labels only, kept because the Phase 1 panel and its tests are written
    /// against it and because the Phase 5 groups still have nothing else.
    public var plannedParameters: [String] {
        parameters.isEmpty ? plannedNames : parameters.map(\.label)
    }
    private let plannedNames: [String]

    /// How many of **this panel's own** sliders the document has moved off 0.
    ///
    /// Not `state[section: storageKey].values.count`: two panels can share a
    /// namespace, and "Răng" must not claim the eye sliders' dot.
    public func activeParameterCount(in state: EditState) -> Int {
        let values = state[section: storageKey]
        return parameters.reduce(into: 0) { count, parameter in
            if values.slider(parameter.key) != Slider.defaultValue { count += 1 }
        }
    }

    /// `true` when this panel has nothing of its own to reset.
    ///
    /// A locked group has no parameters to count, so it falls back to "is the
    /// namespace empty" — the check this replaced, and the only one available
    /// for a group whose sliders do not exist yet.
    public func isNeutral(in state: EditState) -> Bool {
        parameters.isEmpty
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
        plannedParameters: [String] = [],
        needsFace: Bool = false,
        notifiesFromNodeNamed: String? = nil
    ) {
        self.notifiesFromNodeNamed = notifiesFromNodeNamed
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

/// The slider taxonomy: **eight panels over six `EditState` namespaces**, six
/// of the panels working.
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
                    ColorSliders.Key.exposure: ("Phơi sáng", "+ sáng hơn (+1 EV) · − tối hơn (−1 EV)"),
                    ColorSliders.Key.contrast: ("Tương phản", "+ tương phản mạnh · − phẳng lại"),
                    ColorSliders.Key.highlights: ("Vùng sáng", "+ kéo vùng sáng xuống · − đẩy lên"),
                    ColorSliders.Key.shadows: ("Vùng tối", "+ nâng vùng tối lên · − dìm xuống"),
                    ColorSliders.Key.wbTemperature: ("Nhiệt độ", "+ ấm hơn · − lạnh hơn"),
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
    /// `SliderPanelLayoutTests` pins this to `EditState.SectionKey.all` — that is
    /// the invariant the split had to keep, not "one panel per namespace".
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
            guard !section.parameters.isEmpty else { return true }
            return section.parameters.contains { values.values[$0.key] != nil }
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

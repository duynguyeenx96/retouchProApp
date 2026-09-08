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
    /// one-directional (Da / Mặt / Mắt & Răng, docs/ADR-0010) or signed (Màu,
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
    /// The `EditState.SectionKey` namespace this group writes into.
    public let key: String
    /// Short tab label — "Da", "Mặt", "Mắt & Răng", "Màu", "Trang điểm", "Tóc".
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

    public init(
        key: String,
        title: String,
        panelTitle: String,
        sectionCaption: String,
        systemImage: String,
        phase: String,
        parameters: [SliderParameter] = [],
        plannedParameters: [String] = [],
        needsFace: Bool = false
    ) {
        self.key = key
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

/// The slider taxonomy: six groups, four of them working.
///
/// It is data, not view code, for two reasons: the order and grouping is the
/// thing the render graph has to honour, and a test can assert that the panel
/// covers exactly `EditState.SectionKey.all` — so adding a namespace in RPCore
/// without giving it a home in the UI fails a test instead of silently
/// disappearing.
public enum SliderPanelLayout {
    public static let sections: [SliderSectionDescriptor] = [
        SliderSectionDescriptor(
            key: EditState.SectionKey.skin,
            title: "Da",
            panelTitle: "Làm mịn da",
            sectionCaption: "Da mặt",
            systemImage: "sparkles",
            phase: "Phase 2",
            parameters: Self.parameters(
                in: EditState.SectionKey.skin,
                keys: SkinSliders.Key.all,
                labels: [
                    SkinSliders.Key.smooth: ("Mịn da", "mịn hơn"),
                    SkinSliders.Key.keepTexture: ("Giữ texture", "giữ lỗ chân lông (ở 100 triệt tiêu Mịn da)"),
                    SkinSliders.Key.evenTone: ("Đều màu da", "đều màu hơn"),
                    SkinSliders.Key.redness: ("Khử đỏ", "bớt đỏ"),
                    SkinSliders.Key.shine: ("Khử bóng dầu", "bớt bóng"),
                    SkinSliders.Key.brighten: ("Sáng da", "sáng hơn"),
                    SkinSliders.Key.darkCircle: ("Quầng thâm", "sáng vùng thâm"),
                    SkinSliders.Key.wrinkle: ("Nếp nhăn", "mờ nếp nhăn"),
                ]),
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
        SliderSectionDescriptor(
            key: EditState.SectionKey.eyesTeeth,
            title: "Mắt & Răng",
            panelTitle: "Mắt và răng",
            sectionCaption: "Chi tiết",
            systemImage: "eye",
            phase: "Phase 2",
            parameters: Self.parameters(
                in: EditState.SectionKey.eyesTeeth,
                keys: EyesTeethSliders.Key.all,
                labels: [
                    EyesTeethSliders.Key.eyeBrighten: ("Sáng mắt", "mắt sáng hơn"),
                    EyesTeethSliders.Key.scleraWhiten: ("Trắng lòng trắng", "lòng trắng trắng hơn"),
                    EyesTeethSliders.Key.eyeDefinition: ("Nét mắt", "tương phản cục bộ vùng mắt"),
                    EyesTeethSliders.Key.teethWhiten: ("Trắng răng", "răng trắng hơn"),
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

    public static func section(forKey key: String) -> SliderSectionDescriptor? {
        sections.first { $0.key == key }
    }

    /// The group a freshly opened editor starts on: the first working one.
    public static var defaultSectionKey: String {
        sections.first { !$0.isLocked }?.key ?? EditState.SectionKey.skin
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

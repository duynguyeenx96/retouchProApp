import RPCore
import SwiftUI

/// The "Tự động" panel (docs/PLAN.md §6.5) — takes over the slider panel slot
/// on the Mac (``SliderPanelView``) and the tool sheet's slot on the phone
/// (`PhoneEditorView`), the way ``PresetLibraryView`` does.
///
/// Four read-only recipe rows (what each slider is set to at the current
/// strength), "Áp dụng" (the recipe at 100 %, one undo step), the "Cường độ
/// tổng" slider (drag previews, release writes one undo step) and, when the
/// filmstrip has more than one photo selected, "Áp cho N ảnh đã chọn". The
/// view holds no state of its own beyond a status line: the strength is read
/// back off the document (``EditorModel/autoRetouchStrength``).
struct AutoRetouchView: View {
    @Bindable var model: EditorModel
    var thumbSize: CGFloat = RPTheme.Metrics.macSliderThumb
    let dismiss: () -> Void

    @State private var status: String?

    private var isPhone: Bool { thumbSize > RPTheme.Metrics.macSliderThumb }
    private var strength: Double { model.autoRetouchStrength }
    private var hasShot: Bool { model.activeShot != nil }
    private var batchCount: Int { model.autoRetouchBatchTargetIDs.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(RPTheme.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Công thức v1 · Da + Màu + Mắt nhẹ, không đụng nhóm Mặt")
                        .font(RPTheme.text(11.5))
                        .foregroundStyle(RPTheme.textTertiary)
                    recipeRows
                    RPPrimaryButton(title: "Áp dụng tự động", fillsWidth: true, isEnabled: hasShot) {
                        status = nil
                        Task { await model.applyAutoRetouch() }
                    }
                    .accessibilityHint("Áp công thức ở cường độ 100, một bước hoàn tác")

                    RPSliderRow(
                        label: "Cường độ tổng",
                        direction: "cả bốn thanh trượt của công thức mạnh lên theo cùng tỉ lệ",
                        value: strength,
                        range: Slider.range,
                        thumbSize: thumbSize,
                        isEnabled: hasShot,
                        onChange: { model.previewAutoRetouchStrength($0) },
                        onCommit: { Task { await model.commitAutoRetouchStrength() } })

                    if hasShot, !model.isAutoRetouchExact {
                        Text("Đã chỉnh tay sau khi áp — kéo Cường độ tổng sẽ đưa cả bốn về công thức.")
                            .font(RPTheme.text(11.5))
                            .foregroundStyle(RPTheme.textTertiary)
                    }

                    if batchCount > 1 {
                        RPSecondaryButton(
                            title: "Áp cho \(batchCount) ảnh đã chọn",
                            isEnabled: !model.isPastingSettings
                        ) {
                            let ids = model.autoRetouchBatchTargetIDs
                            // Full strength unless the open photo's slider says
                            // otherwise — 0 would just clear the four keys.
                            let value = strength > 0 ? strength : 100
                            Task {
                                let written = await model.applyAutoRetouch(
                                    toShots: ids, strength: value)
                                status = written == 0
                                    ? "Không có ảnh nào thay đổi."
                                    : "Đã áp Tự động (\(Int(value.rounded()))) cho \(written) ảnh."
                            }
                        }
                    }

                    if let status {
                        Text(status)
                            .font(RPTheme.text(11.5))
                            .foregroundStyle(RPTheme.textSecondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollIndicators(isPhone ? .hidden : .visible)
        }
        .background(RPTheme.chrome)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 15))
                .foregroundStyle(RPTheme.accent)
            Text("Tự động")
                .font(RPTheme.text(14, weight: .semibold))
                .foregroundStyle(RPTheme.textPrimary)
            Spacer()
            Button(action: dismiss) {
                HStack(spacing: 5) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    Text("Đóng").font(RPTheme.text(12))
                }
                .foregroundStyle(RPTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RPTheme.fillNeutralSoft, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Đóng Tự động")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// One line per recipe ingredient: the slider's own label and panel, and
    /// the value it has on this photo right now (so a hand edit shows).
    private var recipeRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(AutoRetouch.recipe, id: \.self) { ingredient in
                let (label, panel) = Self.names(for: ingredient)
                HStack(alignment: .firstTextBaseline) {
                    Text(label)
                        .font(RPTheme.text(12.5))
                        .foregroundStyle(RPTheme.textLabel)
                    Text(panel)
                        .font(RPTheme.text(11))
                        .foregroundStyle(RPTheme.textTertiary)
                    Spacer(minLength: 8)
                    Text(
                        "\(Int(model.slider(ingredient.key, in: ingredient.section).rounded())) / \(Int(ingredient.value))"
                    )
                    .font(RPTheme.mono(11.5))
                    .foregroundStyle(RPTheme.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// The slider's label and the title of the panel it lives in, read from
    /// ``SliderPanelLayout`` so the recipe cannot name a slider differently
    /// from the panel the user would fine-tune it in.
    static func names(for ingredient: AutoRetouch.Ingredient) -> (String, String) {
        for section in SliderPanelLayout.sections(forStorageKey: ingredient.section) {
            if let parameter = section.parameters.first(where: { $0.key == ingredient.key }) {
                return (parameter.label, section.title)
            }
        }
        return (ingredient.key, ingredient.section)
    }
}

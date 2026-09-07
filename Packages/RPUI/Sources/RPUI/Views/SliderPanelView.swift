import RPCore
import RPEngine
import SwiftUI

/// **Screen 1b's right panel** — 326 pt, `#141518`: a header carrying the active
/// group's icon, title and "Đặt lại"; the group's slider list; and a footer with
/// the disabled "Lưu preset · Phase 3" chip and the "Đồng bộ" toggle.
///
/// It shows **one** group at a time — whichever the far-right rail
/// (``GroupIconRail``) has selected — rather than six collapsible sections. That
/// is the mockup, and it is also what makes the rail mean something.
struct SliderPanelView: View {
    @Bindable var model: EditorModel
    /// The chrome the rail and this panel share. Defaulted so the smoke tests
    /// (and SwiftUI previews) can build the panel on its own.
    var chrome: EditorChrome = EditorChrome()

    private var section: SliderSectionDescriptor { chrome.activeSection }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(RPTheme.hairline)
            ScrollView {
                GroupSliderList(
                    model: model, section: section,
                    thumbSize: RPTheme.Metrics.macSliderThumb, showsCaption: true
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.visible)
            Divider().overlay(RPTheme.hairline)
            footer
        }
        .frame(maxHeight: .infinity)
        .background(RPTheme.chrome)
        .overlay(alignment: .leading) { Rectangle().fill(RPTheme.hairline).frame(width: 1) }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 15))
                    .foregroundStyle(RPTheme.accent)
                Text(section.panelTitle)
                    .font(RPTheme.text(14, weight: .semibold))
                    .foregroundStyle(RPTheme.textPrimary)
            }
            Spacer()
            Button {
                model.resetSection(section.key)
            } label: {
                Text("Đặt lại")
                    .font(RPTheme.text(12))
                    .foregroundStyle(RPTheme.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RPTheme.fillNeutralSoft, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(model.activeEditState[section: section.key].isEmpty)
            .opacity(model.activeEditState[section: section.key].isEmpty ? 0.5 : 1)
            .help("Đưa mọi thanh trượt của nhóm này về 0")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Lưu preset · Phase 3")
                .font(RPTheme.text(12.5))
                .foregroundStyle(RPTheme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(RPTheme.fillFaint, in: RoundedRectangle(cornerRadius: 8))
                .help("Lưu và áp preset là docs/PLAN.md Phase 3")

            Button {
                model.setSyncingAllFaces(!model.isSyncingAllFaces)
            } label: {
                Text("Đồng bộ")
                    .font(RPTheme.text(12.5, weight: .medium))
                    .foregroundStyle(
                        model.isSyncingAllFaces ? RPTheme.accent : RPTheme.textSecondary
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        model.isSyncingAllFaces ? RPTheme.accentSoft : Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(model.detectedFaceCount < 2)
            .opacity(model.detectedFaceCount < 2 ? 0.5 : 1)
            .help(
                model.detectedFaceCount < 2
                    ? "Chỉ có tác dụng khi ảnh có nhiều khuôn mặt"
                    : "Áp chỉnh sửa cho mọi khuôn mặt thay vì một khuôn mặt đã chọn")
            .accessibilityAddTraits(model.isSyncingAllFaces ? [.isButton, .isSelected] : .isButton)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

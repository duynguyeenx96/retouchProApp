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
    /// Owns the two preset stores; shared with the rest of the editor so the
    /// library is not silently re-read from disk every time this panel swaps
    /// content in. Defaulted for the same reason `chrome` is.
    var library: PresetLibraryModel = PresetLibraryModel()

    private var section: SliderSectionDescriptor { chrome.activeSection }

    var body: some View {
        Group {
            // The preset library used to be a floating dialog over the canvas
            // (`MacPresetLibraryDialog`); since 2026-09-22 it takes over this
            // same panel slot instead, the way every slider group already does
            // — a user asked for "ở vị trí side panel tương tự các chức năng
            // khác" (see `PresetLibraryView`'s own doc comment for why that
            // also fixed the hover preview). `chrome.presetLibrary` still
            // carries a `PresetLibraryKind` (the rail always asks for
            // `.templates`; `RailPresentation` still needs a value there),
            // but the view itself has no more kind to ask for — only whether
            // the panel is open at all (also 2026-09-22, dropping the
            // "Mẫu"/"Looks" split the kind used to pick between).
            if chrome.presetLibrary != nil {
                PresetLibraryView(
                    model: model, library: library,
                    dismiss: { chrome.presetLibrary = nil })
            } else {
                slidersPanel
            }
        }
        .frame(maxHeight: .infinity)
        .background(RPTheme.chrome)
        .overlay(alignment: .leading) { Rectangle().fill(RPTheme.hairline).frame(width: 1) }
    }

    private var slidersPanel: some View {
        VStack(spacing: 0) {
            // The brush is a **mode**, not a seventh group, so it borrows the
            // panel rather than adding one: the user keeps the slider group they
            // were on underneath and "Xong" puts them straight back on it
            // (docs/PLAN.md §6.1, docs/ADR-0019).
            if chrome.isBrushing {
                ManualMaskBrushHeader(model: model, chrome: chrome)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 12)
            } else {
                header
            }
            Divider().overlay(RPTheme.hairline)
            // The second level (2026-09-18): the sub-features of the body part
            // the open panel belongs to, between the panel header and its
            // sliders. Absent for a top-level leaf's panel (Trang điểm, Tóc,
            // Màu), so those panels look exactly as they did.
            if let parent = chrome.activeRailParent {
                RailChildStrip(chrome: chrome, parent: parent) { section in
                    section.activeParameterCount(in: model.activeEditState)
                }
                Divider().overlay(RPTheme.hairline)
            }
            ScrollView {
                if chrome.isBrushing {
                    ManualMaskBrushBar(model: model, chrome: chrome)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                } else {
                    GroupSliderList(
                        model: model, section: section,
                        thumbSize: RPTheme.Metrics.macSliderThumb, showsCaption: true
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
            .scrollIndicators(.visible)
            Divider().overlay(RPTheme.hairline)
            footer
        }
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
                // The panel, not its namespace: "Đặt lại" on Răng must not clear
                // the three eye sliders it shares `eyesTeeth` with.
                model.resetSection(section)
            } label: {
                Text("Đặt lại")
                    .font(RPTheme.text(12))
                    .foregroundStyle(RPTheme.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RPTheme.fillNeutralSoft, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(section.isNeutral(in: model.activeEditState))
            .opacity(section.isNeutral(in: model.activeEditState) ? 0.5 : 1)
            .help("Đưa mọi thanh trượt của nhóm này về 0")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // Phase 3 landed, so the chip is a real button now: it opens the
            // same preset library the rail's "Preset" item opens
            // (``PresetLibraryView``), where saving the current look lives.
            // Clears the brush the same way `EditorChrome.selectRailItem`
            // does — this is a second door into the same panel slot, and the
            // two must agree on "exactly one thing is ever open".
            Button {
                chrome.isBrushing = false
                chrome.presetLibrary = .templates
            } label: {
                Text("Lưu preset")
                    .font(RPTheme.text(12.5))
                    .foregroundStyle(RPTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RPTheme.fillFaint, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Mở thư viện preset để lưu hoặc áp một preset")

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

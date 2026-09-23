import RPCore
import RPEngine
import SwiftUI

/// The brush's controls: add / erase, three 0–100 rows, undo · làm lại · xoá
/// (docs/PLAN.md §6.1 "Cọ mask thủ công", docs/ADR-0019).
///
/// It stands **in place of the slider list** in both shells — the phone's tool
/// sheet and the Mac's right panel — rather than as a floating palette over the
/// picture. Two reasons, both about the canvas: the brush needs every pixel of
/// the photo it can get (a palette would sit on exactly the region the user is
/// painting), and the mask is only useful while some slider group is turned up,
/// so the user is going to move between this and the panel constantly. Sharing
/// the panel's slot keeps that one tap.
///
/// It reuses `RPSliderRow` unchanged, which is why ``ManualMaskBrushSettings``
/// is 0–100 in the first place: a brush control that looked different from every
/// other control in the app would be new UI, and this phase has none to spare.
///
/// **No detection notice.** Unlike Da or Mặt this feature detects nothing — it
/// is user input — so `SliderSectionDescriptor.notifiesFromNodeNamed` has no
/// entry for it and there is no "Không phát hiện được …" line to show. What it
/// *does* say is when there is nothing to paint on (no picture open, or the
/// GPU path is down), because that is a fact about the canvas rather than about
/// a detector.
struct ManualMaskBrushBar: View {
    @Bindable var model: EditorModel
    @Bindable var chrome: EditorChrome
    var thumbSize: CGFloat = RPTheme.Metrics.macSliderThumb

    private var live: LivePreviewController? { model.live }
    private var canPaint: Bool { live?.canPaintManualMask ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            modeRow
            if !canPaint {
                Label(unavailableReason, systemImage: "info.circle")
                    .font(RPTheme.text(11))
                    .foregroundStyle(RPTheme.textTertiary)
                    .padding(.vertical, 8)
            } else {
                Text(hint)
                    .font(RPTheme.text(11))
                    .foregroundStyle(RPTheme.textTertiary)
                    .padding(.vertical, 8)
            }

            RPSliderRow(
                label: "Kích thước · \(chrome.brush.radiusText)",
                direction: "cỡ cọ tính bằng điểm ảnh của ảnh, không đổi theo mức phóng",
                value: chrome.brush.size, thumbSize: thumbSize, isEnabled: canPaint,
                onChange: { chrome.brush.size = $0 })
            RPSliderRow(
                label: "Độ cứng",
                direction: "viền cọ sắc nét",
                value: chrome.brush.hardness, thumbSize: thumbSize, isEnabled: canPaint,
                onChange: { chrome.brush.hardness = $0 })
            RPSliderRow(
                label: "Độ đậm",
                direction: "vùng chọn đặc hoàn toàn",
                value: chrome.brush.flow, thumbSize: thumbSize, isEnabled: canPaint,
                onChange: { chrome.brush.flow = $0 })

            historyRow
            effectRow
            layerList
        }
    }

    /// The sliders of whichever group is open underneath the brush — the same
    /// ``GroupSliderList`` the panel shows once the brush is put away, right
    /// here instead, so the mask and the effect it gates can be tuned in one
    /// pass instead of a "paint, tap Xong, drag, arm the brush again" loop.
    ///
    /// Painting the mask's tint is not drawn while a row here is dragged — the
    /// canvas already stops drawing it the instant a stroke ends (see
    /// ``layerList``), so there is nothing left to turn off here.
    private var effectRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(RPTheme.hairline).padding(.vertical, 4)
            Text("Cường độ — \(chrome.activeSection.panelTitle)")
                .font(RPTheme.text(11, weight: .medium))
                .foregroundStyle(RPTheme.textTertiary)
                .padding(.top, 4)
                .padding(.bottom, 2)
            GroupSliderList(model: model, section: chrome.activeSection, thumbSize: thumbSize)
        }
    }

    /// One row per finished stroke, oldest first (user's request, 2026-09-21:
    /// "giống Lightroom"). The green tint only comes back on screen for the one
    /// row the user is hovering (Mac) or has tapped (phone) —
    /// ``EditorChrome/previewedMaskStrokeIndex`` says why at length — so this is
    /// also the only way to see a past stroke's extent again once painting it
    /// has ended.
    ///
    /// A stroke, not a paint-then-adjust cycle, is the unit: the session already
    /// tracks strokes individually for undo/redo, so a second grouping concept
    /// on top would be state with nothing behind it to keep in sync.
    @ViewBuilder
    private var layerList: some View {
        let strokes = live?.manualMaskStrokes ?? []
        if !strokes.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Divider().overlay(RPTheme.hairline).padding(.vertical, 4)
                Text("Các nét đã vẽ")
                    .font(RPTheme.text(11, weight: .medium))
                    .foregroundStyle(RPTheme.textTertiary)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
                VStack(spacing: 4) {
                    ForEach(Array(strokes.enumerated()), id: \.offset) { index, stroke in
                        layerRow(index: index, stroke: stroke)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func layerRow(index: Int, stroke: BrushStroke) -> some View {
        let isPreviewed = chrome.previewedMaskStrokeIndex == index
        return HStack(spacing: 8) {
            Image(systemName: stroke.mode == .add ? "paintbrush.fill" : "eraser")
                .font(.system(size: 11))
                .foregroundStyle(isPreviewed ? RPTheme.accent : RPTheme.textSecondary)
                .frame(width: 16)
            Text(stroke.mode == .add ? "Nét \(index + 1) · vẽ" : "Nét \(index + 1) · xoá")
                .font(RPTheme.text(12))
                .foregroundStyle(isPreviewed ? RPTheme.accent : RPTheme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            isPreviewed ? RPTheme.accentSoft : Color.white.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        #if os(macOS)
            .onHover { hovering in
                chrome.previewedMaskStrokeIndex = hovering ? index : nil
            }
        #else
            .onTapGesture {
                chrome.previewedMaskStrokeIndex = isPreviewed ? nil : index
            }
        #endif
        .help("Di chuột vào để xem vùng nét này ảnh hưởng")
        .accessibilityLabel(stroke.mode == .add ? "Nét \(index + 1), vẽ" : "Nét \(index + 1), xoá")
        .accessibilityAddTraits(isPreviewed ? [.isButton, .isSelected] : .isButton)
    }

    /// Why the canvas cannot be painted on right now — a canvas fact, not a
    /// detection failure.
    private var unavailableReason: String {
        if model.activeShot == nil { return "Chọn một ảnh để vẽ mask." }
        if live == nil || live?.isReady == false {
            return "Không có preview GPU nên chưa vẽ được mask."
        }
        return "Cọ mask đang tắt trong bản dựng này."
    }

    private var hint: String {
        chrome.brush.isErasing
            ? "Kéo trên ảnh để xoá bớt vùng mask."
            : "Kéo trên ảnh để vẽ vùng cho các thanh trượt ăn vào."
    }

    // MARK: - Rows

    private var modeRow: some View {
        HStack(spacing: 8) {
            ForEach(BrushMode.allCases, id: \.self) { mode in
                Button {
                    chrome.brush.mode = mode
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode == .add ? "paintbrush.fill" : "eraser")
                            .font(.system(size: 11))
                        Text(mode == .add ? "Vẽ" : "Xoá")
                            .font(RPTheme.text(12.5, weight: .medium))
                    }
                    .foregroundStyle(
                        chrome.brush.mode == mode ? RPTheme.accent : RPTheme.textSecondary
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        chrome.brush.mode == mode
                            ? RPTheme.accentSoft : Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!canPaint)
                .accessibilityLabel(mode == .add ? "Cọ vẽ mask" : "Cọ xoá mask")
                .accessibilityAddTraits(
                    chrome.brush.mode == mode ? [.isButton, .isSelected] : .isButton)
            }
        }
        .opacity(canPaint ? 1 : RPTheme.lockedOpacity)
        .padding(.top, 12)
    }

    /// "Hoàn tác" / "Làm lại" here are the **shot's** undo and redo — the same
    /// one timeline as the toolbar's buttons and ⌘Z (docs/ADR-0025), so a
    /// slider moved from the list below undoes from here too, in the order it
    /// happened. "Xoá mask" is one undoable step.
    private var historyRow: some View {
        HStack(spacing: 8) {
            historyButton(
                title: "Hoàn tác", systemImage: "arrow.uturn.backward",
                isEnabled: model.canUndo
            ) {
                Task { await model.undo() }
            }
            historyButton(
                title: "Làm lại", systemImage: "arrow.uturn.forward",
                isEnabled: model.canRedo
            ) {
                Task { await model.redo() }
            }
            historyButton(
                title: "Xoá mask", systemImage: "trash",
                isEnabled: !model.activeStrokes.isEmpty
            ) {
                model.clearBrushStrokes()
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func historyButton(
        title: String, systemImage: String, isEnabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 13))
                Text(title).font(RPTheme.text(10.5))
            }
            .foregroundStyle(RPTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RPTheme.fillFaint, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(title)
    }
}

/// The brush's header, shown where each shell puts a panel title: the full
/// Vietnamese name the rail chip had no room for, the stroke count, and the way
/// out of the mode.
struct ManualMaskBrushHeader: View {
    @Bindable var model: EditorModel
    @Bindable var chrome: EditorChrome

    var body: some View {
        HStack {
            HStack(spacing: 9) {
                Image(systemName: "paintbrush")
                    .font(.system(size: 15))
                    .foregroundStyle(RPTheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cọ mask thủ công")
                        .font(RPTheme.text(14, weight: .semibold))
                        .foregroundStyle(RPTheme.textPrimary)
                    Text(strokeCountText)
                        .font(RPTheme.text(10.5))
                        .foregroundStyle(RPTheme.textTertiary)
                }
            }
            Spacer()
            Button {
                chrome.disarmBrush()
            } label: {
                Text("Xong")
                    .font(RPTheme.text(12))
                    .foregroundStyle(RPTheme.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RPTheme.fillNeutralSoft, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Cất cọ và quay lại thanh trượt")
            .accessibilityLabel("Xong, cất cọ mask")
        }
    }

    private var strokeCountText: String {
        // The document's count: a reopened shot has its strokes back
        // (docs/ADR-0025), so there is no "saved mask without strokes" state.
        let count = model.activeStrokes.count
        return count > 0 ? "\(count) nét" : "chưa có nét nào"
    }
}

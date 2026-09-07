import RPCore
import RPEngine
import SwiftUI

/// The slider list of **one** group — the body of the phone's tool sheet and of
/// the Mac's right-hand panel.
///
/// Both screens show the same thing (label + mono value + flat mint track) at
/// two thumb sizes, so it is one view. What it enforces, all of it decided
/// elsewhere:
///
/// * **0–100, default 0, one direction.** `RPCore.Slider` fixes the range;
///   `EditSection.setSlider` *deletes* a key set back to 0, so "absent" and
///   "neutral" are the same number and a slider centred at 50 would make an
///   empty document a non-identity render (docs/ADR-0012). Each row carries the
///   direction as its tooltip / VoiceOver hint.
/// * **Dragging does not write to disk.** The drag mutates memory and repaints
///   the GPU canvas; the release writes `edits/<id>.json` once.
/// * **Face-dependent groups say when they cannot work.** With no face detected
///   (no Core ML models, or no face in the frame) the Da / Mặt / Mắt & Răng
///   sliders would silently do nothing, so the group is disabled with the reason
///   written out rather than offering a dead control.
struct GroupSliderList: View {
    @Bindable var model: EditorModel
    let section: SliderSectionDescriptor
    var thumbSize: CGFloat = RPTheme.Metrics.macSliderThumb
    /// The uppercase caption above the list ("DA MẶT"). The Mac panel shows it;
    /// the phone sheet has no room.
    var showsCaption = false

    /// Why this group cannot do anything right now, or `nil` when it can.
    private var blockedReason: String? {
        if section.isLocked { return "\(section.phase) · chưa khả dụng" }
        guard section.needsFace else { return nil }
        guard model.detectedFaceCount == 0 else { return nil }
        guard let live = model.live else {
            return "Máy này không có preview GPU."
        }
        if !live.isReady { return "Preview GPU chưa sẵn sàng." }
        return live.faceAnalysisRan
            ? "Không nhận diện được khuôn mặt trong ảnh này."
            : "Chưa chạy được phân tích khuôn mặt — nhóm này cần model Core ML."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsCaption {
                RPSectionLabel(title: section.sectionCaption)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            }
            if let blockedReason {
                Label(blockedReason, systemImage: "info.circle")
                    .font(RPTheme.text(11))
                    .foregroundStyle(RPTheme.textTertiary)
                    .padding(.vertical, 8)
            }
            if section.isLocked {
                ForEach(section.plannedParameters, id: \.self) { name in
                    RPSliderRow(
                        label: name, value: 0, thumbSize: thumbSize, isEnabled: false,
                        onChange: { _ in })
                }
                .opacity(RPTheme.lockedOpacity)
            } else {
                ForEach(section.parameters) { parameter in
                    RPSliderRow(
                        label: parameter.label,
                        direction: parameter.direction,
                        value: model.slider(parameter.key, in: section.key),
                        thumbSize: thumbSize,
                        isEnabled: blockedReason == nil,
                        onChange: { value in
                            model.setSlider(parameter.key, in: section.key, to: value)
                        },
                        onCommit: {
                            // One disk write per drag, at the end.
                            Task { await model.commitEditState() }
                        })
                }
            }
        }
    }
}

/// The six group buttons, drawn as the phone's bottom tab row or the Mac's
/// far-right icon rail.
///
/// Locked (Phase 5) groups are dimmed to 38 % and inert — they are *shown*, not
/// hidden, so the shell carries the whole future taxonomy
/// (docs/design/SPEC.md rule 4).
struct GroupTabRow: View {
    @Bindable var chrome: EditorChrome
    /// How many sliders of each group the active shot carries, for the small
    /// "this group is doing something" dot.
    var activeCount: (String) -> Int = { _ in 0 }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SliderPanelLayout.sections) { section in
                Button {
                    chrome.selectGroup(section.key)
                } label: {
                    VStack(spacing: 5) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: section.systemImage)
                                .font(.system(size: 17, weight: .regular))
                            if activeCount(section.key) > 0 {
                                Circle()
                                    .fill(RPTheme.accent)
                                    .frame(width: 5, height: 5)
                                    .offset(x: 6, y: -2)
                            }
                        }
                        .frame(height: 20)
                        Text(section.title)
                            .font(RPTheme.text(9.5, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(
                        section.key == chrome.activeGroupKey ? RPTheme.accent : RPTheme.textMuted
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
                    .opacity(section.isLocked ? RPTheme.lockedOpacity : 1)
                }
                .buttonStyle(.plain)
                .disabled(section.isLocked)
                .accessibilityLabel(section.title)
                .accessibilityHint(section.isLocked ? "\(section.phase) · chưa khả dụng" : "")
                .accessibilityAddTraits(
                    section.key == chrome.activeGroupKey ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

/// The macOS far-right rail: the same six groups as 40×40 icon buttons, the
/// active one on a faint mint pill.
struct GroupIconRail: View {
    @Bindable var chrome: EditorChrome

    var body: some View {
        VStack(spacing: 4) {
            ForEach(SliderPanelLayout.sections) { section in
                Button {
                    chrome.selectGroup(section.key)
                } label: {
                    Image(systemName: section.systemImage)
                        .font(.system(size: 17))
                        .foregroundStyle(
                            section.key == chrome.activeGroupKey
                                ? RPTheme.accent : RPTheme.textMuted
                        )
                        .frame(width: 40, height: 40)
                        .background(
                            section.key == chrome.activeGroupKey
                                ? RPTheme.accentRail : .clear,
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .opacity(section.isLocked ? RPTheme.lockedOpacity : 1)
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(section.isLocked)
                .help(section.isLocked ? "\(section.title) — \(section.phase)" : section.title)
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(
                    section.key == chrome.activeGroupKey ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .frame(width: RPTheme.Metrics.macRailWidth)
        .frame(maxHeight: .infinity)
        .background(RPTheme.chrome)
        .overlay(alignment: .leading) {
            Rectangle().fill(RPTheme.hairline).frame(width: 1)
        }
    }
}

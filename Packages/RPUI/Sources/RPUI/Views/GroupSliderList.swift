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
/// * **Default 0, and 0 is always neutral.** `RPCore.Slider` fixes each row's
///   range — 0–100 for Da / Mặt / Mắt & Răng, −100…100 centred on 0 for sixteen
///   of the eighteen "Màu" sliders (docs/ADR-0016). `EditSection.setSlider`
///   *deletes* a key set back to 0, so "absent" and "neutral" are the same
///   number and a slider centred at 50 would still make an empty document a
///   non-identity render (docs/ADR-0012). Each row carries the direction as its
///   tooltip / VoiceOver hint.
/// * **Dragging does not write to disk.** The drag mutates memory and repaints
///   the GPU canvas; the release writes `edits/<id>.json` once.
/// * **Detection-dependent groups say when they cannot work.** With no face
///   detected (no Core ML models, or no face in the frame) the Da / Mặt /
///   Mắt & Răng sliders would silently do nothing, so the group is disabled with
///   the reason written out rather than offering a dead control. The same line
///   now carries whatever the group's render node reports it could not find
///   (`SliderSectionDescriptor.notifiesFromNodeNamed` → `RenderReport.notices`);
///   the rule itself lives in ``GroupAvailability`` so it can be tested without
///   a view.
struct GroupSliderList: View {
    @Bindable var model: EditorModel
    let section: SliderSectionDescriptor
    var thumbSize: CGFloat = RPTheme.Metrics.macSliderThumb
    /// The uppercase caption above the list ("DA MẶT"). The Mac panel shows it;
    /// the phone sheet has no room.
    var showsCaption = false

    /// Why this group cannot do anything right now, or `nil` when it can.
    ///
    /// Re-evaluated on every render, deliberately: see ``GroupAvailability``.
    private var blockedReason: String? {
        GroupAvailability.blockedReason(
            section: section,
            detectedFaceCount: model.detectedFaceCount,
            preview: GroupAvailability.previewState(of: model.live),
            notices: model.live?.detectionNotices ?? [:])
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
                        range: parameter.range,
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

/// The eighteen tool buttons of ``RailLayout``, drawn as the phone's bottom row
/// (screen 3a) or the Mac's far-right rail (screen 3f). (The canvas's `RAIL`
/// const has nineteen — "Xoá vật thể" was cut from scope 2026-09-11, see
/// `docs/design/SPEC.md` §Turn 3 "Cut from scope".)
///
/// Two rules carried over unchanged from the six-group rail this replaced:
///
/// * **Locked items are dimmed to 38 % and inert** — shown, not hidden, so the
///   shell carries the whole future taxonomy (docs/design/SPEC.md rule 4). With
///   the Turn 3 rail that is twelve of eighteen: the ten tools with no
///   engine behind them plus the two Phase 5 groups (Trang điểm, Tóc).
/// * **Highlight follows the *section*, not the item** — several items open the
///   same panel (Mắt / Bọng mắt / Răng → Mắt & Răng; Mịn da / Kiềm dầu → Da),
///   so they light up together. That is SPEC's wiring table, not a bug.
///
/// Eighteen items do not fit a phone's width, so the row scrolls horizontally
/// with a fixed item width instead of splitting the width eighteen ways.
///
/// **Màu is pinned outside that scroll view**, at the trailing edge behind a
/// hairline: the canvas's `RAIL` const has no colour entry, so replacing the old
/// six-group tab row with it orphaned the eighteen working Color sliders. SPEC
/// (§"macOS panel (3f) structural note") asks for it back as an always-visible
/// top-level tab alongside the rail, which is what `RailLayout.colorItem` is —
/// same icon, label and selected treatment as the eighteen, just not scrollable.
/// Trailing rather than leading because colour is the user's last step, the same
/// ordering decision that puts Mặt/Mắt/Mịn da first in `RailLayout.items`.
struct GroupTabRow: View {
    @Bindable var chrome: EditorChrome
    /// How many sliders of the group behind each item the active shot carries,
    /// for the small "this group is doing something" dot. An item with no
    /// section behind it can carry nothing, so it never shows the dot.
    var activeCount: (String) -> Int = { _ in 0 }

    /// Wide enough for "Trang điểm" (the longest surviving label) at 9.5 pt with
    /// the row's own scaling, and narrow enough that the phone shows ~6 items —
    /// the mockup's proportions.
    private let itemWidth: CGFloat = 58

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(RailLayout.items) { railItem in
                        item(railItem)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)
            Rectangle()
                .fill(RPTheme.hairlineStrong)
                .frame(width: 1, height: 34)
                .padding(.horizontal, 3)
            item(RailLayout.colorItem)
                .padding(.trailing, 6)
                .padding(.top, 6)
                .padding(.bottom, 4)
        }
    }

    /// One tab, used both for the pinned Màu chip and for the eighteen scrolling
    /// ones so the two cannot end up looking different.
    @ViewBuilder
    private func item(_ item: RailItemDescriptor) -> some View {
        let isActive = item.sectionKey == chrome.activeGroupKey
        Button {
            chrome.selectRailItem(item)
        } label: {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 17, weight: .regular))
                    if item.sectionKey.map({ activeCount($0) > 0 }) == true {
                        Circle()
                            .fill(RPTheme.accent)
                            .frame(width: 5, height: 5)
                            .offset(x: 6, y: -2)
                    }
                }
                .frame(height: 20)
                Text(item.label)
                    .font(RPTheme.text(9.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isActive ? RPTheme.accent : RPTheme.textMuted)
            .frame(width: itemWidth)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .opacity(item.isLocked ? RPTheme.lockedOpacity : 1)
        }
        .buttonStyle(.plain)
        .disabled(item.isLocked)
        .accessibilityLabel(item.label)
        .accessibilityHint(item.isLocked ? item.lockedHint : "")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

/// The macOS far-right rail: the same eighteen tools as 40×40 icon buttons, the
/// active one on a faint mint pill.
///
/// It scrolls vertically — eighteen 40 pt buttons are ~792 pt tall with the
/// spacing, which is more than the panel has on a laptop screen.
///
/// **Màu is pinned below that scroll view**, behind a hairline, for the reason
/// spelled out on ``GroupTabRow``: the canvas's rail has no colour entry and the
/// Color panel's eighteen sliders would otherwise have no way in. Bottom rather
/// than top because colour is the user's last step.
struct GroupIconRail: View {
    @Bindable var chrome: EditorChrome

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(spacing: 4) {
                    ForEach(RailLayout.items) { railItem in
                        item(railItem)
                    }
                }
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            Rectangle()
                .fill(RPTheme.hairlineStrong)
                .frame(width: 28, height: 1)
            item(RailLayout.colorItem)
                .padding(.top, 6)
                .padding(.bottom, 10)
        }
        .frame(width: RPTheme.Metrics.macRailWidth)
        .frame(maxHeight: .infinity)
        .background(RPTheme.chrome)
        .overlay(alignment: .leading) {
            Rectangle().fill(RPTheme.hairline).frame(width: 1)
        }
    }

    /// One 40×40 icon button, used both for the pinned Màu item and for the
    /// eighteen scrolling ones.
    @ViewBuilder
    private func item(_ item: RailItemDescriptor) -> some View {
        let isActive = item.sectionKey == chrome.activeGroupKey
        Button {
            chrome.selectRailItem(item)
        } label: {
            Image(systemName: item.systemImage)
                .font(.system(size: 17))
                .foregroundStyle(isActive ? RPTheme.accent : RPTheme.textMuted)
                .frame(width: 40, height: 40)
                .background(
                    isActive ? RPTheme.accentRail : .clear,
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .opacity(item.isLocked ? RPTheme.lockedOpacity : 1)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(item.isLocked)
        .help(item.isLocked ? "\(item.label) — \(item.lockedHint)" : item.label)
        .accessibilityLabel(item.label)
        .accessibilityHint(item.isLocked ? item.lockedHint : "")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

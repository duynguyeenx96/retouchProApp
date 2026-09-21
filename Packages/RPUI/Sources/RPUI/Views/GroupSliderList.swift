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

    /// Whether this group's **switches** stay usable while ``blockedReason`` is
    /// showing. The rule and its reasoning live in
    /// ``GroupAvailability/togglesEnabled(section:)`` so they can be tested
    /// without building a view, the same as ``blockedReason``.
    private var togglesEnabled: Bool {
        GroupAvailability.togglesEnabled(section: section)
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
                        // `storageKey`, never `key`: "Mắt" and "Răng" are two
                        // panels over the one `eyesTeeth` namespace.
                        value: model.slider(parameter.key, in: section.storageKey),
                        range: parameter.range,
                        thumbSize: thumbSize,
                        isEnabled: blockedReason == nil,
                        unit: Self.unit(for: parameter.key),
                        onChange: { value in
                            model.setSlider(parameter.key, in: section.storageKey, to: value)
                        },
                        onCommit: {
                            // One disk write per drag, at the end.
                            Task { await model.commitEditState() }
                        })
                }
                ForEach(section.toggles) { toggle in
                    RPToggleRow(
                        label: toggle.label,
                        detail: toggle.detail,
                        // `storageKey` for the same reason the sliders use it:
                        // "Sửa da" is a panel over the `mask` namespace, which
                        // it shares with "Khoá nền".
                        isOn: model.isToggleOn(toggle.key, in: section.storageKey),
                        isEnabled: togglesEnabled,
                        onChange: { isOn in
                            // One tap, one write — see `EditorModel.setToggle`.
                            model.setToggle(toggle.key, in: section.storageKey, to: isOn)
                        })
                }
            }
        }
    }

    /// "Nhiệt độ" is a **Kelvin** row — it shows "5200K" instead of its raw
    /// −100…100 amount, which is meaningless to a photographer on its own, and
    /// since 2026-09-21 it also *accepts* a typed Kelvin (2026-09-21, user
    /// request after shipping docs/ADR-0023's real Kelvin/Bradford model — the
    /// number next to the slider should say, and take, what the model actually
    /// computes, the same way Lightroom's does).
    ///
    /// `RenderRequest.referenceColorTemperatureKelvin` has no producer yet
    /// (ADR-0023 §"What this round did not do" — real RAW/EXIF Kelvin is Phase 2
    /// spike S4), so this passes the same `WhiteBalance.defaultNeutralKelvin`
    /// (6500K/D65) the render node falls back to: the label and the pixels agree
    /// because they call the same function with the same neutral.
    ///
    /// Everything else is `.amount`, whose raw number already *is* the value
    /// (EV, %, …).
    private static func unit(for key: String) -> SliderValueUnit {
        guard key == ColorSliders.Key.wbTemperature else { return .amount }
        return .kelvin(neutral: WhiteBalance.defaultNeutralKelvin)
    }
}

/// The **top level** of ``RailLayout`` — eight tool buttons plus the pinned Màu
/// chip — drawn as the phone's bottom row (screen 3a) or the Mac's far-right
/// rail (screen 3f). The sub-features of a parent ("Mặt", "Cơ thể") are not
/// here: they are one level in, in ``RailChildStrip``.
///
/// Three rules, the first two carried over unchanged from the six-group rail
/// this replaced:
///
/// * **Locked items are dimmed to 38 % and inert** — shown, not hidden, so the
///   shell carries the whole future taxonomy (docs/design/SPEC.md rule 4). A
///   parent is locked only when every child is, which today is "Cơ thể".
/// * **Highlight follows the *panel*, not the item** — an item lights up when
///   the open panel is the one it opens, and a **parent** lights up when the
///   open panel is any of its children's (`RailItemDescriptor.opensPanel`).
///   Since 2026-09-18 no two *siblings* share a panel: that was the duplicate
///   "Bọng mắt" / "Kiềm dầu" behaviour the user reported, and both duplicates
///   are gone.
/// * **A parent's tap opens its first working child** and the panel then shows
///   the strip, so the second level is never a dead end.
///
/// Nine items still do not fit a phone's width comfortably, so the row keeps its
/// horizontal scroll and fixed item width.
///
/// **Màu is pinned outside that scroll view**, at the trailing edge behind a
/// hairline: the canvas's `RAIL` const has no colour entry, so replacing the old
/// six-group tab row with it orphaned the eighteen working Color sliders. SPEC
/// (§"macOS panel (3f) structural note") asks for it back as an always-visible
/// top-level tab alongside the rail, which is what `RailLayout.colorItem` is —
/// same icon, label and selected treatment as the eight, just not scrollable.
/// Trailing rather than leading because colour is the user's last step, the same
/// ordering decision that puts "Mặt" first in `RailLayout.items`.
struct GroupTabRow: View {
    @Bindable var chrome: EditorChrome
    /// How many sliders of the panel behind each item the active shot carries,
    /// for the small "this group is doing something" dot. Takes the **panel**
    /// rather than a namespace string so that two panels sharing one namespace
    /// (Mắt / Răng, Mịn da / Kiềm dầu) count only their own sliders. An item with
    /// no panel behind it can carry nothing, so it never shows the dot; a parent
    /// adds its children's up.
    var activeCount: (SliderSectionDescriptor) -> Int = { _ in 0 }

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

    /// One tab, used both for the pinned Màu chip and for the scrolling ones so
    /// the two cannot end up looking different.
    @ViewBuilder
    private func item(_ item: RailItemDescriptor) -> some View {
        let isActive = chrome.isRailItemActive(item)
        Button {
            chrome.selectRailItem(item)
        } label: {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 17, weight: .regular))
                    if RailDot.count(for: item, activeCount: activeCount) > 0 {
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

/// How many moved sliders sit behind one rail item — its own panel's for a leaf,
/// all of its children's added up for a parent.
///
/// A free function rather than a method on the descriptor because the count
/// comes from the document, which `RPUI`'s model layer owns and `RailLayout`
/// (pure data) must not reach into.
enum RailDot {
    static func count(
        for item: RailItemDescriptor, activeCount: (SliderSectionDescriptor) -> Int
    ) -> Int {
        item.sectionKeys
            .compactMap(SliderPanelLayout.section(forKey:))
            .reduce(0) { $0 + activeCount($1) }
    }
}

/// The **second level**: the sub-features of whichever body part the open panel
/// belongs to, drawn as a pill strip inside the panel itself (2026-09-18).
///
/// It is deliberately the same visual language as ``GroupTabRow`` / the Mac
/// rail's selected state — icon + label, mint on a faint mint pill when active,
/// 38 % and inert when locked — one level deeper rather than a new kind of
/// chrome. It appears only when ``EditorChrome/activeRailParent`` is non-nil, so
/// a top-level leaf's panel (Trang điểm, Tóc, Màu) looks exactly as it did.
struct RailChildStrip: View {
    @Bindable var chrome: EditorChrome
    /// The body part whose children this strip draws.
    let parent: RailItemDescriptor
    /// Same "this group is doing something" dot as the rail's.
    var activeCount: (SliderSectionDescriptor) -> Int = { _ in 0 }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(parent.children ?? []) { child in
                    pill(child)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Nhóm \(parent.label)")
    }

    @ViewBuilder
    private func pill(_ child: RailItemDescriptor) -> some View {
        let isActive = child.opensPanel(chrome.activeGroupKey)
        Button {
            chrome.selectRailItem(child)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: child.systemImage)
                    .font(.system(size: 12))
                Text(child.label)
                    .font(RPTheme.text(11, weight: .medium))
                    .lineLimit(1)
                if RailDot.count(for: child, activeCount: activeCount) > 0 {
                    Circle().fill(RPTheme.accent).frame(width: 4, height: 4)
                }
            }
            .foregroundStyle(isActive ? RPTheme.accent : RPTheme.textMuted)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                isActive ? RPTheme.accentRail : .clear,
                in: Capsule()
            )
            .contentShape(Capsule())
            .opacity(child.isLocked ? RPTheme.lockedOpacity : 1)
        }
        .buttonStyle(.plain)
        .disabled(child.isLocked)
        .help(child.isLocked ? "\(child.label) — \(child.lockedHint)" : child.label)
        .accessibilityLabel(child.label)
        .accessibilityHint(child.isLocked ? child.lockedHint : "")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

/// The macOS far-right rail: the same top-level tools as 40×40 icon buttons, the
/// active one on a faint mint pill.
///
/// It scrolls vertically, as it did when the rail was a flat nineteen — the
/// hierarchy made it shorter, not fixed-height.
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
    /// scrolling ones.
    @ViewBuilder
    private func item(_ item: RailItemDescriptor) -> some View {
        let isActive = chrome.isRailItemActive(item)
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

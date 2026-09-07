import SwiftUI

/// The controls the mockup draws by hand: a flat-track slider, pill buttons,
/// choice chips and a star rating.
///
/// They exist as their own types (rather than `SwiftUI.Slider` +
/// `.tint(RPTheme.accent)`) because the mockup's slider is a **2 px track with a
/// 13 px free-floating thumb** and no platform chrome at all: no macOS bezel, no
/// iOS shadowed capsule, and the same shape on both platforms. `SwiftUI.Slider`
/// draws a different control per platform and gives no way to reach that.

// MARK: - Slider

/// One 0–100 row: label + mono value on top, custom track below.
///
/// Dragging writes through ``onChange`` on every movement (memory + a GPU
/// repaint, `EditorModel.setSlider`) and calls ``onCommit`` once when the finger
/// lifts — the "one disk write per drag" rule from docs/ADR-0013.
struct RPSliderRow: View {
    let label: String
    /// Which way 100 goes. Not drawn — every slider here is 0–100 and
    /// one-directional (ADR-0010/0012), so it is the help text on macOS and the
    /// accessibility hint on iOS rather than a third line in a 250 pt sheet.
    var direction: String = ""
    let value: Double
    var thumbSize: CGFloat = RPTheme.Metrics.macSliderThumb
    var isEnabled: Bool = true
    let onChange: (Double) -> Void
    var onCommit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(RPTheme.text(thumbSize > 12 ? 13 : 12.5))
                    .foregroundStyle(RPTheme.textLabel)
                Spacer(minLength: 8)
                Text("\(Int(value.rounded()))")
                    .font(RPTheme.mono(thumbSize > 12 ? 12 : 11.5))
                    .foregroundStyle(value > 0 ? RPTheme.accent : RPTheme.textTertiary)
                    .monospacedDigit()
            }
            RPSliderTrack(
                value: value, thumbSize: thumbSize, isEnabled: isEnabled,
                onChange: onChange, onCommit: onCommit)
        }
        .padding(.vertical, thumbSize > 12 ? 9 : 8)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value.rounded())) trên 100")
        .accessibilityHint(direction.isEmpty ? "" : "100 = \(direction)")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: onChange(min(100, value + 5))
            case .decrement: onChange(max(0, value - 5))
            @unknown default: break
            }
            onCommit()
        }
        #if os(macOS)
            .help(direction.isEmpty ? label : "\(label) — 100 = \(direction)")
        #endif
    }
}

/// The track itself: 2 px line, mint fill up to the value, a round white thumb.
///
/// ## Living inside a `ScrollView` (the reason for the two thresholds)
///
/// On the phone this control is stacked eight-to-eighteen deep inside a 250 pt
/// scrolling sheet, and the first build made that sheet almost unscrollable: a
/// `DragGesture(minimumDistance: 0)` wins SwiftUI's gesture arbitration
/// immediately, so a finger landing anywhere near a track grabbed the *slider*
/// and the list would not move.
///
/// The fix is two-part, and both parts are needed:
///
/// 1. **`minimumDistance` > 0 on touch platforms.** The scroll view's own pan
///    recogniser starts within a couple of points; giving the slider a 12 pt
///    threshold lets the scroll win a flick before the slider ever activates.
///    macOS keeps 0 — a pointer has no scroll gesture to lose to, and a click
///    should set the value immediately.
/// 2. **A direction test on the first movement.** If the drag that *does* reach
///    the threshold is mostly vertical, the whole sequence is ignored, so a slow
///    vertical drag over a track cannot nudge a slider by accident.
///
/// Because (1) means a plain tap no longer reaches `onEnded` on iOS, tap-to-set
/// is a separate `SpatialTapGesture` there.
struct RPSliderTrack: View {
    let value: Double
    var thumbSize: CGFloat = RPTheme.Metrics.macSliderThumb
    var isEnabled: Bool = true
    let onChange: (Double) -> Void
    var onCommit: () -> Void = {}

    /// Nil until the first `onChanged` of a sequence has decided whether this
    /// drag belongs to the slider (`true`) or to the scroll view (`false`).
    @State private var isMine: Bool?

    /// 0 on macOS, 12 pt on touch — see the type's note.
    private var minimumDistance: CGFloat {
        #if os(macOS)
            0
        #else
            12
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let fraction = min(1, max(0, value / 100))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(RPTheme.sliderTrack)
                    .frame(height: 2)
                Capsule()
                    .fill(RPTheme.accent)
                    .frame(width: width * fraction, height: 2)
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.7), radius: 2.5, y: 1)
                    .offset(x: width * fraction - thumbSize / 2)
            }
            .frame(height: geometry.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: minimumDistance)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        if isMine == nil {
                            isMine =
                                abs(gesture.translation.width)
                                >= abs(gesture.translation.height)
                        }
                        guard isMine == true else { return }
                        onChange(clamped(gesture.location.x / width))
                    }
                    .onEnded { gesture in
                        defer { isMine = nil }
                        guard isEnabled, isMine != false else { return }
                        onChange(clamped(gesture.location.x / width))
                        onCommit()
                    }
            )
            #if !os(macOS)
                // A tap never travels 12 pt, so on touch it needs its own
                // gesture. `SpatialTapGesture` is the one that reports where.
                .simultaneousGesture(
                    SpatialTapGesture()
                        .onEnded { tap in
                            guard isEnabled else { return }
                            onChange(clamped(tap.location.x / width))
                            onCommit()
                        }
                )
            #endif
        }
        .frame(height: thumbSize + 3)
    }

    private func clamped(_ fraction: CGFloat) -> Double {
        min(100, max(0, Double(fraction) * 100)).rounded()
    }
}

// MARK: - Buttons and pills

/// The mint primary button ("Xuất", "Files", "Mở trong Chỉnh sửa").
struct RPPrimaryButton: View {
    let title: String
    var horizontalPadding: CGFloat = 18
    var verticalPadding: CGFloat = 7
    var cornerRadius: CGFloat = 8
    var fontSize: CGFloat = 13
    /// Stretch to the container's width — the mint fill has to stretch with it,
    /// so this is inside the button and not a `.frame` at the call site.
    var fillsWidth: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(RPTheme.text(fontSize, weight: .semibold))
                .foregroundStyle(RPTheme.onAccent)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .background(RPTheme.accent, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(!isEnabled)
    }
}

/// A neutral (translucent white) button, the secondary of the pair.
struct RPSecondaryButton: View {
    let title: String
    var horizontalPadding: CGFloat = 14
    var verticalPadding: CGFloat = 6
    var cornerRadius: CGFloat = 8
    var fontSize: CGFloat = 12.5
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(RPTheme.text(fontSize))
                .foregroundStyle(RPTheme.textPrimary)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(RPTheme.fillNeutral, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(!isEnabled)
    }
}

/// A square icon button — the phone top bar's back / hold / overflow controls
/// and the macOS toolbar's tool group.
struct RPIconButton: View {
    let systemImage: String
    var accessibilityTitle: String
    var size: CGFloat = 30
    var fontSize: CGFloat = 15
    var isActive: Bool = false
    var tint: Color = RPTheme.textBright
    var background: Color = .clear
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(isActive ? RPTheme.textPrimary : tint)
                .frame(width: size, height: size)
                .background(
                    isActive ? RPTheme.fillNeutralStrong : background,
                    in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

/// A choice pill: the library filter row, the export option rows, the sidebar
/// filters. Selected = mint tint + mint text, otherwise neutral.
struct RPChoicePill: View {
    let title: String
    let isSelected: Bool
    var fontSize: CGFloat = 12
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 5
    var cornerRadius: CGFloat = 7
    /// The library filter row draws its active pill solid light, not mint
    /// (`background:#f2f4f7;color:#111214` in 2a).
    var selectedStyle: SelectedStyle = .mint
    let action: () -> Void

    enum SelectedStyle { case mint, solid }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(RPTheme.text(fontSize, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(background, in: RoundedRectangle(cornerRadius: cornerRadius))
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var foreground: Color {
        guard isSelected else { return RPTheme.textSecondary }
        return selectedStyle == .mint ? RPTheme.accent : RPTheme.chromeDeep
    }

    private var background: Color {
        guard isSelected else { return RPTheme.fillNeutralSoft }
        return selectedStyle == .mint ? RPTheme.accentPill : RPTheme.textPrimary
    }
}

/// A translucent, blurred pill that sits **on the photo**: the face chips, the
/// sync toggle and the subject selector in screen 1a.
struct RPOverlayPill<Content: View>: View {
    var isSelected: Bool = false
    var cornerRadius: CGFloat = 999
    let content: Content

    init(isSelected: Bool = false, cornerRadius: CGFloat = 999, @ViewBuilder content: () -> Content)
    {
        self.isSelected = isSelected
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                if isSelected {
                    shape.fill(RPTheme.accent.opacity(0.92))
                } else {
                    shape.fill(.ultraThinMaterial)
                        .overlay(shape.fill(RPTheme.overlayPill))
                        .overlay(shape.strokeBorder(RPTheme.overlayPillBorder, lineWidth: 1))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Stars

/// Five interactive stars. A second click on the same star clears the rating —
/// the rule `EditorModel.toggleRating` already implements.
struct RPStarRating: View {
    let rating: Int
    var size: CGFloat = 14
    var isEnabled: Bool = true
    let setRating: (Int) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    setRating(value)
                } label: {
                    Image(systemName: value <= rating ? "star.fill" : "star")
                        .font(.system(size: size))
                        .foregroundStyle(value <= rating ? RPTheme.star : RPTheme.starEmpty)
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityLabel("Chấm \(value) sao")
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// The read-only "★★★" caption drawn over a thumbnail.
struct RPStarCaption: View {
    let rating: Int
    var size: CGFloat = 9

    var body: some View {
        Text(String(repeating: "★", count: max(0, rating)))
            .font(RPTheme.mono(size))
            .foregroundStyle(RPTheme.star)
    }
}

// MARK: - Section label

/// The uppercase, letter-spaced caption over a sidebar or panel section
/// ("NGUỒN", "LỌC", "DA MẶT").
struct RPSectionLabel: View {
    let title: String
    var size: CGFloat = 11

    var body: some View {
        Text(title.uppercased())
            .font(RPTheme.text(size, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(RPTheme.textTertiary)
    }
}

// MARK: - Format tag

/// The `RAW` / `HEIC` / `JPEG` chip in a thumbnail's top-right corner.
struct RPFormatTag: View {
    let text: String
    var isRaw: Bool

    var body: some View {
        Text(text)
            .font(RPTheme.text(8.5, weight: .medium))
            .foregroundStyle(isRaw ? RPTheme.star : RPTheme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
    }
}

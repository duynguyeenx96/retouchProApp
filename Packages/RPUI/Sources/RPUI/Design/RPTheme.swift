import SwiftUI

/// The palette, type and metrics of the approved design
/// (`docs/design/SPEC.md`, pixel values from `docs/design/RetouchPro.dc.html`).
///
/// ## Why literal colours and not the semantic system ones
///
/// The mockup is a **fixed dark surface**: `#0c0d0f` canvas, `#141518` chrome,
/// one mint accent. `Color.primary` / `.background` follow the user's appearance
/// and vibrancy settings, so they cannot reproduce it — the editor would be a
/// different grey on every Mac and would go white in Light Mode, which is wrong
/// for a photo tool where the surround decides how the picture reads. So the
/// colours are spelled out here, once, and the root view pins
/// `.preferredColorScheme(.dark)`.
///
/// Fonts are the opposite: the mockup names "Be Vietnam Pro" / "JetBrains Mono",
/// and `docs/design/SPEC.md` says explicitly *"do not bundle web fonts, use
/// system fonts with matching weight"*. So text is SF (`.system`) and every
/// number, file name and EXIF value is SF Mono (`.system(design: .monospaced)`).
public enum RPTheme {

    // MARK: - Surfaces

    /// `#0c0d0f` — the window/canvas background on both platforms.
    public static let canvas = Color(hex: 0x0C0D0F)
    /// `#141518` — toolbars, side panels, the phone tool sheet.
    public static let chrome = Color(hex: 0x141518)
    /// `#111214` — the macOS filmstrip strip and the phone bezel.
    public static let chromeDeep = Color(hex: 0x111214)
    /// `#17191d` — the iPhone export sheet.
    public static let sheet = Color(hex: 0x17191D)
    /// `#191b1f` — the macOS export dialog.
    public static let dialog = Color(hex: 0x191B1F)
    /// Pure black behind a photo, so nothing tints the picture.
    public static let imageBackground = Color.black

    // MARK: - Accent

    /// `#7de3c3` — primary buttons, the active tab underline, the active slider
    /// fill and thumb track, an active value, the "Sau" badge.
    public static let accent = Color(hex: 0x7DE3C3)
    /// `#93e9ce` — the hover shade of ``accent``.
    public static let accentHover = Color(hex: 0x93E9CE)
    /// `#06231c` — text drawn *on* ``accent``.
    public static let onAccent = Color(hex: 0x06231C)
    /// `rgba(125,227,195,.12)` — the rail pill behind the active group icon.
    public static let accentRail = Color(hex: 0x7DE3C3, opacity: 0.12)
    /// `rgba(125,227,195,.14)` — an active filter chip / the sync toggle when on.
    public static let accentSoft = Color(hex: 0x7DE3C3, opacity: 0.14)
    /// `rgba(125,227,195,.16)` — a selected export option pill.
    public static let accentPill = Color(hex: 0x7DE3C3, opacity: 0.16)

    // MARK: - Text

    /// `#f2f4f7`
    public static let textPrimary = Color(hex: 0xF2F4F7)
    /// `#e6e9ee` — icon glyphs on the canvas overlay and the phone top bar.
    public static let textBright = Color(hex: 0xE6E9EE)
    /// `#d6dae0` — a slider row's label.
    public static let textLabel = Color(hex: 0xD6DAE0)
    /// `#c9ccd1` — mono captions on a thumbnail.
    public static let textMono = Color(hex: 0xC9CCD1)
    /// `#9aa1ab`
    public static let textSecondary = Color(hex: 0x9AA1AB)
    /// `#8b929c` — an inactive group icon.
    public static let textMuted = Color(hex: 0x8B929C)
    /// `#6e757f` — meta text, a zero slider value, a section caption.
    public static let textTertiary = Color(hex: 0x6E757F)

    /// `#e8c46a` — stars.
    public static let star = Color(hex: 0xE8C46A)
    /// The unfilled star.
    public static let starEmpty = Color.white.opacity(0.2)

    // MARK: - Lines and fills

    /// `rgba(255,255,255,.06)` — the hairline under a toolbar / between panels.
    public static let hairline = Color.white.opacity(0.06)
    /// `rgba(255,255,255,.07)` — the phone sheet's borders and neutral buttons.
    public static let hairlineStrong = Color.white.opacity(0.07)
    /// `rgba(255,255,255,.09)` — the dialog border and the toolbar divider.
    public static let hairlineDialog = Color.white.opacity(0.09)
    /// `rgba(255,255,255,.13)` — an unfilled slider track.
    public static let sliderTrack = Color.white.opacity(0.13)
    /// `rgba(255,255,255,.06/.07/.08)` — neutral chip / button fills.
    public static let fillNeutral = Color.white.opacity(0.07)
    public static let fillNeutralSoft = Color.white.opacity(0.06)
    public static let fillNeutralStrong = Color.white.opacity(0.08)
    /// `rgba(255,255,255,.04)` — the footnote card and the progress card.
    public static let fillFaint = Color.white.opacity(0.04)
    /// `rgba(18,19,22,.72)` — a translucent canvas-overlay pill.
    public static let overlayPill = Color(hex: 0x121316, opacity: 0.72)
    /// `rgba(18,19,22,.78)` — the "Trước" badge.
    public static let overlayBadge = Color(hex: 0x121316, opacity: 0.78)
    /// `rgba(255,255,255,.14)` — the border of an unselected overlay pill.
    public static let overlayPillBorder = Color.white.opacity(0.14)
    /// `rgba(6,8,10,.62)` — the scrim behind the iPhone export sheet.
    public static let scrim = Color(hex: 0x06080A, opacity: 0.62)
    /// `rgba(6,8,10,.55)` — the scrim behind the macOS export dialog.
    public static let scrimMac = Color(hex: 0x06080A, opacity: 0.55)
    /// The diagonal hatch a thumbnail shows before its pixels arrive
    /// (`repeating-linear-gradient(135deg,#212327 0 6px,#191b1f 6px 12px)`).
    public static let thumbnailPlaceholder = Color(hex: 0x1E2024)
    /// The dimming applied to a locked (Phase 5) group.
    public static let lockedOpacity: Double = 0.38

    // MARK: - Type

    /// Every number, file name, EXIF value, percentage and "on-device · Metal".
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    public static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // MARK: - Metrics

    public enum Metrics {
        // 1a — iPhone editor
        /// Height of the phone editor's top bar row (`8 + 30 + 10` in the
        /// mockup). Documented, not enforced with a `frame`: Dynamic Type has to
        /// be able to grow it.
        public static let phoneTopBarHeight: CGFloat = 48
        /// Height of the scrollable slider list in the bottom tool sheet.
        public static let phoneSheetSliderHeight: CGFloat = 250
        /// Corner radius of the attached tool sheet.
        public static let phoneSheetRadius: CGFloat = 16
        /// The sheet overlaps the canvas by this much, as in the mockup
        /// (`margin-top:-14px`).
        public static let phoneSheetOverlap: CGFloat = 14
        public static let phoneSliderThumb: CGFloat = 13

        // 1b — macOS editor
        public static let macToolbarHeight: CGFloat = 46
        /// Reserved for the real traffic lights the system draws.
        ///
        /// **0 today.** The mockup puts the lights inside the 46 pt row; on a
        /// real `NavigationStack` window they live in the transparent title-bar
        /// strip *above* it, because the only ways to bring the row up under
        /// them either delete the lights or lay the row out off-screen (see
        /// `EditorView`'s note). Kept named so the intent survives if a future
        /// window without a navigation stack can do it.
        public static let macTrafficLightInset: CGFloat = 0
        public static let macFilmstripHeight: CGFloat = 104
        public static let macFilmstripThumbnail = CGSize(width: 68, height: 76)
        public static let macPanelWidth: CGFloat = 326
        public static let macRailWidth: CGFloat = 56
        public static let macSliderThumb: CGFloat = 12
        /// The 2 px gap between the "Trước" and "Sau" panes.
        public static let macCanvasGap: CGFloat = 2
        public static let macCanvasPadding: CGFloat = 16

        // 2c — macOS library
        public static let macLibrarySidebarWidth: CGFloat = 212
        public static let macLibraryInfoWidth: CGFloat = 268
        public static let macLibraryColumns = 5

        // 2d — macOS export dialog
        public static let macDialogWidth: CGFloat = 520

        /// Thumbnails are decoded at this long edge for every grid and strip.
        public static let thumbnailPixelSize = 256
    }
}

extension Color {
    /// `Color(hex: 0x7DE3C3)` — the mockup's values transcribed without a
    /// per-channel division at every call site.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}

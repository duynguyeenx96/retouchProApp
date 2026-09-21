import Foundation
import Observation
import RPCore

/// The purely-visual state of the shell: which tab, which slider group, which
/// filter, which export options.
///
/// Deliberately **separate from ``EditorModel``** and never written to disk.
/// `EditorModel` owns the project and the `EditState`; everything here is
/// "where the user is looking", which must not end up in `edits/<id>.json` or in
/// a `Preset` (docs/design/SPEC.md cross-cutting rule 1: *"Do not invent new
/// EditState fields"*).
///
/// Two things this type does **not** own, because they already have a home:
///
/// * the **face selection** — that is `EditState.perImage["selectedFace"]`
///   through `EditorModel.selectFace` (ADR-0013), and the "Đồng bộ" toggle in
///   the mockup is exactly the presence or absence of that key
///   (`EditorModel.isSyncingAllFaces`);
/// * **before/after** — `EditorModel.beforeAfter`.
@MainActor
@Observable
public final class EditorChrome {

    /// The toolbar's "Thư viện" / "Chỉnh sửa" switcher (screens 2c ⇄ 1b) and,
    /// on the phone, the library screen (2a) ⇄ the editor (1a).
    public enum Tab: String, CaseIterable, Hashable, Sendable {
        case library
        case edit

        public var title: String {
            switch self {
            case .library: "Thư viện"
            case .edit: "Chỉnh sửa"
            }
        }
    }

    /// The macOS toolbar's four tool icons. Only `pan` does anything today;
    /// heal and brush are Phase 5 (`docs/PLAN.md` §Phase 5) and undo is not
    /// implemented, so they are shown selected-but-inert rather than hidden —
    /// the same rule as the locked slider groups.
    public enum MacTool: String, CaseIterable, Hashable, Sendable {
        case pan, heal, brush, undo

        public var title: String {
            switch self {
            case .pan: "Bàn tay"
            case .heal: "Tẩy vết"
            case .brush: "Cọ"
            case .undo: "Hoàn tác"
            }
        }

        public var systemImage: String {
            switch self {
            case .pan: "hand.raised"
            case .heal: "bandage"
            case .brush: "paintbrush"
            case .undo: "arrow.uturn.backward"
            }
        }

        /// `true` for the tools that have no implementation yet.
        public var isPlanned: Bool { self != .pan }
    }

    /// The canvas overlay's subject pill in screen 1a.
    ///
    /// **Presentation only.** There is no per-subject behaviour in RPEngine —
    /// every slider is one 0–100 value applied to the selected face — so this
    /// records the photographer's own note about the frame and changes no
    /// rendering. It is here rather than invented into `EditState` for exactly
    /// that reason.
    public enum Subject: String, CaseIterable, Hashable, Sendable {
        case female, male, child, all

        public var title: String {
            switch self {
            case .female: "Nữ"
            case .male: "Nam"
            case .child: "Trẻ em"
            case .all: "Tất cả"
            }
        }

        public var next: Subject {
            let all = Subject.allCases
            return all[(all.firstIndex(of: self)! + 1) % all.count]
        }
    }

    /// The library's filter pill row (2a) and the macOS sidebar chips (2c).
    public enum LibraryFilter: String, CaseIterable, Hashable, Sendable {
        case all, edited, raw

        public var title: String {
            switch self {
            case .all: "Tất cả"
            case .edited: "Đã chỉnh"
            case .raw: "RAW"
            }
        }
    }

    /// Leaving the editor puts the brush away: a mode that survived a trip to
    /// the library would come back armed over a different photo, whose session
    /// is a different object (``isBrushing``). One place rather than at every
    /// call site that moves the tab.
    public var tab: Tab = .library {
        didSet {
            if tab != .edit { isBrushing = false }
        }
    }
    /// Which slider group the sheet / panel / rail is showing.
    public var activeGroupKey: String = SliderPanelLayout.defaultSectionKey
    public var macTool: MacTool = .pan
    public var subject: Subject = .female
    public var libraryFilter: LibraryFilter = .all
    /// The macOS sidebar's "★ 3+" chip.
    public var showsThreeStarsAndUp = false
    public var isShowingExport = false
    public var export = ExportOptions()
    /// Which half of the preset library is on screen, or `nil` when it is not
    /// (docs/PLAN.md §Phase 3). Like every other property here it is pure
    /// chrome: the library writes through ``EditorModel``, and closing it
    /// changes nothing on disk.
    public var presetLibrary: PresetLibraryKind?

    /// `true` while "Cọ mask thủ công" is armed (docs/PLAN.md §6.1,
    /// docs/ADR-0019): the brush bar is on screen and a drag on the canvas
    /// paints the mask instead of panning the picture.
    ///
    /// A *mode*, which is why it is a boolean here rather than a value in
    /// ``activeGroupKey``: the user keeps whichever slider panel they were on,
    /// because the point of painting a mask is to narrow what those sliders
    /// touch. Leaving the editor turns it off (see ``tab``); moving between
    /// slider groups does not.
    public var isBrushing = false
    /// Size / hardness / flow / add-or-erase. Chrome, not document —
    /// ``ManualMaskBrushSettings`` says why at length.
    public var brush = ManualMaskBrushSettings()

    /// The row in the brush bar's "layers" list (one row per finished stroke,
    /// oldest first — user's request, 2026-09-21: "giống Lightroom") the user is
    /// hovering (Mac) or has tapped (phone), or `nil` for none.
    ///
    /// This is the **only** thing that puts the green tint back on screen once
    /// a stroke has ended: painting shows it live (the canvas drives that off
    /// its own in-flight-stroke state, not this), and it goes away the instant
    /// the finger lifts. Adjusting a slider afterward must never bring it back
    /// on its own — the tint is opaque paint sitting on top of the one thing a
    /// "how strong is this" judgement needs to see, the real pixels — so the
    /// only way to see a past stroke's extent again is to deliberately ask for
    /// it from the list.
    public var previewedMaskStrokeIndex: Int?

    public init() {}

    public var activeSection: SliderSectionDescriptor {
        SliderPanelLayout.section(forKey: activeGroupKey)
            ?? SliderPanelLayout.sections[0]
    }

    /// Selecting a locked group does nothing — the tab stays where it was
    /// (docs/design/SPEC.md: *"tap does nothing … must not crash/switch"*).
    public func selectGroup(_ key: String) {
        guard let section = SliderPanelLayout.section(forKey: key), !section.isLocked else {
            return
        }
        activeGroupKey = key
    }

    /// Tapping a rail item (docs/design/SPEC.md §Turn 3). An item with no
    /// section and no screen behind it does **nothing at all** — it does not
    /// clear the selection and does not switch the panel — and an item pointing
    /// at a locked section is stopped by ``selectGroup(_:)`` for the same
    /// reason, so the view layer needs no conditional of its own.
    ///
    /// An item that opens a screen ("Mẫu" → the preset library) **only** opens
    /// it: `activeGroupKey` stays where it was, so closing the library puts the
    /// user back on the panel they were using. The same holds for the brush,
    /// which is a mode on top of whatever panel is open — see ``isBrushing``.
    ///
    /// A **locked** item does nothing at all, including a locked presentation:
    /// with `RPEngineFeatureFlags.manualMask` off there is no session to paint
    /// into, so arming the brush would put a bar on screen over a canvas that
    /// cannot take a stroke (docs/design/SPEC.md: *"tap does nothing … must not
    /// crash/switch"*). The views already disable the button; this is the same
    /// rule stated where it can be tested.
    ///
    /// A **parent** ("Mặt", "Cơ thể") has no panel of its own, so — once past the
    /// lock guard above — it forwards to ``RailItemDescriptor/defaultChild``, the
    /// first child that works.
    public func selectRailItem(_ item: RailItemDescriptor) {
        guard !item.isLocked else { return }
        if let child = item.defaultChild { return selectRailItem(child) }
        switch item.presentation {
        case .presetLibrary(let kind):
            presetLibrary = kind
        case .manualMaskBrush:
            // A second tap puts the brush away, the same "tap it again to undo
            // it" rule the face chips and the filmstrip's ratings follow.
            isBrushing.toggle()
        case nil:
            if let key = item.sectionKey { selectGroup(key) }
        }
    }

    /// The body part whose sub-features belong in the panel's second-level strip
    /// right now, or `nil` when the open panel is a top-level leaf's (Trang
    /// điểm, Tóc, Màu).
    ///
    /// Derived from ``activeGroupKey``, not stored: one piece of state, so the
    /// strip and the panel cannot disagree about where the user is.
    public var activeRailParent: RailItemDescriptor? {
        RailLayout.parent(ofPanelKey: activeGroupKey)
    }

    /// `true` when the rail should draw `item` as the current one.
    ///
    /// Not simply `item.sectionKey == activeGroupKey` any more: a parent has no
    /// section of its own (it is active when any of its children's panels are
    /// open, via ``RailItemDescriptor/opensPanel(_:)``) and the brush is a mode
    /// with no section at all, so the rail has to ask the mode directly. Both
    /// shells call this rather than each working it out, so the phone row and
    /// the Mac rail cannot disagree about what is active.
    public func isRailItemActive(_ item: RailItemDescriptor) -> Bool {
        if case .manualMaskBrush = item.presentation { return isBrushing }
        return item.opensPanel(activeGroupKey)
    }

    /// Puts the brush away. Called when the editor closes or another screen
    /// takes over the canvas, so a mode cannot outlive the picture it was armed
    /// on.
    public func disarmBrush() {
        isBrushing = false
        previewedMaskStrokeIndex = nil
    }


    public func cycleSubject() { subject = subject.next }
}

/// The choices in the export sheet (2b) and the export dialog (2d).
///
/// **No renderer behind it yet.** Export is `docs/PLAN.md` Phase 3, and
/// ADR-0011 records the open question it depends on (Da + Mắt/Răng together are
/// ~936 MB of scratch at 24 MP, unmeasured on a real iPhone). So this value type
/// and its UI exist, the button says so, and nothing writes a file.
public struct ExportOptions: Hashable, Sendable {
    public enum Format: String, CaseIterable, Hashable, Sendable {
        case jpeg, heif, tiff
        public var title: String {
            switch self {
            case .jpeg: "JPEG"
            case .heif: "HEIF"
            case .tiff: "TIFF"
            }
        }
    }

    public enum Quality: Int, CaseIterable, Hashable, Sendable {
        case low = 80, standard = 92, maximum = 100
        public var title: String { "\(rawValue)" }
    }

    public enum Size: String, CaseIterable, Hashable, Sendable {
        case original, long4000, long2048
        public var title: String {
            switch self {
            case .original: "Gốc"
            case .long4000: "Dài 4000px"
            case .long2048: "Dài 2048px"
            }
        }
    }

    public enum ColorSpace: String, CaseIterable, Hashable, Sendable {
        case sRGB, displayP3
        public var title: String {
            switch self {
            case .sRGB: "sRGB"
            case .displayP3: "Display P3"
            }
        }
    }

    public var format: Format = .jpeg
    public var quality: Quality = .low
    public var size: Size = .original
    public var colorSpace: ColorSpace = .sRGB
    /// The macOS dialog's destination folder row. `nil` until the user picks
    /// one, in which case the export lands in
    /// ``ExportDestination/defaultDirectory(fileManager:)``.
    public var destinationFolder: URL?

    public init() {}

    /// What the folder row shows — **the folder that will actually be written
    /// to**, not a placeholder.
    ///
    /// It used to read `~/Pictures/RetouchPro`, which was the mockup's caption
    /// and never a path this app can write: both builds are sandboxed without
    /// the pictures entitlement. See ``ExportDestination``.
    public var destinationDisplayPath: String {
        ExportDestination.displayPath(destinationFolder)
    }
}

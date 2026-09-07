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

    public var tab: Tab = .library
    /// Which slider group the sheet / panel / rail is showing.
    public var activeGroupKey: String = SliderPanelLayout.defaultSectionKey
    public var macTool: MacTool = .pan
    public var subject: Subject = .female
    public var libraryFilter: LibraryFilter = .all
    /// The macOS sidebar's "★ 3+" chip.
    public var showsThreeStarsAndUp = false
    public var isShowingExport = false
    public var export = ExportOptions()

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
    /// one; the row then shows `~/Pictures/RetouchPro` as the placeholder the
    /// mockup uses.
    public var destinationFolder: URL?

    public init() {}

    public var destinationDisplayPath: String {
        guard let destinationFolder else { return "~/Pictures/RetouchPro" }
        return destinationFolder.path.replacingOccurrences(
            of: NSHomeDirectory(), with: "~")
    }
}

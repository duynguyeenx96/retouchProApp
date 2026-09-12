import Foundation
import Observation
import RPCore

/// Which picker the preset library is showing (docs/PLAN.md §Phase 3).
///
/// Two kinds, **one** screen, one storage layer, one favourites file — the plan
/// says the Looks picker *"dùng chung đúng cơ chế (a), chỉ khác tab hiển thị …
/// và giới hạn `sections` còn mỗi `color`"*, so the only thing that differs here
/// is ``sectionNames``.
public enum PresetLibraryKind: String, CaseIterable, Hashable, Sendable, Identifiable {
    /// "Mẫu" — whole looks: skin, eyes/teeth and colour together.
    case templates
    /// "Looks" — the colour-only swatches of design screen 3d.
    case looks

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .templates: "Mẫu"
        case .looks: "Looks"
        }
    }

    /// The `Preset` sections this kind reads and writes.
    ///
    /// `.templates` takes everything a preset may carry — i.e. every section
    /// except the per-image data `Preset` already drops. `.looks` is exactly
    /// `[color]`, which is what `Preset.init(from:limitedTo:)` gets when the
    /// user saves one and what ``EditState/applying(_:replacingSections:)``
    /// replaces when they apply one, so a Look can never disturb skin work.
    public var sectionNames: Set<String> {
        switch self {
        case .templates: Set(EditState.SectionKey.all)
        case .looks: [EditState.SectionKey.color]
        }
    }

    var builtInKind: BuiltInPresets.Kind {
        switch self {
        case .templates: .template
        case .looks: .look
        }
    }

    /// The `Preset.group` string presets of this kind carry, so a saved preset
    /// still knows which picker it belongs in after a round trip through disk.
    public var groupName: String { builtInKind.groupName }
}

/// The three tabs of both pickers.
///
/// **"Nổi bật", not the mockup's "Cho bạn"** — decided 2026-09-11 (see
/// `docs/design/SPEC.md` §Turn 3 "Tab rename" and `BuiltInPresets`): the list is
/// static and identical for everyone, and a "for you" label would promise
/// personalisation that is a later feature (Phase 6.6, "Tự động v2"). Nothing in
/// this file computes a recommendation, by design.
public enum PresetLibraryTab: String, CaseIterable, Hashable, Sendable, Identifiable {
    case featured
    case mine
    case favorites

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .featured: "Nổi bật"
        case .mine: "Của tôi"
        case .favorites: "Yêu thích"
        }
    }
}

/// The preset library's own state: what is in the two stores, what is starred,
/// and which tab is up.
///
/// It owns **reading and writing presets**; applying one to a photo is
/// `EditorModel`'s job (it owns the project and the `EditState`). Splitting it
/// that way keeps this type testable with nothing but a temporary directory.
@MainActor
@Observable
public final class PresetLibraryModel {
    /// The user's cross-project presets ("Của tôi"). `nil` only if Application
    /// Support could not be resolved, in which case the tab says so instead of
    /// silently showing an empty list.
    public let store: PresetLibraryStore?

    public var kind: PresetLibraryKind
    public var tab: PresetLibraryTab = .featured
    public private(set) var mine: [Preset] = []
    public private(set) var favorites: Set<PresetID> = []
    public private(set) var lastErrorMessage: String?

    public init(kind: PresetLibraryKind = .templates, store: PresetLibraryStore? = nil) {
        self.kind = kind
        if let store {
            self.store = store
        } else {
            self.store = try? PresetLibraryStore.default()
        }
    }

    // MARK: - Contents

    /// The built-in presets of the current kind — read-only, shipped in the app
    /// bundle.
    public var featured: [Preset] { BuiltInPresets.all(of: kind.builtInKind) }

    /// The user's presets of the current kind.
    ///
    /// A preset with **no** group is shown under "Mẫu": that is what a preset
    /// saved by an earlier build (or copied out of a project's `presets/`
    /// folder) looks like, and hiding it would make it unreachable.
    public var mineForKind: [Preset] {
        mine.filter { preset in
            if let group = preset.group { return group == kind.groupName }
            return kind == .templates
        }
    }

    /// Starred presets of the current kind, built-in ones included — a favourite
    /// is only an id, so both stores contribute.
    public var favoritePresets: [Preset] {
        (featured + mineForKind).filter { favorites.contains($0.id) }
    }

    /// What the visible tab should list.
    public var visiblePresets: [Preset] {
        switch tab {
        case .featured: featured
        case .mine: mineForKind
        case .favorites: favoritePresets
        }
    }

    /// Why the visible tab is empty, or `nil` when it is not empty.
    public var emptyMessage: String? {
        guard visiblePresets.isEmpty else { return nil }
        switch tab {
        case .featured:
            return
                "Không đọc được preset dựng sẵn trong bản dựng này."
        case .mine:
            return store == nil
                ? "Không mở được thư mục preset của máy này."
                : "Chưa có preset nào. Dùng \"Lưu preset\" để lưu thiết lập đang chỉnh."
        case .favorites:
            return "Chưa đánh dấu preset nào."
        }
    }

    public func isBuiltIn(_ preset: Preset) -> Bool { BuiltInPresets.isBuiltIn(preset.id) }

    public func isFavorite(_ preset: Preset) -> Bool { favorites.contains(preset.id) }

    // MARK: - Reading

    public func reload() async {
        guard let store else {
            mine = []
            favorites = []
            return
        }
        do {
            mine = try await Task.detached { try store.listPresets() }.value
        } catch {
            mine = []
            lastErrorMessage = "Không đọc được preset của bạn: \(error)"
        }
        favorites = await Task.detached { store.loadFavorites() }.value
    }

    // MARK: - Writing

    /// Stars / unstars a preset. Built-in presets can be starred too — that is
    /// the point of keeping favourites outside the preset document.
    public func toggleFavorite(_ preset: Preset) {
        guard let store else { return }
        let shouldBeFavorite = !favorites.contains(preset.id)
        do {
            favorites = try store.setFavorite(shouldBeFavorite, for: preset.id)
        } catch {
            lastErrorMessage = "Không lưu được \"Yêu thích\": \(error)"
        }
    }

    /// Saves the look currently on screen as a preset of the visible kind.
    ///
    /// `Preset.init(from:limitedTo:)` does the section filtering, which is what
    /// makes a preset saved from the Looks picker colour-only. Per-image data is
    /// dropped by that initialiser, not here.
    @discardableResult
    public func savePreset(named name: String, from editState: EditState) -> Preset? {
        guard let store else {
            lastErrorMessage = "Không mở được thư mục preset của máy này."
            return nil
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = Preset(
            name: trimmed.isEmpty ? defaultPresetName() : trimmed,
            group: kind.groupName,
            from: editState,
            limitedTo: kind.sectionNames
        )
        do {
            try store.savePreset(preset)
            mine.insert(preset, at: 0)
            tab = .mine
            return preset
        } catch {
            lastErrorMessage = "Không lưu được preset: \(error)"
            return nil
        }
    }

    /// Deletes one of the user's presets. Built-in presets are not deletable —
    /// there is no file of theirs to delete.
    public func delete(_ preset: Preset) {
        guard let store, !isBuiltIn(preset) else { return }
        do {
            try store.deletePreset(id: preset.id)
            mine.removeAll { $0.id == preset.id }
            favorites.remove(preset.id)
        } catch {
            lastErrorMessage = "Không xoá được preset: \(error)"
        }
    }

    public func dismissError() { lastErrorMessage = nil }

    /// "Mẫu 3" / "Looks 2" — the next free number for this kind, so saving
    /// twice in a row does not produce two presets with the same name.
    public func defaultPresetName() -> String {
        let existing = Set(mineForKind.map(\.name))
        var index = mineForKind.count + 1
        while existing.contains("\(kind.title) \(index)") { index += 1 }
        return "\(kind.title) \(index)"
    }
}

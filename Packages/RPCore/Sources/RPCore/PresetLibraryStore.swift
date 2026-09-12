import Foundation

/// The user's own presets, **outside** any one `.rpproj` (docs/PLAN.md §Phase 3,
/// "kho preset toàn cục ngoài project").
///
/// `ProjectStore` already does preset CRUD, but only inside the bundle it owns:
/// a preset saved while "Shoot 2026-09-11" is open cannot be seen from the next
/// shoot. "Của tôi" has to survive projects, so it needs a second root — and
/// nothing else. Everything here is deliberately the same machinery as
/// `ProjectStore`:
///
/// * the same ``Preset`` value and the same one-file-per-preset layout
///   (`presets/<preset id>.json`), so a preset can be copied between the two
///   stores by value with no conversion;
/// * the same ``AtomicFileWriter``, so a global preset cannot be left truncated
///   by a crash mid-write any more than a project's can;
/// * the same "an unreadable file is skipped, not fatal" rule in ``listPresets``.
///
/// **Root.** `Application Support/RetouchPro/PresetLibrary/` on both platforms —
/// one code path, because `FileManager.applicationSupportDirectory` already
/// resolves to `~/Library/Application Support` on macOS and to the app
/// container's `Library/Application Support` on iOS. It is not in `Documents/`
/// on purpose: this is app data the user never browses as files, and on iOS
/// `Documents/` is what shows up in the Files app.
///
/// **Favourites live here too**, in one `favorites.json` next to the presets,
/// rather than as a `Preset` field. Two reasons: a favourite is a property of
/// *this install*, not of the preset document (copying a preset to a project
/// must not carry someone's star), and the built-in presets are read-only —
/// a bool on `Preset` could never be flipped for them (docs/PLAN.md Phase 3 (c)
/// explicitly allows either shape).
public struct PresetLibraryStore: Sendable {
    /// Directory holding `presets/` and `favorites.json`.
    public let rootURL: URL
    public var writer: AtomicFileWriter

    public init(rootURL: URL, writer: AtomicFileWriter = AtomicFileWriter()) {
        self.rootURL = rootURL.standardizedFileURL
        self.writer = writer
    }

    /// The real, per-user library. Throws only if Application Support itself
    /// cannot be resolved, which on a sandboxed app means something is very
    /// wrong.
    public static func `default`(fileManager: FileManager = .default) throws -> PresetLibraryStore {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return PresetLibraryStore(
            rootURL:
                support
                .appendingPathComponent(directoryName, isDirectory: true)
                .appendingPathComponent(libraryDirectoryName, isDirectory: true)
        )
    }

    /// `Application Support/RetouchPro`. Named here so anything else the app
    /// puts beside the preset library uses the same folder.
    public static let directoryName = "RetouchPro"
    public static let libraryDirectoryName = "PresetLibrary"
    public static let favoritesFileName = "favorites.json"

    public var presetsURL: URL {
        rootURL.appendingPathComponent(ProjectBundle.presetsDirectory, isDirectory: true)
    }

    public var favoritesURL: URL {
        rootURL.appendingPathComponent(Self.favoritesFileName)
    }

    public func presetURL(for presetID: PresetID) -> URL {
        presetsURL.appendingPathComponent("\(presetID.rawValue).json")
    }

    public func createDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: presetsURL, withIntermediateDirectories: true)
    }

    // MARK: - Presets

    /// Every readable preset, newest first.
    ///
    /// Newest first — not by name like `ProjectStore.listPresets()` — because
    /// this list is the user's own saves and the one they just made is the one
    /// they are looking for. Ties break on id so the order is still total and
    /// stable.
    public func listPresets(fileManager: FileManager = .default) throws -> [Preset] {
        guard fileManager.fileExists(atPath: presetsURL.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(
            at: presetsURL, includingPropertiesForKeys: nil)
        let presets: [Preset] = files
            .filter {
                $0.pathExtension.lowercased() == "json" && !$0.lastPathComponent.hasPrefix(".")
            }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? RPJSON.decoder.decode(Preset.self, from: data)
            }
        return presets.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }
    }

    public func loadPreset(id: PresetID, fileManager: FileManager = .default) throws -> Preset {
        let url = presetURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ProjectStoreError.presetNotFound(id)
        }
        return try RPJSON.decoder.decode(Preset.self, from: try Data(contentsOf: url))
    }

    public func savePreset(_ preset: Preset, fileManager: FileManager = .default) throws {
        try createDirectories(fileManager: fileManager)
        try writer.writeJSON(preset, to: presetURL(for: preset.id))
    }

    /// Deletes a preset **and** its favourite flag — leaving the flag behind
    /// would silently re-star a future preset that happened to reuse the id.
    public func deletePreset(id: PresetID, fileManager: FileManager = .default) throws {
        let url = presetURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ProjectStoreError.presetNotFound(id)
        }
        try fileManager.removeItem(at: url)
        _ = try? setFavorite(false, for: id, fileManager: fileManager)
    }

    // MARK: - Favourites

    /// Starred preset ids — built-in **or** user-made, since a favourite is only
    /// an id.
    ///
    /// A missing or corrupt file reads as "nothing starred" rather than
    /// throwing: losing the stars is annoying, refusing to open the library is
    /// worse.
    public func loadFavorites(fileManager: FileManager = .default) -> Set<PresetID> {
        guard let data = try? Data(contentsOf: favoritesURL),
            let document = try? RPJSON.decoder.decode(FavoritesDocument.self, from: data)
        else { return [] }
        return Set(document.favorites)
    }

    public func saveFavorites(_ favorites: Set<PresetID>, fileManager: FileManager = .default) throws
    {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try writer.writeJSON(FavoritesDocument(favorites: favorites.sorted()), to: favoritesURL)
    }

    /// Returns the new favourites set so the caller does not have to re-read it.
    @discardableResult
    public func setFavorite(
        _ isFavorite: Bool, for presetID: PresetID, fileManager: FileManager = .default
    ) throws -> Set<PresetID> {
        var favorites = loadFavorites(fileManager: fileManager)
        if isFavorite {
            favorites.insert(presetID)
        } else {
            favorites.remove(presetID)
        }
        try saveFavorites(favorites, fileManager: fileManager)
        return favorites
    }

    /// `favorites.json`. An envelope rather than a bare array so a later field
    /// (an order, a sync stamp) does not need a migration.
    struct FavoritesDocument: Codable, Sendable {
        var favorites: [PresetID]
    }
}

import Foundation

/// The presets that ship **inside the app** — the "Nổi bật" tab of both the
/// template library (Mẫu) and the Looks picker (docs/PLAN.md §Phase 3, item (a)).
///
/// Read-only by construction: they are `Preset` JSON files in the package's
/// resource bundle, so there is nowhere to write them back to. The library UI
/// therefore offers no rename/delete for them, and "editing" one means applying
/// it and saving the result into ``PresetLibraryStore`` as a new preset of the
/// user's own.
///
/// **The tab is called "Nổi bật", not "Cho bạn"** (decided 2026-09-11,
/// `docs/design/SPEC.md` §Turn 3 "Tab rename"): this list is static and curated,
/// identical for every user, and a "for you" label over a static list promises
/// personalisation the app does not do. Real personalisation is Phase 6.6
/// ("Tự động v2", by recognised face) and deliberately nothing here computes a
/// recommendation.
///
/// ## Two kinds, one mechanism
///
/// ``Kind/template`` presets carry whole looks (skin + eyes/teeth + colour);
/// ``Kind/look`` presets are the five colour swatches of design screen 3d
/// (Gốc, Tự nhiên, Normcore, Sữa, Điện ảnh) and carry **only** the `color`
/// section — they are built with `Preset.init(from:limitedTo:)`'s section
/// filter, which is why applying one in `.merge` mode leaves a user's skin work
/// alone. Nothing else differs: same type, same decoder, same favourites.
public enum BuiltInPresets {
    public enum Kind: String, CaseIterable, Sendable {
        /// Full looks — the "Mẫu" gallery.
        case template
        /// Colour-only swatches — the "Looks / AI Retouch" picker.
        case look

        /// Sub-directory inside the resource bundle.
        var directoryName: String {
            switch self {
            case .template: "templates"
            case .look: "looks"
            }
        }

        /// The `Preset.group` every preset of this kind must declare. It is what
        /// ``kind(of:)`` reads back, so a preset that travels into a project or
        /// into the user's library keeps saying which picker it came from.
        public var groupName: String {
            switch self {
            case .template: "Mẫu"
            case .look: "Looks"
            }
        }
    }

    /// Full-look presets, in the order the gallery shows them.
    public static var templates: [Preset] { all(of: .template) }

    /// The five colour swatches, in the mockup's order (Gốc first).
    public static var looks: [Preset] { all(of: .look) }

    /// Both kinds, templates first.
    public static var all: [Preset] { templates + looks }

    public static func all(of kind: Kind) -> [Preset] { cache.presets(of: kind) }

    public static func preset(id: PresetID) -> Preset? {
        all.first { $0.id == id }
    }

    /// Which picker a preset belongs to, or `nil` for a user-made preset that
    /// declares no group.
    public static func kind(of preset: Preset) -> Kind? {
        Kind.allCases.first { $0.groupName == preset.group }
    }

    public static func isBuiltIn(_ presetID: PresetID) -> Bool {
        all.contains { $0.id == presetID }
    }

    /// `true` when the resource bundle produced nothing — the symptom of a
    /// packaging mistake, which on a real device is otherwise invisible
    /// (`.claude/agents/coder.md` step 6: a resource path that works on macOS
    /// and the Simulator can silently fail in a device's sandbox). The app logs
    /// this at launch instead of showing an empty tab with no explanation.
    public static var isEmpty: Bool { all.isEmpty }

    /// Directory the JSON is read from, exposed for diagnostics only.
    public static var resourceRootURL: URL? { Bundle.module.resourceURL }

    // MARK: - Loading

    /// Decoded once. The files never change at runtime, and the library UI asks
    /// for this list on every keystroke of its filter.
    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var loaded: [Kind: [Preset]] = [:]

        func presets(of kind: Kind) -> [Preset] {
            lock.lock()
            defer { lock.unlock() }
            if let cached = loaded[kind] { return cached }
            let presets = BuiltInPresets.load(kind)
            loaded[kind] = presets
            return presets
        }
    }

    /// Reads `<bundle>/BuiltInPresets/<kind>/*.json`.
    ///
    /// Ordering is by **file name**, and the files are numbered (`01-goc.json`)
    /// for exactly that reason: the display order of a curated list is a product
    /// decision, and putting it in the file name keeps it out of the `Preset`
    /// schema, which has no `order` field and does not need one.
    ///
    /// A file that fails to decode is skipped, like `ProjectStore.listPresets()`
    /// — one bad resource must not empty the tab.
    private static func load(_ kind: Kind) -> [Preset] {
        let bundle = Bundle.module
        guard
            let root = bundle.resourceURL?
                .appendingPathComponent(resourceDirectoryName, isDirectory: true)
                .appendingPathComponent(kind.directoryName, isDirectory: true),
            let files = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
        else { return [] }

        return
            files
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                    let preset = try? RPJSON.decoder.decode(Preset.self, from: data)
                else { return nil }
                return preset
            }
    }

    static let resourceDirectoryName = "BuiltInPresets"
}

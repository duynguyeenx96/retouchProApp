import Foundation
import RPCore

/// A launch-time run through the **preset library** against a real project on
/// the device, driven by the same objects the "Mẫu" screen drives.
///
/// ## Why this exists
///
/// Same reason as ``ExportSelfTest`` and `App/FaceSelfTest` (docs/ADR-0015):
/// the two halves of Phase 3's preset feature are exactly the sandbox-shaped
/// kind of surface that unit tests on macOS cannot cover.
///
/// 1. **"Nổi bật"** is JSON read out of `Bundle.module` — RPCore's resource
///    bundle. A resource that resolves on macOS and in the Simulator (both
///    share the Mac's filesystem, and SwiftPM has a `#filePath` fallback there)
///    can come back empty inside a device's app container. An empty tab looks
///    exactly like a short curated list.
/// 2. **"Của tôi"** writes into `Application Support` — a directory that exists
///    on the Mac whether or not the app is entitled to it, and that on iOS is
///    inside the container and is *not* created for you.
///
/// Nobody can tap through the library from a script, so this is one
/// env-var-gated path through the product objects: ``PresetLibraryModel`` for
/// the stores and ``EditorModel/applyPreset(_:replacingSections:scope:)`` for
/// the apply — the "Áp dụng" button's action minus the tap.
///
/// ```
/// xcrun devicectl device process launch --console --device <udid> \
///   --environment-variables '{"RP_PRESET_SELFTEST":"1"}' com.duynguyen.RetouchPro
/// ```
///
/// **It leaves the device as it found it**: the photo's `EditState` is restored
/// after the apply is verified on disk, the preset it saves is deleted, and the
/// star it sets is cleared. It is off unless the variable is set.
public enum PresetSelfTest {
    public static let environmentKey = "RP_PRESET_SELFTEST"

    /// What `RP_PRESET_SELFTEST` may hold — the same two shapes
    /// ``ExportSelfTest/Target`` takes, so one habit covers both.
    public enum Target: Equatable, Sendable {
        /// `1` / `first-shot`: the first shot of the most recently modified
        /// project.
        case firstShot
        /// A bare original file name (`DSC05259.jpg`), looked up across projects.
        case fileName(String)

        public init?(_ raw: String) {
            let value = raw.trimmingCharacters(in: .whitespaces)
            switch value {
            case "": return nil
            case "1", "first-shot", "first": self = .firstShot
            default: self = .fileName(value)
            }
        }

        /// Reuses ``ExportSelfTest``'s resolver rather than repeating it: "find
        /// the project holding this photo" is the same question.
        var exportTarget: ExportSelfTest.Target {
            switch self {
            case .firstShot: .firstShot
            case .fileName(let name): .fileName(name)
            }
        }
    }

    public static func target(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Target? {
        environment[environmentKey].flatMap(Target.init)
    }

    /// Reports every step through `log`; never throws and never touches the
    /// `EditorModel` the user is looking at (it opens its own).
    @MainActor
    public static func run(target: Target, log: @escaping (String) -> Void) async {
        log(
            "preset-selftest: built-in \(BuiltInPresets.templates.count) mẫu + "
                + "\(BuiltInPresets.looks.count) looks from "
                + (BuiltInPresets.resourceRootURL?.path ?? "NO RESOURCE URL"))
        guard !BuiltInPresets.isEmpty else {
            log("preset-selftest: FAILED — the app bundle yielded no built-in presets")
            return
        }

        await runStoreChecks(log: log)
        await runApplyCheck(target: target, log: log)
    }

    // MARK: - "Của tôi" + favourites

    /// Saves, re-reads through a *second* store over the same root (what a
    /// relaunch sees), stars a built-in preset, then undoes both.
    @MainActor
    private static func runStoreChecks(log: @escaping (String) -> Void) async {
        guard let store = try? PresetLibraryStore.default() else {
            log("preset-selftest: FAILED — Application Support is unavailable in this container")
            return
        }
        log("preset-selftest: của tôi root \(store.rootURL.path)")

        let library = PresetLibraryModel(kind: .looks, store: store)
        await library.reload()
        let before = library.mineForKind.count

        var state = EditState()
        state.setSlider("exposure", in: EditState.SectionKey.color, to: 12)
        state.setSlider("smooth", in: EditState.SectionKey.skin, to: 40)
        guard let saved = library.savePreset(named: "selftest-\(UUID().uuidString.prefix(4))", from: state)
        else {
            log("preset-selftest: FAILED — save — \(library.lastErrorMessage ?? "no reason given")")
            return
        }
        // A Look carries colour only; the skin slider above must not have
        // travelled with it.
        log(
            "preset-selftest: saved \"\(saved.name)\" sections "
                + "\(saved.carriedSectionNames.sorted().joined(separator: ","))")

        let relaunched = PresetLibraryModel(kind: .looks, store: store)
        await relaunched.reload()
        let readBack = relaunched.mineForKind.first { $0.id == saved.id }
        log(
            readBack == nil
                ? "preset-selftest: FAILED — \(saved.id.rawValue) is not on disk after a reload"
                : "preset-selftest: OK persisted — của tôi now \(relaunched.mineForKind.count), was \(before)")

        let builtIn = BuiltInPresets.looks[1]
        relaunched.toggleFavorite(builtIn)
        // A third store over the same root: the star has to be in the file, not
        // only in the model that set it.
        let starred = (try? PresetLibraryStore.default())?.loadFavorites().contains(builtIn.id)
        log(
            starred == true
                ? "preset-selftest: OK favourite \(builtIn.name) is in favorites.json"
                : "preset-selftest: FAILED — favourite did not reach disk")

        // Leave the device as found.
        relaunched.toggleFavorite(builtIn)
        relaunched.delete(saved)
        log("preset-selftest: cleaned up (preset deleted, star cleared)")
    }

    // MARK: - Applying to a real photo

    /// Applies the "Điện ảnh" Look to a real shot, checks `edits/<id>.json` on
    /// disk, and puts the previous document back.
    @MainActor
    private static func runApplyCheck(target: Target, log: @escaping (String) -> Void) async {
        let libraryRoot = try? ProjectLibrary.defaultRoot()
        let resolution: ExportSelfTest.Resolution
        switch ExportSelfTest.resolve(target.exportTarget, libraryRoot: libraryRoot) {
        case .resolved(let value): resolution = value
        case .failure(let reason):
            log("preset-selftest: cannot apply — \(reason)")
            return
        }

        let model: EditorModel
        do {
            model = try await EditorModel.open(bundleURL: resolution.bundleURL)
        } catch {
            log("preset-selftest: cannot open \(resolution.bundleURL.lastPathComponent): \(error)")
            return
        }
        if let name = resolution.originalFileName,
            let shot = model.shots.first(where: { $0.originalFileName == name })
        {
            await model.select(shotID: shot.id)
        }
        guard let shot = model.activeShot else {
            log("preset-selftest: \(resolution.bundleURL.lastPathComponent) has no active shot")
            return
        }

        let original = model.activeEditState
        let look = BuiltInPresets.looks[4]  // "Điện ảnh"
        let count = await model.applyPreset(
            look, replacingSections: PresetLibraryKind.looks.sectionNames)

        let onDisk = (try? model.store.loadEditState(for: shot.id)) ?? EditState()
        let colour = onDisk[section: EditState.SectionKey.color]
        let matches = colour == (look.sections[EditState.SectionKey.color] ?? EditSection())
        log(
            "preset-selftest: applied \"\(look.name)\" to \(shot.originalFileName) "
                + "(\(count) ảnh) — edits/<id>.json colour \(summary(of: colour)) "
                + (matches ? "OK" : "FAILED — does not match the preset"))

        // Restore, so a self-test run never edits the user's photo.
        model.replaceActiveEditState(original)
        await model.commitEditState()
        let restored = (try? model.store.loadEditState(for: shot.id)) ?? EditState()
        log(
            restored == original
                ? "preset-selftest: restored the previous edit state"
                : "preset-selftest: WARNING — could not restore the previous edit state")
    }

    private static func summary(of section: EditSection) -> String {
        let pairs = section.values.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.numberValue.map { Int($0) }.map(String.init) ?? "?")" }
        return pairs.isEmpty ? "{}" : "{\(pairs.joined(separator: " "))}"
    }
}

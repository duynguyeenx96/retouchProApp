import Foundation
import RPCore

/// Where a preset lands (docs/PLAN.md §Phase 3: *"áp cho ảnh chọn / cả project,
/// auto-apply mọi ảnh mới vào project"*).
///
/// There is no "the selected photos" case because the filmstrip has exactly one
/// selection (`FilmstripSelection.activeShotID`); multi-select is not a thing
/// this app has, so offering a control for it would be a lie.
public enum PresetApplyScope: String, CaseIterable, Hashable, Sendable, Identifiable {
    /// The photo on the canvas.
    case activeShot
    /// Every photo in the project, the one on the canvas included.
    case allShots

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .activeShot: "Ảnh này"
        case .allShots: "Cả project"
        }
    }
}

/// Applying presets — the write half of the preset library.
///
/// Kept out of `EditorModel.swift` because it is a self-contained Phase 3
/// feature, and kept *in* `EditorModel` (rather than in the library's own model)
/// because only this type owns the project, the `EditState` and the live
/// preview. The library UI reads the two stores; everything that touches a photo
/// goes through here.
extension EditorModel {

    /// Applies `preset` to the chosen photos.
    ///
    /// **Which sections are touched is the preset kind's business, not the
    /// preset's**: a Look replaces `color` and nothing else even if it happens
    /// to be empty (that is what "Gốc" means), while a template replaces every
    /// section it is allowed to carry. `EditState.perImage` — the face
    /// selection, later the crop — is never touched by either, so applying a
    /// preset cannot silently retarget the sliders onto a different face.
    ///
    /// Returns the number of photos actually written.
    @discardableResult
    public func applyPreset(
        _ preset: Preset,
        replacingSections sectionNames: Set<String>,
        scope: PresetApplyScope = .activeShot
    ) async -> Int {
        switch scope {
        case .activeShot:
            guard activeShot != nil else { return 0 }
            replaceActiveEditState(
                activeEditState.applying(preset, replacingSections: sectionNames))
            await commitEditState()
            return 1

        case .allShots:
            let activeID = activeShot?.id
            if activeID != nil {
                replaceActiveEditState(
                    activeEditState.applying(preset, replacingSections: sectionNames))
                await commitEditState()
            }
            let store = self.store
            let others = project.shots.map(\.id).filter { $0 != activeID }
            let written = await Task.detached { () -> Int in
                var count = 0
                for id in others {
                    // One unreadable document must not abort the batch: it is
                    // replaced by a fresh state carrying only the preset, which
                    // is what the user asked for anyway.
                    let current = (try? store.loadEditState(for: id)) ?? EditState()
                    let updated = current.applying(preset, replacingSections: sectionNames)
                    guard updated != current else { continue }
                    do {
                        try store.saveEditState(updated, for: id)
                        count += 1
                    } catch {
                        continue
                    }
                }
                return count
            }.value
            await refreshEditedIndex()
            return written + (activeID == nil ? 0 : 1)
        }
    }

    /// Arms `preset` for **every photo imported from now on**, including the
    /// ones the folder watcher and the MTP importer bring in
    /// (`RPImport.ShotIngestor` reads this through
    /// `ProjectStore.autoApplyEditState(for:)`).
    ///
    /// The preset is **copied into the project's `presets/` folder** first. That
    /// is the whole reason this is not a one-line assignment: a built-in preset
    /// lives in the app bundle and a "Của tôi" preset lives in Application
    /// Support, and a project whose auto-apply pointed at either would stop
    /// working the moment the bundle moved to another machine. After this call
    /// the project is self-contained.
    public func setAutoApplyPreset(_ preset: Preset) async {
        do {
            try await withProject { project, store in
                try store.savePreset(preset)
                project.autoApplyPresetID = preset.id
                if !project.presetOrder.contains(preset.id) {
                    project.presetOrder.append(preset.id)
                }
                project = try store.save(project, touchingModifiedAt: Date())
            }
            await refresh()
            await reloadPresets()
        } catch {
            report("Không đặt được preset tự động: \(error)")
        }
    }

    /// Disarms auto-apply. The copied preset stays in `presets/` — it is the
    /// project's own library now, and deleting a file because a toggle was
    /// turned off would be surprising.
    public func clearAutoApplyPreset() async {
        do {
            try await withProject { project, store in
                project.autoApplyPresetID = nil
                project = try store.save(project, touchingModifiedAt: Date())
            }
            await refresh()
        } catch {
            report("Không bỏ được preset tự động: \(error)")
        }
    }

    /// The preset armed for new imports, if it is still readable.
    public var autoApplyPreset: Preset? {
        guard let id = project.autoApplyPresetID else { return nil }
        return presets.first { $0.id == id } ?? BuiltInPresets.preset(id: id)
    }

    public func isAutoApply(_ preset: Preset) -> Bool {
        project.autoApplyPresetID == preset.id
    }
}

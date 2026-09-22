import Foundation
import RPCore
import RPEngine

/// Where a preset lands (docs/PLAN.md §Phase 3: *"áp cho ảnh chọn / cả project,
/// auto-apply mọi ảnh mới vào project"*).
///
/// There is no "the selected photos" case even though the filmstrip *does* now
/// have a batch selection (`FilmstripSelection.selectedShotIDs`). The preset
/// library is a modal screen with no filmstrip on it, so a third scope there
/// would point at a selection the user cannot see while choosing. Applying a
/// look to a hand-picked set is the copy/paste-settings path instead
/// (`EditorModel+CopySettings.swift`), which is driven from the strip itself.
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

/// One preset selected in the library, waiting on the "Cường độ" slider
/// before it is committed to the open photo — see
/// ``EditorModel/selectPresetForApply(_:)``.
public struct PresetIntensityPreview: Sendable, Equatable {
    public let presetID: PresetID
    /// Which sections applying this preset is allowed to touch —
    /// ``Preset/inferredKind``'s `sectionNames`, fixed for the life of one
    /// preview even if the preset's own tag could theoretically change under
    /// it (it cannot, in practice, but the type does not need to know that).
    let sectionNames: Set<String>
    /// The preset's own sections, exactly as saved — a key absent here reads
    /// as neutral (0) for every key inside `sectionNames`, not "untouched".
    let presetSections: [String: EditSection]
    /// The shot's own state before this preset was selected.
    public let baseline: EditState
    /// 0…100, default 100 — the preset at full strength, exactly like
    /// selecting it promises before the slider has been touched.
    public var intensity: Double = 100
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

    // MARK: - Applying with intensity

    /// Selects `preset` for the "Cường độ" slider (2026-09-22, replacing the
    /// old "Áp cho" scope row + "Áp dụng" button): picking it previews the
    /// look immediately at full strength, live on the canvas next to the
    /// panel — the visual feedback hovering used to give, now folded into
    /// selection since a user has to select before the slider means anything
    /// anyway. Dragging the slider afterwards dials the strength up or down;
    /// ``commitPresetApply()`` on release is the one call that reaches disk,
    /// the same "drag previews, release commits" contract every slider in
    /// this app follows.
    ///
    /// Selecting a **second** preset without committing the first keeps the
    /// original baseline rather than starting from the half-applied first
    /// one — switching around while browsing must always compare against the
    /// photo as it actually was, not wherever the last preview left it.
    public func selectPresetForApply(_ preset: Preset) {
        guard activeShot != nil else { return }
        let baseline = presetApply?.baseline ?? activeEditState
        presetApply = PresetIntensityPreview(
            presetID: preset.id, sectionNames: preset.inferredKind.sectionNames,
            presetSections: preset.sections, baseline: baseline, intensity: 100)
        applyPresetIntensityPreview()
    }

    /// Moves the intensity slider — memory and GPU preview only.
    public func setPresetApplyIntensity(_ value: Double) {
        guard presetApply != nil else { return }
        presetApply?.intensity = Slider.clamp(value)
        applyPresetIntensityPreview()
    }

    /// Writes the current blend to disk and clears the pending selection.
    public func commitPresetApply() async {
        guard presetApply != nil else { return }
        presetApply = nil
        await commitEditState()
    }

    /// Deselecting (closing the panel, or about to select a different preset
    /// from a clean slate) restores exactly what was there before. Safe to
    /// call with nothing selected.
    public func cancelPresetApply() {
        guard let preview = presetApply else { return }
        replaceActiveEditState(preview.baseline)
        presetApply = nil
    }

    /// Blends every key of every section `presetApply` scopes, from the
    /// baseline toward whatever the preset holds there (0 — neutral — for a
    /// key the preset does not set), by `intensity / 100`. Whole-section
    /// replace, the way ``EditState/applying(_:replacingSections:)`` itself
    /// works, is what makes "Gốc" reset colour to neutral even though its own
    /// `sections` dictionary is empty — see ``Preset/inferredKind``.
    private func applyPresetIntensityPreview() {
        guard let preview = presetApply else { return }
        var state = preview.baseline
        let t = preview.intensity / 100
        for sectionName in preview.sectionNames {
            var section = state[section: sectionName]
            let presetSection = preview.presetSections[sectionName] ?? EditSection()
            for key in Self.allSliderKeys(inSection: sectionName) {
                let target = presetSection.slider(key)
                let start = section.slider(key)
                guard start != target else { continue }
                section.setSlider(
                    key, to: start + (target - start) * t,
                    range: Slider.range(for: key, in: sectionName))
            }
            state[section: sectionName] = section
        }
        replaceActiveEditState(state)
    }

    /// Every slider parameter a section can hold — RPEngine's own key list for
    /// "Color", RPUI's panel layout (unioned across the several panels that
    /// can share one storage section, e.g. "Mắt" + "Răng" both write
    /// `eyesTeeth`) for the other five. Needed only so a preset that sets a
    /// handful of keys still resets the rest of its section to neutral rather
    /// than leaving them at whatever the photo already had.
    private static func allSliderKeys(inSection sectionName: String) -> Set<String> {
        guard sectionName != EditState.SectionKey.color else { return Set(ColorSliders.Key.all) }
        return Set(
            SliderPanelLayout.sections
                .filter { $0.storageKey == sectionName }
                .flatMap { $0.parameters.map(\.key) })
    }
}

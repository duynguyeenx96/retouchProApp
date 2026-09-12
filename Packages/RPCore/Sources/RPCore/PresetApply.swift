import Foundation

extension EditState {
    /// Applies a preset to **named sections only**, replacing each one whole.
    ///
    /// Neither existing mode does what a grouped picker needs. `.replace` wipes
    /// the sections the preset does not carry — applying a colour-only "Look"
    /// would throw away the user's skin work; `.merge` writes the preset's keys
    /// over whatever is there but cannot *remove* a key, so "Gốc" (the empty
    /// colour preset that means "no look") could never undo the look applied
    /// before it.
    ///
    /// Replacing exactly the named sections gives both: outside `names` nothing
    /// is touched, and inside them the preset is the whole truth, so an empty
    /// preset is a reset of those sections. ``perImage`` is never touched, for
    /// the reason spelled out on ``applying(_:mode:)``.
    public func applying(_ preset: Preset, replacingSections names: Set<String>) -> EditState {
        var result = self
        for name in names {
            result[section: name] = preset.sections[name] ?? EditSection()
        }
        result.additionalValues = additionalValues.merging(preset.additionalValues) { _, new in new }
        result.schemaVersion = Swift.max(schemaVersion, preset.schemaVersion)
        return result
    }
}

extension Preset {
    /// The namespaces this preset actually carries (empty sections do not
    /// count). Used by the library to say "Da · Màu" under a preset's name and
    /// by ``EditState/applying(_:replacingSections:)`` callers that want
    /// "replace what this preset is about, leave the rest".
    public var carriedSectionNames: Set<String> {
        Set(sections.filter { !$0.value.isEmpty }.map(\.key))
    }
}

extension ProjectStore {
    /// The `EditState` a **newly imported** shot should start from, or `nil`
    /// when the project has no auto-apply preset.
    ///
    /// This is docs/PLAN.md §Phase 3's *"auto-apply mọi ảnh mới vào project (kể
    /// cả từ FolderWatcher/MTP)"*: `Project.autoApplyPresetID` has existed since
    /// Phase 1 and nothing read it. It is resolved **inside the project's own
    /// `presets/` folder** on purpose — a built-in or a "Của tôi" preset is
    /// copied into the bundle when the user arms it, so a project that is moved
    /// to another machine keeps applying the same look instead of silently
    /// importing raw frames because the global library is not there.
    ///
    /// A missing or unreadable preset file returns `nil` rather than throwing:
    /// an import must not fail because a preset was deleted.
    public func autoApplyEditState(
        for project: Project, fileManager: FileManager = .default
    ) -> EditState? {
        guard let id = project.autoApplyPresetID,
            let preset = try? loadPreset(id: id, fileManager: fileManager)
        else { return nil }
        return EditState().applying(preset, mode: .replace)
    }
}

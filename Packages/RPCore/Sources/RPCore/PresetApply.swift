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

import RPCore
import SwiftUI

/// The project's preset library, **read-only**.
///
/// Presets come from `presets/` via `ProjectStore.listPresets()` in
/// `Project.presetOrder`. Selecting one only highlights it — applying a preset
/// writes an `EditState`, and "apply to a selection / to the whole project /
/// auto-apply on import" is docs/PLAN.md Phase 3.
///
/// **Not on screen right now.** The approved design
/// (docs/design/RetouchPro.dc.html) has no preset bar: its only preset
/// affordance is the disabled "Lưu preset · Phase 3" chip in screen 1b's panel
/// footer (``SliderPanelView``). This view is kept, unchanged in behaviour and
/// still covered by `ViewConstructionTests`, because Phase 3 is where the
/// preset library gets a home again and re-deriving it would be waste.
struct PresetBarView: View {
    @Bindable var model: EditorModel
    @State private var highlighted: PresetID?

    /// The height it had in the Phase 1 shell.
    static let barHeight: CGFloat = 92

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Presets")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if model.project.autoApplyPresetID != nil {
                    Label("auto-apply set", systemImage: "wand.and.stars")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Applying presets is Phase 3")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if model.orderedPresets.isEmpty {
                        Text("This project has no presets yet.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 12)
                    }
                    ForEach(model.orderedPresets) { preset in
                        PresetChip(
                            preset: preset,
                            isAutoApply: preset.id == model.project.autoApplyPresetID,
                            isHighlighted: preset.id == highlighted
                        )
                        .onTapGesture { highlighted = preset.id }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
        }
        .frame(height: Self.barHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
        .task { await model.reloadPresets() }
    }
}

private struct PresetChip: View {
    let preset: Preset
    let isAutoApply: Bool
    let isHighlighted: Bool

    /// Which of the six namespaces this preset carries — the only honest
    /// summary available without a renderer.
    private var sectionSummary: String {
        let names = SliderPanelLayout.sections
            .filter { preset.sections[$0.key]?.isEmpty == false }
            .map(\.title)
        return names.isEmpty ? "empty" : names.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(preset.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if isAutoApply {
                    Image(systemName: "wand.and.stars").font(.caption2)
                }
            }
            Text(sectionSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minWidth: 110, alignment: .leading)
        .background(
            isHighlighted ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isHighlighted ? Color.accentColor : .clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .help("Preset \"\(preset.name)\" — \(sectionSummary)")
    }
}

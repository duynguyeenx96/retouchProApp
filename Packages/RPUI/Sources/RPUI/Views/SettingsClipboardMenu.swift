import RPCore
import SwiftUI

/// The two context-menu entries that make up Lightroom's *Copy Settings* /
/// *Paste Settings*, shared by every surface that shows more than one photo: the
/// macOS filmstrip and the iPhone library grid.
///
/// `.contextMenu` is one implementation for both platforms — right-click on
/// macOS, long-press on iOS — so there is deliberately no `#if os(...)` here.
///
/// **What "paste" means depends on where the menu was opened**, because macOS
/// does not select a cell when you right-click it and guessing wrong would write
/// the wrong files:
///
/// * on a photo that is *in* the batch selection → paste onto the **whole
///   selection**, and say how many;
/// * on a photo that is not → paste onto **that photo only**.
///
/// The entry is disabled, not hidden, when nothing has been copied or when the
/// only target is the photo the settings came from — a menu item that vanishes
/// teaches the user nothing.
struct SettingsClipboardMenuItems: View {
    let model: EditorModel
    let shot: Shot

    /// The photos this menu's paste would write.
    private var targets: [ShotID] {
        model.selection.isSelected(shot.id) && model.selection.isMultiSelecting
            ? model.pasteTargetIDs
            : [shot.id]
    }

    var body: some View {
        Button("Sao chép thiết lập") {
            Task { await model.copySettings(from: shot.id) }
        }

        if let copied = model.copiedSettings {
            let targets = targets
            Button(pasteTitle(count: targets.count, source: copied.sourceFileName)) {
                Task { await model.pasteSettings(to: targets) }
            }
            .disabled(!model.canPasteSettings(into: targets))
        } else {
            Button("Dán thiết lập") {}
                .disabled(true)
        }
    }

    private func pasteTitle(count: Int, source: String) -> String {
        count > 1
            ? "Dán thiết lập của \(source) vào \(count) ảnh đang chọn"
            : "Dán thiết lập của \(source)"
    }
}

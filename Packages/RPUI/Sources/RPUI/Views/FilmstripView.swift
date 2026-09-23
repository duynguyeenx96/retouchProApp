import RPCore
import RPEngine
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// **Screen 1b's filmstrip** — the 104 pt strip under the macOS canvas: 68×76
/// thumbnails with a 2 px mint border on the selected one, and a right-aligned
/// status cluster (`N ảnh · M chọn` · the selected shot's stars · the zoom).
///
/// Shows every shot in `Project.shots` order — the array order *is* the display
/// order (ADR-0002 §1) — and writes the rating back through ``EditorModel``,
/// which goes through `ProjectSession` (ADR-0003 §12).
///
/// It is also where **multi-select** lives (⌘-click, ⇧-click) and therefore
/// where copy/paste settings is driven from: the strip is the one place on the
/// macOS editor screen that shows several photos at once, so "the photos this
/// batch action is about" can be pointed at directly. The selected-but-not-open
/// cells get a dimmer mint border than the open one.
struct FilmstripView: View {
    @Bindable var model: EditorModel
    let cache: PreviewImageCache
    var axis: Axis = .horizontal
    /// Raise the two pickers, which are `.fileImporter` / `.photosPicker`
    /// modifiers on ``EditorView``'s body. `nil` in previews and in the tests
    /// that build this view on its own; the empty state then shows the plain
    /// label it always did.
    var importFromFiles: (() -> Void)?
    var importFromPhotos: (() -> Void)?

    /// Shot the user asked to remove, waiting for the confirmation in
    /// ``ShotRemovalConfirmation``. `nil` means no alert is up.
    @State private var shotPendingRemoval: Shot?

    var body: some View {
        HStack(spacing: 14) {
            ScrollViewReader { proxy in
                ScrollView(axis == .vertical ? .vertical : .horizontal) {
                    strip
                }
                .scrollIndicators(.hidden)
                .onChange(of: model.selection.activeShotID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            if axis == .horizontal {
                statusCluster
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RPTheme.chromeDeep)
        .overlay(alignment: .top) { Rectangle().fill(RPTheme.hairline).frame(height: 1) }
        .overlay {
            if model.shots.isEmpty { emptyLabel }
        }
        .shotRemovalConfirmation($shotPendingRemoval, model: model)
    }

    @ViewBuilder private var strip: some View {
        let cells = ForEach(model.shots) { shot in
            Button {
                click(shot)
            } label: {
                RPThumbnail(
                    request: PreviewRequest(
                        originalURL: model.thumbnailURL(for: shot),
                        maxPixelSize: RPTheme.Metrics.thumbnailPixelSize),
                    cache: cache,
                    aspectRatio: nil,
                    cornerRadius: 4,
                    isSelected: shot.id == model.selection.activeShotID
                ) {
                    RPThumbnailCaption(
                        name: shot.originalFileName, rating: shot.rating, fontSize: 8)
                }
                .frame(
                    width: RPTheme.Metrics.macFilmstripThumbnail.width,
                    height: RPTheme.Metrics.macFilmstripThumbnail.height)
                .overlay { batchSelectionBorder(for: shot) }
            }
            .buttonStyle(.plain)
            .id(shot.id)
            .help(shot.originalFileName)
            .contextMenu {
                SettingsClipboardMenuItems(model: model, shot: shot)
                Divider()
                ratingMenu(for: shot)
                Divider()
                ShotRemovalMenuItem(shot: shot, pending: $shotPendingRemoval)
            }
            .accessibilityLabel(
                "\(shot.originalFileName), \(shot.rating) sao"
                    + (model.selection.isSelected(shot.id) ? ", đã chọn" : ""))
            .accessibilityAddTraits(
                model.selection.isSelected(shot.id) ? [.isButton, .isSelected] : .isButton)
        }

        if axis == .vertical {
            LazyVStack(spacing: 8) { cells }.padding(.vertical, 8)
        } else {
            LazyHStack(spacing: 8) { cells }.padding(.vertical, 14)
        }
    }

    /// A click on a cell. Plain click opens the photo and collapses the batch
    /// selection; **⌘-click** toggles one cell in or out of it and **⇧-click**
    /// takes the range from the anchor — the Finder/Lightroom conventions.
    ///
    /// The modifiers are read from `NSEvent.modifierFlags` inside the button's
    /// action rather than declared as `TapGesture().modifiers(.command)`
    /// simultaneous gestures: those fire *in addition to* the button, so a
    /// ⌘-click would both open the photo and toggle it. One handler, one
    /// outcome. (No marquee drag-select: the strip is a one-row `ScrollView`
    /// where a horizontal drag is already the scroll gesture, so rubber-banding
    /// would fight it for every event. ⌘/⇧-click is the whole MVP, which is what
    /// a filmstrip — as opposed to a 2-D grid — gets in Lightroom too.)
    private func click(_ shot: Shot) {
        model.handleShotClick(shot.id)
    }

    private func batchSelectionBorder(for shot: Shot) -> some View {
        BatchSelectionBorder(model: model, shotID: shot.id, cornerRadius: 4)
    }

    @ViewBuilder
    private func ratingMenu(for shot: Shot) -> some View {
        ForEach(0...5, id: \.self) { value in
            Button {
                Task { await model.setRating(value, for: shot.id) }
            } label: {
                Label(
                    value == 0 ? "Bỏ chấm sao" : String(repeating: "★", count: value),
                    systemImage: shot.rating == value ? "checkmark" : "")
            }
        }
        Divider()
        Button("Chọn (pick)") { Task { await model.toggleFlag(.pick, for: shot.id) } }
        Button("Loại (reject)") { Task { await model.toggleFlag(.reject, for: shot.id) } }
        Button("Bỏ cờ") { Task { await model.setFlag(.unflagged, for: shot.id) } }
    }

    /// `6 ảnh · 1 chọn` · stars · `Fit · 24%`, the cluster on the right of the
    /// mockup's strip. The stars are the **selected shot's** and are
    /// interactive, which is the only rating control on screen 1b.
    private var statusCluster: some View {
        HStack(spacing: 10) {
            Text("\(model.shots.count) ảnh · \(model.selection.selectedShotIDs.count) chọn")
                .font(RPTheme.mono(12))
                .foregroundStyle(RPTheme.textSecondary)
            settingsClipboardCluster
            RPStarRating(
                rating: model.activeShot?.rating ?? 0, size: 15,
                isEnabled: model.activeShot != nil
            ) { value in
                guard let id = model.activeShot?.id else { return }
                Task { await model.toggleRating(value, for: id) }
            }
            divider
            Text(
                model.viewport.isFittingToWindow
                    ? "Fit · \(model.viewport.zoomPercentText)"
                    : model.viewport.zoomPercentText
            )
            .font(RPTheme.mono(12))
            .foregroundStyle(RPTheme.textSecondary)
        }
        .fixedSize()
    }

    /// "Sao chép" / "Dán · N" — the **visible** half of copy-settings.
    ///
    /// The context menu alone would be the Lightroom-faithful answer and a
    /// discoverability trap: a photographer who never right-clicks a thumbnail
    /// would never find the feature. So the buttons appear in the strip's own
    /// status row as soon as the feature is usable — "Sao chép" whenever a photo
    /// is open, "Dán" once something has been copied — and say how many photos
    /// they are about to write.
    @ViewBuilder private var settingsClipboardCluster: some View {
        if model.activeShot != nil {
            divider
            HStack(spacing: 6) {
                RPSecondaryButton(
                    title: "Sao chép", horizontalPadding: 10, verticalPadding: 4, fontSize: 11.5
                ) {
                    Task { await model.copySettingsFromActiveShot() }
                }
                .help("Sao chép thiết lập chỉnh sửa của ảnh đang mở")

                if let copied = model.copiedSettings {
                    RPSecondaryButton(
                        title: "Dán · \(model.pasteTargetIDs.count)",
                        horizontalPadding: 10, verticalPadding: 4, fontSize: 11.5,
                        isEnabled: model.canPasteSettingsIntoSelection
                    ) {
                        Task { await model.pasteSettingsIntoSelection() }
                    }
                    .help(
                        "Dán thiết lập của \(copied.sourceFileName) cho \(model.pasteTargetIDs.count) ảnh đang chọn (⌘-click / ⇧-click để chọn nhiều)"
                    )
                }
            }
            if let message = model.lastSettingsMessage {
                Text(message)
                    .font(RPTheme.text(11))
                    .foregroundStyle(RPTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .leading)
                    .help(message)
                    .accessibilityLabel(message)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 16)
    }

    private var emptyLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray")
                .foregroundStyle(RPTheme.textTertiary)
            Text("Chưa có ảnh nào")
                .font(RPTheme.text(12))
                .foregroundStyle(RPTheme.textSecondary)
            if model.canImport, let importFromFiles {
                RPSecondaryButton(title: "Nhập từ Files…", isEnabled: !model.isImporting, action: importFromFiles)
            }
            if model.canImport, let importFromPhotos {
                RPSecondaryButton(title: "Từ Photos…", isEnabled: !model.isImporting, action: importFromPhotos)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RPTheme.chromeDeep)
    }
}

/// Five stars, click a star to set, click it again to clear. Kept as its own
/// type because the library screens use it too.
struct RatingControl: View {
    let rating: Int
    let setRating: (Int) -> Void

    var body: some View {
        RPStarRating(rating: rating, size: 10, setRating: setRating)
    }
}

extension EditorModel {
    /// One click on a photo cell, in any Mac grid or strip: plain click opens
    /// it and collapses the batch, **⌘-click** toggles it in or out of the
    /// batch, **⇧-click** takes the range from the anchor (Finder/Lightroom).
    /// Shared by the editor filmstrip and the library grid so the two can never
    /// disagree about what a click means again.
    func handleShotClick(_ shotID: ShotID) {
        #if os(macOS)
            let flags = NSEvent.modifierFlags
            if flags.contains(.command) {
                Task { await toggleSelection(shotID: shotID) }
                return
            }
            if flags.contains(.shift) {
                Task { await extendSelection(toShotID: shotID) }
                return
            }
        #endif
        Task { await select(shotID: shotID) }
    }
}

/// The dimmer border on cells that are in the batch selection but are not
/// the open photo — Lightroom's "most selected cell is brighter".
struct BatchSelectionBorder: View {
    let model: EditorModel
    let shotID: ShotID
    let cornerRadius: CGFloat

    var body: some View {
        if shotID != model.selection.activeShotID, model.selection.isSelected(shotID) {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(RPTheme.accent.opacity(0.8), lineWidth: 2)
                .overlay(alignment: .topLeading) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(RPTheme.onAccent, RPTheme.accent)
                        .padding(4)
                }
        }
    }
}

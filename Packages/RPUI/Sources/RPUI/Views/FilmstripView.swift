import RPCore
import RPEngine
import SwiftUI

/// **Screen 1b's filmstrip** — the 104 pt strip under the macOS canvas: 68×76
/// thumbnails with a 2 px mint border on the selected one, and a right-aligned
/// status cluster (`N ảnh · M chọn` · the selected shot's stars · the zoom).
///
/// Shows every shot in `Project.shots` order — the array order *is* the display
/// order (ADR-0002 §1) — and writes the rating back through ``EditorModel``,
/// which goes through `ProjectSession` (ADR-0003 §12).
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
    }

    @ViewBuilder private var strip: some View {
        let cells = ForEach(model.shots) { shot in
            Button {
                Task { await model.select(shotID: shot.id) }
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
            }
            .buttonStyle(.plain)
            .id(shot.id)
            .help(shot.originalFileName)
            .contextMenu { ratingMenu(for: shot) }
            .accessibilityLabel(
                "\(shot.originalFileName), \(shot.rating) sao")
            .accessibilityAddTraits(
                shot.id == model.selection.activeShotID ? [.isButton, .isSelected] : .isButton)
        }

        if axis == .vertical {
            LazyVStack(spacing: 8) { cells }.padding(.vertical, 8)
        } else {
            LazyHStack(spacing: 8) { cells }.padding(.vertical, 14)
        }
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
            Text("\(model.shots.count) ảnh · \(model.activeShot == nil ? 0 : 1) chọn")
                .font(RPTheme.mono(12))
                .foregroundStyle(RPTheme.textSecondary)
            divider
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

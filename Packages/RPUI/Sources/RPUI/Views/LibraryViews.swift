import RPCore
import RPEngine
import SwiftUI

/// The "NGUỒN" rows of screen 2c's sidebar.
///
/// Every row is a **real** predicate over `Project.shots`, not a placeholder.
/// `imported` and `all` do coincide today, and that is honest rather than
/// redundant: the app has exactly one way in (import), so "everything that was
/// imported" *is* "every photo" until Phase 4's tethering adds a second source.
enum LibrarySource: String, CaseIterable, Hashable, Sendable {
    /// Shots imported on the same day as the newest import — one shoot.
    case shoot
    case imported
    /// Edited but never exported. Export is Phase 3, so until then this is
    /// "every shot with edits".
    case drafts
    case all

    func title(project: Project) -> String {
        switch self {
        case .shoot:
            let date = project.shots.map(\.importedAt).max() ?? project.modifiedAt
            return "Buổi chụp · " + Self.dayFormatter.string(from: date)
        case .imported: return "Đã nhập"
        case .drafts: return "Nháp chưa xuất"
        case .all: return "Tất cả ảnh"
        }
    }

    func shots(in project: Project, edited: (Shot) -> Bool) -> [Shot] {
        switch self {
        case .shoot:
            guard let newest = project.shots.map(\.importedAt).max() else { return [] }
            let calendar = Calendar.current
            return project.shots.filter {
                calendar.isDate($0.importedAt, inSameDayAs: newest)
            }
        case .imported, .all:
            return project.shots
        case .drafts:
            return project.shots.filter(edited)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM"
        return formatter
    }()
}

/// Shared filtering for both library screens.
enum LibraryFiltering {
    static func apply(
        _ shots: [Shot],
        filter: EditorChrome.LibraryFilter,
        search: String,
        threeStarsAndUp: Bool = false,
        edited: (Shot) -> Bool
    ) -> [Shot] {
        var result = shots
        switch filter {
        case .all: break
        case .edited: result = result.filter(edited)
        case .raw: result = result.filter(ShotDisplay.isRaw)
        }
        if threeStarsAndUp { result = result.filter { $0.rating >= 3 } }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            result = result.filter { $0.originalFileName.lowercased().contains(query) }
        }
        return result
    }
}

// MARK: - Screen 2a — iPhone library

/// **Screen 2a** — the iPhone library: a title block, a filter pill row, a
/// three-column 3:4 grid, and the dashed import card pinned above the home
/// indicator.
struct PhoneLibraryView: View {
    @Bindable var model: EditorModel
    @Bindable var chrome: EditorChrome
    let cache: PreviewImageCache
    let back: () -> Void
    let importFromFiles: () -> Void
    let importFromPhotos: () -> Void
    /// Opens a shot in the editor (screen 1a).
    let open: (Shot) -> Void

    @State private var isSearching = false
    @State private var search = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    private var shots: [Shot] {
        LibraryFiltering.apply(
            model.shots, filter: chrome.libraryFilter, search: search, edited: model.isEdited)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            filterRow
            if isSearching { searchField }
            grid
            importCard
        }
        .background(RPTheme.canvas)
        .task { await model.refreshEditedIndex() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17))
                    .foregroundStyle(RPTheme.textBright)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Về danh sách dự án")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.project.name)
                    .font(RPTheme.text(22, weight: .bold))
                    .foregroundStyle(RPTheme.textPrimary)
                    .lineLimit(1)
                Text("Lưu trong ứng dụng · \(model.shots.count) ảnh")
                    .font(RPTheme.text(12))
                    .foregroundStyle(RPTheme.textTertiary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button {
                    isSearching.toggle()
                    if !isSearching { search = "" }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundStyle(RPTheme.textPrimary)
                        .frame(width: 34, height: 34)
                        .background(RPTheme.fillNeutral, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tìm ảnh")

                Menu {
                    Button("Từ Files…", action: importFromFiles)
                    Button("Từ Photos…", action: importFromPhotos)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(RPTheme.onAccent)
                        .frame(width: 34, height: 34)
                        .background(RPTheme.accent, in: RoundedRectangle(cornerRadius: 10))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!model.canImport || model.isImporting)
                .accessibilityLabel("Nhập ảnh")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            ForEach(EditorChrome.LibraryFilter.allCases, id: \.self) { filter in
                RPChoicePill(
                    title: filter.title,
                    isSelected: chrome.libraryFilter == filter,
                    fontSize: 12.5, horizontalPadding: 14, verticalPadding: 6,
                    cornerRadius: 999, selectedStyle: .solid
                ) {
                    chrome.libraryFilter = filter
                }
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        TextField("Tên tệp", text: $search)
            .textFieldStyle(.plain)
            .font(RPTheme.text(13))
            .foregroundStyle(RPTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RPTheme.fillNeutral, in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(shots) { shot in
                    Button { open(shot) } label: {
                        RPThumbnail(
                            request: PreviewRequest(
                                originalURL: model.thumbnailURL(for: shot),
                                maxPixelSize: RPTheme.Metrics.thumbnailPixelSize),
                            cache: cache,
                            cornerRadius: 8,
                            isSelected: shot.id == model.selection.activeShotID,
                            formatTag: (
                                ShotDisplay.formatTag(shot), ShotDisplay.isRaw(shot)
                            )
                        ) {
                            RPThumbnailCaption(
                                name: shot.originalFileName, rating: shot.rating,
                                fontSize: 8.5, hasBackground: true)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(shot.originalFileName), \(shot.rating) sao")
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity)
        .overlay {
            if shots.isEmpty {
                Text(
                    model.shots.isEmpty
                        ? "Dự án này chưa có ảnh nào."
                        : "Không có ảnh nào khớp bộ lọc."
                )
                .font(RPTheme.text(13))
                .foregroundStyle(RPTheme.textTertiary)
            }
        }
    }

    private var importCard: some View {
        VStack(spacing: 3) {
            Text("Nhập ảnh để bắt đầu")
                .font(RPTheme.text(13, weight: .semibold))
                .foregroundStyle(RPTheme.textPrimary)
            Text("JPEG · HEIC · RAW (Sony ARW)\nTừ Files hoặc Photos")
                .font(RPTheme.text(11.5))
                .foregroundStyle(RPTheme.textTertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            HStack(spacing: 8) {
                Button(action: importFromFiles) {
                    Text("Files")
                        .font(RPTheme.text(12.5, weight: .semibold))
                        .foregroundStyle(RPTheme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RPTheme.accent, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                Button(action: importFromPhotos) {
                    Text("Photos")
                        .font(RPTheme.text(12.5, weight: .medium))
                        .foregroundStyle(RPTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RPTheme.fillNeutralStrong, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 9)
            .disabled(!model.canImport || model.isImporting)
            .opacity(model.canImport ? 1 : 0.4)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    Color.white.opacity(0.16),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }
}

// MARK: - Screen 2c — macOS library tab

/// **Screen 2c** — the macOS library: a 212 pt sidebar, a five-column grid, and
/// a 268 pt info panel.
struct MacLibraryView: View {
    @Bindable var model: EditorModel
    @Bindable var chrome: EditorChrome
    let cache: PreviewImageCache
    let back: () -> Void
    let importFromFiles: () -> Void
    let importFromPhotos: () -> Void
    let openInEditor: (Shot) -> Void

    @State private var source: LibrarySource = .shoot

    private var sourceShots: [Shot] {
        source.shots(in: model.project, edited: model.isEdited)
    }

    private var shots: [Shot] {
        LibraryFiltering.apply(
            sourceShots, filter: chrome.libraryFilter, search: "",
            threeStarsAndUp: chrome.showsThreeStarsAndUp, edited: model.isEdited)
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(
                model: model, chrome: chrome, back: back,
                importFromFiles: importFromFiles, importFromPhotos: importFromPhotos,
                showsToolGroup: false)
            HStack(spacing: 0) {
                sidebar
                centre
                infoPanel
            }
            .frame(maxHeight: .infinity)
        }
        .background(RPTheme.canvas)
        .task { await model.refreshEditedIndex() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            RPSectionLabel(title: "Nguồn", size: 10.5)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

            ForEach(LibrarySource.allCases, id: \.self) { candidate in
                Button {
                    source = candidate
                } label: {
                    HStack {
                        Text(candidate.title(project: model.project))
                            .font(RPTheme.text(12.5))
                            .foregroundStyle(
                                source == candidate ? RPTheme.accent : RPTheme.textMono)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(candidate.shots(in: model.project, edited: model.isEdited).count)")
                            .font(RPTheme.mono(11))
                            .foregroundStyle(RPTheme.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        source == candidate ? RPTheme.accentRail : .clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(source == candidate ? [.isButton, .isSelected] : .isButton)
            }

            RPSectionLabel(title: "Lọc", size: 10.5)
                .padding(.horizontal, 8)
                .padding(.top, 16)
                .padding(.bottom, 6)

            // Two rows, not one: three chips do not fit across a 212 pt sidebar
            // and SwiftUI wraps the *text* instead of the row ("Đã / chỉnh").
            // The mockup's `flex-wrap` is this.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    RPChoicePill(
                        title: "★ 3+", isSelected: chrome.showsThreeStarsAndUp, fontSize: 11.5,
                        horizontalPadding: 10, verticalPadding: 4, cornerRadius: 6
                    ) {
                        chrome.showsThreeStarsAndUp.toggle()
                    }
                    RPChoicePill(
                        title: "RAW", isSelected: chrome.libraryFilter == .raw, fontSize: 11.5,
                        horizontalPadding: 10, verticalPadding: 4, cornerRadius: 6
                    ) {
                        chrome.libraryFilter = chrome.libraryFilter == .raw ? .all : .raw
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    RPChoicePill(
                        title: "Đã chỉnh", isSelected: chrome.libraryFilter == .edited,
                        fontSize: 11.5, horizontalPadding: 10, verticalPadding: 4, cornerRadius: 6
                    ) {
                        chrome.libraryFilter = chrome.libraryFilter == .edited ? .all : .edited
                    }
                    Spacer(minLength: 0)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text("Tethering qua cáp")
                    .font(RPTheme.text(11))
                    .foregroundStyle(RPTheme.textTertiary)
                Text("Phase 4 · chưa bật")
                    .font(RPTheme.text(11))
                    .foregroundStyle(RPTheme.textMuted)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RPTheme.fillFaint, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .frame(width: RPTheme.Metrics.macLibrarySidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RPTheme.chrome)
        .overlay(alignment: .trailing) { Rectangle().fill(RPTheme.hairline).frame(width: 1) }
    }

    // MARK: Centre

    private var centre: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(source.title(project: model.project))
                    .font(RPTheme.text(13, weight: .semibold))
                    .foregroundStyle(RPTheme.textPrimary)
                Text("\(shots.count) ảnh · \(model.activeShot == nil ? 0 : 1) chọn")
                    .font(RPTheme.mono(11.5))
                    .foregroundStyle(RPTheme.textTertiary)
                Spacer()
                RPStarRating(
                    rating: model.activeShot?.rating ?? 0, size: 14,
                    isEnabled: model.activeShot != nil
                ) { value in
                    guard let id = model.activeShot?.id else { return }
                    Task { await model.toggleRating(value, for: id) }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(RPTheme.hairline).frame(height: 1) }

            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 12),
                        count: RPTheme.Metrics.macLibraryColumns),
                    spacing: 12
                ) {
                    ForEach(shots) { shot in
                        Button {
                            Task { await model.select(shotID: shot.id) }
                        } label: {
                            RPThumbnail(
                                request: PreviewRequest(
                                    originalURL: model.thumbnailURL(for: shot),
                                    maxPixelSize: RPTheme.Metrics.thumbnailPixelSize),
                                cache: cache,
                                isSelected: shot.id == model.selection.activeShotID,
                                formatTag: (ShotDisplay.formatTag(shot), ShotDisplay.isRaw(shot))
                            ) {
                                RPThumbnailCaption(name: shot.originalFileName, rating: shot.rating)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(shot.originalFileName)
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded { openInEditor(shot) }
                        )
                        .accessibilityLabel("\(shot.originalFileName), \(shot.rating) sao")
                    }
                }
                .padding(18)
            }
            .overlay {
                if shots.isEmpty {
                    Text(
                        model.shots.isEmpty
                            ? "Dự án này chưa có ảnh nào. Dùng “Nhập…” ở thanh trên."
                            : "Không có ảnh nào khớp bộ lọc."
                    )
                    .font(RPTheme.text(13))
                    .foregroundStyle(RPTheme.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RPTheme.canvas)
    }

    // MARK: Info panel

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let shot = model.activeShot {
                RPThumbnail(
                    request: PreviewRequest(
                        originalURL: model.thumbnailURL(for: shot),
                        maxPixelSize: 512),
                    cache: cache,
                    cornerRadius: 8)

                VStack(alignment: .leading, spacing: 0) {
                    Text(shot.originalFileName)
                        .font(RPTheme.text(13, weight: .semibold))
                        .foregroundStyle(RPTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.bottom, 8)

                    metaRow("Định dạng", ShotDisplay.fileExtension(shot))
                    metaRow("Kích thước", ShotDisplay.pixelSize(shot))
                    metaRow("ISO", ShotDisplay.iso(shot))
                    metaRow("Khẩu độ", ShotDisplay.aperture(shot))
                    metaRow("Tốc độ", ShotDisplay.shutter(shot))
                    metaRow(
                        "Số mặt nhận diện",
                        model.detectedFaceCount(for: shot).map(String.init) ?? "—",
                        help: model.detectedFaceCount(for: shot) == nil
                            ? "Đếm được sau khi mở ảnh trong tab Chỉnh sửa" : nil)
                }

                Spacer(minLength: 8)

                RPPrimaryButton(
                    title: "Mở trong Chỉnh sửa", horizontalPadding: 0, verticalPadding: 11,
                    cornerRadius: 9, fillsWidth: true
                ) {
                    openInEditor(shot)
                }
            } else {
                Spacer()
                Text("Chọn một ảnh để xem thông tin.")
                    .font(RPTheme.text(12))
                    .foregroundStyle(RPTheme.textTertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(16)
        .frame(width: RPTheme.Metrics.macLibraryInfoWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RPTheme.chrome)
        .overlay(alignment: .leading) { Rectangle().fill(RPTheme.hairline).frame(width: 1) }
    }

    private func metaRow(_ key: String, _ value: String, help: String? = nil) -> some View {
        HStack {
            Text(key)
                .font(RPTheme.text(11.5))
                .foregroundStyle(RPTheme.textTertiary)
            Spacer(minLength: 8)
            Text(value)
                .font(RPTheme.mono(11.5))
                .foregroundStyle(RPTheme.textMono)
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
        }
        .help(help ?? "")
    }
}

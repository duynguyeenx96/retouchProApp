import RPCore
import SwiftUI

/// The preset library — the screen behind the rail's "Mẫu" item and, with a
/// different ``PresetLibraryKind``, behind the Looks picker
/// (docs/PLAN.md §Phase 3: *"dùng lại UI rail 'Mẫu' đã khoá … làm màn preset
/// thay vì xây UI preset riêng"*).
///
/// One view for both kinds, because the plan says the two differ only in which
/// sections they carry — templates take everything a `Preset` may hold, Looks
/// are colour-only. Everything else (the three tabs, the stores, favourites,
/// apply, auto-apply) is shared, so there is one body and a kind switcher at the
/// top rather than two screens that drift apart.
///
/// **Reading vs writing.** ``PresetLibraryModel`` owns the two stores (the
/// app-bundle built-ins and the user's cross-project library) and favourites;
/// ``EditorModel`` owns the project, the `EditState` and the live preview, so
/// every apply goes through `EditorModel.applyPreset(_:replacingSections:scope:)`.
/// This view holds nothing but the selection and the transient status line.
///
/// The mockup's tab labels were "Cho bạn / Của tôi / Yêu thích"; the first ships
/// as **"Nổi bật"** (decided 2026-09-11, `docs/design/SPEC.md` §Turn 3 "Tab
/// rename") because the list is static and curated for everyone — see
/// ``PresetLibraryTab``.
struct PresetLibraryView: View {
    @Bindable var model: EditorModel
    @Bindable var library: PresetLibraryModel
    /// Which kind the rail asked for. The switcher writes back through
    /// ``setKind`` so ``EditorChrome/presetLibrary`` stays the one authority on
    /// what is open.
    let kind: PresetLibraryKind
    let setKind: (PresetLibraryKind) -> Void
    let dismiss: () -> Void

    /// Compact layouts (the iPhone sheet) drop the scope row's labels to icons
    /// and use a two-column grid.
    var isCompact = false

    @State private var selectedID: PresetID?
    @State private var scope: PresetApplyScope = .activeShot
    @State private var status: String?
    @State private var isNamingPreset = false
    @State private var newPresetName = ""

    private var selected: Preset? {
        guard let selectedID else { return nil }
        return library.visiblePresets.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(RPTheme.hairlineDialog).frame(height: 1)
            controls
            presetGrid
            Rectangle().fill(RPTheme.hairlineDialog).frame(height: 1)
            footer
        }
        .background(RPTheme.dialog)
        .task(id: kind) {
            library.kind = kind
            selectedID = nil
            await library.reload()
        }
        .alert("Lưu preset", isPresented: $isNamingPreset) {
            TextField("Tên preset", text: $newPresetName)
            Button("Huỷ", role: .cancel) {}
            Button("Lưu") { save() }
        } message: {
            Text(
                "Lưu thiết lập của ảnh đang mở thành preset \(kind.title.lowercased()) trong \"Của tôi\"."
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(kind.title)
                .font(RPTheme.text(16, weight: .bold))
                .foregroundStyle(RPTheme.textPrimary)

            // The canvas's rail has no Looks entry, so the only way into the
            // colour-only picker is from inside this screen.
            HStack(spacing: 6) {
                ForEach(PresetLibraryKind.allCases) { value in
                    RPChoicePill(
                        title: value.title, isSelected: value == kind, fontSize: 11.5,
                        horizontalPadding: 10, verticalPadding: 4
                    ) {
                        setKind(value)
                    }
                }
            }

            Spacer(minLength: 8)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RPTheme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(RPTheme.fillNeutralSoft, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Đóng thư viện preset")
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Tabs + scope

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(PresetLibraryTab.allCases) { tab in
                    RPChoicePill(
                        title: tab.title, isSelected: library.tab == tab, fontSize: 12,
                        horizontalPadding: 12, verticalPadding: 5
                    ) {
                        library.tab = tab
                        selectedID = nil
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Text("Áp cho")
                    .font(RPTheme.text(11.5))
                    .foregroundStyle(RPTheme.textTertiary)
                ForEach(PresetApplyScope.allCases) { value in
                    RPChoicePill(
                        title: value == .allShots
                            ? "\(value.title) · \(model.project.shots.count)" : value.title,
                        isSelected: scope == value, fontSize: 11.5,
                        horizontalPadding: 10, verticalPadding: 4
                    ) {
                        scope = value
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Grid

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: isCompact ? 132 : 150), spacing: 10)]
    }

    private var presetGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                // The mockup's "Thêm" add card, only where a new preset can
                // actually land: the built-ins are read-only and "Yêu thích" is
                // a view over the other two.
                if library.tab == .mine {
                    addCard
                }
                ForEach(library.visiblePresets) { preset in
                    PresetCard(
                        preset: preset,
                        isSelected: preset.id == selectedID,
                        isFavorite: library.isFavorite(preset),
                        isAutoApply: model.isAutoApply(preset),
                        isBuiltIn: library.isBuiltIn(preset),
                        toggleFavorite: { library.toggleFavorite(preset) }
                    )
                    .onTapGesture { selectedID = preset.id }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)

            if let message = library.emptyMessage {
                Text(message)
                    .font(RPTheme.text(12))
                    .foregroundStyle(RPTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)
            }
        }
        .scrollIndicators(.visible)
        .frame(minHeight: 120)
    }

    private var addCard: some View {
        Button {
            beginSaving()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                Text("Thêm")
                    .font(RPTheme.text(11.5, weight: .medium))
            }
            .foregroundStyle(RPTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: PresetCard.height)
            .background(RPTheme.fillFaint, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        RPTheme.hairlineDialog, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Thêm preset từ ảnh đang mở")
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = status ?? library.lastErrorMessage {
                Text(message)
                    .font(RPTheme.text(11.5))
                    .foregroundStyle(
                        library.lastErrorMessage == nil ? RPTheme.textSecondary : .orange
                    )
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                RPSecondaryButton(title: "Lưu preset", isEnabled: model.activeShot != nil) {
                    beginSaving()
                }

                if let preset = selected, !library.isBuiltIn(preset) {
                    RPSecondaryButton(title: "Xoá") {
                        library.delete(preset)
                        selectedID = nil
                        status = "Đã xoá \"\(preset.name)\"."
                    }
                }

                Spacer(minLength: 0)

                if let preset = selected {
                    Button {
                        Task { await toggleAutoApply(preset) }
                    } label: {
                        Label(
                            "Tự động",
                            systemImage: model.isAutoApply(preset)
                                ? "wand.and.stars" : "wand.and.stars.inverse"
                        )
                        .font(RPTheme.text(12.5, weight: .medium))
                        .foregroundStyle(
                            model.isAutoApply(preset) ? RPTheme.accent : RPTheme.textSecondary
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            model.isAutoApply(preset)
                                ? RPTheme.accentSoft : RPTheme.fillNeutral,
                            in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Áp preset này cho mọi ảnh nhập vào project từ giờ")
                    .accessibilityAddTraits(
                        model.isAutoApply(preset) ? [.isButton, .isSelected] : .isButton)
                }

                RPPrimaryButton(
                    title: "Áp dụng", horizontalPadding: 18, verticalPadding: 7,
                    isEnabled: selected != nil && model.activeShot != nil
                ) {
                    Task { await apply() }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Actions

    private func beginSaving() {
        guard model.activeShot != nil else {
            status = "Chưa có ảnh nào đang mở để lưu."
            return
        }
        newPresetName = library.defaultPresetName()
        isNamingPreset = true
    }

    private func save() {
        guard let preset = library.savePreset(named: newPresetName, from: model.activeEditState)
        else { return }
        selectedID = preset.id
        status =
            preset.isEmpty
            ? "Đã lưu \"\(preset.name)\" — preset rỗng, áp nó sẽ đưa nhóm này về 0."
            : "Đã lưu \"\(preset.name)\"."
    }

    private func apply() async {
        guard let preset = selected else { return }
        let count = await model.applyPreset(
            preset, replacingSections: kind.sectionNames, scope: scope)
        status =
            count == 0
            ? "Không có ảnh nào thay đổi."
            : "Đã áp \"\(preset.name)\" cho \(count) ảnh."
    }

    private func toggleAutoApply(_ preset: Preset) async {
        if model.isAutoApply(preset) {
            await model.clearAutoApplyPreset()
            status = "Đã tắt tự động áp cho ảnh mới."
        } else {
            await model.setAutoApplyPreset(preset)
            status = "Ảnh nhập vào project từ giờ sẽ được áp \"\(preset.name)\"."
        }
    }
}

/// One preset in the grid: name, which groups it carries, its star, and whether
/// it is the project's auto-apply preset.
///
/// There is **no thumbnail**. The mockup draws one per template, but rendering a
/// preview of every preset against the open photo means a full render graph pass
/// each — measured work that Phase 3 has no budget for and that would make the
/// screen's cost scale with the library. The section summary is the honest
/// substitute, the same one `PresetBarView` already uses.
private struct PresetCard: View {
    let preset: Preset
    let isSelected: Bool
    let isFavorite: Bool
    let isAutoApply: Bool
    let isBuiltIn: Bool
    let toggleFavorite: () -> Void

    static let height: CGFloat = 72

    /// "Da · Mắt & Răng · Màu", in the panel's own group order.
    private var summary: String {
        let names = SliderPanelLayout.sections
            .filter { preset.sections[$0.key]?.isEmpty == false }
            .map(\.title)
        return names.isEmpty ? "không đổi gì" : names.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(preset.name)
                    .font(RPTheme.text(12.5, weight: .semibold))
                    .foregroundStyle(RPTheme.textPrimary)
                    .lineLimit(1)
                if isAutoApply {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 10))
                        .foregroundStyle(RPTheme.accent)
                }
                Spacer(minLength: 2)
                Button(action: toggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundStyle(isFavorite ? RPTheme.star : RPTheme.starEmpty)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isFavorite
                        ? "Bỏ yêu thích \(preset.name)" : "Đánh dấu yêu thích \(preset.name)")
            }

            Text(summary)
                .font(RPTheme.text(10.5))
                .foregroundStyle(RPTheme.textTertiary)
                .lineLimit(2)

            Spacer(minLength: 0)

            Text(isBuiltIn ? "Dựng sẵn" : "Của tôi")
                .font(RPTheme.mono(9.5))
                .foregroundStyle(RPTheme.textMuted)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
        .background(
            isSelected ? RPTheme.accentPill : RPTheme.fillNeutralSoft,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? RPTheme.accent : RPTheme.hairlineDialog, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(preset.name) — \(summary)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Presentations

/// The macOS presentation: the same in-window dialog treatment as
/// ``MacExportDialog`` (2d), over the scrim.
struct MacPresetLibraryDialog: View {
    @Bindable var model: EditorModel
    @Bindable var library: PresetLibraryModel
    let kind: PresetLibraryKind
    let setKind: (PresetLibraryKind) -> Void
    let dismiss: () -> Void

    var body: some View {
        PresetLibraryView(
            model: model, library: library, kind: kind, setKind: setKind, dismiss: dismiss
        )
        .frame(width: 560, height: 460)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(RPTheme.hairlineDialog, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.6), radius: 40, y: 30)
    }
}

/// The iPhone presentation: a sheet, like the export sheet (2b).
struct PhonePresetLibrarySheet: View {
    @Bindable var model: EditorModel
    @Bindable var library: PresetLibraryModel
    let kind: PresetLibraryKind
    let setKind: (PresetLibraryKind) -> Void
    let dismiss: () -> Void

    var body: some View {
        PresetLibraryView(
            model: model, library: library, kind: kind, setKind: setKind, dismiss: dismiss,
            isCompact: true
        )
    }
}

import RPCore
import SwiftUI

/// The preset library — the panel behind the rail's "Preset" item.
///
/// **One flat, unified list (2026-09-22).** It used to switch between two
/// pickers — "Mẫu" (whole looks) and "Looks" (colour-only) — behind a pair of
/// header pills, with a separate "Áp cho" scope row and an "Áp dụng" button in
/// the footer. A user asked for all of that gone: *"tao đâu có yêu cầu tách 2
/// tab là Mẫu và Looks, Preset bấm vô chỉ là list các preset … bỏ cái Áp dụng
/// cho đi, thay vào đó là thanh trượt Cường độ"*. Both kinds now live in one
/// list (``presetList``); which sections a given preset is allowed to touch —
/// what the two pickers used to fix by which tab was open — is inferred from
/// the preset's own `group` (``Preset/inferredKind``), so applying still
/// cannot let a colour-only Look reach into skin work. Selecting a row
/// previews it immediately at full strength; the "Cường độ" slider in the
/// footer (``EditorModel/selectPresetForApply(_:)`` and friends) dials the
/// strength and commits on release, the same "drag previews, release commits"
/// contract every slider in this app already follows — no separate apply
/// button needed.
///
/// **Grouped, not tabbed.** "Hệ thống" (built-in) and "Của tôi" (saved/imported)
/// are two headed groups in the same scroll, not tabs to click between — see
/// ``presetList``.
///
/// **A side panel, not a floating dialog (2026-09-22).** It used to be
/// `MacPresetLibraryDialog`/`PhonePresetLibrarySheet`, a modal over a scrim —
/// which covered the canvas, so nothing about a preset was visible until
/// committed. A user asked for it to sit "ở vị trí side panel tương tự các
/// chức năng khác" instead, the same slot every slider group already occupies
/// (``SliderPanelView``, the phone tool sheet) — the canvas stays on screen,
/// which is what makes selecting a row show something real.
///
/// **Reading vs writing.** ``PresetLibraryModel`` owns the two stores (the
/// app-bundle built-ins and the user's cross-project library) and favourites;
/// ``EditorModel`` owns the project, the `EditState` and the live preview, so
/// every apply goes through `EditorModel.selectPresetForApply(_:)` /
/// ``EditorModel/commitPresetApply()``. This view holds nothing but the
/// selection and the transient status line.
struct PresetLibraryView: View {
    @Bindable var model: EditorModel
    @Bindable var library: PresetLibraryModel
    let dismiss: () -> Void

    @State private var selectedID: PresetID?
    @State private var status: String?
    @State private var isNamingPreset = false
    @State private var newPresetName = ""
    /// Group titles the user has collapsed (2026-09-22, user request —
    /// folder-imported groups need this most, but every group gets it for
    /// the same reason "Hệ thống" does). Expanded is the default for a title
    /// never seen before, which is why this holds the *collapsed* set rather
    /// than the expanded one.
    @State private var collapsedGroups: Set<String> = []

    private var selected: Preset? {
        guard let selectedID else { return nil }
        return (library.allFeatured + library.mine).first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(RPTheme.hairlineDialog).frame(height: 1)
            presetList
            Rectangle().fill(RPTheme.hairlineDialog).frame(height: 1)
            footer
        }
        .background(RPTheme.chrome)
        .task {
            selectedID = nil
            await library.reload()
        }
        // Leaving the panel (e.g. for Màu to fine-tune) keeps the preset: it
        // was applied when picked. Only the blending session ends.
        .onDisappear { Task { await model.endPresetApply() } }
        .alert("Lưu preset", isPresented: $isNamingPreset) {
            TextField("Tên preset", text: $newPresetName)
            Button("Huỷ", role: .cancel) {}
            Button("Lưu") { save() }
        } message: {
            Text("Lưu thiết lập của ảnh đang mở thành preset trong \"Của tôi\".")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Preset")
                .font(RPTheme.text(16, weight: .bold))
                .foregroundStyle(RPTheme.textPrimary)

            Spacer(minLength: 8)

            // Text, not just the icon (2026-09-22, alongside the rail's own
            // rename): a bare "✕" was exactly the "toàn icon, không biết mục
            // đích" complaint, one screen over.
            Button(action: dismiss) {
                HStack(spacing: 5) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    Text("Đóng").font(RPTheme.text(12))
                }
                .foregroundStyle(RPTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
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

    // MARK: - List

    /// A plain list of rows (Lightroom's own preset panel shape), grouped
    /// under collapsible headers instead of tab pills you have to click
    /// between (2026-09-22, user request, against the Lightroom screenshot
    /// they sent: *"gom nhóm lại ví dụ 'Hệ thống', 'Imported'"*) — everything
    /// is visible at once, scrolled to rather than switched to. "Hệ thống"
    /// is one group; "Của tôi" is one *or more* — a whole folder of `.xmp`
    /// sidecars imported together lands as its own named group instead of
    /// flattened in (``PresetLibraryModel/mineGroupedByCollection``, *"nếu
    /// import folder thì sẽ tạo 1 group"*). Every group can collapse
    /// (*"phải cho phép collapse/expand các group này"*) — see
    /// ``groupHeader(title:count:)``.
    ///
    /// A row is **only the name**, truncated with `lineLimit(1)` rather than
    /// wrapped or dropped — the section summary, the "Dựng sẵn"/"Của tôi" tag
    /// and the star all used to sit on every row and were called out by name
    /// as clutter nobody asked for. Favouriting still exists — it moved to
    /// the footer, next to "Xoá", so it only appears once a preset is
    /// selected.
    ///
    /// The old grid's "Thêm" tile is still gone: tapping it silently saved the
    /// **currently-open photo's edits**, which read as "add/import a preset"
    /// and was not; that action lives only as the clearly-labelled "Lưu
    /// preset" button in the footer now, and this list is a pure browser.
    private var presetList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                group(title: "Hệ thống", presets: library.allFeatured)
                ForEach(library.mineGroupedByCollection) { mineGroup in
                    group(title: mineGroup.title, presets: mineGroup.presets)
                }
                if library.mine.isEmpty {
                    Text("Chưa có preset nào. Dùng \"Lưu preset\" hoặc nhập từ .xmp bên dưới.")
                        .font(RPTheme.text(11.5))
                        .foregroundStyle(RPTheme.textTertiary)
                        .padding(.top, 2)
                        .padding(.bottom, 6)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)

            // Always here — every preset in this list is browsable now,
            // "Nhập từ .xmp…" always writes a Look the same way regardless.
            XMPImportRow(model: model, library: library)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
        }
        .scrollIndicators(.visible)
        .frame(minHeight: 120)
    }

    /// One group: a collapsible caption, then its rows while expanded —
    /// empty groups draw nothing rather than an empty header.
    @ViewBuilder
    private func group(title: String, presets: [Preset]) -> some View {
        if !presets.isEmpty {
            groupHeader(title: title, count: presets.count)
            if !collapsedGroups.contains(title) {
                ForEach(presets) { preset in
                    PresetRow(
                        preset: preset, isSelected: preset.id == selectedID,
                        isAutoApply: model.isAutoApply(preset)
                    )
                    .onTapGesture {
                        selectedID = preset.id
                        // Picking applies it (canvas + disk, one undo step).
                        Task { await model.selectPresetForApply(preset) }
                    }
                }
            }
        }
    }

    /// The caption itself: a chevron, the (uppercased) title, a count, and
    /// the whole row toggles ``collapsedGroups`` — expanded is the default
    /// for any title not in that set yet.
    private func groupHeader(title: String, count: Int) -> some View {
        let isCollapsed = collapsedGroups.contains(title)
        return Button {
            if isCollapsed {
                collapsedGroups.remove(title)
            } else {
                collapsedGroups.insert(title)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Text(title.uppercased())
                Text("\(count)")
                    .foregroundStyle(RPTheme.textMuted.opacity(0.7))
                Spacer(minLength: 0)
            }
            .font(RPTheme.text(10.5, weight: .semibold))
            .foregroundStyle(RPTheme.textMuted)
            .padding(.top, 4)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) preset")
        .accessibilityHint(isCollapsed ? "Đang thu gọn — bấm để mở" : "Đang mở — bấm để thu gọn")
        .accessibilityAddTraits(.isButton)
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

            // Replaces "Áp cho" + "Áp dụng" (2026-09-22, user request). Drag
            // previews live on the canvas already selecting the row started;
            // release writes it — no separate apply button, the same contract
            // every slider in this app follows. Self-healing against
            // `model.presetApply` having been cleared by an earlier commit:
            // touching the slider again just starts a fresh preview from
            // wherever the photo now stands.
            if let preset = selected {
                RPSliderRow(
                    label: "Cường độ",
                    value: model.presetApply?.presetID == preset.id
                        ? model.presetApply!.intensity : 100,
                    range: Slider.range,
                    onChange: { value in
                        if model.presetApply?.presetID != preset.id {
                            model.beginPresetBlend(preset)
                        }
                        model.setPresetApplyIntensity(value)
                    },
                    onCommit: { Task { await model.commitPresetApply() } })
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

                // Moved off the row (2026-09-22, alongside removing the
                // summary and the "Dựng sẵn"/"Của tôi" tag) — it only makes
                // sense once something is selected anyway.
                if let preset = selected {
                    Button {
                        library.toggleFavorite(preset)
                    } label: {
                        Image(systemName: library.isFavorite(preset) ? "star.fill" : "star")
                            .font(.system(size: 13))
                            .foregroundStyle(
                                library.isFavorite(preset) ? RPTheme.star : RPTheme.starEmpty)
                            .frame(width: 30, height: 30)
                            .background(RPTheme.fillNeutral, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help(
                        library.isFavorite(preset)
                            ? "Bỏ yêu thích \(preset.name)" : "Đánh dấu yêu thích \(preset.name)")
                    .accessibilityLabel(
                        library.isFavorite(preset)
                            ? "Bỏ yêu thích \(preset.name)" : "Đánh dấu yêu thích \(preset.name)")
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

/// One preset in the list: **its name, and nothing else** — grouped under
/// "Hệ thống" / "Của tôi" headers (``PresetLibraryView/group(title:presets:)``)
/// rather than carrying a section summary, a "Dựng sẵn"/"Của tôi" tag and a
/// star, which a user explicitly asked to have removed (2026-09-22, sent
/// alongside a Lightroom screenshot: *"mày thêm cái 'không đổi gì' với 'Dựng
/// sẵn' với cái rating kia làm méo gì thế?"*). Favouriting still exists; it
/// moved to the footer. The one thing kept on the row is the auto-apply wand
/// — not named in that complaint, and the only one of the four that answers a
/// question about *this project* rather than describing the preset itself.
///
/// **No thumbnail image** — that would mean a full render-graph pass per row,
/// real work with no budget (docs history). Hovering the row instead shows the
/// real thing, live, on the canvas next to this panel (``PresetLibraryView/presetList``).
private struct PresetRow: View {
    let preset: Preset
    let isSelected: Bool
    var isAutoApply: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(preset.name)
                .font(RPTheme.text(13))
                .foregroundStyle(RPTheme.textPrimary)
                .lineLimit(1)
            if isAutoApply {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 10))
                    .foregroundStyle(RPTheme.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            isSelected ? RPTheme.accentPill : RPTheme.fillNeutralSoft,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? RPTheme.accent : RPTheme.hairlineDialog, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

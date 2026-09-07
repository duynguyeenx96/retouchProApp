import RPCore
import RPEngine
import SwiftUI

/// **Screen 1b** — the wide (macOS / large-window) editor.
///
/// `docs/design/RetouchPro.dc.html#1b`, left to right:
///
/// * a 46 pt toolbar — traffic-light inset, a divider, the four tool icons, the
///   "Thư viện" / "Chỉnh sửa" switcher, the mono "on-device · Metal" caption and
///   the mint "Xuất";
/// * the centre column — the **Trước | Sau** dual-pane canvas with a 2 px gap
///   and 16 pt padding, over the 104 pt filmstrip;
/// * a 326 pt slider panel (``SliderPanelView``);
/// * a 56 pt group rail (``GroupIconRail``).
///
/// The toolbar is drawn in the content, not with `.toolbar`, because the mockup
/// puts a tool group, a tab switcher and a caption in one 46 pt row — a shape
/// `NSToolbar` does not give and cannot be styled into.
struct MacEditorView: View {
    @Bindable var model: EditorModel
    @Bindable var chrome: EditorChrome
    let cache: PreviewImageCache
    let back: () -> Void
    let importFromFiles: () -> Void
    let importFromPhotos: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(
                model: model, chrome: chrome, back: back,
                importFromFiles: importFromFiles, importFromPhotos: importFromPhotos)
            HStack(spacing: 0) {
                centreColumn
                SliderPanelView(model: model, chrome: chrome)
                    .frame(width: RPTheme.Metrics.macPanelWidth)
                GroupIconRail(chrome: chrome)
            }
            .frame(maxHeight: .infinity)
        }
        .background(RPTheme.canvas)
        .background { shortcuts }
        .onAppear {
            // 1b opens on the before/after comparison. Set it once, on appear,
            // so switching to a single pane with **Y** is not undone by the next
            // re-layout.
            if !hasSetComparison {
                hasSetComparison = true
                model.beforeAfter.mode = .sideBySide
            }
        }
    }

    @State private var hasSetComparison = false

    /// Keyboard-only controls, drawn nowhere: the mockup's toolbar has no
    /// compare control, and adding one would be inventing chrome the design does
    /// not have. Zero-sized buttons are how SwiftUI attaches a shortcut to a
    /// view that has no button.
    ///
    /// * **Y** — cycle the canvas: *chỉ ảnh đang chỉnh* ⇄ *ảnh đang chỉnh + ảnh
    ///   gốc cạnh nhau* (`BeforeAfterMode.off` ⇄ `.sideBySide`).
    /// * **\\** — hold-to-compare, i.e. show the untouched original full frame.
    ///   A key press has no "release", so it toggles.
    @ViewBuilder private var shortcuts: some View {
        Button("Đổi chế độ xem") {
            model.beforeAfter.mode = model.beforeAfter.mode == .sideBySide ? .off : .sideBySide
        }
        .keyboardShortcut("y", modifiers: [])
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)

        Button("Xem ảnh gốc") {
            model.beforeAfter.isHoldingOriginal.toggle()
        }
        .keyboardShortcut("\\", modifiers: [])
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var centreColumn: some View {
        VStack(spacing: 0) {
            CanvasView(
                model: model, cache: cache,
                showsPaneBadges: true,
                paneCornerRadius: 4,
                afterPaneOverlay: AnyView(FaceChipsView(model: model))
            )
            .padding(RPTheme.Metrics.macCanvasPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            FilmstripView(
                model: model, cache: cache, axis: .horizontal,
                importFromFiles: importFromFiles, importFromPhotos: importFromPhotos
            )
            .frame(height: RPTheme.Metrics.macFilmstripHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RPTheme.canvas)
    }
}

/// The 46 pt toolbar shared by the macOS editor (1b) and library (2c) tabs.
struct EditorToolbar: View {
    @Bindable var model: EditorModel
    @Bindable var chrome: EditorChrome
    let back: () -> Void
    let importFromFiles: () -> Void
    let importFromPhotos: () -> Void
    /// The editor tab shows the tool group; the library tab (2c) does not.
    var showsToolGroup = true

    var body: some View {
        HStack(spacing: 14) {
            // No back control here: the mockup's row has none, and the window's
            // own title-bar strip already carries the navigation stack's back
            // button next to the traffic lights. `back` is still taken so the
            // narrow layout and a future window without a navigation stack have
            // one place to hand it in.
            if showsToolGroup {
                HStack(spacing: 2) {
                    ForEach(EditorChrome.MacTool.allCases, id: \.self) { tool in
                        RPIconButton(
                            systemImage: tool.systemImage,
                            accessibilityTitle: tool.title,
                            isActive: chrome.macTool == tool,
                            tint: RPTheme.textMuted
                        ) {
                            chrome.macTool = tool
                        }
                        .help(tool.isPlanned ? "\(tool.title) — Phase 5" : tool.title)
                        .disabled(tool.isPlanned)
                        .opacity(tool.isPlanned ? RPTheme.lockedOpacity : 1)
                    }
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 22) {
                ForEach(EditorChrome.Tab.allCases, id: \.self) { tab in
                    Button {
                        chrome.tab = tab
                    } label: {
                        VStack(spacing: 2) {
                            Text(tab.title)
                                .font(RPTheme.text(13.5, weight: .medium))
                                .foregroundStyle(
                                    chrome.tab == tab ? RPTheme.textPrimary : RPTheme.textSecondary)
                            Rectangle()
                                .fill(chrome.tab == tab ? RPTheme.accent : .clear)
                                .frame(height: 2)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        chrome.tab == tab ? [.isButton, .isSelected] : .isButton)
                }
            }

            Spacer(minLength: 8)

            if chrome.tab == .library, model.canImport {
                Menu {
                    Button("Từ Files…", action: importFromFiles)
                    Button("Từ Photos…", action: importFromPhotos)
                } label: {
                    Text("Nhập…")
                        .font(RPTheme.text(12.5))
                        .foregroundStyle(RPTheme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(RPTheme.fillNeutral, in: RoundedRectangle(cornerRadius: 8))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.isImporting)
            } else {
                Text("on-device · Metal")
                    .font(RPTheme.mono(11))
                    .foregroundStyle(RPTheme.textTertiary)
            }

            RPPrimaryButton(title: "Xuất", isEnabled: model.activeShot != nil) {
                chrome.isShowingExport = true
            }
        }
        .padding(.horizontal, 14)
        .frame(height: RPTheme.Metrics.macToolbarHeight)
        .background(RPTheme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(RPTheme.hairline).frame(height: 1) }
    }
}

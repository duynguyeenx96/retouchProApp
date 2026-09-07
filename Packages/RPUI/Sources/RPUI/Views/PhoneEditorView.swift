import RPCore
import RPEngine
import SwiftUI

/// **Screen 1a** — the iPhone editor: full-bleed canvas, a thin top bar, canvas
/// overlays, and an attached bottom tool sheet.
///
/// Layout, top to bottom, exactly as `docs/design/RetouchPro.dc.html#1a`:
///
/// 1. top bar — `‹` back · "Nhập" · spacer · hold-to-compare eye · "Fit" ·
///    `···` overflow · mint "Xuất";
/// 2. the photo, filling everything left over, with the face chips top-left and
///    the "Đồng bộ" / subject / compare controls bottom;
/// 3. the tool sheet: a 16 pt-radius `#141518` panel that overlaps the canvas by
///    14 pt, a grabber, a **250 pt scrollable slider list for the active group**,
///    then the fixed six-tab group row.
///
/// It is also what a *narrow Mac window* gets — the split is on measured width
/// (``EditorLayout``), not on platform, because a 700 pt Mac window has the same
/// problem an iPhone does.
struct PhoneEditorView: View {
    @Bindable var model: EditorModel
    @Bindable var chrome: EditorChrome
    let cache: PreviewImageCache
    /// Back out of the editor. On the phone that is the library screen (2a).
    let back: () -> Void
    let importFromFiles: () -> Void
    let importFromPhotos: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
            canvas
            toolSheet
        }
        .background(RPTheme.canvas)
        // No **Y** here on purpose: the phone has one canvas mode (the edited
        // picture) and comparing is holding it. Y switches between the single
        // and the dual pane, and the dual pane only exists in the wide layout.
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            RPIconButton(
                systemImage: "chevron.left", accessibilityTitle: "Quay lại thư viện",
                fontSize: 17, action: back)

            if model.canImport {
                Menu {
                    Button("Từ Files…", action: importFromFiles)
                    Button("Từ Photos…", action: importFromPhotos)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 13))
                        Text("Nhập").font(RPTheme.text(12.5))
                    }
                    .foregroundStyle(RPTheme.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.isImporting)
            }

            Spacer(minLength: 0)

            // No eye button: **holding the picture itself** shows the original
            // (`CanvasInputModifier`). One less control in a 48 pt row, and the
            // gesture is where the user is already looking.

            Button {
                model.viewport = CanvasViewport()
            } label: {
                Text(model.viewport.isFittingToWindow ? "Fit" : model.viewport.zoomPercentText)
                    .font(RPTheme.mono(11.5))
                    .foregroundStyle(RPTheme.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RPTheme.fillNeutralSoft, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Thu phóng vừa khung")

            Menu {
                Button("100 %") { model.viewport.actualSize() }
                Button("Vừa khung") { model.viewport = CanvasViewport() }
                Divider()
                Button("Ảnh trước") { Task { await model.selectPreviousShot() } }
                Button("Ảnh sau") { Task { await model.selectNextShot() } }
                Divider()
                Button("Đặt lại nhóm \(chrome.activeSection.title)") {
                    model.resetSection(chrome.activeGroupKey)
                }
                .disabled(model.activeEditState[section: chrome.activeGroupKey].isEmpty)
                Button("Đặt lại tất cả", role: .destructive) { model.resetAllSliders() }
                    .disabled(model.activeEditState.sections.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15))
                    .foregroundStyle(RPTheme.textBright)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Thêm")

            RPPrimaryButton(
                title: "Xuất", horizontalPadding: 16, verticalPadding: 7, cornerRadius: 999,
                isEnabled: model.activeShot != nil
            ) {
                chrome.isShowingExport = true
            }
        }
        // 8 + 30 + 10 = the mockup's 48 pt row; not a fixed `frame`, so a larger
        // Dynamic Type setting grows it instead of clipping the controls.
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(RPTheme.canvas)
    }

    // MARK: - Canvas

    private var canvas: some View {
        CanvasView(model: model, cache: cache)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                FaceChipsView(model: model)
                    .padding(12)
            }
            .overlay(alignment: .bottom) { bottomOverlay }
            .clipped()
    }

    private var bottomOverlay: some View {
        HStack(alignment: .center) {
            HStack(spacing: 8) {
                Button {
                    model.setSyncingAllFaces(!model.isSyncingAllFaces)
                } label: {
                    RPOverlayPill {
                        Text("Đồng bộ")
                            .font(RPTheme.text(12.5, weight: .medium))
                            .foregroundStyle(
                                model.isSyncingAllFaces ? RPTheme.accent : RPTheme.textBright)
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.detectedFaceCount < 2)
                .opacity(model.detectedFaceCount < 2 ? 0.5 : 1)
                .help("Áp chỉnh sửa cho mọi khuôn mặt nhận diện được")
                .accessibilityLabel("Đồng bộ mọi khuôn mặt")
                .accessibilityAddTraits(
                    model.isSyncingAllFaces ? [.isButton, .isSelected] : .isButton)

                Button {
                    chrome.cycleSubject()
                } label: {
                    RPOverlayPill {
                        HStack(spacing: 6) {
                            Text(chrome.subject.title)
                                .font(RPTheme.text(12.5, weight: .medium))
                                .foregroundStyle(RPTheme.textBright)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8))
                                .foregroundStyle(RPTheme.textBright.opacity(0.6))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Đối tượng: \(chrome.subject.title)")
            }

            Spacer(minLength: 8)

            // The split-view toggle is gone: comparing is "hold the picture",
            // which needs no button and does not cut the phone's canvas in half.
            // The badge below only appears while the finger is down, so the user
            // knows *why* the picture changed.
            if model.beforeAfter.isHoldingOriginal {
                RPOverlayPill {
                    Text("Ảnh gốc")
                        .font(RPTheme.text(12.5, weight: .medium))
                        .foregroundStyle(RPTheme.textBright)
                }
                .transition(.opacity)
                .accessibilityHidden(true)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.beforeAfter.isHoldingOriginal)
        .padding(.horizontal, 12)
        .padding(.bottom, 28 + RPTheme.Metrics.phoneSheetOverlap)
    }

    // MARK: - Tool sheet

    private var toolSheet: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(width: 36, height: 4)
                .padding(.top, 7)
                .padding(.bottom, 3)

            ScrollView {
                GroupSliderList(
                    model: model, section: chrome.activeSection,
                    thumbSize: RPTheme.Metrics.phoneSliderThumb)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            .frame(height: RPTheme.Metrics.phoneSheetSliderHeight)
            .scrollIndicators(.hidden)

            Divider().overlay(RPTheme.hairlineStrong)

            GroupTabRow(chrome: chrome) { key in
                model.activeEditState[section: key].values.count
            }
        }
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: RPTheme.Metrics.phoneSheetRadius,
                topTrailingRadius: RPTheme.Metrics.phoneSheetRadius
            )
            .fill(RPTheme.chrome)
        )
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(
                topLeadingRadius: RPTheme.Metrics.phoneSheetRadius,
                topTrailingRadius: RPTheme.Metrics.phoneSheetRadius
            )
            .strokeBorder(RPTheme.hairlineStrong, lineWidth: 1)
        }
        .offset(y: -RPTheme.Metrics.phoneSheetOverlap)
        .padding(.bottom, -RPTheme.Metrics.phoneSheetOverlap)
    }
}

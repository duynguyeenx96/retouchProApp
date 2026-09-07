import Photos
import PhotosUI
import RPCore
import RPEngine
import SwiftUI

/// One open project, in whichever of the approved layouts fits the window.
///
/// * wide (macOS, or any window ≥ ``EditorLayout/threePaneMinimumWidth``) —
///   ``MacLibraryView`` (screen 2c) and ``MacEditorView`` (screen 1b), switched
///   by the toolbar's "Thư viện" / "Chỉnh sửa" tabs;
/// * narrow (iPhone, or a small Mac window) — ``PhoneLibraryView`` (2a) and
///   ``PhoneEditorView`` (1a), with the editor's `‹` going back to the library.
///
/// The split is on **measured width**, not on `horizontalSizeClass` — which does
/// not exist on macOS, and a 700 pt Mac window has the same problem an iPhone
/// does.
///
/// This type owns the things both layouts need and neither should own twice:
/// the two pickers (`.fileImporter` / `.photosPicker` are body modifiers, so
/// they have to be on a common ancestor), the import / error banners, the
/// export presentation, and the ``EditorChrome`` both halves read.
public struct EditorView: View {
    @Bindable var model: EditorModel
    let cache: PreviewImageCache
    let close: () -> Void

    @State private var chrome = EditorChrome()
    @State private var layout: EditorLayout = .threePane
    @State private var isPickingFiles = false
    @State private var isPickingPhotos = false
    @State private var pickedPhotos: [PhotosPickerItem] = []

    public init(model: EditorModel, cache: PreviewImageCache, close: @escaping () -> Void) {
        self.model = model
        self.cache = cache
        self.close = close
    }

    public var body: some View {
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width, height: geometry.size.height)
                .onAppear { layout = EditorLayout.forWidth(geometry.size.width) }
                .onChange(of: geometry.size.width) { _, width in
                    layout = EditorLayout.forWidth(width)
                }
        }
        .background(RPTheme.canvas)
        .preferredColorScheme(.dark)
        .tint(RPTheme.accent)
        // The screen draws its own top row (the mockup's 46 pt toolbar with the
        // tool group, the tab switcher and "Xuất"; the phone's back / Nhập / Fit
        // / Xuất bar), so the iOS navigation bar has to go.
        //
        // **macOS keeps its window toolbar**, deliberately. Two things were
        // tried and measured on screen first: hiding it (`.toolbar(.hidden, for:
        // .windowToolbar)`) also removes the traffic lights, leaving a window
        // that cannot be closed or moved by its top edge; and letting the content
        // ignore the top safe area, so the design row could sit under the lights
        // the way the mockup draws them, laid the row out *above* the window's
        // visible content — the buttons were still in the accessibility tree at
        // sensible positions and completely invisible on screen (verified with a
        // red background). So on macOS the transparent title-bar strip stays,
        // carrying the lights and the navigation back button, and the design's
        // 46 pt row sits directly under it.
        #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
        #endif
        .fileImporter(
            isPresented: $isPickingFiles,
            allowedContentTypes: ImportFileTypes.allowed,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await model.importFiles(at: urls) }
            case .failure(let error):
                // Cancelling is not reported as a failure by `fileImporter`, so
                // anything arriving here is worth showing.
                model.reportImportFailure(String(describing: error))
            }
        }
        .photosPicker(
            isPresented: $isPickingPhotos,
            selection: $pickedPhotos,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            // `itemIdentifier` is the `PHAsset.localIdentifier`, and it is only
            // non-nil because the picker above was given `photoLibrary: .shared()`.
            // That is deliberate: RPImport exports the asset's **RAW** resource by
            // identifier (docs/ADR-0003 §6), which `loadTransferable` cannot do.
            let identifiers = items.compactMap(\.itemIdentifier)
            pickedPhotos = []
            Task { await model.importPhotos(withLocalIdentifiers: identifiers) }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                errorBanner
                importBanner
            }
            .frame(maxWidth: 420)
            .padding(.top, 8)
        }
        .overlay { exportOverlay }
        #if os(iOS)
            .sheet(isPresented: exportSheetBinding) {
                PhoneExportSheet(chrome: chrome, shot: model.activeShot) {
                    chrome.isShowingExport = false
                }
                .presentationDetents([.height(430)])
                .presentationDragIndicator(.hidden)
                .presentationBackground(RPTheme.sheet)
                .preferredColorScheme(.dark)
            }
        #endif
    }

    // MARK: - Arrangements

    @ViewBuilder private var content: some View {
        switch (layout, chrome.tab) {
        case (.threePane, .library):
            MacLibraryView(
                model: model, chrome: chrome, cache: cache, back: close,
                importFromFiles: { isPickingFiles = true },
                importFromPhotos: { isPickingPhotos = true },
                openInEditor: open)
        case (.threePane, .edit):
            MacEditorView(
                model: model, chrome: chrome, cache: cache, back: close,
                importFromFiles: { isPickingFiles = true },
                importFromPhotos: { isPickingPhotos = true })
        case (.compact, .library):
            PhoneLibraryView(
                model: model, chrome: chrome, cache: cache, back: close,
                importFromFiles: { isPickingFiles = true },
                importFromPhotos: { isPickingPhotos = true },
                open: open)
        case (.compact, .edit):
            PhoneEditorView(
                model: model, chrome: chrome, cache: cache,
                back: { chrome.tab = .library },
                importFromFiles: { isPickingFiles = true },
                importFromPhotos: { isPickingPhotos = true })
        }
    }

    private func open(_ shot: Shot) {
        Task {
            await model.select(shotID: shot.id)
            chrome.tab = .edit
        }
    }

    // MARK: - Export

    /// `Binding` rather than the `@Bindable` property directly, because the
    /// sheet only exists on iOS and macOS uses the in-window dialog of 2d.
    private var exportSheetBinding: Binding<Bool> {
        Binding(
            get: { chrome.isShowingExport },
            set: { chrome.isShowingExport = $0 })
    }

    @ViewBuilder private var exportOverlay: some View {
        #if os(macOS)
            if chrome.isShowingExport {
                ZStack {
                    RPTheme.scrimMac
                        .ignoresSafeArea()
                        .onTapGesture { chrome.isShowingExport = false }
                    MacExportDialog(
                        chrome: chrome,
                        shotCount: model.activeShot == nil ? 0 : 1
                    ) {
                        chrome.isShowingExport = false
                    }
                }
                .transition(.opacity)
            }
        #endif
    }

    // MARK: - Banners

    /// "12 imported, 3 skipped" — the one thing the user needs after a picker
    /// closes. `ImportReport`'s per-item detail goes to the app log instead
    /// (docs/ADR-0003 §2); a banner is the wrong place for 400 lines.
    @ViewBuilder private var importBanner: some View {
        if model.isImporting {
            banner {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(RPTheme.accent)
                    Text("Đang nhập ảnh…")
                        .font(RPTheme.text(12))
                        .foregroundStyle(RPTheme.textPrimary)
                    Spacer()
                }
            }
        } else if let message = model.lastImportMessage {
            banner {
                HStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down").foregroundStyle(RPTheme.accent)
                    Text(message)
                        .font(RPTheme.text(12))
                        .foregroundStyle(RPTheme.textPrimary)
                        .lineLimit(2)
                    Spacer()
                    Button("Đóng") { model.dismissImportMessage() }
                        .buttonStyle(.plain)
                        .font(RPTheme.text(12))
                        .foregroundStyle(RPTheme.accent)
                }
            }
        }
    }

    @ViewBuilder private var errorBanner: some View {
        if let message = model.lastErrorMessage {
            banner {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message)
                        .font(RPTheme.text(12))
                        .foregroundStyle(RPTheme.textPrimary)
                        .lineLimit(3)
                    Spacer()
                    Button("Đóng") { model.dismissError() }
                        .buttonStyle(.plain)
                        .font(RPTheme.text(12))
                        .foregroundStyle(RPTheme.accent)
                }
            }
        }
    }

    private func banner(@ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(10)
            .background(RPTheme.dialog, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(RPTheme.hairlineDialog, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
            .padding(.horizontal, 12)
    }
}

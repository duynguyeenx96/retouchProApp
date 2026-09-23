import Photos
import PhotosUI
import RPCore
import RPEngine
import SwiftUI

#if os(macOS)
    import AppKit
#endif

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
    /// One per open editor, holding one `ExportRenderer` (built on the first
    /// export, not at launch — see ``MetalExportRunner``).
    @State private var exporter = ExportController.standard()
    /// The preset library's own state (the two stores + favourites), owned here
    /// for the same reason the pickers are: both layouts present it, and it must
    /// not be rebuilt — and re-read from disk — every time the sheet opens.
    @State private var presetLibrary = PresetLibraryModel()
    @State private var layout: EditorLayout = .threePane
    @State private var isPickingFiles = false
    @State private var isPickingPhotos = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @Environment(\.scenePhase) private var scenePhase

    /// - Parameter opensInEditor: start on the editor (1a / 1b) instead of the
    ///   project's library (2a / 2c). The Share Extension hand-off passes
    ///   `true`: "Mở với RetouchPro" promises the canvas, not a grid with one
    ///   thumbnail in it (docs/ADR-0017). Everything else leaves it `false`,
    ///   which is the behaviour opening a project has always had — unless the
    ///   project's `session.json` says the editor was showing when it was last
    ///   left (docs/ADR-0025), in which case it reopens there.
    @MainActor
    public init(
        model: EditorModel,
        cache: PreviewImageCache,
        opensInEditor: Bool = false,
        close: @escaping () -> Void
    ) {
        self.model = model
        self.cache = cache
        self.close = close
        let chrome = EditorChrome()
        if opensInEditor {
            chrome.tab = .edit
        } else if let restored = model.restoredTab {
            chrome.tab = restored
        }
        _chrome = State(initialValue: chrome)
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
        // "A project is a session" (docs/ADR-0025): the tab goes into
        // `session.json` with the selection and the zoom, and the pending
        // (debounced) write is forced out whenever there may be no "later" —
        // leaving the project, the app going to the background, the app quitting.
        .onChange(of: chrome.tab, initial: true) { _, tab in model.noteTab(tab) }
        .onDisappear { model.saveSessionPositionNow() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.saveSessionPositionNow() }
        }
        #if os(macOS)
            .onReceive(
                NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            ) { _ in
                model.saveSessionPositionNow()
            }
        #endif
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
                PhoneExportSheet(
                    chrome: chrome, shot: model.activeShot,
                    selectedCount: model.selection.selectedShots(in: model.shots).count,
                    projectCount: model.shots.count,
                    exporter: exporter,
                    export: runExport
                ) {
                    chrome.isShowingExport = false
                }
                .presentationDetents([.height(480)])
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
                importFromPhotos: { isPickingPhotos = true },
                library: presetLibrary)
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
                importFromPhotos: { isPickingPhotos = true },
                library: presetLibrary)
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
                        // Not while a file is being written: dismissing the
                        // dialog mid-export would hide the only place the
                        // finished file's path is shown.
                        .onTapGesture {
                            if !exporter.isExporting { chrome.isShowingExport = false }
                        }
                    MacExportDialog(
                        chrome: chrome,
                        selectedCount: model.selection.selectedShots(in: model.shots).count,
                        projectCount: model.shots.count,
                        exporter: exporter,
                        export: runExport
                    ) {
                        chrome.isShowingExport = false
                    }
                }
                .transition(.opacity)
            }
        #endif
    }

    /// The scope row's photos — the selection (just the open photo unless more
    /// are selected) or the whole project. `ExportController` refuses a second
    /// call while the first is running, so a double-click is one batch.
    private func runExport() {
        let options = chrome.export
        Task { await exporter.export(scope: options.scope, of: model, options: options) }
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

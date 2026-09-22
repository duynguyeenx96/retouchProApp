import RPCore
import SwiftUI
import UniformTypeIdentifiers

/// The preset panel's row for **importing Lightroom `.xmp` sidecars**: one
/// file, several files, or a whole folder, and every one of them lands in
/// "Của tôi" immediately, at full strength — no naming prompt, no intensity
/// step, nothing to confirm (2026-09-22, user request: *"import thì mặc định
/// vào luôn list presets … chứ đéo phải chờ nhấn lưu hay gì nữa"*). Applying
/// one to a photo afterwards is exactly like applying any other preset in the
/// list — select the row, the panel's own "Cường độ" slider takes it from
/// there (``EditorModel/selectPresetForApply(_:)``).
///
/// **Files vs. a folder** (2026-09-22, user request: *"cho phép import theo
/// folder hoặc nhiều file preset 1 lúc"*) are two different menu items rather
/// than one picker that somehow takes either, because `.fileImporter` cannot
/// mix the two in one dialog. Picking several loose files drops each into the
/// default "Của tôi" bucket on its own; picking a folder groups everything
/// inside it under that folder's own name (``EditorModel/importXMPPresets(fromFolder:in:)``,
/// *"import folder thì sẽ tạo 1 group"*).
struct XMPImportRow: View {
    @Bindable var model: EditorModel
    /// Where the imported Look(s) are written — the same instance the rest of
    /// the screen reads, so the list on screen shows them immediately.
    @Bindable var library: PresetLibraryModel
    @State private var isPickingFiles = false
    @State private var isPickingFolder = false

    var body: some View {
        Menu {
            Button("Nhập file .xmp…") { isPickingFiles = true }
            Button("Nhập thư mục…") { isPickingFolder = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 11))
                Text("Nhập từ .xmp…").font(RPTheme.text(12.5))
            }
            .foregroundStyle(RPTheme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(RPTheme.fillNeutral, in: RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .fileImporter(
            isPresented: $isPickingFiles,
            allowedContentTypes: [UTType(filenameExtension: "xmp") ?? .xml],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                model.importXMPPresets(fromFiles: urls, in: library)
            case .failure(let error):
                model.reportImportFailure(String(describing: error))
            }
        }
        .fileImporter(
            isPresented: $isPickingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                model.importXMPPresets(fromFolder: url, in: library)
            case .failure(let error):
                model.reportImportFailure(String(describing: error))
            }
        }
    }
}

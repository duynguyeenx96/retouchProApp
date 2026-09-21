import RPCore
import SwiftUI

/// "Xoá ảnh khỏi dự án" — the one destructive action the shot lists offer, kept
/// in a single file so the Mac filmstrip and the iPhone library cannot drift
/// apart in wording or in what they promise.
///
/// The promise matters here: `ProjectStore.removeShot` drops the shot and its
/// `edits/<id>.json`, but **leaves the imported file in `originals/`** — so the
/// confirmation says "tệp gốc vẫn được giữ" rather than the usual "không thể
/// hoàn tác", which would be a lie in the scarier direction.
enum ShotRemoval {
    /// Menu label. The ellipsis is the app's existing convention for an item
    /// that opens something else before it acts (cf. "Từ Files…").
    static let menuTitle = "Xoá ảnh khỏi dự án…"
    static let confirmTitle = "Xoá ảnh khỏi dự án?"
    static let confirmButton = "Xoá"
    static let cancelButton = "Huỷ"

    static func message(for shot: Shot) -> String {
        """
        \(shot.originalFileName) sẽ không còn trong dự án và các chỉnh sửa của \
        ảnh này bị xoá. Tệp gốc vẫn được giữ trong dự án, không bị xoá khỏi máy.
        """
    }
}

/// The context-menu entry. Arms ``ShotRemovalConfirmation`` instead of deleting:
/// nothing is removed until the user confirms.
struct ShotRemovalMenuItem: View {
    let shot: Shot
    @Binding var pending: Shot?

    var body: some View {
        Button(ShotRemoval.menuTitle, role: .destructive) { pending = shot }
    }
}

/// The confirmation itself — an `.alert` rather than a `.confirmationDialog`
/// because that is the pattern `ProjectsView` already uses ("Dự án mới", the
/// error banner): same two buttons, same "Huỷ" spelling.
struct ShotRemovalConfirmation: ViewModifier {
    let model: EditorModel
    @Binding var pending: Shot?

    func body(content: Content) -> some View {
        content.alert(
            ShotRemoval.confirmTitle,
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            presenting: pending
        ) { shot in
            Button(ShotRemoval.cancelButton, role: .cancel) { pending = nil }
            Button(ShotRemoval.confirmButton, role: .destructive) {
                pending = nil
                Task { await model.removeShot(shot.id) }
            }
        } message: { shot in
            Text(ShotRemoval.message(for: shot))
        }
    }
}

extension View {
    /// Attach once per shot list, next to the `.contextMenu` that sets `pending`.
    func shotRemovalConfirmation(_ pending: Binding<Shot?>, model: EditorModel) -> some View {
        modifier(ShotRemovalConfirmation(model: model, pending: pending))
    }
}

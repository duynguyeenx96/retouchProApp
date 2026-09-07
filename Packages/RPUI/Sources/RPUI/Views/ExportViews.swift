import RPCore
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// The four option rows shared by screen 2b (iPhone sheet) and 2d (macOS
/// dialog): Định dạng / Chất lượng / Kích thước / Không gian màu.
///
/// **No renderer behind it.** Export is `docs/PLAN.md` Phase 3 and ADR-0011
/// records what it is waiting on (Da + Mắt/Răng together are ~936 MB of scratch
/// at 24 MP, never measured on a real iPhone), so the primary button is disabled
/// and says so. The options are real state (``ExportOptions``) so that Phase 3
/// wires a renderer, not a screen.
struct ExportOptionRows: View {
    @Binding var options: ExportOptions
    var fontSize: CGFloat = 13.5
    var pillFontSize: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            row("Định dạng") {
                ForEach(ExportOptions.Format.allCases, id: \.self) { value in
                    pill(value.title, options.format == value) { options.format = value }
                }
            }
            row("Chất lượng") {
                ForEach(ExportOptions.Quality.allCases, id: \.self) { value in
                    pill(value.title, options.quality == value) { options.quality = value }
                }
            }
            row("Kích thước") {
                ForEach(ExportOptions.Size.allCases, id: \.self) { value in
                    pill(value.title, options.size == value) { options.size = value }
                }
            }
            row("Không gian màu") {
                ForEach(ExportOptions.ColorSpace.allCases, id: \.self) { value in
                    pill(value.title, options.colorSpace == value) { options.colorSpace = value }
                }
            }
        }
    }

    private func row(_ label: String, @ViewBuilder options content: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(RPTheme.text(fontSize))
                .foregroundStyle(RPTheme.textLabel)
            Spacer(minLength: 8)
            HStack(spacing: 6) { content() }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(RPTheme.hairline).frame(height: 1) }
    }

    private func pill(_ title: String, _ isSelected: Bool, action: @escaping () -> Void)
        -> some View
    {
        RPChoicePill(
            title: title, isSelected: isSelected, fontSize: pillFontSize,
            horizontalPadding: 12, verticalPadding: 5, cornerRadius: 7, action: action)
    }
}

// MARK: - Screen 2b — iPhone export sheet

/// **Screen 2b** — the modal export sheet over a dimmed canvas.
struct PhoneExportSheet: View {
    @Bindable var chrome: EditorChrome
    let shot: Shot?
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 12)

            HStack(alignment: .firstTextBaseline) {
                Text("Xuất ảnh")
                    .font(RPTheme.text(17, weight: .bold))
                    .foregroundStyle(RPTheme.textPrimary)
                Spacer()
                Text(caption)
                    .font(RPTheme.mono(12))
                    .foregroundStyle(RPTheme.textTertiary)
            }
            .padding(.bottom, 14)

            ExportOptionRows(options: Binding(get: { chrome.export }, set: { chrome.export = $0 }))

            HStack {
                Text("Xử lý on-device")
                    .font(RPTheme.text(12))
                    .foregroundStyle(RPTheme.textTertiary)
                Spacer()
                Text("Xuất & batch: Phase 3")
                    .font(RPTheme.text(12))
                    .foregroundStyle(RPTheme.textTertiary)
            }
            .padding(.vertical, 14)

            HStack(spacing: 10) {
                Button(action: dismiss) {
                    Text("Huỷ")
                        .font(RPTheme.text(14, weight: .medium))
                        .foregroundStyle(RPTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(RPTheme.fillNeutral, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                Text("Xuất 1 ảnh")
                    .font(RPTheme.text(14, weight: .semibold))
                    .foregroundStyle(RPTheme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(RPTheme.accent, in: RoundedRectangle(cornerRadius: 12))
                    .opacity(0.45)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Xuất 1 ảnh — chưa khả dụng, Phase 3")
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 18)
        .background(RPTheme.sheet)
    }

    private var caption: String {
        guard let shot else { return "—" }
        let name = (shot.originalFileName as NSString).deletingPathExtension
        let size = ShotDisplay.pixelSize(shot)
        return size == "—" ? name : "\(name) · \(size)"
    }
}

// MARK: - Screen 2d — macOS export dialog

/// **Screen 2d** — the 520 pt modal dialog over a dimmed window, with the
/// folder row and the progress card.
///
/// The progress card only appears once an export is running. Nothing runs one
/// today (Phase 3), so it is rendered from ``ExportProgress`` and stays hidden —
/// the shape is here, the fake numbers are not.
struct MacExportDialog: View {
    @Bindable var chrome: EditorChrome
    let shotCount: Int
    var progress: ExportProgress?
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Xuất \(max(1, shotCount)) ảnh")
                    .font(RPTheme.text(16, weight: .bold))
                    .foregroundStyle(RPTheme.textPrimary)
                Spacer()
                Text("on-device")
                    .font(RPTheme.mono(11.5))
                    .foregroundStyle(RPTheme.textTertiary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .overlay(alignment: .bottom) {
                Rectangle().fill(RPTheme.hairlineDialog).frame(height: 1)
            }

            VStack(spacing: 0) {
                ExportOptionRows(
                    options: Binding(get: { chrome.export }, set: { chrome.export = $0 }),
                    fontSize: 12.5, pillFontSize: 11.5)

                HStack {
                    Text("Thư mục")
                        .font(RPTheme.text(12.5))
                        .foregroundStyle(RPTheme.textLabel)
                    Spacer()
                    Button {
                        chooseFolder()
                    } label: {
                        Text(chrome.export.destinationDisplayPath + " ⌄")
                            .font(RPTheme.mono(11.5))
                            .foregroundStyle(RPTheme.textSecondary)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Chọn thư mục xuất")
                }
                .padding(.vertical, 12)

                if let progress {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Đang xử lý \(progress.currentFileName)")
                                .font(RPTheme.text(11.5))
                                .foregroundStyle(RPTheme.textMono)
                                .lineLimit(1)
                            Spacer()
                            Text("\(progress.completed) / \(progress.total)")
                                .font(RPTheme.mono(11.5))
                                .foregroundStyle(RPTheme.accent)
                        }
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.1))
                                Capsule().fill(RPTheme.accent)
                                    .frame(width: geometry.size.width * progress.fraction)
                            }
                        }
                        .frame(height: 4)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(RPTheme.fillFaint, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 14)

            HStack(spacing: 10) {
                Spacer()
                Button(action: dismiss) {
                    Text("Huỷ")
                        .font(RPTheme.text(13))
                        .foregroundStyle(RPTheme.textPrimary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(RPTheme.fillNeutral, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Text("Xuất")
                    .font(RPTheme.text(13, weight: .semibold))
                    .foregroundStyle(RPTheme.onAccent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(RPTheme.accent, in: RoundedRectangle(cornerRadius: 8))
                    .opacity(0.45)
                    .help("Xuất ảnh là docs/PLAN.md Phase 3 — chưa bật")
                    .accessibilityLabel("Xuất — chưa khả dụng, Phase 3")
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 18)
            .overlay(alignment: .top) {
                Rectangle().fill(RPTheme.hairlineDialog).frame(height: 1)
            }
        }
        .frame(width: RPTheme.Metrics.macDialogWidth)
        .background(RPTheme.dialog, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(RPTheme.hairlineDialog, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.6), radius: 40, y: 30)
    }

    private func chooseFolder() {
        #if os(macOS)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Chọn"
            if panel.runModal() == .OK { chrome.export.destinationFolder = panel.url }
        #endif
    }
}

/// What a running export would report. Phase 3 fills it; today nothing does, and
/// the dialog simply omits the card.
public struct ExportProgress: Hashable, Sendable {
    public var currentFileName: String
    public var completed: Int
    public var total: Int

    public init(currentFileName: String, completed: Int, total: Int) {
        self.currentFileName = currentFileName
        self.completed = completed
        self.total = total
    }

    public var fraction: CGFloat {
        guard total > 0 else { return 0 }
        return min(1, max(0, CGFloat(completed) / CGFloat(total)))
    }
}

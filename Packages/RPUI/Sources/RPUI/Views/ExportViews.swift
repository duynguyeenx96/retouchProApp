import RPCore
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// The four option rows shared by screen 2b (iPhone sheet) and 2d (macOS
/// dialog): Định dạng / Chất lượng / Kích thước / Không gian màu.
///
/// The pills are `ExportOptions`, and `ExportOptions.engineSettings` turns them
/// into the `RPEngine.ExportSettings` the renderer takes — so what the row shows
/// and what the file gets are one mapping in one place.
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
///
/// The primary button runs one export of the shot the editor has open, through
/// ``ExportController``. The file lands in the app's container
/// (``ExportDestination``), which on iOS is not somewhere the user can browse —
/// so the finished row carries a `ShareLink`, which is how the picture gets into
/// Files, Photos or anywhere else. `docs/PLAN.md` Phase 3's batch queue is not
/// here: this button is one photo.
struct PhoneExportSheet: View {
    @Bindable var chrome: EditorChrome
    let shot: Shot?
    var exporter: ExportController
    let export: () -> Void
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

            statusRow
                .frame(height: 34)
                .padding(.vertical, 10)

            HStack(spacing: 10) {
                Button(action: dismiss) {
                    Text(exporter.lastSummary == nil ? "Huỷ" : "Xong")
                        .font(RPTheme.text(14, weight: .medium))
                        .foregroundStyle(RPTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(RPTheme.fillNeutral, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                Button(action: export) {
                    Text(exporter.isExporting ? "Đang xuất…" : "Xuất 1 ảnh")
                        .font(RPTheme.text(14, weight: .semibold))
                        .foregroundStyle(RPTheme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(RPTheme.accent, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .opacity(canExport ? 1 : 0.45)
                .disabled(!canExport)
                .accessibilityLabel("Xuất 1 ảnh")
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 18)
        .background(RPTheme.sheet)
    }

    private var canExport: Bool {
        shot != nil && exporter.isAvailable && !exporter.isExporting
    }

    /// One line, four states: running, finished, failed, idle. The finished one
    /// carries the `ShareLink` — without it the file is in a container the user
    /// cannot open.
    @ViewBuilder private var statusRow: some View {
        if exporter.isExporting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(RPTheme.accent)
                Text("Đang xuất ảnh…")
                    .font(RPTheme.text(12))
                    .foregroundStyle(RPTheme.textSecondary)
                Spacer()
            }
        } else if let summary = exporter.lastSummary {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(RPTheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.fileName)
                        .font(RPTheme.text(12, weight: .medium))
                        .foregroundStyle(RPTheme.textPrimary)
                        .lineLimit(1)
                    Text(summary.detailText)
                        .font(RPTheme.mono(10.5))
                        .foregroundStyle(RPTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                ShareLink(item: summary.url) {
                    Text("Chia sẻ")
                        .font(RPTheme.text(12, weight: .medium))
                        .foregroundStyle(RPTheme.accent)
                }
                .accessibilityLabel("Chia sẻ ảnh đã xuất")
            }
        } else if let message = exporter.lastErrorMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .font(RPTheme.text(11.5))
                    .foregroundStyle(RPTheme.textSecondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        } else {
            HStack {
                Text("Xử lý on-device")
                    .font(RPTheme.text(12))
                    .foregroundStyle(RPTheme.textTertiary)
                Spacer()
                Text("1 ảnh · batch: Phase 3")
                    .font(RPTheme.text(12))
                    .foregroundStyle(RPTheme.textTertiary)
            }
        }
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
/// The progress card appears while an export is running and is replaced by the
/// finished file's row afterwards; both come from ``ExportController``, so the
/// numbers on screen are a real export's or there are none.
///
/// The title still says "Xuất N ảnh" with N = 1: this button exports the
/// selected photo. The batch queue behind a larger N is `docs/PLAN.md` Phase 3's
/// next item and is not wired here.
struct MacExportDialog: View {
    @Bindable var chrome: EditorChrome
    let shotCount: Int
    var exporter: ExportController
    let export: () -> Void
    let dismiss: () -> Void

    private var progress: ExportProgress? { exporter.progress }

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
                } else if let summary = exporter.lastSummary {
                    finishedCard(summary)
                } else if let message = exporter.lastErrorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(RPTheme.text(11.5))
                            .foregroundStyle(RPTheme.textSecondary)
                            .lineLimit(3)
                        Spacer(minLength: 0)
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

                RPPrimaryButton(
                    title: exporter.isExporting ? "Đang xuất…" : "Xuất",
                    horizontalPadding: 20, verticalPadding: 9,
                    isEnabled: canExport, action: export
                )
                .help(
                    exporter.isAvailable
                        ? "Xuất ảnh đang chọn vào \(chrome.export.destinationDisplayPath)"
                        : "Máy này không có GPU Metal nên chưa xuất được")
                .accessibilityLabel("Xuất")
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

    private var canExport: Bool {
        shotCount > 0 && exporter.isAvailable && !exporter.isExporting
    }

    /// The finished file, with the one control that matters on macOS: showing it
    /// in Finder. The default folder is inside the app's container, which is not
    /// a path anyone navigates to by hand.
    private func finishedCard(_ summary: ExportSummary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(RPTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.fileName)
                    .font(RPTheme.text(12, weight: .medium))
                    .foregroundStyle(RPTheme.textPrimary)
                    .lineLimit(1)
                Text(summary.detailText)
                    .font(RPTheme.mono(11))
                    .foregroundStyle(RPTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            #if os(macOS)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([summary.url])
                } label: {
                    Text("Hiện trong Finder")
                        .font(RPTheme.text(12, weight: .medium))
                        .foregroundStyle(RPTheme.accent)
                }
                .buttonStyle(.plain)
            #else
                ShareLink(item: summary.url) {
                    Text("Chia sẻ")
                        .font(RPTheme.text(12, weight: .medium))
                        .foregroundStyle(RPTheme.accent)
                }
            #endif
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RPTheme.fillFaint, in: RoundedRectangle(cornerRadius: 10))
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

/// What a running export reports. ``ExportController`` fills it for a single
/// photo (`total` 1); the batch queue of `docs/PLAN.md` Phase 3 will fill it for
/// N without this type changing.
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

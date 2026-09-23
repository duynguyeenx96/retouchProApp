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

/// "Xuất" row: the filmstrip selection or the whole project, each with its
/// real count — the number the button will actually write.
struct ExportScopeRow: View {
    @Binding var scope: ExportScope
    let selectedCount: Int
    let projectCount: Int
    var fontSize: CGFloat = 13.5
    var pillFontSize: CGFloat = 12

    var body: some View {
        HStack {
            Text("Xuất")
                .font(RPTheme.text(fontSize))
                .foregroundStyle(RPTheme.textLabel)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                pill("Đã chọn (\(selectedCount))", .selection)
                pill("Cả project (\(projectCount))", .allShots)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(RPTheme.hairline).frame(height: 1) }
    }

    private func pill(_ title: String, _ value: ExportScope) -> some View {
        RPChoicePill(
            title: title, isSelected: scope == value, fontSize: pillFontSize,
            horizontalPadding: 12, verticalPadding: 5, cornerRadius: 7
        ) { scope = value }
        .accessibilityLabel(value.title)
    }
}

/// How many photos `scope` covers.
func exportCount(scope: ExportScope, selectedCount: Int, projectCount: Int) -> Int {
    scope == .selection ? selectedCount : projectCount
}

// MARK: - Screen 2b — iPhone export sheet

/// **Screen 2b** — the modal export sheet over a dimmed canvas.
///
/// The primary button exports the scope row's photos (the selection — the open
/// photo unless "Chọn" picked more — or the whole project) through
/// ``ExportController`` / ``BatchQueue``. The files land in the app's container
/// (``ExportDestination``), which on iOS is not somewhere the user can browse —
/// so the finished row carries a `ShareLink` over every file written, which is
/// how the pictures get into Files, Photos or anywhere else.
struct PhoneExportSheet: View {
    @Bindable var chrome: EditorChrome
    let shot: Shot?
    let selectedCount: Int
    let projectCount: Int
    var exporter: ExportController
    let export: () -> Void
    let dismiss: () -> Void

    private var count: Int {
        exportCount(
            scope: chrome.export.scope, selectedCount: selectedCount, projectCount: projectCount)
    }

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

            ExportScopeRow(
                scope: Binding(get: { chrome.export.scope }, set: { chrome.export.scope = $0 }),
                selectedCount: selectedCount, projectCount: projectCount)
            ExportOptionRows(options: Binding(get: { chrome.export }, set: { chrome.export = $0 }))

            statusRow
                .frame(height: 34)
                .padding(.vertical, 10)

            HStack(spacing: 10) {
                Button {
                    if exporter.isExporting { exporter.cancel() } else { dismiss() }
                } label: {
                    Text(secondaryTitle)
                        .font(RPTheme.text(14, weight: .medium))
                        .foregroundStyle(RPTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(RPTheme.fillNeutral, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .disabled(exporter.isCancelling)

                Button(action: export) {
                    Text(exporter.isExporting ? "Đang xuất…" : "Xuất \(count) ảnh")
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
                .accessibilityLabel("Xuất \(count) ảnh")
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 18)
        .background(RPTheme.sheet)
    }

    /// While running, the left button stops the batch after the current photo
    /// — closing the sheet would hide the only progress there is.
    private var secondaryTitle: String {
        if exporter.isCancelling { return "Đang dừng…" }
        if exporter.isExporting { return "Dừng" }
        return exporter.lastBatch == nil ? "Huỷ" : "Xong"
    }

    private var canExport: Bool {
        shot != nil && count > 0 && exporter.isAvailable && !exporter.isExporting
    }

    /// One line, four states: running, finished, failed, idle. The finished one
    /// carries the `ShareLink` — without it the files are in a container the
    /// user cannot open.
    @ViewBuilder private var statusRow: some View {
        if let progress = exporter.progress {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(RPTheme.accent)
                Text(progress.isThermalPaused ? progress.statusText : "Đang xuất ảnh…")
                    .font(RPTheme.text(12))
                    .foregroundStyle(RPTheme.textSecondary)
                    .lineLimit(1)
                Spacer()
                Text("\(progress.completed) / \(progress.total)")
                    .font(RPTheme.mono(12))
                    .foregroundStyle(RPTheme.accent)
            }
        } else if let batch = exporter.lastBatch, batch.total > 1 {
            HStack(spacing: 8) {
                Image(systemName: batch.failures.isEmpty
                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(batch.failures.isEmpty ? RPTheme.accent : .orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(batch.headline)
                        .font(RPTheme.text(12, weight: .medium))
                        .foregroundStyle(RPTheme.textPrimary)
                        .lineLimit(1)
                    if let failure = batch.failures.first {
                        Text("\(failure.fileName): \(failure.reason)")
                            .font(RPTheme.mono(10.5))
                            .foregroundStyle(RPTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if !batch.exported.isEmpty {
                    ShareLink(items: batch.exported.map(\.url)) {
                        Text("Chia sẻ")
                            .font(RPTheme.text(12, weight: .medium))
                            .foregroundStyle(RPTheme.accent)
                    }
                    .accessibilityLabel("Chia sẻ ảnh đã xuất")
                }
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
                Text("\(count) ảnh · lần lượt từng ảnh")
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
/// The title says "Xuất N ảnh" with N = what the scope row covers: the
/// filmstrip selection (⌘/⇧-click) or the whole project. A batch runs through
/// ``BatchQueue``, one photo at a time.
struct MacExportDialog: View {
    @Bindable var chrome: EditorChrome
    let selectedCount: Int
    let projectCount: Int
    var exporter: ExportController
    let export: () -> Void
    let dismiss: () -> Void

    private var progress: ExportProgress? { exporter.progress }

    private var shotCount: Int {
        exportCount(
            scope: chrome.export.scope, selectedCount: selectedCount, projectCount: projectCount)
    }

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
                ExportScopeRow(
                    scope: Binding(
                        get: { chrome.export.scope }, set: { chrome.export.scope = $0 }),
                    selectedCount: selectedCount, projectCount: projectCount,
                    fontSize: 12.5, pillFontSize: 11.5)
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
                            if progress.isThermalPaused {
                                Image(systemName: "thermometer.high")
                                    .foregroundStyle(.orange)
                            }
                            Text(progress.statusText)
                                .font(RPTheme.text(11.5))
                                .foregroundStyle(
                                    progress.isThermalPaused ? .orange : RPTheme.textMono)
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
                } else if let batch = exporter.lastBatch, batch.total > 1 {
                    batchCard(batch)
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
                Button {
                    if exporter.isExporting { exporter.cancel() } else { dismiss() }
                } label: {
                    Text(secondaryTitle)
                        .font(RPTheme.text(13))
                        .foregroundStyle(RPTheme.textPrimary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(RPTheme.fillNeutral, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(exporter.isCancelling)
                .help(exporter.isExporting ? "Dừng sau ảnh đang xử lý" : "")

                RPPrimaryButton(
                    title: exporter.isExporting ? "Đang xuất…" : "Xuất",
                    horizontalPadding: 20, verticalPadding: 9,
                    isEnabled: canExport, action: export
                )
                .help(
                    exporter.isAvailable
                        ? "Xuất \(shotCount) ảnh vào \(chrome.export.destinationDisplayPath)"
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

    private var secondaryTitle: String {
        if exporter.isCancelling { return "Đang dừng…" }
        if exporter.isExporting { return "Dừng" }
        return exporter.lastBatch == nil ? "Huỷ" : "Đóng"
    }

    /// A batch's result: the count, the first few failures by name and reason,
    /// and the folder. Failures are listed, not summarised as a number — "2
    /// lỗi" with no names sends the user hunting through the whole shoot.
    private func batchCard(_ batch: BatchExportSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: batch.failures.isEmpty
                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(batch.failures.isEmpty ? RPTheme.accent : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(batch.headline)
                        .font(RPTheme.text(12, weight: .medium))
                        .foregroundStyle(RPTheme.textPrimary)
                        .lineLimit(1)
                    Text(
                        "\(ExportDestination.displayPath(batch.folder)) · "
                            + String(format: "%.1f s", batch.milliseconds / 1000)
                    )
                    .font(RPTheme.mono(11))
                    .foregroundStyle(RPTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                #if os(macOS)
                    if !batch.exported.isEmpty {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                batch.exported.map(\.url))
                        } label: {
                            Text("Hiện trong Finder")
                                .font(RPTheme.text(12, weight: .medium))
                                .foregroundStyle(RPTheme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                #endif
            }
            ForEach(Array(batch.failures.prefix(3).enumerated()), id: \.offset) { _, failure in
                Text("\(failure.fileName): \(failure.reason)")
                    .font(RPTheme.mono(10.5))
                    .foregroundStyle(RPTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if batch.failures.count > 3 {
                Text("… và \(batch.failures.count - 3) ảnh lỗi khác (xem log)")
                    .font(RPTheme.text(10.5))
                    .foregroundStyle(RPTheme.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RPTheme.fillFaint, in: RoundedRectangle(cornerRadius: 10))
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

/// What a running export reports. ``BatchQueue`` fills it — `total` 1 for the
/// single-photo button, N for a batch.
public struct ExportProgress: Hashable, Sendable {
    public var currentFileName: String
    public var completed: Int
    public var total: Int
    /// The queue is waiting between photos for the device to cool down
    /// (`ProcessInfo.thermalState` `.serious` / `.critical`).
    public var isThermalPaused: Bool

    public init(
        currentFileName: String, completed: Int, total: Int, isThermalPaused: Bool = false
    ) {
        self.currentFileName = currentFileName
        self.completed = completed
        self.total = total
        self.isThermalPaused = isThermalPaused
    }

    public var fraction: CGFloat {
        guard total > 0 else { return 0 }
        return min(1, max(0, CGFloat(completed) / CGFloat(total)))
    }

    /// The progress card's line.
    public var statusText: String {
        isThermalPaused
            ? "Máy đang nóng, tạm dừng…"
            : "Đang xử lý \(currentFileName)"
    }
}

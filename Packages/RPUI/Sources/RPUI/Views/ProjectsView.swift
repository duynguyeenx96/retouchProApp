import RPCore
import RPEngine
import SwiftUI

/// The projects list: every `.rpproj` in the library folder, plus "Dự án mới".
///
/// Not one of the six mockup screens — the design starts inside a project — so
/// it wears the same palette and the same header shape as screen 2a rather than
/// inventing a look: title block left, actions right, dark `#0c0d0f` ground.
/// It only has to get the user into a project.
public struct ProjectsView: View {
    @Environment(ProjectsModel.self) private var model
    let cache: PreviewImageCache
    /// Called with the bundle URL to open.
    let open: (URL) -> Void

    @State private var isNamingProject = false
    @State private var newProjectName = ""

    public init(cache: PreviewImageCache, open: @escaping (URL) -> Void) {
        self.cache = cache
        self.open = open
    }

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 14)]

    public var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                if model.entries.isEmpty && !model.isLoading {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(model.entries) { entry in
                            Button { open(entry.bundleURL) } label: {
                                ProjectCard(entry: entry, cache: cache)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("project-\(entry.name)")
                        }
                    }
                    .padding(16)
                }
            }
            .refreshable { await model.reload() }
        }
        .background(RPTheme.canvas)
        .preferredColorScheme(.dark)
        .tint(RPTheme.accent)
        #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
        #endif
        .task { await model.reload() }
        .alert("Dự án mới", isPresented: $isNamingProject) {
            TextField("Tên", text: $newProjectName)
            Button("Huỷ", role: .cancel) {}
            Button("Tạo") {
                let name = newProjectName
                Task {
                    if let url = await model.createProject(named: name) { open(url) }
                }
            }
        } message: {
            Text("Một dự án là một buổi chụp: ảnh đã nhập, các chỉnh sửa và preset của nó.")
        }
        .alert(
            "Có lỗi xảy ra",
            isPresented: Binding(
                get: { model.lastErrorMessage != nil },
                set: { if !$0 { model.dismissError() } }
            )
        ) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.lastErrorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dự án")
                    .font(RPTheme.text(22, weight: .bold))
                    .foregroundStyle(RPTheme.textPrimary)
                Text("\(model.entries.count) buổi chụp · trên máy")
                    .font(RPTheme.text(12))
                    .foregroundStyle(RPTheme.textTertiary)
            }
            Spacer()
            Button {
                newProjectName = model.suggestedProjectName
                isNamingProject = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(RPTheme.onAccent)
                    .frame(width: 34, height: 34)
                    .background(RPTheme.accent, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityLabel("Dự án mới")
        }
        .padding(.horizontal, 18)
        .padding(.top, macTitleBarInset)
        .padding(.bottom, 12)
    }

    /// The window's title bar is transparent (`.hiddenTitleBar`) and the safe
    /// area already keeps the content out from under the traffic lights, so this
    /// is breathing room, not clearance.
    private var macTitleBarInset: CGFloat {
        #if os(macOS)
            12
        #else
            10
        #endif
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.stack")
                .font(.system(size: 44))
                .foregroundStyle(RPTheme.textTertiary)
            Text("Chưa có dự án nào")
                .font(RPTheme.text(17, weight: .semibold))
                .foregroundStyle(RPTheme.textPrimary)
            Text("Một dự án là một buổi chụp. Tạo một dự án, rồi thêm ảnh từ Files hoặc Photos.")
                .font(RPTheme.text(13))
                .foregroundStyle(RPTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Text(model.library.rootURL.path)
                .font(RPTheme.mono(10))
                .foregroundStyle(RPTheme.textTertiary)
                .textSelection(.enabled)
                .padding(.top, 4)
        }
    }
}

private struct ProjectCard: View {
    let entry: ProjectEntry
    let cache: PreviewImageCache

    private var coverRequest: PreviewRequest? {
        entry.coverURL.map {
            PreviewRequest(originalURL: $0, maxPixelSize: RPTheme.Metrics.thumbnailPixelSize)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RPTheme.thumbnailPlaceholder
                if coverRequest != nil {
                    AsyncPreviewImageView(
                        request: coverRequest, cache: cache, contentMode: .fill
                    ) {
                        AnyView(RPTheme.thumbnailPlaceholder)
                    }
                } else {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.title)
                        .foregroundStyle(RPTheme.textTertiary)
                }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(entry.name)
                .font(RPTheme.text(14, weight: .semibold))
                .foregroundStyle(RPTheme.textPrimary)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text("\(entry.shotCount) ảnh")
                Text("·")
                Text(entry.modifiedAt, style: .date)
            }
            .font(RPTheme.text(11.5))
            .foregroundStyle(RPTheme.textTertiary)

            if let problem = entry.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(RPTheme.text(11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(RPTheme.chrome, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(RPTheme.hairline, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

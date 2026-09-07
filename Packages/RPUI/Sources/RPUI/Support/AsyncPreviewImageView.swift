import RPCore
import RPEngine
import SwiftUI

/// Loads one image through ``PreviewImageCache`` and shows it, with a
/// placeholder while it decodes and a visible failure state.
///
/// The failure state is deliberately not silent: a shot whose original has been
/// ejected with the card is a thing the user needs to see (ADR-0002 §9 keeps
/// such shots in the project rather than deleting them).
struct AsyncPreviewImageView<Placeholder: View>: View {
    let request: PreviewRequest?
    let cache: PreviewImageCache
    var contentMode: ContentMode = .fit
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: PreviewImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                ScaledPreviewImage(cgImage: image.cgImage, contentMode: contentMode)
            } else if failed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .help("The imported file could not be read.")
            } else {
                placeholder()
            }
        }
        .task(id: request) {
            guard let request else {
                image = nil
                failed = false
                return
            }
            failed = false
            do {
                image = try await cache.image(for: request)
            } catch {
                guard !Task.isCancelled else { return }
                image = nil
                failed = true
            }
        }
    }
}

/// One decoded preview, drawn at `contentMode` **without letting `.fill` leak
/// into layout**.
///
/// `Image.resizable().aspectRatio(contentMode: .fill)` reports the size that
/// *covers* the proposal, not the proposal: a 6000×4000 shot offered the
/// filmstrip's 68×76 tile answers 114×76. Nothing above it put that back —
/// `clipShape` clips to the view's *own* (already oversized) frame, and
/// `.frame(width:height:)` only centres an oversized child, it does not clip
/// it. So every landscape thumbnail drew ~23 pt outside its cell on each side,
/// overlapping its neighbour in the filmstrip's `LazyHStack` and in the library
/// grid, and dragging its caption bar and mint selection outline out with it.
///
/// The fix is the standard "fill without resizing the container" shape: a
/// flexible `Color.clear` takes exactly the proposed size, the image is an
/// overlay on it (an overlay is proposed the parent's size and never changes
/// it), and `.clipped()` cuts the part that covers beyond the tile. Layout size
/// is therefore always the proposal, for any source aspect ratio.
struct ScaledPreviewImage: View {
    let cgImage: CGImage
    var contentMode: ContentMode = .fit

    private var image: some View {
        Image(decorative: cgImage, scale: 1)
            .resizable()
            .aspectRatio(contentMode: contentMode)
    }

    var body: some View {
        if contentMode == .fill {
            Color.clear
                .overlay { image }
                .clipped()
        } else {
            // `.fit` never exceeds the proposal, so it needs no wrapper — and
            // views that size themselves to the picture keep working.
            image
        }
    }
}

extension AsyncPreviewImageView where Placeholder == AnyView {
    /// The default placeholder: a neutral tile, no spinner. A filmstrip full of
    /// spinners reads as "broken"; a filmstrip of grey tiles reads as "loading".
    init(request: PreviewRequest?, cache: PreviewImageCache, contentMode: ContentMode = .fit) {
        self.init(request: request, cache: cache, contentMode: contentMode) {
            AnyView(Rectangle().fill(.quaternary))
        }
    }
}

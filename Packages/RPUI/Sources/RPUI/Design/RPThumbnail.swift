import RPCore
import RPEngine
import SwiftUI

/// One photo tile, shared by the two library grids (2a, 2c) and the macOS
/// filmstrip (1b).
///
/// The captions differ per screen, so they are passed in rather than switched
/// on inside: the phone grid shows the file name bottom-left and the format
/// chip top-right, the Mac grid adds stars, the filmstrip has a single compact
/// bar. What is shared is the tile itself — aspect ratio, the diagonal-hatch
/// placeholder, and the 2 px mint outline when selected.
struct RPThumbnail<Caption: View>: View {
    let request: PreviewRequest?
    let cache: PreviewImageCache
    var aspectRatio: CGFloat? = 3.0 / 4.0
    var cornerRadius: CGFloat = 6
    var isSelected: Bool = false
    var selectionWidth: CGFloat = 2
    var formatTag: (text: String, isRaw: Bool)?
    @ViewBuilder var caption: () -> Caption

    var body: some View {
        ZStack {
            RPTheme.thumbnailPlaceholder
            AsyncPreviewImageView(request: request, cache: cache, contentMode: .fill) {
                AnyView(RPTheme.thumbnailPlaceholder)
            }
        }
        .modifier(OptionalAspectRatio(ratio: aspectRatio))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(alignment: .bottom) { caption() }
        .overlay(alignment: .topTrailing) {
            if let formatTag {
                RPFormatTag(text: formatTag.text, isRaw: formatTag.isRaw)
                    .padding(5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    isSelected ? RPTheme.accent : .clear, lineWidth: selectionWidth)
        }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

extension RPThumbnail where Caption == EmptyView {
    init(
        request: PreviewRequest?,
        cache: PreviewImageCache,
        aspectRatio: CGFloat? = 3.0 / 4.0,
        cornerRadius: CGFloat = 6,
        isSelected: Bool = false,
        selectionWidth: CGFloat = 2,
        formatTag: (text: String, isRaw: Bool)? = nil
    ) {
        self.init(
            request: request, cache: cache, aspectRatio: aspectRatio,
            cornerRadius: cornerRadius, isSelected: isSelected,
            selectionWidth: selectionWidth, formatTag: formatTag
        ) { EmptyView() }
    }
}

/// The dark caption bar over the bottom of a tile: file name left, stars right.
struct RPThumbnailCaption: View {
    let name: String
    var rating: Int = 0
    var showsStars: Bool = true
    var fontSize: CGFloat = 9
    var hasBackground: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(RPTheme.mono(fontSize))
                .foregroundStyle(RPTheme.textMono)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
            if showsStars, rating > 0 {
                RPStarCaption(rating: rating, size: fontSize)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .background(hasBackground ? Color.black.opacity(0.55) : .clear)
    }
}

/// `aspectRatio(nil)` is not the same as not applying the modifier, so the
/// filmstrip's fixed 68×76 tile needs this to opt out.
///
/// `contentMode` is **`.fit`, not `.fill`**: `.fill` sizes the view to *cover*
/// the proposal, so a 3:4 tile in a flexible grid column comes out taller than
/// its cell and the whole column overflows — which on the first macOS run
/// pushed the 46 pt toolbar off the top of the window. `.fit` keeps the tile
/// inside the width it was offered. The *picture* still fills the tile: that is
/// `AsyncPreviewImageView(contentMode: .fill)`, which crops to the tile inside
/// ``ScaledPreviewImage`` — note that the `clipShape` above cannot do that job,
/// it clips to whatever frame its own content reports, so an oversized child
/// stays oversized.
private struct OptionalAspectRatio: ViewModifier {
    let ratio: CGFloat?

    func body(content: Content) -> some View {
        if let ratio {
            content.aspectRatio(ratio, contentMode: .fit)
        } else {
            content
        }
    }
}

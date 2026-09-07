import CoreGraphics
import RPCore
import RPEngine
import SwiftUI

/// The picture itself: the selected shot, zoomable and pannable, with the
/// before/after comparison and — Phase 2 — the **live GPU preview**.
///
/// ## Two pictures, two paths, on purpose
///
/// * **Sau (after)** — an `MTKView` running `RPEngine.RenderGraph` over a texture
///   uploaded once per shot (``LivePreviewMetalView``). A slider drag re-runs
///   the graph only; it does not decode, upload or re-analyse anything.
/// * **Trước (before)** — the file under `originals/` decoded by
///   `PassthroughPreviewRenderer`. That renderer ignoring `EditState` is exactly
///   what the "before" side wants, so it stayed (docs/ADR-0013).
///
/// With no Metal device, or when the graph will not build, the canvas shows the
/// decoded original for both sides and says so in a small pill rather than
/// pretending the sliders are doing something.
///
/// ## Chrome lives outside this view
///
/// Screens 1a and 1b put different things on top of the same picture — the
/// phone's face chips sit top-left of the whole canvas, the Mac's sit
/// bottom-left of the *Sau* pane only. So this view draws the photo, the
/// Trước/Sau badges and the tappable face outlines, and takes the rest as
/// ``afterPaneOverlay``; the sync / subject / compare pills belong to
/// ``PhoneEditorView``.
struct CanvasView: View {
    @Bindable var model: EditorModel
    let cache: PreviewImageCache
    /// Draw the mockup's "Trước" / "Sau" badges (screen 1b). Off on the phone,
    /// whose canvas is a single full-bleed pane.
    var showsPaneBadges = false
    /// Corner radius of each pane — 4 pt on the Mac, square on the phone.
    var paneCornerRadius: CGFloat = 0
    /// Extra chrome for the *edited* pane, e.g. the Mac's face chips.
    var afterPaneOverlay: AnyView?

    /// The decoded original: the "before" side, the geometry everything is laid
    /// out from, and the CPU fallback when there is no live preview.
    @State private var original: PreviewImage?
    @State private var loadFailure: String?
    /// Live pinch scale on iOS, applied on top of `viewport.zoom`.
    @State private var gestureZoomBaseline: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let content = contentSize(in: geometry.size)
            ZStack {
                RPTheme.imageBackground

                if model.activeShot == nil {
                    emptyState
                } else if let failure = loadFailure {
                    failureState(failure)
                } else if let original {
                    imageLayer(original: original, size: geometry.size, paneSize: content)
                } else {
                    ProgressView().controlSize(.small).tint(RPTheme.accent)
                }

                if model.beforeAfter.mode == .split, original != nil,
                    !model.beforeAfter.showsOriginalFullFrame
                {
                    SplitHandle(
                        fraction: model.beforeAfter.splitFraction,
                        width: geometry.size.width
                    ) { x in
                        model.beforeAfter.setSplit(fromX: x, width: geometry.size.width)
                    }
                }
            }
            .contentShape(Rectangle())
            .modifier(
                CanvasInputModifier(
                    viewSize: content,
                    imageSize: original?.pixelSize ?? .zero,
                    viewport: $model.viewport,
                    gestureZoomBaseline: $gestureZoomBaseline,
                    holdOriginal: { isHolding in
                        guard model.activeShot != nil else { return }
                        model.beforeAfter.isHoldingOriginal = isHolding
                    }
                )
            )
            // Everything below is applied **after** the input modifier, because
            // on macOS `CanvasEventCatcher` is an `NSView` overlay that would
            // otherwise swallow every click on a face outline or a chip.
            .overlay { faceOutlines(size: geometry.size, paneSize: content) }
            .overlay(alignment: .bottomLeading) {
                if let afterPaneOverlay, !model.beforeAfter.showsOriginalFullFrame {
                    afterPaneOverlay
                        .padding(.leading, isDualPane ? content.width + gap + 12 : 12)
                        .padding(.bottom, 12)
                }
            }
            .overlay(alignment: .bottom) { livePreviewWarning }
            .onAppear { adopt(size: content) }
            .onChange(of: content) { _, size in adopt(size: size) }
            .onChange(of: original?.pixelSize) { _, _ in adopt(size: content) }
        }
        .task(id: taskKey) { await load() }
    }

    /// The size one pane gets. In the Mac's dual-pane comparison the picture is
    /// fitted into **half** the canvas, so "Fit" means fit inside the pane the
    /// user is actually looking at — not inside the whole canvas and then
    /// clipped.
    private func contentSize(in size: CGSize) -> CGSize {
        guard isDualPane else { return size }
        return CGSize(
            width: max(1, (size.width - RPTheme.Metrics.macCanvasGap) / 2), height: size.height)
    }

    private var isDualPane: Bool {
        model.beforeAfter.mode == .sideBySide && !model.beforeAfter.showsOriginalFullFrame
    }

    private var gap: CGFloat { RPTheme.Metrics.macCanvasGap }

    // MARK: - Layers

    @ViewBuilder
    private func imageLayer(original: PreviewImage, size: CGSize, paneSize: CGSize) -> some View {
        let frame = model.viewport.imageFrame(imageSize: original.pixelSize, viewSize: paneSize)

        if isDualPane {
            HStack(spacing: RPTheme.Metrics.macCanvasGap) {
                pane(badge: .before) { picture(original, frame: frame, in: paneSize) }
                pane(badge: .after) {
                    editedPicture(original, frame: frame, in: paneSize)
                }
            }
        } else if model.beforeAfter.mode == .split && !model.beforeAfter.showsOriginalFullFrame {
            ZStack {
                editedPicture(original, frame: frame, in: size)
                picture(original, frame: frame, in: size)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: size.width * model.beforeAfter.splitFraction)
                    }
                    .overlay(alignment: .topLeading) {
                        if showsPaneBadges { badge(.before).padding(10) }
                    }
            }
        } else if model.beforeAfter.showsOriginalFullFrame {
            picture(original, frame: frame, in: size)
                .overlay(alignment: .topLeading) {
                    badge(.before).padding(10)
                }
        } else {
            pane(badge: nil) { editedPicture(original, frame: frame, in: size) }
        }
    }

    private enum PaneBadge { case before, after }

    @ViewBuilder
    private func pane(badge kind: PaneBadge?, @ViewBuilder content: () -> some View) -> some View {
        content()
            .background(RPTheme.imageBackground)
            .clipShape(RoundedRectangle(cornerRadius: paneCornerRadius))
            .overlay(alignment: .topLeading) {
                if showsPaneBadges, let kind { badge(kind).padding(10) }
            }
    }

    private func badge(_ kind: PaneBadge) -> some View {
        Text(kind == .before ? "Trước" : "Sau")
            .font(RPTheme.text(11.5, weight: .medium))
            .foregroundStyle(kind == .before ? RPTheme.textPrimary : RPTheme.onAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                kind == .before ? AnyShapeStyle(RPTheme.overlayBadge)
                    : AnyShapeStyle(RPTheme.accent.opacity(0.9)),
                in: RoundedRectangle(cornerRadius: 6))
    }

    /// The edited side. An `MTKView` when the GPU path is up, otherwise the
    /// decoded original — never a fake.
    @ViewBuilder
    private func editedPicture(_ fallback: PreviewImage, frame: CGRect, in size: CGSize)
        -> some View
    {
        if let live = model.live, live.isReady {
            // `live.version` is read *here*, in the body, so that a slider move
            // re-evaluates this view and the representable's `update` fires.
            // See `LivePreviewMetalView.version`.
            LivePreviewMetalView(controller: live, version: live.version, imageFrame: frame)
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            picture(fallback, frame: frame, in: size)
        }
    }

    private func picture(_ image: PreviewImage, frame: CGRect, in size: CGSize) -> some View {
        Image(decorative: image.cgImage, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: max(1, frame.width), height: max(1, frame.height))
            .position(x: frame.midX, y: frame.midY)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
    }

    // MARK: - Face outlines

    /// One tappable outline per detected face, shown only when the choice
    /// matters (more than one face) and only in "after" modes — a face box over
    /// the untouched original would suggest the selection changes that too.
    ///
    /// The chips in ``FaceChipsView`` are the primary control (the mockup's);
    /// these outlines say *which* face a chip means.
    @ViewBuilder
    private func faceOutlines(size: CGSize, paneSize: CGSize) -> some View {
        if let live = model.live, live.faces.count > 1, let original,
            !model.beforeAfter.showsOriginalFullFrame
        {
            let frame = model.viewport.imageFrame(
                imageSize: original.pixelSize, viewSize: paneSize)
            // In the dual-pane comparison the outlines belong over the *Sau*
            // pane, which starts half a canvas to the right.
            let originX = isDualPane ? (size.width + RPTheme.Metrics.macCanvasGap) / 2 : 0
            let selected = model.faceSelection.selectedIndex
            ZStack(alignment: .topLeading) {
                ForEach(Array(live.faces.indices), id: \.self) { index in
                    if let box = live.faceBox(index) {
                        let rect = FaceOverlayGeometry.viewRect(
                            imageRect: box, imageSize: original.pixelSize, frame: frame)
                        FaceTarget(
                            number: index + 1,
                            isSelected: selected == index,
                            isDimmed: selected != nil && selected != index
                        ) {
                            // Tapping the selected face clears the selection —
                            // the same "second tap undoes it" rule the filmstrip
                            // uses for ratings and flags.
                            model.selectFace(selected == index ? nil : index)
                        }
                        .frame(width: max(8, rect.width), height: max(8, rect.height))
                        .position(x: originX + rect.midX, y: rect.midY)
                    }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            .allowsHitTesting(true)
        }
    }

    // MARK: - States

    /// Only shown when something is actually wrong: the GPU path is down and the
    /// sliders therefore cannot change the picture. The mockup has no status
    /// bar, and a permanently-visible HUD would be chrome the design does not
    /// have — but silently showing the unedited file is worse (docs/ADR-0015).
    @ViewBuilder private var livePreviewWarning: some View {
        if model.activeShot != nil, let live = model.live, !live.isReady, !live.isPreparing {
            Label(
                live.failureMessage ?? "Không có preview GPU — đang hiện ảnh gốc",
                systemImage: "exclamationmark.triangle"
            )
            .font(RPTheme.text(11))
            .foregroundStyle(RPTheme.textSecondary)
            .lineLimit(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RPTheme.overlayPill, in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 14)
        } else if model.activeShot != nil, model.live == nil {
            Label("Không có preview GPU — đang hiện ảnh gốc", systemImage: "exclamationmark.triangle")
                .font(RPTheme.text(11))
                .foregroundStyle(RPTheme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RPTheme.overlayPill, in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 14)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.system(size: 40))
                .foregroundStyle(RPTheme.textTertiary)
            Text("Chưa chọn ảnh")
                .font(RPTheme.text(14, weight: .medium))
                .foregroundStyle(RPTheme.textSecondary)
            Text("Nhập ảnh vào dự án, rồi chọn một khung trong thư viện.")
                .font(RPTheme.text(11.5))
                .foregroundStyle(RPTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text("Không mở được ảnh này")
                .font(RPTheme.text(14, weight: .medium))
                .foregroundStyle(RPTheme.textSecondary)
            Text(message)
                .font(RPTheme.text(11))
                .foregroundStyle(RPTheme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
    }

    // MARK: - Loading

    /// **Only the shot identity.** The `EditState` is deliberately *not* in the
    /// key any more: an edit now repaints the GPU canvas from the texture that
    /// is already uploaded, and re-decoding the file on every slider tick is the
    /// thing this whole item exists to stop.
    private var taskKey: String {
        model.activeShot?.id.rawValue ?? "-"
    }

    private func load() async {
        guard let shot = model.activeShot,
            let request = model.previewRequest(
                maxPixelSize: RenderQuality.preview.preferredLongEdge ?? 2048)
        else {
            original = nil
            model.live?.close()
            return
        }
        loadFailure = nil
        do {
            // `request.original` — the "before" side and the geometry source is
            // always the untouched file.
            let decoded = try await cache.image(for: request.original)
            original = decoded
            await model.live?.open(
                decoded,
                contentHash: shot.contentHash ?? shot.id.rawValue,
                editState: model.activeEditState)
        } catch {
            guard !Task.isCancelled else { return }
            original = nil
            loadFailure = String(describing: error)
        }
    }

    private func adopt(size: CGSize) {
        guard let image = original else { return }
        model.viewport.refitIfFollowingWindow(imageSize: image.pixelSize, in: size)
        model.viewport.clampOffset(imageSize: image.pixelSize, viewSize: size)
    }
}

/// The mockup's face-selection chips: "Mặt 1", "Mặt 2", the selected one filled
/// mint. Tapping the selected chip clears the selection, i.e. goes back to
/// "every face" — which is the same thing the "Đồng bộ" toggle says.
struct FaceChipsView: View {
    @Bindable var model: EditorModel

    var body: some View {
        if model.detectedFaceCount > 0 {
            let selected = model.faceSelection.selectedIndex
            HStack(spacing: 8) {
                ForEach(0..<model.detectedFaceCount, id: \.self) { index in
                    Button {
                        model.selectFace(selected == index ? nil : index)
                    } label: {
                        RPOverlayPill(isSelected: selected == index) {
                            Text("Mặt \(index + 1)")
                                .font(RPTheme.text(11.5, weight: .medium))
                                .foregroundStyle(
                                    selected == index ? RPTheme.onAccent : RPTheme.textBright)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mặt \(index + 1)")
                    .accessibilityAddTraits(
                        selected == index ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }
}

/// One tappable face outline.
private struct FaceTarget: View {
    let number: Int
    let isSelected: Bool
    let isDimmed: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isSelected ? RPTheme.accent : .white.opacity(isDimmed ? 0.25 : 0.55),
                    lineWidth: isSelected ? 2 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Khung mặt \(number)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// The draggable divider for `.split` mode.
private struct SplitHandle: View {
    let fraction: CGFloat
    let width: CGFloat
    let move: (CGFloat) -> Void

    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.9))
            .frame(width: 1)
            .overlay {
                Circle()
                    .fill(.white.opacity(0.9))
                    .frame(width: 24, height: 24)
                    .overlay {
                        Image(systemName: "arrow.left.and.right")
                            .font(.caption2)
                            .foregroundStyle(.black)
                    }
            }
            .frame(maxHeight: .infinity)
            .position(x: width * fraction)
            .contentShape(Rectangle().size(width: 40, height: 10_000))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { move($0.location.x) }
            )
            .allowsHitTesting(true)
    }
}

/// Platform input. AppKit events on macOS (scroll = pan, ⌥scroll / pinch =
/// zoom, drag = pan, double click = fit ⇄ 100 %, **press and hold = show the
/// original**); SwiftUI gestures on iOS, where the hold is a
/// `LongPressGesture` sequenced into a zero-distance drag so the *release* is
/// observable — `onLongPressGesture(pressing:)` reports the press starting, not
/// the finger lifting after the threshold.
///
/// Holding the picture replaced a toolbar eye button and a split-view toggle,
/// on both platforms: the picture is the control.
private struct CanvasInputModifier: ViewModifier {
    let viewSize: CGSize
    let imageSize: CGSize
    @Binding var viewport: CanvasViewport
    @Binding var gestureZoomBaseline: CGFloat?
    let holdOriginal: (Bool) -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
            content.overlay {
                CanvasEventCatcher(
                    onPan: { delta in
                        viewport.pan(by: delta)
                        viewport.clampOffset(imageSize: imageSize, viewSize: viewSize)
                    },
                    onZoom: { factor, anchor in
                        viewport.zoom(by: factor, anchor: anchor, viewSize: viewSize)
                        viewport.clampOffset(imageSize: imageSize, viewSize: viewSize)
                    },
                    onDoubleClick: { anchor in
                        if viewport.isFittingToWindow {
                            viewport.setZoom(1, anchor: anchor, viewSize: viewSize)
                        } else {
                            viewport.fit(imageSize: imageSize, in: viewSize)
                        }
                        viewport.clampOffset(imageSize: imageSize, viewSize: viewSize)
                    },
                    onHoldOriginal: holdOriginal
                )
            }
        #else
            content
                // `simultaneousGesture`, not `gesture`: the pan below is
                // attached further out and would otherwise win the arbitration
                // and the hold would never fire. They do not fight — the hold
                // needs the finger still for 0.18 s, the pan needs 2 pt of
                // movement — and a hold that then drags legitimately does both.
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.18)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { value in
                            if case .second(true, _) = value { holdOriginal(true) }
                        }
                        .onEnded { _ in holdOriginal(false) }
                )
                .gesture(
                    SimultaneousGesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                viewport.pan(
                                    by: CGSize(
                                        width: value.translation.width - lastPan.width,
                                        height: value.translation.height - lastPan.height))
                                lastPan = value.translation
                                viewport.clampOffset(imageSize: imageSize, viewSize: viewSize)
                            }
                            .onEnded { _ in lastPan = .zero },
                        MagnifyGesture(minimumScaleDelta: 0.005)
                            .onChanged { value in
                                let baseline = gestureZoomBaseline ?? viewport.zoom
                                if gestureZoomBaseline == nil { gestureZoomBaseline = baseline }
                                let anchor = CGPoint(
                                    x: value.startLocation.x, y: value.startLocation.y)
                                viewport.setZoom(
                                    baseline * value.magnification,
                                    anchor: anchor, viewSize: viewSize)
                                viewport.clampOffset(imageSize: imageSize, viewSize: viewSize)
                            }
                            .onEnded { _ in gestureZoomBaseline = nil }
                    )
                )
                .onTapGesture(count: 2) {
                    let anchor = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
                    if viewport.isFittingToWindow {
                        viewport.setZoom(1, anchor: anchor, viewSize: viewSize)
                    } else {
                        viewport.fit(imageSize: imageSize, in: viewSize)
                    }
                    viewport.clampOffset(imageSize: imageSize, viewSize: viewSize)
                }
        #endif
    }

    #if !os(macOS)
        @State private var lastPan: CGSize = .zero
    #endif
}

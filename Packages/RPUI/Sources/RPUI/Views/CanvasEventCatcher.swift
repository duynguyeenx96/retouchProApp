#if os(macOS)

    import AppKit
    import SwiftUI

    /// Mac-only overlay that turns real AppKit input into viewport changes.
    ///
    /// SwiftUI has no scroll-wheel or right-drag event on macOS, and
    /// `MagnifyGesture` alone leaves the Mac with no way to pan a photo with the
    /// trackpad — which is how everyone actually navigates a 24 MP frame. A
    /// 60-line `NSView` gets the platform behaviour instead of an approximation:
    ///
    /// | input | result |
    /// |---|---|
    /// | two-finger scroll / wheel | pan |
    /// | ⌥ or ⌘ + scroll | zoom about the pointer |
    /// | pinch (`magnify:`) | zoom about the pointer |
    /// | drag | pan |
    /// | double click | fit / 100 % toggle |
    /// | press and hold (no drag) | show the untouched original while held |
    ///
    /// It is `#if os(macOS)` and lives in RPUI, the only package allowed to see
    /// AppKit (docs/ADR-0001 §2).
    struct CanvasEventCatcher: NSViewRepresentable {
        var onPan: (CGSize) -> Void
        var onZoom: (CGFloat, CGPoint) -> Void
        var onDoubleClick: (CGPoint) -> Void
        /// `true` while the pointer has been held still on the picture — the
        /// Mac half of "đè chuột vào hình sẽ show hình gốc". There is no toolbar
        /// button for it: pressing the picture *is* the control.
        var onHoldOriginal: (Bool) -> Void = { _ in }
        /// `true` while "Cọ mask thủ công" is armed (docs/PLAN.md §6.1). A
        /// press-drag-release then paints a stroke instead of panning, and the
        /// press-and-hold peek is off so a slow stroke cannot flash the
        /// original. Scroll-wheel pan and ⌥scroll zoom are untouched — the
        /// trackpad keeps navigating while the mouse button paints.
        var isBrushing = false
        var onBrush: (CanvasBrushPhase, CGPoint) -> Void = { _, _ in }

        func makeNSView(context: Context) -> EventView {
            let view = EventView()
            apply(to: view)
            return view
        }

        func updateNSView(_ view: EventView, context: Context) {
            apply(to: view)
        }

        private func apply(to view: EventView) {
            view.onPan = onPan
            view.onZoom = onZoom
            view.onDoubleClick = onDoubleClick
            view.onHoldOriginal = onHoldOriginal
            view.onBrush = onBrush
            // Disarming mid-stroke (the user hit "Xong" with the button down)
            // has to close the stroke, or the session keeps an in-flight stroke
            // no event will ever finish.
            //
            // One runloop later, because this runs *inside* a SwiftUI update and
            // the callback writes the canvas's `@State` — doing it synchronously
            // is the "Modifying state during view update" warning.
            if view.isBrushing && !isBrushing {
                DispatchQueue.main.async { [weak view] in view?.finishBrushStroke() }
            }
            view.isBrushing = isBrushing
        }

        final class EventView: NSView {
            var onPan: ((CGSize) -> Void)?
            var onZoom: ((CGFloat, CGPoint) -> Void)?
            var onDoubleClick: ((CGPoint) -> Void)?
            var onHoldOriginal: ((Bool) -> Void)?
            var onBrush: ((CanvasBrushPhase, CGPoint) -> Void)?
            var isBrushing = false
            private var isPainting = false

            /// Ends a stroke that is still in flight. Safe to call when there is
            /// none.
            func finishBrushStroke() {
                guard isPainting else { return }
                isPainting = false
                onBrush?(.ended, .zero)
            }

            /// Seconds the button must be down, without moving, before the
            /// original appears. Long enough that a click-drag pan never flashes
            /// it, short enough to feel like "press to peek".
            private static let holdDelay: TimeInterval = 0.18
            private var holdTimer: Timer?
            private var isHolding = false

            /// Flipped so the coordinates handed to the viewport match
            /// SwiftUI's top-left origin without a per-event conversion.
            override var isFlipped: Bool { true }
            override var acceptsFirstResponder: Bool { true }

            private func location(of event: NSEvent) -> CGPoint {
                convert(event.locationInWindow, from: nil)
            }

            override func scrollWheel(with event: NSEvent) {
                let zooming = event.modifierFlags.contains(.option)
                    || event.modifierFlags.contains(.command)
                if zooming {
                    // ~1.5 % per point: fast enough to cross the zoom range in
                    // one gesture, slow enough to land on 100 %.
                    let factor = exp(event.scrollingDeltaY * 0.015)
                    onZoom?(factor, location(of: event))
                } else {
                    onPan?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
                }
            }

            override func magnify(with event: NSEvent) {
                onZoom?(1 + event.magnification, location(of: event))
            }

            override func mouseDown(with event: NSEvent) {
                if isBrushing {
                    // No double-click fit while painting: the second click of a
                    // dab is a dab, not a zoom.
                    cancelHold()
                    isPainting = true
                    onBrush?(.began, location(of: event))
                    return
                }
                if event.clickCount == 2 {
                    cancelHold()
                    onDoubleClick?(location(of: event))
                    return
                }
                holdTimer?.invalidate()
                holdTimer = Timer.scheduledTimer(
                    withTimeInterval: Self.holdDelay, repeats: false
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.isHolding = true
                        self.onHoldOriginal?(true)
                    }
                }
            }

            override func mouseDragged(with event: NSEvent) {
                if isPainting {
                    onBrush?(.moved, location(of: event))
                    return
                }
                // Any movement means "pan", not "peek".
                cancelHold()
                onPan?(CGSize(width: event.deltaX, height: -event.deltaY))
            }

            override func mouseUp(with event: NSEvent) {
                finishBrushStroke()
                cancelHold()
            }

            /// Also on window deactivation / view teardown, so the canvas cannot
            /// get stuck showing the original with no button down — or, now,
            /// with a stroke still open.
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if window == nil {
                    finishBrushStroke()
                    cancelHold()
                }
            }

            private func cancelHold() {
                holdTimer?.invalidate()
                holdTimer = nil
                if isHolding {
                    isHolding = false
                    onHoldOriginal?(false)
                }
            }
        }
    }

#endif

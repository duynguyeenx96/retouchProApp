import CoreGraphics
import Metal
import MetalKit
import RPEngine
import SwiftUI

#if os(macOS)
    import AppKit
    private typealias PlatformViewRepresentable = NSViewRepresentable
#else
    import UIKit
    private typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// The canvas's `MTKView`, wrapped for SwiftUI on both platforms.
///
/// ## On-demand drawing, not a 60 Hz treadmill
///
/// `isPaused = true` + `enableSetNeedsDisplay = true`. A photo editor's canvas
/// is static between interactions; a display-link loop would keep the GPU (and
/// on iPhone, the battery and the thermal budget) busy redrawing an unchanged
/// picture. A redraw happens when SwiftUI hands this view a new
/// ``LivePreviewController/version`` or a new placement, and at no other time.
///
/// ## Which work happens per redraw
///
/// * `version` changed (a slider moved, the shot changed, faces arrived) →
///   run the render graph, then present.
/// * only the placement changed (zoom / pan / window resize) → present only.
///   Panning does not re-run a single node, which is the whole reason the graph
///   output is a texture the renderer keeps rather than something it hands back.
///
/// ## Colour
///
/// `colorPixelFormat = .bgra8Unorm` (**not** `_srgb`) with the layer's colour
/// space set to sRGB, because the pipeline's values are already sRGB-encoded
/// (`RenderQuality.pixelSpace`, ADR-0007). An `_srgb` drawable would encode them
/// a second time and the canvas would look washed out.
/// `framebufferOnly = false` because the present pass is a compute kernel
/// writing straight into the drawable.
struct LivePreviewMetalView: PlatformViewRepresentable {
    let controller: LivePreviewController
    /// `controller.version`, passed in as a **stored property on purpose**.
    ///
    /// SwiftUI re-runs `updateNSView`/`updateUIView` when the enclosing body is
    /// re-evaluated, and it re-evaluates a body only for the observable
    /// properties that body *read*. Holding the controller is not enough — the
    /// controller is a reference and reading `.version` inside `draw(in:)` is
    /// not a body read. Taking the version here forces the canvas to read it
    /// while building this view, which is what turns a slider move into a
    /// redraw. Without it the graph runs once and never again.
    let version: Int
    /// Where the image goes inside the view, in **points**. The coordinator
    /// scales it to drawable pixels, because that factor is the view's and
    /// SwiftUI does not know it.
    let imageFrame: CGRect
    /// Canvas background, sRGB-encoded.
    var background: SIMD4<Float> = SIMD4<Float>(0.08, 0.08, 0.08, 1)

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    #if os(macOS)
        func makeNSView(context: Context) -> MTKView { makeView(context.coordinator) }
        func updateNSView(_ view: MTKView, context: Context) { update(view, context.coordinator) }
        static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
            view.delegate = nil
        }
    #else
        func makeUIView(context: Context) -> MTKView { makeView(context.coordinator) }
        func updateUIView(_ view: MTKView, context: Context) { update(view, context.coordinator) }
        static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
            view.delegate = nil
        }
    #endif

    private func makeView(_ coordinator: Coordinator) -> MTKView {
        let view = MTKView(frame: .zero, device: controller.renderer.context.device)
        view.delegate = coordinator
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColor(
            red: Double(background.x), green: Double(background.y),
            blue: Double(background.z), alpha: 1)
        #if os(macOS)
            view.layer?.isOpaque = true
        #else
            view.isOpaque = true
            view.backgroundColor = .black
        #endif
        if let layer = view.layer as? CAMetalLayer {
            // The values in the pipeline are sRGB *code values*; say so, and let
            // the compositor do no further conversion.
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            // `framebufferOnly = false` above already asks for this on every OS
            // shipped so far; setting it explicitly means a future default
            // cannot silently take `.shaderWrite` away from the present pass.
            layer.framebufferOnly = false
        }
        return view
    }

    private func update(_ view: MTKView, _ coordinator: Coordinator) {
        coordinator.imageFrameInPoints = imageFrame
        coordinator.background = background
        view.setNeedsDisplay(view.bounds)
    }

    /// The `MTKViewDelegate`. `@MainActor` because `MTKView` calls it on the
    /// main thread when `enableSetNeedsDisplay` drives the redraw, and because
    /// it reads the `@MainActor` controller.
    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let controller: LivePreviewController
        var imageFrameInPoints: CGRect = .zero
        var background = SIMD4<Float>(0.08, 0.08, 0.08, 1)
        /// The controller version whose graph output is currently in the
        /// renderer's output texture.
        private var drawnVersion = -1

        init(controller: LivePreviewController) {
            self.controller = controller
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Nothing to invalidate: a resize changes only the placement, and
            // `draw(in:)` recomputes it from the new drawable size.
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable else { return }
            guard controller.isReady else { return }

            let renderer = controller.renderer
            if drawnVersion != controller.version {
                let request = controller.renderRequest
                let start = DispatchTime.now().uptimeNanoseconds
                do {
                    let report = try renderer.render(request)
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                    controller.recordFrame(milliseconds: ms, report: report)
                    drawnVersion = controller.version
                } catch {
                    // Leave `drawnVersion` alone so the next redraw retries, and
                    // still present the previous picture rather than a black
                    // flash.
                    RPUILog.renderFailure(error)
                }
            }

            let scale = view.bounds.width > 0 ? view.drawableSize.width / view.bounds.width : 1
            let placement = PreviewPlacement(
                destinationSize: view.drawableSize,
                imageRect: CGRect(
                    x: imageFrameInPoints.origin.x * scale,
                    y: imageFrameInPoints.origin.y * scale,
                    width: imageFrameInPoints.width * scale,
                    height: imageFrameInPoints.height * scale),
                background: background)
            do {
                let commandBuffer = try renderer.makePresentCommandBuffer(
                    into: drawable.texture, placement: placement)
                // Present without `waitUntilCompleted`: the graph render above
                // already synchronised, and blocking the main thread on the
                // compositor as well would halve the interactive frame rate for
                // nothing.
                commandBuffer.present(drawable)
                commandBuffer.commit()
            } catch {
                RPUILog.renderFailure(error)
            }
        }
    }
}

/// One place for the canvas's failure logging, so a per-frame error cannot turn
/// into a per-frame `print` storm.
enum RPUILog {
    nonisolated(unsafe) private static var lastMessage: String?

    static func renderFailure(_ error: any Error) {
        let message = String(describing: error)
        guard message != lastMessage else { return }
        lastMessage = message
        print("[RPUI] live preview: \(message)")
    }
}

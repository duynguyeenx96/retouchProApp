import CoreGraphics
import Foundation
import Testing

import RPCore
import RPEngine
@testable import RPUI

/// Phase 2 — the UI half of the live preview (docs/ADR-0013).
///
/// Nothing here needs a GPU: what is being checked is the *wiring* — that a
/// slider writes the key the engine reads, that dragging does not hit the disk,
/// that the face outline lands where the face is, and that the face selection
/// goes into `perImage`. The GPU half (bit-identity with `RenderGraph`) is
/// `RPEngineTests/LivePreviewRendererTests`.
@Suite("Phase 2 live preview wiring")
@MainActor
struct LivePreviewWiringTests {

    // MARK: - Panel ↔ engine

    /// The panel builds its parameter list from the engine's own key lists, so
    /// this is really "did that stay true": a hand-written key in the UI would
    /// write JSON that no node reads, and the slider would look like it works
    /// and do nothing.
    @Test("Every working group's slider keys are exactly the engine's, in order")
    func panelKeysMatchTheEngine() throws {
        let expected: [String: [String]] = [
            EditState.SectionKey.skin: SkinSliders.Key.all,
            EditState.SectionKey.face: FaceSliders.Key.all,
            EditState.SectionKey.eyesTeeth: EyesTeethSliders.Key.all,
            EditState.SectionKey.color: ColorSliders.Key.all,
        ]
        for (key, keys) in expected {
            let section = try #require(SliderPanelLayout.section(forKey: key))
            #expect(section.parameters.map(\.key) == keys, "\(key)")
        }
        #expect(SliderPanelLayout.workingParameterCount == 8 + 15 + 4 + 18)
    }

    @Test("Every working slider has a label and a stated direction")
    func everySliderSaysWhichWayItGoes() {
        for section in SliderPanelLayout.sections {
            for parameter in section.parameters {
                #expect(!parameter.label.isEmpty, "\(parameter.key)")
                // Every slider in this project is 0–100 one-directional
                // (ADR-0010/0012); an unlabelled direction is a guess.
                #expect(!parameter.direction.isEmpty, "\(parameter.key)")
            }
        }
    }

    @Test("Phase 5 groups still carry names only")
    func phaseFiveGroupsHaveNoWorkingSliders() throws {
        for key in [EditState.SectionKey.makeup, EditState.SectionKey.hair] {
            let section = try #require(SliderPanelLayout.section(forKey: key))
            #expect(section.parameters.isEmpty)
            #expect(!section.plannedParameters.isEmpty)
            #expect(section.phase == "Phase 5")
        }
    }

    @Test("Only the Color group works without a face")
    func faceDependenceIsDeclared() {
        #expect(SliderPanelLayout.section(forKey: EditState.SectionKey.color)?.needsFace == false)
        for key in [
            EditState.SectionKey.skin, EditState.SectionKey.face, EditState.SectionKey.eyesTeeth,
        ] {
            #expect(SliderPanelLayout.section(forKey: key)?.needsFace == true, "\(key)")
        }
    }

    // MARK: - Writing sliders

    @Test("A slider drag changes memory and the render request, but not the disk")
    func dragDoesNotWriteToDisk() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        await model.select(shotID: temp.project.shots[0].id)

        model.setSlider(ColorSliders.Key.exposure, in: EditState.SectionKey.color, to: 40)
        #expect(model.slider(ColorSliders.Key.exposure, in: EditState.SectionKey.color) == 40)
        #expect(ColorSliders(model.activeEditState).exposure == 40)
        // Nothing on disk yet: a drag is tens of values a second.
        let onDisk = try temp.store.loadEditState(for: temp.project.shots[0].id)
        #expect(onDisk.isDefault)

        await model.commitEditState()
        let saved = try temp.store.loadEditState(for: temp.project.shots[0].id)
        #expect(ColorSliders(saved).exposure == 40)
    }

    @Test("Leaving a shot commits an uncommitted drag")
    func switchingShotsCommits() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        await model.select(shotID: temp.project.shots[0].id)
        model.setSlider(SkinSliders.Key.smooth, in: EditState.SectionKey.skin, to: 60)

        await model.select(shotID: temp.project.shots[1].id)
        let saved = try temp.store.loadEditState(for: temp.project.shots[0].id)
        #expect(SkinSliders(saved).smooth == 60)
        // …and the new shot starts from its own (empty) document.
        #expect(model.activeEditState.isDefault)
    }

    @Test("Setting a slider back to 0 removes the key, keeping 'absent' == 'neutral'")
    func zeroRemovesTheKey() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        await model.select(shotID: temp.project.shots[0].id)

        model.setSlider(ColorSliders.Key.contrast, in: EditState.SectionKey.color, to: 30)
        #expect(model.activeEditState.sections[EditState.SectionKey.color] != nil)
        model.setSlider(ColorSliders.Key.contrast, in: EditState.SectionKey.color, to: 0)
        #expect(model.activeEditState.isDefault)
    }

    @Test("Reset clears one group and 'reset all' clears every group but keeps perImage")
    func resets() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        await model.select(shotID: temp.project.shots[0].id)

        model.setSlider(ColorSliders.Key.exposure, in: EditState.SectionKey.color, to: 40)
        model.setSlider(SkinSliders.Key.smooth, in: EditState.SectionKey.skin, to: 50)
        model.selectFace(1)

        model.resetSection(EditState.SectionKey.skin)
        #expect(model.activeEditState[section: EditState.SectionKey.skin].isEmpty)
        #expect(ColorSliders(model.activeEditState).exposure == 40)

        model.resetAllSliders()
        #expect(model.activeEditState.sections.isEmpty)
        // The face selection is per-image state, not a look: resetting the look
        // must not silently retarget the sliders onto a different person.
        #expect(FaceSelection(model.activeEditState).selectedIndex == 1)
    }

    // MARK: - Face selection

    @Test("Selecting a face writes perImage and clearing it removes the key")
    func faceSelectionRoundTrip() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        await model.select(shotID: temp.project.shots[0].id)

        model.selectFace(2)
        #expect(model.activeEditState.perImage[FaceSelection.key]?.numberValue == 2)
        await model.commitEditState()
        #expect(
            FaceSelection(try temp.store.loadEditState(for: temp.project.shots[0].id))
                .selectedIndex == 2)

        model.selectFace(nil)
        #expect(model.activeEditState.perImage.isEmpty)
    }

    /// With no live preview (no GPU in CI, or no face analysis) the model says
    /// zero faces and the selection resolves to "all" — which is the behaviour
    /// that existed before this feature.
    @Test("No live preview means no faces and no selection")
    func noLivePreviewMeansAllFaces() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        #expect(model.live == nil)
        #expect(model.detectedFaceCount == 0)
        model.selectFace(3)
        #expect(model.faceSelection.selectedIndex == nil)
    }

    // MARK: - The performance rule

    /// Counts how many times the canvas asks for face analysis.
    final class CountingFaceProvider: FaceInputProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return _calls
        }
        let faces: [FaceRenderInput]

        init(faces: [FaceRenderInput]) { self.faces = faces }

        func faceInputs(
            for image: PreviewImage, contentHash: String, kinds: Set<RenderMaskKind>
        ) async throws -> [FaceRenderInput] {
            count()
            return faces
        }

        /// Not inline in the `async` method: `NSLock.lock()` is unavailable from
        /// an asynchronous context (it would be held across a suspension point).
        private func count() {
            lock.lock()
            defer { lock.unlock() }
            _calls += 1
        }
    }

    /// The rule this whole item is built around: face analysis is ~36 ms per
    /// image and a drag issues tens of redraws a second, so it must run **once
    /// per shot** and never per frame. The engine-side cost of a redraw is in
    /// `Research/bench/p2-live-preview-*.json`; this is the structural half.
    @Test("Opening a shot analyses once; a hundred slider changes analyse zero more times")
    func analysisRunsOncePerShot() async throws {
        guard let context = MetalContext.shared else { return }
        let provider = CountingFaceProvider(faces: [
            Self.face(centre: CGPoint(x: 60, y: 60), width: 40),
            Self.face(centre: CGPoint(x: 200, y: 60), width: 40),
        ])
        let renderer = try LivePreviewRenderer(context: context)
        let controller = LivePreviewController(renderer: renderer, faceProvider: provider)

        let url = try TempProject.writePNG(
            at: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rpui-live-\(UUID().uuidString).png"),
            size: 256)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoded = try ImageDecoder.decode(contentsOf: url, maxPixelSize: 2048)

        await controller.open(decoded, contentHash: "hash-a", editState: EditState())
        #expect(provider.calls == 1)
        #expect(controller.faces.count == 2)
        #expect(controller.faceAnalysisRan)

        let versionAfterOpen = controller.version
        for step in 0..<100 {
            var state = EditState()
            state.setSlider(
                ColorSliders.Key.exposure, in: EditState.SectionKey.color, to: Double(step) + 1)
            controller.update(editState: state)
        }
        #expect(provider.calls == 1, "a slider change must not re-analyse")
        // …and every one of those changes did ask for a redraw.
        #expect(controller.version == versionAfterOpen + 100)

        // Re-opening the same shot does not re-upload or re-analyse either.
        await controller.open(decoded, contentHash: "hash-a", editState: EditState())
        #expect(provider.calls == 1)

        // A different shot does.
        await controller.open(decoded, contentHash: "hash-b", editState: EditState())
        #expect(provider.calls == 2)

        controller.close()
        #expect(controller.faces.isEmpty)
        #expect(controller.isReady == false)
    }

    /// The selection narrows what the graph is asked to render, and nothing
    /// else: `RenderRequest.faces` is the only thing that changes.
    @Test("The render request carries only the selected face")
    func requestCarriesTheSelectedFace() async throws {
        guard let context = MetalContext.shared else { return }
        let provider = CountingFaceProvider(faces: [
            Self.face(centre: CGPoint(x: 60, y: 60), width: 40),
            Self.face(centre: CGPoint(x: 200, y: 60), width: 90),
        ])
        let controller = LivePreviewController(
            renderer: try LivePreviewRenderer(context: context), faceProvider: provider)
        let url = try TempProject.writePNG(
            at: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rpui-live-\(UUID().uuidString).png"),
            size: 256)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoded = try ImageDecoder.decode(contentsOf: url, maxPixelSize: 2048)
        await controller.open(decoded, contentHash: "h", editState: EditState())

        #expect(controller.renderRequest.faces.count == 2)

        var state = EditState()
        FaceSelection(target: .face(index: 1)).write(into: &state)
        controller.update(editState: state)
        #expect(controller.renderRequest.faces.count == 1)
        #expect(controller.renderRequest.faces[0].faceWidth == 90)
        #expect(controller.faceSelection.selectedIndex == 1)
        #expect(controller.renderRequest.quality == .preview)
    }

    /// End to end, without a window: a slider written through the model reaches
    /// the GPU and **changes the pixels**.
    ///
    /// The panel and the canvas are two different views; the only thing joining
    /// them is `EditorModel.activeEditState` → `LivePreviewController` →
    /// `RenderRequest`. This walks that path and reads the output texture back.
    @Test("A slider written through the model changes the rendered pixels")
    func sliderReachesTheGPU() async throws {
        guard let context = MetalContext.shared else { return }
        // The Color group needs no face, so this needs no Core ML models.
        let wasOn = RPEngineFeatureFlags.colorSliders
        RPEngineFeatureFlags.colorSliders = true
        defer { RPEngineFeatureFlags.colorSliders = wasOn }

        let renderer = try LivePreviewRenderer(
            context: context, outputPixelFormat: .rgba32Float)
        #expect(renderer.graph.nodes.contains { $0.name == "color" })
        let controller = LivePreviewController(renderer: renderer)

        let temp = try TempProject(shots: 1)
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL, live: controller)
        await model.select(shotID: temp.project.shots[0].id)

        let url = try #require(model.activeOriginalURL)
        let decoded = try ImageDecoder.decode(contentsOf: url, maxPixelSize: 2048)
        await controller.open(
            decoded, contentHash: "e2e", editState: model.activeEditState)

        try renderer.render(controller.renderRequest)
        let before = try renderer.readOutputPixels()

        model.setSlider(ColorSliders.Key.exposure, in: EditState.SectionKey.color, to: 100)
        let report = try renderer.render(controller.renderRequest)
        let after = try renderer.readOutputPixels()

        #expect(report.nodes == ["color"])
        let change = SpikeTextureIO.maxAbsoluteDifference(before, after)
        print("RPUI slider → GPU: max abs change = \(change)")
        // Exposure 100 is +1 EV on a mid-grey fixture; anything near zero means
        // the write never reached the render request.
        #expect(change > 0.1)

        // …and back to 0 is the original again, bit for bit — the "absent ==
        // neutral" rule all the way down to the shader.
        model.setSlider(ColorSliders.Key.exposure, in: EditState.SectionKey.color, to: 0)
        try renderer.render(controller.renderRequest)
        #expect(
            SpikeTextureIO.maxAbsoluteDifference(before, try renderer.readOutputPixels()) == 0)
    }

    // MARK: - Overlay geometry

    static func face(centre: CGPoint, width: CGFloat) -> FaceRenderInput {
        FaceRenderInput(
            landmarks: [
                CGPoint(x: centre.x - width / 2, y: centre.y - width / 2),
                CGPoint(x: centre.x + width / 2, y: centre.y - width / 2),
                CGPoint(x: centre.x - width / 2, y: centre.y + width / 2),
                CGPoint(x: centre.x + width / 2, y: centre.y + width / 2),
            ],
            faceWidth: width)
    }

    @Test("A face box is the mesh bounding box padded by 12 % of the face width")
    func faceBoxPadding() throws {
        let face = Self.face(centre: CGPoint(x: 100, y: 100), width: 50)
        let box = try #require(FaceOverlayGeometry.box(of: face))
        // 50 × 0.12 is 6.000000000000001 in binary floating point, so compare
        // with a tolerance rather than pretending it is exact.
        #expect(abs(box.minX - 69) < 1e-9)
        #expect(abs(box.width - 62) < 1e-9)
    }

    @Test("A face with no landmarks has no box, and that is legal")
    func facesWithoutLandmarks() {
        #expect(FaceOverlayGeometry.box(of: FaceRenderInput(faceWidth: 100)) == nil)
        #expect(FaceOverlayGeometry.index(at: .zero, in: [FaceRenderInput(faceWidth: 100)]) == nil)
    }

    @Test("Hit testing prefers the smallest box, so a face in front stays selectable")
    func hitTestingPrefersTheSmallestFace() {
        let big = Self.face(centre: CGPoint(x: 100, y: 100), width: 200)
        let small = Self.face(centre: CGPoint(x: 100, y: 100), width: 40)
        #expect(FaceOverlayGeometry.index(at: CGPoint(x: 100, y: 100), in: [big, small]) == 1)
        #expect(FaceOverlayGeometry.index(at: CGPoint(x: 100, y: 100), in: [small, big]) == 0)
        // Outside every box.
        #expect(FaceOverlayGeometry.index(at: CGPoint(x: 400, y: 400), in: [big, small]) == nil)
    }

    /// The outline has to sit on the face at any zoom and pan, so it is mapped
    /// with the very frame the picture is drawn with.
    @Test("The overlay maps through CanvasViewport.imageFrame and round-trips")
    func overlayMapping() {
        let imageSize = CGSize(width: 2048, height: 1365)
        var viewport = CanvasViewport()
        viewport.setZoom(0.37, anchor: CGPoint(x: 200, y: 150), viewSize: CGSize(width: 800, height: 600))
        let frame = viewport.imageFrame(imageSize: imageSize, viewSize: CGSize(width: 800, height: 600))

        let box = CGRect(x: 500, y: 300, width: 240, height: 260)
        let onScreen = FaceOverlayGeometry.viewRect(
            imageRect: box, imageSize: imageSize, frame: frame)
        // A box inside the image maps inside the drawn frame…
        #expect(onScreen.minX >= frame.minX - 0.001)
        #expect(onScreen.maxX <= frame.maxX + 0.001)
        // …and the inverse of the mapping gives the corner back.
        let back = FaceOverlayGeometry.imagePoint(
            viewPoint: CGPoint(x: onScreen.minX, y: onScreen.minY),
            imageSize: imageSize, frame: frame)
        #expect(abs(back.x - box.minX) < 1e-6)
        #expect(abs(back.y - box.minY) < 1e-6)
    }

    @Test("A zero-sized frame cannot divide by zero")
    func degenerateFrames() {
        #expect(
            FaceOverlayGeometry.viewRect(
                imageRect: CGRect(x: 0, y: 0, width: 10, height: 10), imageSize: .zero,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100)) == .zero)
        #expect(
            FaceOverlayGeometry.imagePoint(
                viewPoint: CGPoint(x: 5, y: 5), imageSize: CGSize(width: 10, height: 10),
                frame: .zero) == .zero)
    }
}

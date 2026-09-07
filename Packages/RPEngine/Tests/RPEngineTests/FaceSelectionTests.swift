import CoreGraphics
import Foundation
import RPCore
import Testing

@testable import RPEngine

/// Phase 2 — the multi-face selection state model (docs/ADR-0013).
///
/// No GPU here on purpose: the whole feature is one integer in
/// `EditState.perImage` plus an array filter, and that is the point — no render
/// node changed, so no measured number moved.
@Suite("Phase 2 face selection")
struct FaceSelectionTests {
    static func face(_ width: CGFloat) -> FaceRenderInput {
        FaceRenderInput(landmarks: [CGPoint(x: width, y: width)], faceWidth: width)
    }
    static let faces = [face(100), face(200), face(300)]

    @Test("The default is every face, and it writes nothing into the document")
    func defaultIsAllFaces() {
        var state = EditState()
        let selection = FaceSelection()
        #expect(selection.target == .allFaces)
        #expect(selection.selectedIndex == nil)
        selection.write(into: &state)
        // An untouched document must stay empty — the same rule
        // `EditSection.setSlider` follows for a slider back at 0.
        #expect(state.perImage.isEmpty)
        #expect(state.isDefault)
        #expect(selection.select(from: Self.faces).count == 3)
    }

    @Test("A selected face round-trips through the document")
    func roundTrip() throws {
        var state = EditState()
        FaceSelection(target: .face(index: 2)).write(into: &state)
        #expect(state.perImage[FaceSelection.key]?.numberValue == 2)
        #expect(state.isDefault == false)

        let data = try RPJSON.encoder.encode(state)
        let decoded = try RPJSON.decoder.decode(EditState.self, from: data)
        #expect(FaceSelection(decoded).selectedIndex == 2)
    }

    @Test("Selecting a face narrows the request to exactly that face")
    func selectionNarrowsTheRequest() {
        let selection = FaceSelection(target: .face(index: 1))
        let selected = selection.select(from: Self.faces)
        #expect(selected.count == 1)
        #expect(selected[0].faceWidth == 200)
    }

    /// The reason the index lives in `perImage` at all: `Preset.make` drops that
    /// bucket, so "face 2" cannot travel to a photo where face 2 is someone else
    /// or does not exist.
    @Test("A preset does not carry the face selection")
    func presetsDoNotCarryTheSelection() {
        var state = EditState()
        ColorSliders(exposure: 40).write(into: &state)
        FaceSelection(target: .face(index: 1)).write(into: &state)

        let preset = Preset(name: "p", from: state)
        let applied = EditState().applying(preset)
        #expect(applied.perImage.isEmpty)
        #expect(FaceSelection(applied).selectedIndex == nil)
        // …and the transferable half is still there.
        #expect(ColorSliders(applied).exposure == 40)
    }

    /// A stale index must not make the sliders silently stop working — that
    /// looks exactly like a broken render graph.
    @Test("An index past the end of the array falls back to every face")
    func staleIndexFallsBackToAllFaces() {
        let selection = FaceSelection(target: .face(index: 7))
        #expect(selection.resolved(faceCount: 3).target == .allFaces)
        #expect(selection.select(from: Self.faces).count == 3)
        #expect(selection.select(from: []).isEmpty)
    }

    @Test("Nonsense in the JSON reads as every face")
    func malformedValuesReadAsAllFaces() {
        for value: JSONValue in [.string("first"), .number(-1), .number(1.5), .bool(true)] {
            var state = EditState()
            state.perImage[FaceSelection.key] = value
            #expect(FaceSelection(state).selectedIndex == nil, "\(value)")
        }
    }

    @Test("RenderRequest(editState:allFaces:) applies the selection once")
    func requestConvenienceApplies() {
        var state = EditState()
        FaceSelection(target: .face(index: 0)).write(into: &state)
        let request = RenderRequest(editState: state, allFaces: Self.faces)
        #expect(request.faces.count == 1)
        #expect(request.faces[0].faceWidth == 100)
        #expect(request.quality == .preview)

        var all = EditState()
        ColorSliders(exposure: 10).write(into: &all)
        #expect(RenderRequest(editState: all, allFaces: Self.faces).faces.count == 3)
    }
}

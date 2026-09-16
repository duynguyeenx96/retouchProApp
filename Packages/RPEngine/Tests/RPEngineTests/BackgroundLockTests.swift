import CoreGraphics
import Foundation
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 6.1 — "Khoá nền" as a document value and as a gate
/// (docs/PLAN.md §6.1, docs/ADR-0018).
///
/// The mask itself is `BackgroundLockMaskTests`; the composite is
/// `ManualMaskTests`. What is left, and what this file pins, is the decision
/// layer between them: one boolean in `EditState`, and the three conditions that
/// must all hold before a subject mask is allowed to narrow a node — **with the
/// empty array, not an all-zero mask, as the answer when any of them does not**.
///
/// `.serialized` and `RPEngineTestFlags.exclusive`, because
/// `RPEngineFeatureFlags` is a process-global store.
@Suite("Phase 6.1 background lock", .serialized)
struct BackgroundLockTests {

    /// A stand-in gate. `TextureGateMask` is what the shipping path builds too,
    /// so this is the real type with a scratch texture behind it.
    static func gate(_ context: MetalContext) throws -> TextureGateMask {
        let texture = try SpikeTextureIO.makeTexture(
            width: 8, height: 8, device: context.device, pixelFormat: .r8Unorm,
            usage: [.shaderRead, .shaderWrite])
        return TextureGateMask(texture: texture)
    }

    // MARK: - The document value

    @Test("The default is off, and it writes nothing into the document")
    func defaultIsOff() {
        var state = EditState()
        #expect(BackgroundLock().isOn == false)
        #expect(BackgroundLock(state).isOn == false)

        BackgroundLock(isOn: false).write(into: &state)
        // An untouched document must stay empty — the same rule
        // `EditSection.setSlider` follows for a slider back at 0, and what keeps
        // `EditState.isDefault` meaning "untouched".
        #expect(state.isDefault)
        #expect(state.sections[BackgroundLock.section] == nil)
    }

    @Test("The toggle round-trips through the document, on disk and back")
    func roundTrip() throws {
        var state = EditState()
        BackgroundLock(isOn: true).write(into: &state)
        #expect(state[section: BackgroundLock.section][BackgroundLock.key]?.boolValue == true)
        #expect(state.isDefault == false)

        let data = try RPJSON.encoder.encode(state)
        let decoded = try RPJSON.decoder.decode(EditState.self, from: data)
        #expect(BackgroundLock(decoded).isOn)
        #expect(decoded == state)

        // …and turning it back off leaves no trace, so a document that was
        // toggled twice is byte-identical to one that never was.
        var reverted = decoded
        BackgroundLock(isOn: false).write(into: &reverted)
        #expect(reverted.isDefault)
        let revertedData = try RPJSON.encoder.encode(reverted)
        let emptyData = try RPJSON.encoder.encode(EditState())
        #expect(revertedData == emptyData)
    }

    /// The failure this guards: a malformed value silently gating every slider
    /// down to nothing. Unreadable reads as **off**, the same way an unreadable
    /// `FaceSelection` reads as "all faces".
    @Test("An unreadable value reads as off")
    func malformedValueIsOff() {
        var state = EditState()
        state[section: BackgroundLock.section][BackgroundLock.key] = .number(1)
        #expect(BackgroundLock(state).isOn == false)

        state[section: BackgroundLock.section][BackgroundLock.key] = .string("true")
        #expect(BackgroundLock(state).isOn == false)

        state[section: BackgroundLock.section][BackgroundLock.key] = .bool(false)
        #expect(BackgroundLock(state).isOn == false)
    }

    /// It is a section and not `perImage` because it transfers: "keep my retouch
    /// off the background" says nothing about which photo it was said on.
    @Test("The lock survives a preset, unlike the face selection")
    func presetsCarryTheLock() {
        var state = EditState()
        BackgroundLock(isOn: true).write(into: &state)
        FaceSelection(target: .face(index: 1)).write(into: &state)

        let preset = Preset(name: "p", from: state)
        #expect(BackgroundLock(EditState().applying(preset)).isOn)
        #expect(FaceSelection(EditState().applying(preset)).selectedIndex == nil)
    }

    // MARK: - The gate

    /// The whole decision table. Three conditions, and the answer to "any of
    /// them is false" is **`[]`** — which `RenderGateMask` defines as "the node
    /// renders exactly the pixels it rendered before Phase 6.1", not "select
    /// nothing". Reading it the other way would switch off every mask-driven
    /// slider in every document that never touched this feature.
    @Test("A gate appears only when the flag, the toggle and a subject mask all agree")
    func gateRequiresAllThree() throws {
        guard let context = SpikeS3Support.context else { return }
        let subject = try Self.gate(context)
        var on = EditState()
        BackgroundLock(isOn: true).write(into: &on)
        let off = EditState()

        try RPEngineTestFlags.exclusive {
            let previous = RPEngineFeatureFlags.backgroundLock
            defer { RPEngineFeatureFlags.backgroundLock = previous }

            // 1. The flag off — the shipping default. Nothing, even with the
            //    document asking for it and a mask in hand.
            RPEngineFeatureFlags.backgroundLock = false
            #expect(BackgroundLock.gateMasks(for: on, subjectGate: subject).isEmpty)

            RPEngineFeatureFlags.backgroundLock = true
            // 2. The toggle off.
            #expect(BackgroundLock.gateMasks(for: off, subjectGate: subject).isEmpty)
            // 3. No subject in the frame — a landscape, a product shot. "Nothing
            //    to lock", not "lock everything".
            #expect(BackgroundLock.gateMasks(for: on, subjectGate: nil).isEmpty)

            // All three: exactly the gate that was handed in, unwrapped and
            // un-copied.
            let gates = BackgroundLock.gateMasks(for: on, subjectGate: subject)
            #expect(gates.count == 1)
            #expect(gates.first === subject)
        }
    }

    /// The flag is re-read per request rather than captured when the gate was
    /// built, so switching it off stops the gating on the very next frame even
    /// though the texture is still allocated.
    @Test("Switching the flag off stops the gating without rebuilding anything")
    func flagIsReadPerRequest() throws {
        guard let context = SpikeS3Support.context else { return }
        let subject = try Self.gate(context)
        var on = EditState()
        BackgroundLock(isOn: true).write(into: &on)

        RPEngineTestFlags.exclusive {
            let previous = RPEngineFeatureFlags.backgroundLock
            defer { RPEngineFeatureFlags.backgroundLock = previous }

            RPEngineFeatureFlags.backgroundLock = true
            #expect(BackgroundLock.gateMasks(for: on, subjectGate: subject).count == 1)
            RPEngineFeatureFlags.backgroundLock = false
            #expect(BackgroundLock.gateMasks(for: on, subjectGate: subject).isEmpty)
        }
    }

    /// `RenderRequest` still defaults to no gates, and the lock only ever
    /// *appends*. A caller with a painted brush keeps it — gates intersect.
    @Test("The gate is appended to gateMasks, never assigned over them")
    func gatesAppend() throws {
        guard let context = SpikeS3Support.context else { return }
        let brush = try Self.gate(context)
        let subject = try Self.gate(context)
        var on = EditState()
        BackgroundLock(isOn: true).write(into: &on)

        var request = RenderRequest(editState: on, faces: [], gateMasks: [brush])
        RPEngineTestFlags.exclusive {
            let previous = RPEngineFeatureFlags.backgroundLock
            defer { RPEngineFeatureFlags.backgroundLock = previous }

            RPEngineFeatureFlags.backgroundLock = true
            request.gateMasks += BackgroundLock.gateMasks(for: on, subjectGate: subject)
            #expect(request.gateMasks.count == 2)
            #expect(request.gateMasks[0] === brush)
            #expect(request.gateMasks[1] === subject)
        }
        #expect(RenderRequest(editState: EditState(), faces: []).gateMasks.isEmpty)
    }

    /// The second half of docs/ADR-0018's still-open blocker, as an assertion
    /// rather than a sentence. (The first half — the flag being off out of the
    /// box — is `BackgroundLockMaskTests.flagDefaultsOff`, which owns the one
    /// `resetToDefaults()` call this suite family makes.)
    ///
    /// `SubjectMaskQuality` has three cases and **no** `default` / `standard`
    /// member for a caller to inherit: that choice belongs to whoever has the
    /// iPhone number, and wiring the UI did not get to make it. `.balanced` is
    /// picked by `RPUI.LivePreviewController` for the *body-skin* mask under its
    /// own flag (ADR-0021), and "Khoá nền" reuses that one already-computed mask
    /// rather than asking for a quality of its own.
    @Test("No quality level default exists to inherit")
    func noQualityDefaultIsDeclared() {
        #expect(SubjectMaskQuality.allCases.count == 3)
        #expect(Set(SubjectMaskQuality.allCases.map(\.rawValue)) == ["fast", "balanced", "accurate"])
    }
}

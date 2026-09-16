import Foundation

/// Default-off switches for RPEngine code that has a measurement but is not yet
/// wired into the product (docs/PLAN.md §2, "measure before ship").
///
/// Phase 0 spike S3 added ``GuidedFilter`` and ``MLSMeshWarp``. Both are off
/// until Phase 2's `RenderGraph` lands, so nothing can accidentally start
/// allocating 24 MP Metal textures on a path that has not been benchmarked on a
/// real device.
///
/// Deliberately a copy of `RPVisionFeatureFlags`' shape rather than a shared
/// type: RPEngine and RPVision are siblings, and hoisting a flag registry into
/// RPCore just so two packages can share three lines would put a
/// process-global mutable store at the bottom of the dependency graph.
public enum RPEngineFeatureFlags {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: [String: Bool] = [:]

    private static func value(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[key] ?? false
    }

    private static func setValue(_ key: String, _ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = newValue
    }

    /// Spike S3: Metal guided filter (edge-preserving smoothing for "Mịn da
    /// giữ texture", docs/PLAN.md §1.3).
    public static var guidedFilter: Bool {
        get { value("guidedFilter") }
        set { setValue("guidedFilter", newValue) }
    }

    /// Spike S3: Moving-Least-Squares mesh warp (face reshape sliders,
    /// docs/PLAN.md §1.3 / §2 "Warp(MLS)").
    public static var mlsMeshWarp: Bool {
        get { value("mlsMeshWarp") }
        set { setValue("mlsMeshWarp", newValue) }
    }

    /// Phase 2: the "Da" slider group (``SkinRenderNode``).
    ///
    /// Owned entirely by that group: nothing else reads it, so turning it off
    /// cannot affect another node.
    public static var skinSliders: Bool {
        get { value("skinSliders") }
        set { setValue("skinSliders", newValue) }
    }

    /// Phase 2: the "Mặt" reshape slider group (``WarpRenderNode``).
    ///
    /// Separate from ``skinSliders`` so any one group can ship while the others
    /// are off — see the note on ``enableSkinRenderGraph()`` about why there is
    /// no umbrella `renderGraph` flag above these two.
    public static var warpSliders: Bool {
        get { value("warpSliders") }
        set { setValue("warpSliders", newValue) }
    }

    /// Phase 2: the "Mắt / Răng" slider group (``EyesTeethRenderNode``).
    ///
    /// Owned entirely by that group, like ``skinSliders`` and ``warpSliders``.
    /// The node also needs ``guidedFilter``, which it shares with the "Da"
    /// group — see ``disableSkinRenderGraph()`` for how the two disable helpers
    /// avoid taking each other down.
    public static var eyesTeethSliders: Bool {
        get { value("eyesTeethSliders") }
        set { setValue("eyesTeethSliders", newValue) }
    }

    /// Phase 2: the "Color" slider group (``ColorRenderNode``).
    ///
    /// Owned entirely by that group, and **the only flag that group needs**: the
    /// node owns all four of its kernels (`rp_color_composite`,
    /// `rp_color_luma_downsample`, `rp_color_box_h`, `rp_color_box_v`) and
    /// borrows neither ``guidedFilter`` nor ``mlsMeshWarp``. So there is no
    /// shared-kernel condition in ``disableColorRenderGraph()`` the way there is
    /// in ``disableSkinRenderGraph()`` — nothing else reads this bit and this bit
    /// reads nothing else.
    public static var colorSliders: Bool {
        get { value("colorSliders") }
        set { setValue("colorSliders", newValue) }
    }

    /// Phase 6 §6.1 "Khoá nền": ``BackgroundLockMaskSource``, the whole-frame
    /// subject mask that keeps an effect off the background.
    ///
    /// Owned entirely by that mask source; no node reads it yet, because nothing
    /// consumes the mask yet (there is no `EditState` field and no UI). It is a
    /// flag rather than nothing at all so the cost — a
    /// `VNGeneratePersonSegmentationRequest` per shot, tens of milliseconds
    /// (`Research/bench/p6-background-lock-*.json`) — cannot start running on a
    /// path nobody has measured on an iPhone.
    ///
    /// Pairs with `RPVisionFeatureFlags.personSegmentation` on the other side of
    /// the seam, and does **not** set it: this bit gates the GPU rasterisation,
    /// that one gates the Vision request, and neither package writes the other's
    /// process-global store.
    public static var backgroundLock: Bool {
        get { value("backgroundLock") }
        set { setValue("backgroundLock", newValue) }
    }

    /// Phase 6.1: the hand-painted mask ("Cọ mask thủ công", docs/PLAN.md §6.1).
    ///
    /// Gated at the **producer**, not at the consumer: ``ManualMaskSession`` and
    /// ``ManualMaskCoverage`` refuse to construct while this is off, so with the
    /// flag off no `RenderRequest` can carry a manual mask and every node renders
    /// exactly the pixels it rendered before Phase 6.1 — the golden numbers in
    /// ADR-0009 … ADR-0012 are untouched by construction, not by promise.
    ///
    /// Owned entirely by this feature: nothing else reads it, and it borrows no
    /// other flag. Painting a mask is useful with *any* mask-driven group on, so
    /// it is deliberately not folded into ``skinSliders``.
    public static var manualMask: Bool {
        get { value("manualMask") }
        set { setValue("manualMask", newValue) }
    }

    /// Phase 6.2: "Tạo khối" (Contour) — the landmark-anchored soft masks that
    /// gate ``ColorRenderNode``'s dodge/burn LUT step (``ContourSliders``,
    /// ``ContourMask``).
    ///
    /// **Not** a second gate on the "Color" group: this bit is read per *render*,
    /// inside `ColorRenderNode.contourLobes(for:)`, not in that node's `init`. So
    /// with it off the node still builds and still grades, and the render is
    /// bit-exact what it was before this group existed — which is the property
    /// `ContourRenderTests.flagOffIsBitExactTheOldRender` measures. Turning it on
    /// borrows no other group's kernel flag (the mask is evaluated inside the
    /// colour composite), so, like ``colorSliders``, it takes exactly one bit
    /// down with it.
    public static var contourSliders: Bool {
        get { value("contourSliders") }
        set { setValue("contourSliders", newValue) }
    }

    /// Turns on the two flags the "Tạo khối" path needs: ``contourSliders`` plus
    /// ``colorSliders``, because the mask is applied by ``ColorRenderNode`` and
    /// that node refuses to build without its own flag.
    public static func enableContourRenderGraph() {
        colorSliders = true
        contourSliders = true
    }

    /// Clears ``contourSliders`` and **nothing else** — in particular it leaves
    /// ``colorSliders`` alone.
    ///
    /// That asymmetry with ``enableContourRenderGraph()`` is the point, and it is
    /// the lesson ``disableSkinRenderGraph()`` records: `colorSliders` is a
    /// *shared* gate (the eighteen colour sliders need it too), so clearing it
    /// from here would let the contour group switch the colour group off behind
    /// its back — exactly the failure the deleted umbrella `renderGraph` flag had.
    /// A caller who wants the colour group off as well says so by calling
    /// ``disableColorRenderGraph()``.
    public static func disableContourRenderGraph() {
        contourSliders = false
    }

    /// Phase 6.2: "Đầu" (head reshape) — the hair-silhouette control points that
    /// extend ``WarpRenderNode``'s MLS solve past the 478-point mesh
    /// (``HeadSliders``, ``HeadReshape``, ``HairBoundary``).
    ///
    /// **Not** a second gate on the "Mặt" group, and read per *render* rather
    /// than in that node's `init` — the same arrangement ``contourSliders`` has
    /// inside ``ColorRenderNode``. With this bit off, ``WarpRenderNode`` neither
    /// traces a hair mask nor looks at a head slider, so it solves exactly the
    /// handles `FaceReshape` gave it before this group existed and the render is
    /// bit-exact what ADR-0010 measured (`HeadReshapeRenderTests
    /// .flagOffIsBitExactTheOldRender`).
    ///
    /// Turning it on borrows the **shared** kernel flag ``mlsMeshWarp``, which
    /// the "Mặt" group also needs — so ``enableHeadRenderGraph()`` sets it and
    /// ``disableHeadRenderGraph()`` deliberately does not clear it, exactly as
    /// ``disableContourRenderGraph()`` leaves ``colorSliders`` alone.
    public static var headSliders: Bool {
        get { value("headSliders") }
        set { setValue("headSliders", newValue) }
    }

    /// Turns on the three flags the "Đầu" path needs: ``headSliders`` plus the
    /// "Mặt" group's ``warpSliders`` and ``mlsMeshWarp``, because the head
    /// handles are solved by ``WarpRenderNode`` and that node refuses to build
    /// without both of its own.
    public static func enableHeadRenderGraph() {
        warpSliders = true
        mlsMeshWarp = true
        headSliders = true
    }

    /// Clears ``headSliders`` and **nothing else** — in particular it leaves
    /// ``warpSliders`` and ``mlsMeshWarp`` alone.
    ///
    /// The asymmetry with ``enableHeadRenderGraph()`` is the point, and it is the
    /// lesson ``disableSkinRenderGraph()`` records: both of those are the "Mặt"
    /// group's gates, and clearing them from here would let the head group switch
    /// the reshape group off behind its back. A caller who wants the whole warp
    /// path off says so by calling ``disableWarpRenderGraph()``.
    public static func disableHeadRenderGraph() {
        headSliders = false
    }

    /// Phase 6 §6.2 "Sửa da": extend the "Da" sliders from the per-face BiSeNet
    /// mask to a whole-frame skin mask (``BodySkinMask`` / ``SkinCore``), so
    /// neck, shoulders and arms in the frame get the *same* slider values as the
    /// face instead of staying untouched.
    ///
    /// **Not a new slider group and not a new kernel gate.** It only decides
    /// whether ``SkinRenderNode`` reads `RenderRequest.bodySkinMask`; with it off
    /// that field is ignored and the node renders exactly what it rendered
    /// before, which is what
    /// `BodySkinUnionTests.flagOffIgnoresTheWholeFrameMask` pins. So it is
    /// deliberately *not* part of ``enableSkinRenderGraph()``: turning the Da
    /// group on must not turn an unshipped mask source on with it.
    ///
    /// ## v2 (2026-09-16) — what the person-segmentation intersection changed
    ///
    /// `BodySkinMask.make(…, subject:)` now multiplies a whole-frame person mask
    /// into the coverage, and the app computes one per shot
    /// (`App/PersonSegmenterSubjectMaskProvider.swift` →
    /// `LivePreviewController` → `RenderRequest.bodySkinMask`). On the cluttered
    /// tone-ladder frame it takes four of six tones from ~0.55 IoU to their
    /// clean-frame recall (I 0.610→0.989, II 0.530→0.872, III 0.572→0.941,
    /// V 0.602→0.983) and drops the wood leak to 0.00 everywhere, while every
    /// clean-frame number is unchanged to the last digit.
    ///
    /// **It fixes neither of the two 0.000s, and the flag stays off because of
    /// them** (docs/ADR-0021 §v2):
    /// * tone VI (deep) is rejected by ``SkinCore``'s Kovac `R <= 95` line, which
    ///   runs before any of this — a multiply can remove a false positive, never
    ///   add a pixel back;
    /// * tone IV on a cluttered frame is still 0.000 because the wood steals the
    ///   *calibration* inside `SkinCore`, not just the output, and by then the
    ///   skin component has already been dropped.
    ///
    /// So: default off, and **no UI toggle** — docs/PLAN.md §6.2's toggle waits
    /// on numbers that do not exist yet, and on a way to tell the user when the
    /// mask came back empty. `AppEngineSetup.enableKey` (`RPEnableExperiments`)
    /// turns the path on for one launch so it can be exercised on a device
    /// without shipping it on.
    public static var bodySkinSync: Bool {
        get { value("bodySkinSync") }
        set { setValue("bodySkinSync", newValue) }
    }

    /// Turns on the two flags the skin path needs: ``skinSliders`` and
    /// ``guidedFilter`` (``SkinRenderNode`` owns a ``GuidedFilter``, whose own
    /// gate is not bypassed).
    ///
    /// A convenience, not a new flag — there is no way to enable the skin path
    /// without also enabling the kernel it is built on, and making a caller
    /// discover that from a thrown `RPEngineFeatureDisabled(feature: "guidedFilter")`
    /// is a worse API than saying it here.
    ///
    /// ### There is deliberately no `renderGraph` flag
    /// Until 2026-09-06 these helpers also set an umbrella `renderGraph` flag
    /// that `RenderGraph.init` gated on, and the disable helpers cleared it. Two
    /// independently shippable groups sharing one stored bit is a bug, not a
    /// gate: `enableSkinRenderGraph()` → `enableWarpRenderGraph()` →
    /// `disableWarpRenderGraph()` left `skinSliders == true` while
    /// `RenderGraph.standard()` threw, i.e. turning the Mặt group off silently
    /// took the Da group down with it. Refcounting the groups behind the bit
    /// would only have fixed the path through these two helpers — a caller
    /// setting `skinSliders = true` directly would still have been switched off
    /// by an unrelated group's disable.
    ///
    /// The flag was also answering the wrong question. What has to be gated is
    /// the *measured algorithm*, and every one of those lives in a node with its
    /// own flag (``skinSliders``, ``warpSliders``, plus the kernels'
    /// ``guidedFilter`` / ``mlsMeshWarp``). ``RenderGraph`` with no registered
    /// node is a stage-ordered list plus one copy pass, whose behaviour —
    /// bit-exact passthrough — is itself asserted
    /// (`RenderGraphTests.emptyEditStateIsPassthrough`). So the flag is gone,
    /// `RenderGraph` is constructible unconditionally, and with every group off
    /// `RenderGraph.standard()` returns an empty graph that copies the picture
    /// through. See docs/ADR-0010.
    public static func enableSkinRenderGraph() {
        skinSliders = true
        guidedFilter = true
    }

    /// The inverse of ``enableSkinRenderGraph()``, and it touches **only** the
    /// skin group's own flag plus the kernel flag *if no other group still needs
    /// it* — see that method's note. Use this in a test `defer` rather than
    /// ``resetToDefaults()`` — see that method's warning.
    ///
    /// ### Why the `guidedFilter` clear is conditional
    /// ``guidedFilter`` gates a *kernel*, and two groups are built on it: the
    /// "Da" group (``SkinRenderNode``) and the "Mắt / Răng" group
    /// (``EyesTeethRenderNode``, which uses it for the local-mean layer behind
    /// "Trắng lòng trắng" / "Nét mắt" / "Trắng răng"). Clearing it
    /// unconditionally would recreate exactly the failure the umbrella
    /// `renderGraph` flag was deleted for: turning one group off would make
    /// `RenderGraph.standard()` throw for the *other* one.
    ///
    /// This is **not** the refcount that was rejected there. It reads the
    /// authoritative group flags themselves, so a caller who set
    /// `eyesTeethSliders = true` by hand — never going through a helper — is
    /// still respected, which a counter could not manage. A caller who sets
    /// `guidedFilter = false` directly is still taken at their word and both
    /// groups then refuse to build: that is the kernel gate meaning what it
    /// says, and `RenderGraph.standard()` throwing is the honest report.
    public static func disableSkinRenderGraph() {
        skinSliders = false
        if !eyesTeethSliders { guidedFilter = false }
    }

    /// The "Mặt" equivalent of ``enableSkinRenderGraph()``: ``warpSliders`` and
    /// ``mlsMeshWarp`` (``WarpRenderNode`` owns an ``MLSMeshWarp``, whose own
    /// gate is not bypassed).
    public static func enableWarpRenderGraph() {
        warpSliders = true
        mlsMeshWarp = true
    }

    /// The exact inverse of ``enableWarpRenderGraph()``, and it touches **only**
    /// the warp group's flags. Unconditional, unlike
    /// ``disableSkinRenderGraph()``: ``mlsMeshWarp`` has exactly one consumer.
    public static func disableWarpRenderGraph() {
        warpSliders = false
        mlsMeshWarp = false
    }

    /// The "Mắt / Răng" equivalent of ``enableSkinRenderGraph()``:
    /// ``eyesTeethSliders`` and ``guidedFilter`` (``EyesTeethRenderNode`` owns a
    /// ``GuidedFilter`` for its local-mean layer, and that kernel's own gate is
    /// not bypassed).
    public static func enableEyesTeethRenderGraph() {
        eyesTeethSliders = true
        guidedFilter = true
    }

    /// The inverse of ``enableEyesTeethRenderGraph()``. Symmetric with
    /// ``disableSkinRenderGraph()``: the shared kernel flag is only cleared when
    /// the other group that needs it is off.
    public static func disableEyesTeethRenderGraph() {
        eyesTeethSliders = false
        if !skinSliders { guidedFilter = false }
    }

    /// The "Color" equivalent of ``enableSkinRenderGraph()`` — except that there
    /// is only one flag to set, because ``ColorRenderNode`` owns every kernel it
    /// uses and borrows no other group's.
    ///
    /// Kept as a helper anyway so every group is enabled the same way at a call
    /// site, and so a future kernel flag for this group has one place to be added.
    public static func enableColorRenderGraph() {
        colorSliders = true
    }

    /// The exact inverse of ``enableColorRenderGraph()``. Unconditional, and
    /// legitimately so — unlike ``disableSkinRenderGraph()``, this group shares
    /// no kernel flag with anyone, so there is nothing to ask about before
    /// clearing.
    public static func disableColorRenderGraph() {
        colorSliders = false
    }

    /// Restores **every** flag to its shipping default.
    ///
    /// Not a per-test teardown hook — this storage is process-global and Swift
    /// Testing runs suites concurrently, so a suite calling this while another
    /// suite has its own flag on switches that other suite off mid-run. That bug
    /// already happened once across RPVision's S1/S2 flags
    /// (docs/ADR-0006). Restore only the flag you set.
    public static func resetToDefaults() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}

/// Thrown when a caller reaches a feature-flagged RPEngine path that is off.
public struct RPEngineFeatureDisabled: Error, CustomStringConvertible {
    public let feature: String
    public init(feature: String) { self.feature = feature }
    public var description: String {
        "RPEngine feature '\(feature)' is disabled. Enable RPEngineFeatureFlags.\(feature) first."
    }
}

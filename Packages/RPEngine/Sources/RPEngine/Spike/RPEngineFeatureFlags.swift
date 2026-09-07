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

# ADR-0009 — `RenderGraph` and the "Da" (skin) slider group

Status: accepted — 2026-09-05
Scope: Phase 2 of `docs/PLAN.md` §3 — the production render pipeline in `RPEngine`
plus the first of its four slider groups. Mặt / Mắt-Răng / Color, the realtime
`MTKView` preview and multi-face canvas selection are **not** in this ADR.

## Context

Spike S3 (`docs/ADR-0007`) left two verified Metal kernels — `GuidedFilter` and
`MLSMeshWarp` — as standalone `encode(into:)` calls behind default-off flags.
They are not a pipeline. Composing them into something a slider panel can drive
needs three things they do not have:

1. a rule for **which passes run at all** (every slider is 0–100 with a default
   of 0, and 0 has to cost nothing, not "cost 1.5 ms to multiply by zero");
2. somewhere to keep the ping-pong intermediates **across frames** — a drag
   re-renders the same size 30–60 times a second;
3. a **fixed stage order**, so the same `EditState` renders the same picture
   twice and a preset means one thing.

`FaceAnalyzer` (`docs/ADR-0008`) supplies the other half: 478 landmarks and
19-class parsing masks per face, cached by content hash.

## Decision — `RenderGraph` is a sorted list of long-lived nodes

`RenderNode` is a class protocol with `name`, `stage`, `isActive(for:)`,
`prewarm()` and `encode(into:source:destination:request:)`. `RenderStage` spells
out `docs/PLAN.md` §2's order — `color → skin → warp → eyesTeeth → makeup` — with
spaced raw values, and the graph sorts by it, so registration order cannot change
the picture.

Nodes are objects, not functions, because they own their pipelines and their
scratch textures. `isActive` is the cheap gate: no dispatch and no allocation for
a slider group the user has not touched. With no active node the graph copies
source to destination; `RenderReport.isPassthrough` says so.

Only `SkinRenderNode` is registered today. The other three groups are absent
rather than stubbed: an inert node would still appear in `RenderReport` and in the
bench JSON, and a number that counts a node doing nothing is worse than no number.

### The copy is a compute kernel, not a blit

`MTLBlitCommandEncoder.copy(from:to:)` requires identical pixel formats. The
golden harness renders an `rgba16Float` source into an `rgba32Float` target so a
PSNR figure is not capped by half-float output quantisation, and a blit across
that pair **does not raise — it produces garbage**. That is how it was found: the
passthrough test read a max absolute difference of exactly 1.0. `rp_render_copy`
is exact for the pair, since every half-float value is representable in float32,
so "an untouched document is bit-exact" still holds.

## Decision — the seam to `FaceAnalysis` is a plain value type

`RPEngine` still does not import `RPVision`. `FaceRenderInput` carries
`landmarks: [CGPoint]`, `faceWidth: CGFloat` and
`masks: [RenderMaskKind: RenderMask]`, where `RenderMask` is bytes + size + a
`CGAffineTransform`. Those are field-for-field what `AnalyzedFace.imagePoints`,
`AnalyzedFace.faceWidth`, `ParsedFace.feathered(_:)` and
`CropRegion.outputToImage` already hand out, so the adapter
(`App/FaceAnalysisRenderBridge.swift`) is a memberwise call with no arithmetic in
it and no chance to get the geometry wrong.

The reason is Core ML, not the layering audit. `FaceAnalysis` is only reachable
through types that drag in the model wrappers, and `RPEngineTests` runs on a
machine with no models. **`docs/ADR-0007` is inaccurate on this point**: it says
`LayeringAuditTests` forbids `RPEngine` → `RPVision`, but that test's rule table
only forbids `RPEngine` → `RPUI` / `RPImport`
(`Packages/RPTestKit/Tests/RPTestKitTests/LayeringAuditTests.swift:61-71`). The
edge is permitted by the test and declined by choice.

`RenderMask.scaled(by:)` moves **only the transform** — the 512² parsing mask is
not resampled, because resampling it would throw away the sub-pixel geometry the
feather exists to preserve. The adapter always uses `ParsedFace.feathered(_:)`,
never `hardMask`, per spike S2 §4.

`RenderRequest.faces` is documented as **already scaled** to the texture being
rendered. The graph never sees the original image size, and inferring a scale
from an aspect ratio is how a mask ends up half a face out of place.

### The adapter gets its own test target (added on review)

The adapter is the project's only piece of coordinate-space code that no package
test could reach: it is in the app target, and the app target had no tests. It
now has `RetouchProAppTests` (`AppTests/`, in `RetouchPro.xcodeproj`, in the
shared scheme's `<Testables>`, and checked for by `Scripts/test.sh` so a dropped
target is an error rather than a quiet gap). 11 tests over a fabricated
`FaceAnalysis` — no models, no GPU, no images — cover the scale transform, the
feathered-vs-hard choice for all ten mask kinds, kind selection, a rotated
parsing crop, and two faces.

The bundle has **no `TEST_HOST`** and compiles `App/FaceAnalysisRenderBridge.swift`
into itself. A host-app bundle would have to link `RPEngine`/`RPVision` a second
time (they are static package products), leaving two copies of every type in one
process, and would launch the SwiftUI app to test a pure function over value
types.

## Decision — the Da group is two blurred layers and one composite

| layer | how | what it is |
|---|---|---|
| `base` | `GuidedFilter`, radius `0.030 × faceWidth`, ε = 4e-3, s = 4 | edge-preserving smooth; `source − base` is pores and fine wrinkles |
| `low` | `GuidedFilter`, radius `0.150 × faceWidth`, **ε = 1e6**, s = 4 | with ε far above any local variance `a → 0` and `b → mean_I`, so the guided filter *is* a double box blur (`GuidedFilterTests.hugeEpsilonIsDoubleBox`, 3.1e-7); the colour and brightness the skin should have locally |

Reusing the guided filter for the large blur rather than writing a second blur
kernel is deliberate: it is already verified against a `Double` control, and the
degenerate case is a *proved* identity rather than an assumption.

Radii are fractions of `faceWidth`, not pixel counts. That is what makes a preset
transfer between a head-and-shoulders frame and a full-length one
(`docs/PLAN.md` §2). 0.030 × a 600 px face is 18 px, spike S3's measured
operating point at a 2048 px preview.

Both layers share **one** `GuidedFilter.Resources`: the two `encode` calls land
in the same command buffer and Metal's automatic hazard tracking orders the
second encoder's writes after the first's reads. Not sharing would double the
largest allocation in the node (144 MB at 24 MP).

Sharing is only legal because both `Options` carry the same `s`.
`GuidedFilter.Resources` bakes the subsampled grid size in at allocation time
while `GuidedFilter.encode` takes its box radius from the per-call `Options`, so
resources built for one `s` and encoded with another box-filter at the wrong
scale — wrong pixels, no crash. The first version of `SkinRenderNode.cache`
hardcoded `RenderQuality.preview.guidedSubsample` while `encode` used
`request.quality.guidedSubsample`; that was harmless only because
`guidedSubsample` is 4 for both qualities today, and this ADR lists splitting it
by quality as plausible future work. Fixed on review, three ways:

* `cache(width:height:subsample:)` takes the request's `s` and the cache is keyed
  on it, so a quality switch reallocates;
* `GuidedFilter.encode` `precondition`s `resources.subsample == options.subsample`,
  so any future mismatch traps with the two numbers in the message instead of
  producing plausible-looking wrong pixels;
* `SkinRenderNode` takes its quality → `s` lookup through an internal seam
  (production value: `{ $0.guidedSubsample }`) so
  `SkinRenderNodeTests.cacheFollowsTheRequestQuality` can stand in the future
  where the two qualities differ, and
  `alternateSubsampleMatchesReference` scores a whole `s = 2` render against the
  `Double` reference at `s = 2` (79.3 dB).

The layers are allocated **on first use**, not on first render: an rgba16Float
layer is 192 MB at 24 MP, and a document with only "Mịn da" set never touches
`low`.

`rp_skin_composite` applies all eight sliders in one pass, in a fixed documented
order, and short-circuits to a bit-exact passthrough where
`mask × Σ amounts == 0`. Every mix is the identity at 0 anyway; the early-out
exists because the final `clamp(c, 0, 1)` is not.

## Decision — three sliders ship as the simplest correct version, and say so

`panelpts/RetouchProUXP/commands.js` is a *manual* panel: the retoucher painted
each mask by hand, so three of the eight sliders have no automatic counterpart
there. This is Phase 2 "cốt lõi", so each gets the simplest version that moves
the picture in the right direction, with the limit stated in the code:

* **Quầng thâm** lifts every local dark patch inside the skin mask, weighted by
  how far below its neighbourhood the pixel sits — not only the eye sockets.
  CelebAMask-HQ has no under-eye class and a landmark-driven region is separate
  work. On a face the eye sockets are by far the strongest such patch, so the
  slider does the right thing first; it will also lighten a deep nasolabial
  shadow.
* **Nếp nhăn** fills the negative half of the high-frequency residual. It cannot
  tell a wrinkle from a stray hair or a lash, and it is bounded by the guided
  filter's radius, so it reaches fine lines and not deep folds.
* **Khử đỏ** works on `R − (G+B)/2` against its local mean, not on a perceptual
  redness axis and not on commands.js's Selective Color table (which would need a
  full CMYK round trip for one slider).

**Sáng da** approximates commands.js's curve `[[0,0],[64,74],[128,143],[255,255]]`
with a gamma of 0.86: the two interior control points want 0.893 and 0.835, and a
single gamma between them is monotone everywhere and one instruction.

## Decision — "Giữ texture" is a modifier, not an effect

`smoothed = base + (source − base) · keepTexture`, then cross-faded by `smooth`.
At `keepTexture = 0` that is the plain guided-filter layer (ADR-0007's `amount`);
at 100 it reconstructs the source exactly, cancelling the smoothing. So it is
excluded from `SkinSliders.isIdentity`: a document with only `keepTexture` set
renders identical to the original, which is what "default 0, no-op at 0" has to
mean for a slider that modifies another one.

## Measurements

`Research/bench/p2-skin-macos.json`, `Research/bench/p2-skin-ios-simulator.json`,
written by `Scripts/bench-skin.sh` from `RPEngineTests/SkinBenchTests`.

**Accuracy** — against `SkinReference`, a `Double` CPU implementation written
from the specification (He & Sun 2015 for the fast guided filter; this ADR's step
order for the composite), not transcribed from the shader. Synthetic 320×240
fixture, one 64 px elliptical skin mask, all eight sliders at mid values.
`docs/PLAN.md` §3's bar is **45 dB**.

| what | result |
|---|---|
| whole node end-to-end | **79.0 dB** (max abs 6.6e-4) |
| composite alone, fed the GPU's own layers | 151.8 dB |
| per-slider (8 sliders, alone) | 151.5 – 189.0 dB, worst `brighten` |
| mask rasterisation vs `Double` affine + bilinear | max abs 2.4e-3 (`r8Unorm` quantises at 3.9e-3) |

The end-to-end figure is the meaningful one and it is limited by the half-float
storage of the two blurred layers, not by the arithmetic.

**Speed** — real a6300 frame `DSC05123` (4000×6000, face width 684 px), Release
build. Wall-clock median of 20 iterations (preview) / 5 (24 MP), after 2 warm-up
renders.

| | 2048 px preview | 24 MP export |
|---|---|---|
| **M1 Pro**, all eight sliders | **3.22 ms → 311 fps** | **33.8 ms** |
| M1 Pro, Mịn da + Giữ texture only | 1.66 ms → 602 fps | 13.7 ms |
| M1 Pro, every slider at 0 (passthrough copy) | 0.47 ms | 2.30 ms |
| **iOS Simulator**, all eight sliders | 4.76 ms → 210 fps | 35.2 ms |
| iOS Simulator, Mịn da + Giữ texture only | 3.83 ms | 16.7 ms |
| node scratch | 64 MB | 552 MB |

Read the **wall-clock** column in the Simulator file, not `gpu_median_ms`: the
Simulator reports `MTLCommandBuffer.gpuStartTime/gpuEndTime` as ~0.08 ms for a
24 MP render, which is not a GPU time.

Both plan bars are cleared by a wide margin at these sizes — but **on a Mac**.
No iPhone is attached, the same limitation S1, S2, S3 and `FaceAnalyzer` all
record; `is_real_device` in the JSON says which environment produced the number.
The 552 MB at 24 MP is the figure to re-check on a phone first: it is
`base` 192 + `low` 192 + guided intermediates 144 + mask 24, and lazy allocation
already removes 192 MB of it for a smoothing-only edit.

## Decision — default-off flags

`RPEngineFeatureFlags.renderGraph` gates the graph; `.skinSliders` gates the node.
Separate, so a later node can ship while this one is off. `SkinRenderNode` owns a
`GuidedFilter`, whose own `.guidedFilter` gate is **not** bypassed;
`enableSkinRenderGraph()` / `disableSkinRenderGraph()` set the three together,
because discovering the third from a thrown
`RPEngineFeatureDisabled(feature: "guidedFilter")` is a worse API than saying it.

> **Superseded 2026-09-06 by docs/ADR-0010.** The umbrella `.renderGraph` flag is
> gone. One stored bit shared by two independently shippable slider groups meant
> `disableWarpRenderGraph()` also switched the Da group off; the gate now lives
> only on the nodes (`.skinSliders` + `.guidedFilter` here), `RenderGraph.init`
> is unconditional and non-throwing, and `standard(context:)` with every group
> flag off returns an empty graph that copies the picture through. The rest of
> this section still holds with "the three" read as "the two".

### A latent test race, fixed

`@Suite(.serialized)` orders tests inside one suite; Swift Testing still runs
suites concurrently, and `RPEngineFeatureFlags` is a process-global store. That
hazard was already latent between the spike S3 suites (`GuidedFilterTests` and
`SpikeS3BenchTests` both drive `guidedFilter`) and became a reproducible failure
as soon as Phase 2 added two more suites that flip flags:
`RenderGraphTests.flagGatesConstruction` saw `renderGraph == true` because
`SkinRenderNodeTests` was mid-run (that test is now
`RenderGraphTests.skinNodeHasItsOwnFlag`, reading `skinSliders`; the race and the
lock are unchanged). `RPEngineTestFlags` (test target only) is one
process-wide lock that every flag-touching RPEngine test now takes for its whole
body.

`RPEngineTestFlags.Scope` is `~Copyable`. It was a copyable struct with a
`consuming func leave()`, which is only half a guarantee — a *copy* can be
consumed too, so two `leave()` calls could unlock an `NSLock` this scope no
longer holds, and the damage would land in whichever other suite held it. With
`~Copyable` the copy is a compile error and the unlock moved into `deinit`, which
runs exactly once at scope exit. `leave` is `borrowing`, not `consuming`, because
Swift refuses to consume a noncopyable value inside `defer` ("cannot be consumed
when captured by an escaping closure") and `defer` is the only way to pair the
scope with an early `return`; ordering makes that safe, since `defer` bodies run
before the scope's values are destroyed. A test that forgets `leave` entirely
used to deadlock the whole suite; it now falls back to
`RPEngineFeatureFlags.resetToDefaults()` in `deinit`, which is safe precisely
because nothing else can hold the lock while the scope is alive.

## Decision — shaders stay run-time-compiled, but in one library

`Render/RenderShaderSources/SkinShaders.metal` is a second copied directory,
**concatenated** onto the S3 source and compiled in the same
`makeLibrary(source:)` call. One library keeps the compile at exactly one per
process — the expensive part, 1.8 s cold in the Simulator (ADR-0007) — and keeps
one pipeline cache, so `RenderGraph.prewarm()` can guarantee no shader work
happens during a drag. The directory is *not* also called `MetalSources`:
`.copy` flattens to the last path component and two directories with the same
leaf name would collide in the bundle.

ADR-0007's "Phase 2 must fix this" (install the Metal Toolchain component, or
cache an `MTLBinaryArchive`) is **still open**. `prewarm()` moves the stall off
the interaction path; it does not remove it from launch.

## Alternatives rejected

* **A second blur kernel for the large-radius layer.** The guided filter with
  ε ≫ variance is provably a double box blur and is already verified; a new
  kernel would need its own control for no gain.
* **A read-write accumulator for the multi-face mask.** `r32Float` is 96 MB at
  24 MP and needs `MTLReadWriteTextureTier`. A `texture2d_array` of the per-face
  crops with `max()` over slices is one dispatch, one `r8Unorm` output (24 MP =
  24 MB), and combines faces by a rule rather than by submission order.
* **Clamp-to-edge addressing for the mask lookup.** A face crop usually has
  non-zero skin coverage at its border (the neck); clamping would smear that band
  across the whole frame. The kernel bounds-tests and skips instead.
* **Letting the graph scale `FaceRenderInput` itself.** It would have to infer
  the scale from an aspect ratio. The caller knows it; the graph does not.
* **Registering inert nodes for the three unimplemented slider groups**, so the
  stage list looks complete. They would appear in `RenderReport` and in the bench.

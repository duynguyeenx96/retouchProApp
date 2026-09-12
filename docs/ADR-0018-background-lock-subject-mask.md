# ADR-0018 — "Khoá nền": a whole-frame subject mask from `VNGeneratePersonSegmentationRequest`

Status: accepted — 2026-09-12
Scope: Phase 6 §6.1, shared infrastructure. **Engine-only this round**: the mask
is produced and rasterised, no node consumes it yet and there is no UI. Both
feature flags ship **off**.

## Context

§6.1 needs a way to keep an effect off the background. The plan already settled
the technique (`VNGeneratePersonSegmentationRequest`, not a new converted model)
and the gating pattern (the existing `MaskRasteriser` from ADR-0009, not new
machinery), and left one question open with an explicit instruction not to guess
at it: `qualityLevel` is `.fast` / `.balanced` / `.accurate`, Apple recommends
`.fast` for interactive work, and **there was no measurement**.

This is a different Vision pipeline from everything else in RPVision. The face
path is per-face — Vision face rectangles → BlazeFace ROI → 478-point mesh →
19-class BiSeNet parsing (ADR-0005/0006/0008) — crop-sized and backed by
converted Core ML models that have to be bundled (ADR-0015). Person segmentation
is one whole-frame request whose model ships inside the OS: no crop, no
landmarks, no `.mlpackage`, and an answer that exists on frames where no face is
detectable at all.

## Decision

### 1. `RPVision/Segmentation/PersonSegmenter.swift`, outside `FaceAnalyzer`

`PersonSegmenter` is its own type, not a stage of `FaceAnalyzer`. Routing it
through the face pipeline would make the background mask depend on a face being
found, which is precisely the dependency "Khoá nền" must not have (a back-turned
subject, a full-body shot at a distance). It returns `PersonSegmentationMask`:
width, height, `[UInt8]` coverage, a mask→image affine — deliberately the same
shape as RPEngine's `RenderMask`, so the app-target adapter is a memberwise call
the way `App/FaceAnalysisRenderBridge.swift` is for the face masks. RPVision does
not import RPEngine and RPEngine does not import RPVision (ADR-0009).

Two implementation details that were measured rather than assumed:

* **The output buffer is padded.** `CVPixelBufferGetBytesPerRow` is not the
  width; copying `width * height` bytes from the base address shears the mask
  diagonally. Rows are copied one at a time, pinned by a test with a
  deliberately over-padded buffer.
* **The mask does not have the frame's aspect ratio.** A 2048x1365 (3:2) frame
  comes back as 256x192 / 512x384 / 2016x1512 — all 4:3; a 682x1365 frame comes
  back 3:4. Vision fits the picture to its own grid and returns a *stretched*
  copy, so the affine scales each axis independently. A single long-edge factor
  would be tens of pixels out vertically at 1365 px — too small to see in a
  portrait, large enough to cut across a chin. Two regression tests cover it, one
  on the affine (RPVision) and one on where a rasterised bar lands (RPEngine).

### 2. `RPEngine/Render/BackgroundLockMask.swift` — one more mask *source*, not a node

`BackgroundLockMaskSource` reuses `MaskRasteriser` through a new whole-frame
initialiser (`kind == nil`, masks passed in directly) and produces the same
full-resolution `r8Unorm` coverage texture the face masks produce, from the same
`rp_skin_mask` dispatch. **No new kernel, no new `RenderGraph` entry, no change
to node ordering.** `RenderMaskKind` gains no case: that enum mirrors the BiSeNet
parsing classes, and this mask belongs to the frame, not to a face.

`SubjectMaskProviding` is the seam, shaped like the existing
`FaceInputProviding`: the app target is the one place that links both packages.
`NoSubjectMaskProvider` is the default and returns `nil` always.

`nil` means "no subject found" and is a legitimate answer (a product shot, a
landscape). A caller must read it as "there is nothing to lock" and leave the
effect ungated — **not** as an all-zero mask, which would silently switch off a
slider the user had set.

### 3. What is deliberately not done yet

No node consumes the texture. There is no `EditState` field, no slider, no
`RenderRequest` member and no UI toggle; the rail's "Khoá nền" control stays
locked. That is this round's scope per the plan, and the follow-up has to be
coordinated with the manual mask brush (§6.1's other half), because both want the
*same* whole-frame mask slot on `RenderRequest` rather than one each — adding it
twice is the thing to avoid. What this round does establish is the path
end-to-end: a mask that belongs to no face can be uploaded, rasterised and
combined by the shipped ADR-0009 machinery, which is exactly what the brush needs
too.

### 4. Two flags, one per package, both off

`RPVisionFeatureFlags.personSegmentation` gates the Vision request;
`RPEngineFeatureFlags.backgroundLock` gates the GPU rasterisation. Neither writes
the other's process-global store, and neither is turned on by the Phase 2 group
helpers (`enableSkinRenderGraph()` and friends) — asserted, because a cost nobody
has measured on an iPhone must not arrive as a side effect of enabling something
else.

## Measurements

`Scripts/bench-background-lock.sh` → `Research/bench/p6-background-lock-*.json`,
scraped from `RPVisionTests/PersonSegmentationBenchTests` so the filed number is
always the number a test measured. Fixtures: three real a6300 frames
(`DSC05123/05146/05164`), Release build, `request_revision` 1.

### macOS host (2026-09-12), per request

| Quality | Mask size @2048 px | Median ms @2048 px | p95 | Median ms @24 MP | Face-box coverage (mean / worst frame) | Corner coverage (max) |
|---|---|---|---|---|---|---|
| `.fast` | 256x192 | **5.5** | 7.0 | 87.9 | 0.896 / **0.714** | 0.000 |
| `.balanced` | 512x384 | **17.2** | 21.5 | 126.5 | 0.997 / 0.991 | 0.0013 |
| `.accurate` | 2016x1512 | **54.5** | 58.8 | 185.1 | 0.998 / 0.993 | 0.0002 |

Two things this says that the timing alone does not:

1. **`.fast` is not "the same mask, sooner".** Its 256x192 grid is ~25 px across
   a head at a 2048 px preview, and it lost a tenth of the face box on average and
   nearly a third on the worst frame. A quality level here has to be chosen on
   coverage first.
2. **All three land on the subject, not on the background.** Coverage inside a
   face box found by a *separate* Vision request is 0.90–1.00 while the frame
   corners are ~0, which is also what proves the mask is not flipped or
   transposed.

The absolute milliseconds are load-dependent: two runs on the same Mac gave
5.5/17.2/54.5 and 9.7/21.0/58.8. The ordering and the coverage did not move. The
bench therefore asserts only coverage (per-quality bars: `.fast` > 0.60,
`.balanced`/`.accurate` > 0.95) and records the timings.

### iOS Simulator: the request cannot run at all

`Research/bench/p6-background-lock-ios-simulator.json` files
`"supported": false, "unsupported_reason": "com.apple.Vision 9: Could not create
inference context"` (the same run also produced `com.apple.VisionCore 1: E5RT is
not supported` from the first request in the process — which is why the probe
tries the request instead of matching an error code). The Simulator has no
person-segmentation model;
`VNDetectFaceRectanglesRequest` in the same process on the same image works
normally, so this is specific to this request family. `PersonSegmenter
.unsupportedReason()` probes it at runtime (one request on a 64x48 scratch image);
the two correctness tests that need a real request run inside `withKnownIssue`
when the probe says no — the same treatment `FaceAnalyzerTests` already gives this
Simulator limitation, so the failure is reported rather than hidden, and the iOS
suite does not go red for something Apple did not ship.

### The gap: no iPhone number

There is no A-series measurement for this node. The user's instruction for this
session was to skip real-device builds entirely, and the Simulator cannot stand
in (above), so the iPhone figure is genuinely missing — not merely unrecorded.
**Both flags stay off and no default `qualityLevel` is declared anywhere** until
someone runs this on the phone. On the evidence available, the choice that will
be argued for then is `.balanced` (coverage equal to `.accurate` at a third of the
cost, and the mask is a once-per-shot cached cost, not a per-frame one), but that
is a recommendation, not this ADR's decision.

## Consequences

* One `r8Unorm` full-resolution texture (24 MB at 24 MP) plus the uploaded source
  mask when the feature is on; nothing at all while it is off.
* The mask must be produced once per shot and cached on
  `(contentHash, pixel size, quality)` — the protocol's doc comment states this as
  a contract, because 17 ms per request against a 30 fps drag is not a per-frame
  cost.
* `MaskRasteriser.kind` became optional. The face path is unchanged (same
  initialiser, same lookup, same dispatch); the whole-frame initialiser traps if
  the face-shaped `encode(into:faces:…)` is called on it, which is a programmer
  error, not an input error.
* A new test-side lock, `RPVisionTestFlags`, mirrors `RPEngineTestFlags`:
  `@Suite(.serialized)` orders tests inside a suite but not two suites against
  each other, and the two new suites both drive `personSegmentation`. Without it
  the full macOS run failed with "feature is disabled" while each suite passed
  alone. Scoped to the contending flag; the older RPVision suites were left alone.

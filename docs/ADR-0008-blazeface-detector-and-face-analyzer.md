# ADR-0008 — Two-stage face detection (BlazeFace → Core ML) and the `FaceAnalyzer` cache

Status: accepted — 2026-09-05
Scope: Phase 2 of `docs/PLAN.md` §3, first item ("`FaceAnalyzer` → `FaceAnalysis`
(landmarks, mask skin/hair/eyes/teeth/lips/brows/neck), cache theo hash").
`RPVision` only — no `RenderGraph`, no slider, no UI.

## Context

Spike S1 (`docs/ADR-0005`, `Research/spikes/S1-landmark/S1-landmark.md` §4a) left
Phase 2 a hard requirement. The 478-point mesh model itself passes the plan's bar
with ~5× margin (0.193 px at a 256 px face crop on the user's real a6300 frames),
but the pipeline S1 shipped — Apple `Vision`'s face box straight into the mesh —
measures **1.399 px** on those same frames. An ROI-scale sweep bottoms out at
1.293 px, so it is not a calibration error: against BlazeFace's ROI, Vision's is
8 % larger, its centre 5.5 % of the ROI side off, and its roll 2.4° out.

Spike S2 (`docs/ADR-0006`) left two constraints of its own: eye IoU is capped at
0.84 by the checkpoint, and CelebAMask-HQ has **no teeth class**.

## Decision 1 — convert `blaze_face_short_range.tflite` with the same hand-written converter

`Research/spikes/S1-landmark/convert_blazeface_to_coreml.py`, a sibling of the
mesh converter, reusing its `TFLiteGraph` reader verbatim. The detector graph adds
only three ops the mesh graph does not use (standalone `RELU`, `CONCATENATION`,
`RESHAPE` with the shape in the builtin options), so the argument in ADR-0005 —
nine ops mapping 1:1 onto MIL, versus three converters in a tf2onnx chain — holds
unchanged.

Measured (`Research/spikes/S1-landmark/results/blazeface_coreml_vs_tflite.json`,
20 face crops + one noise frame, identical input tensors on both sides):

| Build | max abs regressor diff | max abs score diff | max top-1 box diff @128 px |
|---|---|---|---|
| fp32 | 1.22e-4 | 1.9e-6 | **2.3e-5 px** |
| fp16 | 6.1e-1 | 5.8e-3 | **0.14 px** |

fp32 is the control that says the MIL translation is the same network. fp16 is
what ships, and its end-to-end cost was measured rather than argued: an
image-input fp32 build run through the whole analyzer differs by **0.001 px**
(stock set) and **0.002 px** (a6300 set) of final landmark error
(`Research/phase2/face-analyzer/results/summary.json` → `detector_precision`).

**Anchor decode, sigmoid and NMS stay in Swift** (`BlazeFaceDecoder`), not folded
into the graph. They are a few hundred microseconds of scalar maths, MediaPipe
does them on the CPU too, and in Swift they are unit-testable with no Core ML —
`BlazeFaceDecoderTests` checks the reverse-output-order decode and the *weighted*
NMS (the survivor is the score-weighted mean of the cluster it suppressed, not the
top box) against hand-built tensors, and `BlazeFaceModelTests.matchesGolden`
checks the whole chain against a golden the Python side decoded.

One trap found and recorded in the script: **`coremltools.convert` mutates the MIL
program it is given.** Converting the same `prog` twice with an `ImageType` input
prepends the `[-1,1]` scale/bias pair twice, and the second model detects nothing.
It is invisible in the model spec unless you count the ops; the end-to-end harness
caught it (0 faces in 31 frames). The script now rebuilds `prog` per variant.

## Decision 2 — two-stage detection: Vision locates, BlazeFace refines

```
stage 1  Vision DetectFaceRectanglesRequest    rough box over the whole image
stage 2  square crop of 3.5 x that box  → BlazeFace 128 px → precise box + eye keypoints
stage 3  MediaPipe ROI (square_long, x1.5) → 478-point mesh 256 px
stage 4  CelebA-framed roll-normalised crop → 19-class parsing 512 px
```

BlazeFace cannot replace stage 1: S1 §4a measured its 128 px input leaving a
6 %-of-frame face ~8 px wide, and it found **no face at all** in 4 of the 11 full
24 MP frames at every scale from full-res down to 1400 px. Vision cannot replace
stage 2: that is the 1.399 px above.

Result (`Research/phase2/face-analyzer/results/summary.json`, same reference, same
normalisation and the same multi-face guard as S1's `compare_vs_mediapipe.py`, with
S1's own recorded run rescored by the same function as the control):

| | two-stage | control (S1, Vision box) | bar |
|---|---|---|---|
| 11 real a6300 frames | **0.866 px** | 1.399 px | < 1 px |
| 20 stock portraits | **0.858 px** | 0.911 px | < 1 px |
| pooled by point count (14 818 points) | **0.861 px** | 1.084 px | < 1 px |

The stage-2 crop scale is swept, not assumed
(`summary.json` → `detector_scale`, six scales × two datasets): pooled minimum at
**3.5** (0.861 px), 3.0 second at 0.875 px, 1.5 worst at 0.990 px. The curve is
flat between 3.0 and 3.5 — 3.5 is kept because it is also the framing S1's dataset
was built with, so the detector is being asked for something already known to work.

`FaceAnalyzerOptions.landmarkROIScale` is **1.5**, MediaPipe's own value, *not*
`FaceCrop.visionBoxScale` = 1.40. 1.40 was fitted to compensate for Apple's box
being ~6 % larger than BlazeFace's; applying it to a BlazeFace box would
double-count that correction. `FaceCrop.visionBoxScale` and its test are left
untouched — S1's recorded results still describe the path that uses it.

### What is still not measured

Device speed. On the dev Mac (M-series, compute units `.all`, 2691 px frame,
`Research/bench/p2-face-analyzer-macos.json`): Vision 15.2 ms, BlazeFace 7.6 ms,
mesh 4.2 ms, parsing 9.2 ms, **36.4 ms total per image**. The plan's bar is a real
iPhone (§0.1) and, exactly as in S1 §5 and S2 §6, no device is attached to this
machine. Nothing here changes that.

Also unmeasured: multi-face images. Every frame in both datasets has one dominant
face; `BlazeFaceDecoder.Options.maxFaces` and `FaceAnalyzer.pick` are unit-tested
but not measured on a real group photo.

## Decision 3 — parsing crop comes off BlazeFace's box, roll-normalised

S2 §5 measured that the parser needs CelebAMask-HQ's framing (1.87 × face width,
face centre at 54.4 % of the height) and a roll-normalised crop: without the
rotation it collapsed the two most-rolled a6300 frames into one flat `skin` region
(9/11 frames fully parsed), with it 10/11. `FaceAnalyzer` builds that crop from
**BlazeFace's** box and the **mesh ROI's** roll (which is MediaPipe's eye-keypoint
angle, not Vision's `roll` estimate, so there is no sign to guess).

Measured with S2's own parts-present metric
(`summary.json` → `parsing`): **11/11 on the a6300 set** — one better than S2's
best, including `DSC05403`, the two-face frame S2 could not fully parse — and
19/20 on the stock set (`c003.jpg`, a frame where the subject's brow is under
hair).

## Decision 4 — no `teeth`, and eyes are feathered by API, not by convention

`ParsedFace` exposes `mouthInterior()` and there is **no** `teeth` accessor
anywhere; `FaceParsingGroup` has no `teeth` case. The "trắng răng" slider must
derive teeth from luminance inside the mouth interior (S2 §3c). Pinned by
`ParsedFaceTests.noTeethClass`.

For eyes, S2's 0.84 IoU is a ±1 px boundary error on a ~15 px object. Rather than
leave that in a comment, `FaceParsingGroup.requiresFeatheredMask` marks the
affected groups (eyes, brows, lips, mouth) and `ParsedFace.feathered(_:)` is the
accessor those consumers use. Feathering is two separable box-blur passes with
running sums, so its cost is independent of the radius: **4.1 ms for a 512²
mask** on the dev Mac. That is a per-analysis cost, not a per-frame one — a
consumer that feathers on every slider tick will regret it, and RPEngine should do
this on the GPU when it wires the eye sliders up.

## Decision 5 — cache key is a caller-supplied content hash, not a pixel hash

`FaceAnalysisKey = (contentHash, optionsFingerprint)`. `contentHash` is meant to be
`RPCore.Shot.contentHash`, which `RPImport.ContentHash` already computes for every
file at import and whose own doc comment names this as its purpose. RPVision cannot
import RPImport (the layering audit forbids it), so the hash arrives as a `String`.

`FaceAnalysisKey.pixelHash(of:)` exists for callers with no file, and is **not**
the default: it touches every byte, measured at **14.5 ms for a 7.2 MP frame**
(~2 ms/MP, so ~48 ms for a 24 MP frame) — paying that per render would defeat the
cache.

The options fingerprint is a SHA-256 of the options encoded as JSON with sorted
keys, not `hashValue`: `Hasher` is seeded per process, so a persisted key built
from `hashValue` would silently stop matching after a relaunch.

The cache itself is a fixed-capacity LRU (`FaceAnalysisCache`, default 24 entries
≈ 6 MB of single-face portraits) owned by the `FaceAnalyzer` **actor**, so actor
isolation replaces a lock and the eviction policy stays synchronous and
unit-testable. Concurrent requests for the same key share one `Task` rather than
running the models twice — the case a slider drag actually produces.

Measured (`Research/bench/p2-face-analyzer-cache-macos.json`, 6 images through a
4-entry cache): cold 46.7 ms median, warm **0.052 ms** median (**896×**), 4 hits /
6 misses / 2 evictions, and three concurrent requests for one key cost 35.4 ms —
one analysis, not three.

## Decision 6 — one flag per model, plus one for the composition

`RPVisionFeatureFlags.blazeFaceShortRange` joins `faceLandmarks478` and
`faceParsing19`; `faceAnalyzer` gates the pipeline. All default off.
`FaceAnalyzer.init` requires all four and throws `RPVisionFeatureDisabled` naming
whichever is missing — enabling one flag never enables another, because the flag
storage is process-global and a concurrent test suite would see the write (the
failure mode `RPVisionFeatureFlags.resetToDefaults()` already documents).

## Consequences

* `FaceCropRenderer` is hard-wired to 256 px, so `CropRegion` + `CropRegionRenderer`
  generalise it to 128/256/512. `CropRegionRendererTests.matchesFaceCropRenderer`
  asserts **byte-identical** output at 256 px against `FaceCropRenderer`, so S1's
  calibration still describes the mesh path.
* `AnalyzedFace.imagePoints` is `[CGPoint]` in y-down image pixels and
  `faceWidth` is the 234↔454 cheek distance — the exact shapes spike S3's
  `FaceReshape` builds `MLSDeformation.ControlPoints` from, so nothing has to be
  reshaped between RPVision and RPEngine.
* **Apple's `DetectFaceRectanglesRequest` does not work on the iOS 26 Simulator**
  (`com.apple.Vision Code=9 "Could not create inference context"`, reproducible
  with `-parallel-testing-enabled NO`). `FaceAnalyzer.analyze(_:visionBoxes:)`
  lets a caller supply stage 1's boxes, which is how stages 2-4 get iOS coverage;
  the Vision-backed test is recorded as a **known issue** on the Simulator rather
  than skipped, so it will report "unexpectedly passed" the day Apple fixes it.
  That entry point is not a test hack — a render graph that already knows where
  the faces are should not pay for Vision again.
* The BlazeFace `.mlpackage` (348 KB) is copied into the RPVision **test** bundle,
  unlike S2's 25 MB parsing model. Where the three models ship in the app is still
  open and should be decided once, for all three, when the render graph needs them.

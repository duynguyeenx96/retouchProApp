# ADR-0005 — 478-point landmarks: convert TFLite to Core ML with a direct MIL translator

Status: accepted — 2026-09-04
Scope: Phase 0 spike S1 of `docs/PLAN.md` §3 (`RPVision` landmark path only —
no `FaceAnalyzer`, no caching, no render integration).

## Context

PLAN §1.2 chooses "MediaPipe Face Landmarker 478 điểm convert TFLite → Core ML"
because Vision's 76 points are not dense enough to drive an MLS mesh warp, and
because MediaPipe Tasks has no macOS runtime. It does not say *how* to convert.

The obvious routes all chain converters:

| Route | Converters in the chain | Risk |
|---|---|---|
| `tf2onnx --tflite` → `onnx2torch` → `coremltools` | 3 | three sets of version pins (TF, ONNX opset, torch); each hop re-implements ops and can change numerics; `onnx2torch` coverage for `PRelu`/depthwise is not guaranteed |
| `tflite2tensorflow` → SavedModel → `coremltools` | 2 | tool is abandoned |
| Pre-converted model from a third-party zoo | 0 | unknown provenance, no way to re-derive when MediaPipe ships a new version |

Measurement of the actual graph (`Research/spikes/S1-landmark`,
`face_landmarks_detector.tflite`, 471 ops) showed the op set is tiny:

```
CONV_2D 72, PRELU 69, DEPTHWISE_CONV_2D 34, ADD 34, MAX_POOL_2D 6,
PAD 3, LOGISTIC 1, RESHAPE 1, DEQUANTIZE 251 (all constant fp16 weights)
```

## Decision

**Read the TFLite flatbuffer directly and emit coremltools MIL.**
`Research/spikes/S1-landmark/convert_tflite_to_coreml.py` is ~200 lines and has
exactly one dependency chain: `tflite` (the generated flatbuffer accessors) →
`coremltools`. No TensorFlow, no ONNX, no PyTorch.

Consequences that made this the right call rather than merely a shorter one:

- **The conversion is falsifiable.** Because there is no intermediate framework,
  "did this preserve the network" is a single comparison against the LiteRT
  interpreter on identical tensors. Measured: fp32 build **3.5e-5 px** mean
  landmark difference, fp16 build **0.046 px**
  (`results/coreml_vs_tflite.json`). A three-hop chain would have made a
  regression here impossible to attribute.
- **Op-level control was needed twice**, and neither fix is expressible through a
  generic converter:
  1. MediaPipe applies the sigmoid to the presence logit outside the network
     (`TensorsToFloats`). The converter folds it in, so the Core ML output is a
     usable `score` (1.000 on faces, 0.005 on noise) rather than a raw logit.
  2. The three channel-axis `PAD` ops become `mb.pad` in the naive mapping. That
     model loads on macOS but the **iOS Simulator's Core ML runtime rejects it**:
     `Failed to build the model execution plan using ... model.mil, error code:
     -7`. Emitting `mb.concat` with an explicit zero block instead is
     numerically identical and loads everywhere. Without op-level access the
     only option would have been "the Simulator does not work, use a device".
- **Re-derivable.** When MediaPipe ships a new `face_landmarker.task`, rerunning
  one script reproduces the Core ML model; the source SHA-256s are recorded in
  `Research/spikes/S1-landmark/S1-landmark.md` §1.

## Decision — the model does not ship inside RPVision yet

`FaceLandmark478Model` takes a **URL**. The `.mlpackage` lives in
`Research/spikes/S1-landmark/models/` and is copied into
`Packages/RPVision/Tests/RPVisionTests/SpikeS1/` as a *test* resource.

Phase 2 decides where it ships (app bundle vs on-demand). Until then a 2.5 MB
binary is not added to a shipping package for a path that is switched off, and
`RPVision` keeps no product-code dependency on a file that may move.

Note for whoever bundles it: naming the SwiftPM resource directory `Resources`
produces a test bundle that **fails to codesign for iOS Simulator**
(`bundle format unrecognized, invalid, or unsuitable`). It is called `SpikeS1`
for that reason.

## Decision — default-off flag

`RPVisionFeatureFlags.faceLandmarks478` gates construction of
`FaceLandmark478Model`; with the flag off the initialiser throws
`RPVisionFeatureDisabled`. PLAN §2 requires a flag + harness + control for any
new landmark/mask algorithm, and S1's speed bar (< 40 ms/face on device; PLAN
§0.1 makes that an iPhone, not an iPad) is **not yet verified on hardware** —
only on the Simulator. The flag stays off until that number exists.

## Decision — the Vision ROI scale is a measured constant, not 1.5

MediaPipe's graph scales the BlazeFace box by 1.5. RPVision feeds it Apple's
`DetectFaceLandmarksRequest` box, which is ~5 % larger. Sweeping the factor over
20 portraits put the minimum at **1.40** (mean error vs the MediaPipe Python
reference 1.014 px → 0.911 px at a 256 px face crop).

`FaceCrop.visionBoxScale = 1.40`, and `FaceCropTests` asserts the value so it
cannot be edited without redoing the sweep.

Re-measured (2026-09-04) on the user's 11 real a6300 frames now in
`Research/data/` — spike report §4a, `Research/spikes/S1-landmark/a6300/results/`.
The model keeps its margin (matched-ROI error 0.193 px, better than the 0.235 px
on stock imagery), but the end-to-end Vision path does **not**: 1.399 px at scale
1.40, and its sweep minimum, 1.293 px at scale 1.30, still misses the < 1 px bar.
The residual is Vision's ROI rotation (2.4° mean absolute vs BlazeFace's
eye-keypoint roll) and centre offset (0.055 × ROI side), which no scale can
correct. Pooling both sweeps by point count keeps 1.40 as the argmin (1.084 px vs
1.090 at 1.35), so the constant and the test are unchanged.

Consequence: converting `blaze_face_short_range.tflite` with the same script and
using it for the ROI is now **required** for Phase 2 if the < 1 px bar must hold
on the user's own photos, not just a nice-to-have. It trades ~230 KB and a second
model load for exact agreement with MediaPipe. Note it must run on a face-centred
crop, not the full 24 MP frame: on the full a6300 frames the short-range detector
finds no face at all (§4a), so the shape is Vision → face-centred crop → BlazeFace
ROI → mesh.

## Alternatives rejected

- **Vision's 76 landmarks.** PLAN §1.2 already rejects them as too sparse for
  reshape; nothing measured here changes that.
- **Shipping `.mlmodelc` instead of `.mlpackage`.** Would skip the ~1 s
  first-run compile, but ties the artefact to a compiler version.
  `FaceLandmark478Model` caches the compiled model in the temporary directory,
  keyed by the source's newest mtime, which costs the compile once per build.
- **Running MediaPipe Tasks on-device.** No macOS runtime (PLAN §1.2), and
  `mediapipe 1.0.1` does not even run its own `FaceLandmarker` on macOS Python —
  it aborts in `DrishtiMetalHelper`. Confirms the plan's premise.

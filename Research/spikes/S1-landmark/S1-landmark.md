# Spike S1 — MediaPipe Face Landmarker 478 → Core ML

Phase 0, `docs/PLAN.md` §3. Status: **the model conversion passes the accuracy bar
on both stock and real a6300 photos; the end-to-end RPVision pipeline passes on
stock portraits but not on the real a6300 frames (§4a); on-device speed is still
unverified on real hardware (no iPhone/iPad attached to this machine).**

| Plan pass bar | Measured | Verdict |
|---|---|---|
| error < 1 px @256 vs MediaPipe Python | **0.235 px mean** (matched ROI, 20 stock images, 9 560 points) | PASS |
| — same, on 11 real Sony a6300 frames | **0.193 px mean** (matched ROI, 5 258 points) | PASS, §4a |
| — same, whole RPVision pipeline incl. Apple's face detector, stock images | **0.911 px mean**, p95 1.92 px | PASS, but only after ROI calibration; see §4 |
| — same, whole RPVision pipeline, real a6300 frames | **1.399 px mean**, median 1.037, p95 3.60 px | **FAIL** — the Vision ROI, not the model; see §4a |
| < 40 ms/face on device (plan §0.1: iPhone) | **5.7–10.8 ms** on an iOS *Simulator*, 1.3–1.8 ms on the M-series Mac | **NOT VERIFIED** — no real device; see §5 |

Everything below is reproducible from this directory; every number cited is in a
JSON file under `results/` (20 stock portraits), `a6300/results/` (11 real Sony
a6300 frames) or `Research/bench/`.

---

## 1. Model source

| File | SHA-256 | Where from |
|---|---|---|
| `models/face_landmarker_v2_with_blendshapes.task` | `64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff` | <https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/latest/face_landmarker.task>, downloaded 2026-09-04 |
| `models/face_landmarks_detector.tflite` | `c7d54204ce0448474c7f3fa9af494787c0965cbdd6f20fc72867e43046bd43d5` | extracted from the `.task` zip (2 553 590 bytes) |
| `models/blaze_face_short_range.tflite` | `b4578f35940bf5a1a655214a1cce5cab13eba73c1297cd78e1a04c2380b0152f` | <https://storage.googleapis.com/mediapipe-models/face_detector/blaze_face_short_range/float16/1/blaze_face_short_range.tflite> — **byte-identical** to the `face_detector.tflite` inside the `.task`, so the Python reference and the ROI replication use the same detector MediaPipe ships |

`face_landmarks_detector.tflite`: input `1×256×256×3` float NHWC in `[0, 1]`;
outputs `Identity` `1×1×1×1434` (= 478 × (x, y, z) in crop pixels),
`Identity_1` `1×1×1×1` (face-presence **logit**), `Identity_2` `1×1`
(a second scalar head — reads ~1e-4 on clean face crops where presence is ~1.0,
so its meaning is *not* face presence and it is dropped rather than mislabelled).

## 2. Conversion path

`convert_tflite_to_coreml.py` — a direct TFLite-flatbuffer → coremltools MIL
translation. No TensorFlow, no ONNX, no PyTorch in the chain.

Why: the graph uses only nine builtin ops — `CONV_2D` (72), `PRELU` (69),
`DEPTHWISE_CONV_2D` (34), `ADD` (34), `MAX_POOL_2D` (6), `PAD` (3), `LOGISTIC` (1),
`RESHAPE` (1) and `DEQUANTIZE` (251, all constant float16 weights) — so each one
maps 1:1 onto a MIL op. A `tf2onnx → onnx2torch → coremltools` chain would have
introduced three more converters, each with its own numeric drift and version
pinning. See `docs/ADR-0005-landmark-model-conversion.md`.

Layout: TFLite feature maps are NHWC, MIL convolutions are NCHW. Every rank-4
activation is tracked in NCHW, conv weights are transposed on the way in
(`OHWI → OIHW`, depthwise `1HWO → O1HW` with `groups = C`), and `RESHAPE`
transposes back to NHWC first.

Two behaviours had to be adjusted from the naive mapping, both recorded in the
script:

1. **Face-presence score.** MediaPipe's `TensorsToFloats` step applies the sigmoid
   to `Identity_1`; the converter now emits `score = sigmoid(Identity_1)`.
   Verified: 1.000 on all 20 face crops, 0.005 on random noise.
2. **Channel padding.** The three `PAD` ops pad the channel axis (16→32, 32→64,
   64→128). `mb.pad` on the channel axis produces a model that loads on macOS but
   which the **iOS Simulator's Core ML runtime rejects** with
   `Failed to build the model execution plan using ... model.mil, error code: -7`.
   Replacing it with `mb.concat` of an explicit zero block fixes the Simulator and
   changes nothing numerically.

Artefacts produced (all `mlprogram`, `minimum_deployment_target = iOS18`):

| File | Precision | Input | Used for |
|---|---|---|---|
| `models/FaceLandmark478.mlpackage` | fp16 | 256×256 RGB image | the Swift pipeline; copied into `Packages/RPVision/Tests/RPVisionTests/SpikeS1/` |
| `models/FaceLandmark478_fp16.mlpackage` | fp16 | `1×3×256×256` MultiArray | exact numeric comparison vs TFLite |
| `models/FaceLandmark478_fp32.mlpackage` | fp32 | `1×3×256×256` MultiArray | control for the same comparison |

## 3. Accuracy

### 3a. Conversion fidelity — Core ML vs the original TFLite

`verify_coreml_vs_tflite.py` → `results/coreml_vs_tflite.json`. Identical input
tensors (the 20 Swift crops plus a random-noise case), error = 2D distance in
256-crop pixels.

| Build | mean px | p95 px | max px |
|---|---|---|---|
| fp32 | **0.0000347** | 0.0000778 | 0.000587 |
| fp16 | **0.0462** | 0.0921 | 0.2983 |

The fp32 build is numerically the same network; fp16 costs 0.046 px. This is the
control that says the conversion itself is not where error comes from.

### 3b. vs the MediaPipe Python reference (the plan's bar)

`mp_reference.py` (venv `.venv-mp`, mediapipe 0.10.21, CPU delegate, IMAGE mode)
writes the reference landmarks *and* reproduces MediaPipe's own ROI from the
BlazeFace detection — `DetectionsToRectsCalculator` (rotation from the two eye
keypoints) then `RectTransformationCalculator` with `square_long = true,
scale = 1.5` — then `compare_vs_mediapipe.py` maps our crop-space landmarks back
into image pixels and rescales the error to a 256 px face crop.
→ `results/accuracy_vs_mediapipe.json`.

20 images, 9 560 points:

| Comparison | mean | median | p95 | max | worst image (mean) |
|---|---|---|---|---|---|
| **A.** Core ML on MediaPipe's ROI vs MediaPipe | **0.235 px** | 0.181 | 0.643 | 1.498 | 0.637 |
| A control: original TFLite on the same ROI | 0.228 px | 0.173 | 0.628 | 1.508 | 0.627 |
| **B.** full RPVision pipeline (Vision detector) vs MediaPipe | **0.911 px** | 0.784 | 1.920 | 7.474 | 1.301 |

Reading: the residual 0.228 px in the control is the ROI resampler
(`cv2.warpAffine` here vs MediaPipe's `ImageToTensorCalculator`), not the model —
the conversion adds 0.007 px on top of it. **A passes the < 1 px bar with ~4×
margin.**

## 4. The Vision front end costs ~0.7 px

RPVision uses Apple's `DetectFaceLandmarksRequest`, not BlazeFace, so the ROI
differs. Measured over the 20 images, Apple's box is ~5 % larger than BlazeFace's
(mean ratio 0.949 the other way, σ 0.048) and the eye-centroid roll differs from
BlazeFace's keypoint roll by σ 0.058 rad. The scale sweep
(`s1harness sweep` → `results/accuracy_vs_mediapipe.json` →
`C_swift_roi_scale_sweep`):

| ROI scale | 1.30 | 1.35 | **1.40** | 1.425 | 1.45 | 1.50 | 1.55 |
|---|---|---|---|---|---|---|---|
| mean px @256 | 1.128 | 0.973 | **0.911** | 0.926 | 0.965 | 1.014 | 1.074 |

`FaceCrop.visionBoxScale = 1.40` is that minimum, and `FaceCropTests` pins it so
it cannot be changed without redoing this sweep. It was fitted on these 20 stock
Wikimedia portraits; §4a re-measures it on the real a6300 frames.

If Phase 2 wants the full 4× margin end to end, the clean fix is to convert
`blaze_face_short_range.tflite` as well (same converter handles it) so the ROI is
MediaPipe's by construction. §4a upgrades that from "nice to have" to "required".

## 4a. Re-measured on real Sony a6300 photos

The user's 11 a6300 frames are in `Research/data/` (`DSC05123.ARW` …
`DSC05403.ARW`, 24 MP each). Dataset build (see §6 and `prepare_a6300.swift`):
ImageIO RAW decode → EXIF orientation baked in → square crop of 3.5 × face width
around Vision's largest face, at native resolution. Both pipelines are then fed
exactly the same pixels. Everything else — the reference, the harness, the compare
script — is the same code as §3, pointed at `a6300/` via `S1_BASE`.

`a6300/results/accuracy_vs_mediapipe.json`, 11 images, 5 258 points:

| Comparison | mean | median | p95 | max | worst image | stock set, for reference |
|---|---|---|---|---|---|---|
| **A.** Core ML on MediaPipe's ROI | **0.193 px** | 0.165 | 0.437 | 1.231 | 0.293 | 0.235 px |
| A control: original TFLite, same ROI | 0.186 px | 0.157 | 0.424 | 1.200 | 0.281 | 0.228 px |
| **B.** full RPVision pipeline @ scale 1.40 | **1.399 px** | 1.037 | 3.595 | 13.62 | 2.848 | 0.911 px |

**A holds — better than on the stock set** (0.193 vs 0.235 px), and the conversion
still costs the same +0.007 px over the TFLite control. The 478-point model itself
passes the plan's bar on real camera data with ~5× margin.

**B does not hold.** The ROI sweep on the real frames (`s1harness sweep` with
`S1_SWEEP_SCALES`, → `C_swift_roi_scale_sweep`):

| ROI scale | 1.15 | 1.20 | 1.25 | **1.30** | 1.35 | 1.40 | 1.45 | 1.50 | 1.60 |
|---|---|---|---|---|---|---|---|---|---|
| a6300 mean px @256 | 1.989 | 1.563 | 1.394 | **1.293** | 1.303 | 1.399 | 1.547 | 1.589 | 1.857 |

No scale reaches 1 px: the minimum is 1.29–1.30 at 1.293 px, and the curve is flat
(1.30 → 1.35 differs by 0.8 %). So the extra error is **not** a scale error that
calibration can remove. `a6300/results/roi_delta.json` says why — against
BlazeFace's ROI, Vision's is on average 1/0.922 = 8 % bigger *even at scale 1.40*
(σ 6.6 %, vs σ 4.8 % on the stock set), its centre is off by 0.055 × ROI side, and
the eye-centroid roll differs by 2.4° mean absolute (max 5.6°). These are real
portraits with strong head roll (MediaPipe's own roll runs to 0.86 rad = 49°),
glasses and hair over the face — much harder on the ROI than stock frontal
headshots. A rotation error of a few degrees moves points near the crop edge by
several pixels no matter what the scale is.

**`visionBoxScale` stays 1.40.** Pooling both sweeps by point count
(`a6300/results/roi_scale_pooled.json`) still puts the argmin at 1.40 (1.084 px),
with 1.35 a statistical tie at 1.090 px and 1.30 clearly worse at 1.186 px.
Re-tuning to 1.30 would buy 0.11 px on the a6300 set and lose 0.22 px on the stock
set, and would still not pass end to end — so it is not worth invalidating
`FaceCropTests.visionScaleIsCalibrated` for. The constant's doc comment now cites
both datasets.

**Consequence for Phase 2:** porting `blaze_face_short_range.tflite` to Core ML is
now required, not optional, if the < 1 px bar has to hold end to end on the user's
own photos. One implementation note found while building this set: MediaPipe's
short-range detector **cannot** be run on the full 6000×4000 frame — at every scale
from full-res down to 1400 px it found no face at all in DSC05193 / DSC05239 /
DSC05259 / DSC05403 and no landmarks in DSC05146, because a 128×128 detector input
leaves a 6 %-of-frame face ~8 px wide. It has to be a two-stage pipeline: Vision
locates the face, BlazeFace refines the ROI on a face-centred crop.

## 5. Speed

`Research/bench/s1-landmark-macos.json`, `Research/bench/s1-landmark-ios-simulator.json`,
produced by `Scripts/bench-s1.sh` scraping the `RPBENCH` line the RPVisionTests
benchmark prints (60 iterations after 10 warm-ups, median).

| Destination | compute units | inference ms | crop + inference ms |
|---|---|---|---|
| macOS 26.3, M-series | `.all` | 1.37 | 1.83 |
| macOS 26.3, M-series | `.cpuAndNeuralEngine` | 1.26 | 1.74 |
| macOS 26.3, M-series | `.cpuOnly` | 1.73 | 2.61 |
| **iOS Simulator (iPad A16)** | `.cpuOnly` | **5.71** | **10.84** |
| iOS Simulator (iPad A16) | `.cpuAndNeuralEngine` | 7.27 | 10.45 |
| iOS Simulator (iPad A16) | `.all` | 19.66 (p95 122.7) | 27.68 (p95 180.8) |

**The Simulator number is not the device number.** The iOS Simulator has no
Neural Engine and executes on the host Mac's CPU/GPU; `.all` there falls onto a
Metal path that is erratic (p95 180 ms) in a way an A-series chip will not be.
Treat the Simulator figures as "the model is small enough that even an
unaccelerated host run is ~10 ms", i.e. a plausibility check, not the 40 ms
verdict. Which simulator device it was makes no difference for the same reason —
these numbers are the host Mac's. (They were taken on the iPad (A16) simulator
before plan §0.1 moved the scope to iPhone; `Scripts/bench-s1.sh` still defaults to
that destination, `Scripts/test.sh` now defaults to iPhone 17.)

Also measured on the Mac (`results/bench_macos.json`): Vision face detection is
**11.1 ms median per image** on a 1366×2048 photo. It runs once per image, not per
face, but it is the larger cost of the two and needs its own device number in
Phase 2.

**Blocked:** the < 40 ms/face pass bar needs a run on the user's real device
(plan §0.1: an iPhone). The benchmark is already an ordinary test, so once the
device is attached the number comes from `Scripts/bench-s1.sh ios` with
`RP_IOS_DESTINATION='platform=iOS,name=<device>'`, or `Scripts/test.sh` with that
destination — no new code required.

## 6. Test images

**Stock set — `images/raw/`, `results/`.** 20 portraits from Wikimedia Commons,
auto-selected by `fetch_images.py` + `download_filter.py`: exactly one face
detected, ≥600 px on the short side, landmark bounding box ≥260 px so the 256 crop
is not an upsample. Titles, source URLs, licences and SHA-256 are in
`images/manifest_commons.json`.

**Real camera set — `a6300/images/raw/`, `a6300/results/`.** The 11 Sony a6300
ARW files the user put in `Research/data/` (`DSC05123` … `DSC05403`, 24 MP,
6000×4000, EXIF orientation 8 on the portrait frames). Built by
`prepare_a6300.swift`: ImageIO RAW decode → orientation baked into the pixels →
square crop of 3.5 × face width around Vision's largest face, native resolution,
no resampling. Per-image provenance (source ARW, orientation, Vision box, crop
rect) is in `a6300/manifest.json`; the decoded 6000×4000 intermediates are not kept
(regenerate with the `sips` line in §7). Face ROI sides after cropping are
482–2674 px, so the 256 crop is never an upsample here either. DSC05403 has two
faces; the compare script guards against Vision and MediaPipe picking different
people (`excluded` in the report JSON — empty on this set, both picked the same
face). The crop step exists because MediaPipe's own detector cannot find these
faces in the full frame; see §4a.

## 7. How to reproduce

```bash
cd Research/spikes/S1-landmark
python3 -m venv .venv     && .venv/bin/pip install coremltools tflite ai-edge-litert pillow numpy
python3 -m venv .venv-mp  && .venv-mp/bin/pip install "mediapipe==0.10.21" "numpy<2" opencv-python-headless

.venv/bin/python    fetch_images.py            # candidate list from Commons
.venv-mp/bin/python download_filter.py         # download + keep 20 usable faces
.venv/bin/python    convert_tflite_to_coreml.py
.venv/bin/python    verify_coreml_vs_tflite.py # needs crops/, so run the harness first for the real-crop version
.venv-mp/bin/python mp_reference.py

cd SwiftHarness
swift run -c release s1harness run     # Vision -> crop -> Core ML, writes crops/ + results/
swift run -c release s1harness sweep   # ROI scale sweep
swift run -c release s1harness bench   # Mac timings
cd ..
.venv/bin/python compare_vs_mediapipe.py

cd ../../..
Scripts/test.sh all
Scripts/bench-s1.sh all
```

The same measurement on the real a6300 frames (§4a). `S1_BASE` moves images,
crops and results to `a6300/`; the models and the code are unchanged:

```bash
cd Research/spikes/S1-landmark
mkdir -p a6300/images/full
for f in ../../data/*.ARW; do
  sips -s format jpeg -s formatOptions best "$f" \
       --out "a6300/images/full/$(basename "${f%.ARW}").jpg"
done
swift prepare_a6300.swift a6300/images/full a6300/images/raw 3.5   # -> a6300/images/raw + manifest.json
ln -sfn ../models a6300/models     # s1harness looks for models/ inside the dataset dir

S1_BASE="$PWD/a6300" .venv-mp/bin/python mp_reference.py
cd SwiftHarness
swift run -c release s1harness run   ../a6300
S1_SWEEP_SCALES="1.15,1.20,1.25,1.30,1.35,1.40,1.425,1.45,1.50,1.55,1.60" \
  swift run -c release s1harness sweep ../a6300
cd ..
S1_BASE="$PWD/a6300" .venv/bin/python compare_vs_mediapipe.py
python3 a6300_roi_stats.py     # roi_delta.json + roi_scale_pooled.json, stdlib only
```

Note: `mediapipe 1.0.1` **crashes on macOS** inside `FaceLandmarker`
(`DrishtiMetalHelper initWithCalculatorContext:` → `Check failed: service_ Service
is unavailable`) with both the CPU and GPU delegate. 0.10.21 works; that is why
the reference lives in its own venv.

## 8. What landed in the product

`Packages/RPVision/Sources/RPVision/Landmarks/` — behind
`RPVisionFeatureFlags.faceLandmarks478`, **default off**:

* `RPVisionFeatureFlags.swift` — the flag, plus `RPVisionFeatureDisabled`.
* `FaceCrop.swift` — the rotated-square ROI, MediaPipe's rect maths, and
  `FaceLandmarks478` (crop-space points → image-space points).
* `FaceCropRenderer.swift` — Core Image resample into a 256×256 BGRA buffer.
* `FaceLandmark478Model.swift` — Core ML wrapper. Takes the model **URL**; the
  model is deliberately not bundled with RPVision yet.
* `FaceLandmarkDetector.swift` — Vision detection → ROI → mesh.

`FaceAnalyzer` / `FaceAnalysis` / caching are Phase 2 and were not started.

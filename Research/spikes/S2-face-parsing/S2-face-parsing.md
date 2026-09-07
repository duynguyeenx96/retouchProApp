# Spike S2 — BiSeNet CelebAMask-HQ face parsing → Core ML

Phase 0, `docs/PLAN.md` §3. Status: **the model converts cleanly and runs on
device; skin and hair clear the accuracy bar with margin, the eye group misses it
by 0.010 and the PyTorch reference misses it by the same amount, so it is the
checkpoint and not the conversion; on-device speed is unverified on real
hardware (no iPhone attached to this machine).**

| Plan pass bar | Measured | Verdict |
|---|---|---|
| IoU **skin** ≥ 0.85 on 10 images | **0.9393** (first 10 of the CelebAMask-HQ test split; 0.9439 over 30) | **PASS** |
| IoU **hair** ≥ 0.85 on 10 images | **0.9259** (0.9366 over 30) | **PASS** |
| IoU **eye** ≥ 0.85 on 10 images | **0.8396** (0.8211 over 30) | **FAIL by 0.010** — §4 |
| — same, PyTorch reference (control) | skin 0.9393 · hair 0.9259 · **eye 0.8401** | conversion costs 0.0005 IoU; the miss is the model |
| < 150 ms/image on device (plan §0.1: iPhone) | **43.7 ms** on an iOS *Simulator*, 6.9 ms on the M-series Mac | **NOT VERIFIED** — no real device; §6 |
| generalises to real a6300 portraits | 9/11 frames fully parsed as framed, **10/11 after roll-normalising the crop**; no IoU (no ground truth) — §5 | qualitative only, stated as such |

Every number cited is in a JSON file under `results/` (30 CelebAMask-HQ test-split
portraits), `a6300/results/` and `a6300_upright/results/` (11 real Sony a6300
frames) or `Research/bench/`.

---

## 1. Model source

| File | SHA-256 | Where from |
|---|---|---|
| `models/79999_iter.pth` | `468e13ca13a9b43cc0881a9f99083a430e9c0a38abd935431d1c28ee94b26567` (53 289 463 bytes) | the checkpoint `zllrunning/face-parsing.PyTorch` links from its README (PLAN §6), downloaded 2026-09-04 |
| `vendor/model.py` | `92ceb3748df2a82b7211b457dbbbde0875a8afe582ca52115704284f2023d874` | `zllrunning/face-parsing.PyTorch` @ master, verbatim (MIT, `vendor/LICENSE`) |
| `vendor/resnet.py` | `3c33b212a28cdcff1b3f1ab4aa9f59247bf17e6ba66bdc506056f2bf8930ad95` | same |
| `vendor/prepropess_data.py` | — | same; this is the file that defines the class indices |

**Provenance note.** The upstream README points at Google Drive
(id `154JgKpzCPW82qINcVieuPH3fZ2e0P812`), which is not usable programmatically.
`fetch_model.py` defaults to the Hugging Face mirror
`vivym/face-parsing-bisenet`. Both were downloaded side by side and are
**byte-identical** — same SHA-256, same length — so the mirror is the upstream
artefact, not a re-export. `fetch_model.py --drive` fetches the Drive copy and
checks the same hash.

Architecture: BiSeNet with a ResNet-18 context path, **13 300 416 parameters**,
19 output classes. No spatial path (upstream replaced it with the ResNet `res3b1`
feature).

## 2. Conversion path

`convert_bisenet_to_coreml.py`: load the `state_dict` into the vendored module,
`torch.jit.trace` at 1×3×512×512, `coremltools.convert(convert_to="mlprogram",
minimum_deployment_target=iOS18)`. One converter, no ONNX. Rationale and the
alternatives in `docs/ADR-0006-face-parsing-model-conversion.md`.

Two things are folded into the traced graph rather than left to the caller:

1. **The ImageNet normalisation.** A Core ML `ImageType` applies one scalar
   `scale`; the ImageNet std is per-channel, so it cannot be expressed there. The
   model therefore takes RGB **0–255** and does `(x/255 − mean)/std` itself.
2. **The argmax.** Emitting 19×512×512 logits would move 10 MB out of Core ML per
   image at fp16 for something immediately reduced to one byte per pixel. The
   shipped output is `labels`, `int32 [1, 512, 512]`.

Also dropped: `conv_out16` / `conv_out32`, which are training-time deep-supervision
heads (upstream inference is `net(x)[0]`).

Artefacts:

| File | Precision | Input | Output | Size | Used for |
|---|---|---|---|---|---|
| `models/FaceParsing19.mlpackage` | fp16 | 512×512 RGB image | `labels` int32 | 25 MB | the Swift path, the tests, the bench |
| `models/FaceParsing19_logits_fp16.mlpackage` | fp16 | `1×3×512×512` MultiArray | `logits` | 25 MB | exact comparison vs PyTorch |
| `models/FaceParsing19_logits_fp32.mlpackage` | fp32 | same | same | 50 MB | control for that comparison |

The `.mlpackage` also carries `rp.labels` (the class table as JSON) and
`rp.source` (the checkpoint SHA-256) in its user metadata, so a stray copy can be
identified.

## 3. Accuracy

### 3a. Conversion fidelity — Core ML vs the original PyTorch

`verify_coreml_vs_torch.py` → `results/coreml_vs_torch.json`. Both sides get the
identical 512×512 uint8 RGB arrays that `torch_reference.py` wrote to
`images/in512/`, so the resampler is out of the comparison entirely. 30 images.

| Build | mean abs logit diff | max abs | argmax pixels unchanged | skin IoU vs torch | hair | eye |
|---|---|---|---|---|---|---|
| fp32 | **1.96e-6** | 8.0e-5 | 99.99997 % | 0.999999 | 1.000000 | 1.000000 |
| fp16 | **2.23e-3** | 4.5e-2 | 99.976 % | 0.99964 | 0.99963 | 0.99720 |
| fp16, image-input argmax build | — | — | 99.976 % | 0.99964 | 0.99963 | 0.99720 |

The fp32 build is numerically the same network. fp16 costs 0.024 % of pixels. The
image-input build agrees with the fp16 logits build to the last pixel, which is
the check that the in-graph normalisation and the Core ML image plumbing are
right. **This is the control that says the conversion is not where error comes
from.**

### 3b. IoU against ground truth (the plan's bar)

`evaluate_iou.py` → `results/iou.json`.

Ground truth is built locally by `fetch_celebamaskhq.py` from the **raw per-part
annotation PNGs** (`CelebAMask-HQ-mask-anno/<i//2000>/<i:05d>_<att>.png`) using
upstream `prepropess_data.py`'s own rule (`mask[sep_mask == 225] = enumerate(atts, 1)`).
Merging locally rather than using someone's pre-merged label maps is the point:
it guarantees the ground-truth indices are the ones the checkpoint was trained
against.

30 images, the first 30 of the **official CelebAMask-HQ test split**
(CelebA `orig_idx >= 182638`, per `face_parsing/Data_preprocessing/g_partition.py`
in switchablenorms/CelebAMask-HQ), taken in ascending index order — no
cherry-picking. The plan asks for 10, so both are reported.

| Prediction | skin (first 10 / all 30) | hair | eye |
|---|---|---|---|
| **Core ML via Swift, matched input** | **0.9393** / 0.9439 | **0.9259** / 0.9366 | **0.8396** / 0.8211 |
| PyTorch reference (control) | 0.9393 / 0.9438 | 0.9259 / 0.9365 | 0.8401 / 0.8217 |
| Core ML via Swift, its own Core Image resize | 0.9396 / 0.9437 | 0.9258 / 0.9357 | 0.8405 / 0.8223 |

Reading:

* **skin and hair pass with ~0.08 of margin.**
* **eye misses by 0.010 on 10 images and 0.029 on 30**, and the PyTorch control
  misses by the same amount. The conversion contributes 0.0005. §4 is why.
* The third row matters for Phase 2: letting `FaceParsingRenderer` do its own
  Core Image resize from the 1024 px source, instead of being handed PIL-resized
  pixels, changes nothing (±0.001). The resampler is not a risk here, unlike S1's
  ROI.

Per-class IoU over all 30 (Core ML): background 0.937, skin 0.944, l_brow 0.673,
r_brow 0.714, l_eye 0.706, r_eye 0.722, l_ear 0.382, r_ear 0.454, ear_r 0.176,
nose 0.875, mouth 0.806, u_lip 0.806, l_lip 0.862, neck 0.857, neck_l 0.000,
cloth 0.729, hair 0.937. (`eye` in the table above is `l_eye ∪ r_eye`, which
scores higher than either alone because left/right confusion cancels.)

### 3c. The class index mapping is verified, not assumed

Nothing in a Core ML file says "17 means hair". `evaluate_iou.py` computes a
19×19 IoU matrix between predicted and ground-truth classes and reports, for each
predicted class, the ground-truth class it overlaps most (`mapping_check` in
`results/iou.json`). Every class present in both matches **itself**, with one
exception:

* `neck_l` (necklace): self-IoU **0.000** over the 3 frames that contain one; its
  best match is `neck` at IoU 0.011. That is the model failing on a rare accessory
  class, not an index shift — it would move an entire class's mass onto a
  different label, and no other class is affected. Nothing in PLAN uses necklaces.

Two more checks live in the product tests
(`Packages/RPVision/Tests/RPVisionTests/FaceParsingModelTests.swift`):
`classIndicesMatchUpstream` pins `FaceParsingClass` against the table the Python
side wrote into the golden JSON, and `classGeometryIsSane` asserts hair sits above
skin, eyes above lips, lips above neck — a permuted table can fake a histogram, it
cannot fake the geometry.

**There is no teeth class.** CelebAMask-HQ's `mouth` (11) is the mouth *interior*.
PLAN §1.3's "trắng răng" slider has to derive teeth from `mouth` by luminance.
`FaceParsingGroup` says so in a doc comment so Phase 2 does not go looking.

## 4. Why the eye group misses, and what does not fix it

Ground-truth eye area on this set averages **1 365 px of 262 144 (0.52 %)**, and
runs as low as **230 px**. At that size the IoU is dominated by a one-pixel
boundary error: a ~1 400 px blob has a ~140 px perimeter, so being one pixel out
all the way round costs ~10 % of the union. The two worst frames are the two with
the smallest eyes (`175`: eyes of 230/239 px, the model finds one of them, IoU
0.175; `229`: 141/198 px, IoU 0.620). Excluding those two, the other 28 average
**0.8514** — so the two smallest-eye frames are what pull the 30-image mean from
just over the bar to 0.821. Per frame the picture is worse than the mean suggests:
**skin clears 0.85 on 30/30 frames and hair on 30/30, eye on only 16/30.** The two
outliers are not excluded from any headline number above; this is a description of
where the number comes from, not a filtered result.

Two hypotheses were tested and both are ruled out.

**Framing** (`experiment_facecrop.py` → `results/facecrop_sweep.json`). Crop an
oracle square around the ground-truth face classes, scale ×k, parse, map back:

| k | 1.2 | 1.4 | 1.6 | 2.0 |
|---|---|---|---|---|
| skin (first 10) | 0.9430 | 0.9388 | 0.9393 | 0.9393 |
| hair | 0.7472 | 0.9141 | 0.9259 | 0.9259 |
| eye | 0.8447 | 0.8364 | 0.8396 | 0.8396 |

At k ≥ 1.6 the box hits the frame edge and this *is* the baseline — CelebA-HQ
faces already fill the frame (measured: the frame is 1.87 × face width). Cropping
tighter costs hair and buys 0.005 of eye. There is no headroom in framing here.

**Input resolution** (`experiment_resolution.py` → `results/resolution_sweep.json`,
PyTorch, argmax nearest-resized back to the 512 ground-truth grid):

| Input | skin (all 30) | hair | eye | torch-CPU ms |
|---|---|---|---|---|
| 384 | 0.9351 | 0.9294 | 0.7547 | 69 |
| **512** | **0.9438** | **0.9365** | **0.8217** | **131** |
| 768 | 0.9444 | 0.9336 | 0.8225 | 254 |
| 1024 | 0.9353 | 0.9238 | 0.8164 | 558 |

768 buys +0.0008 eye IoU for 2× the compute; 1024 is worse than 512. **512 is the
right input**, which confirms PLAN §1.4's assumption by measurement rather than
inheriting it.

So eye IoU ≈ 0.82–0.84 is this checkpoint's ceiling at any sane cost. Options for
Phase 2, in order of cost:

1. **Accept it.** 0.84 is a boundary-limited number on 15×15-pixel objects. The
   sliders that use it — "sáng mắt", "trắng lòng trắng" — are local curve
   adjustments through a feathered mask; a one-pixel boundary error there is not
   visible, unlike a one-pixel error in a reshape warp.
2. **Parse the eye region a second time at higher magnification**, using the
   478-point landmarks from S1 to crop each eye. Costs a second inference on a
   small tile.
3. **A different checkpoint.** `jonathandinu/face-parsing` (SegFormer-B5) reports
   much better small-class accuracy; it is ~85 M parameters against BiSeNet's
   13.3 M, so it needs its own 150 ms measurement before anyone commits to it.

**Caveat on the ground truth, stated plainly:** zllrunning's `face_dataset.FaceMask`
lists *all* of `CelebA-HQ-img` regardless of `mode`, so this checkpoint was very
likely trained on the whole 30 000 images, official test split included. Using the
official test split is the best available convention, not a held-out guarantee.
The skin/hair numbers above should be read as an upper bound on this dataset, and
§5 is the out-of-distribution check that carries the generalisation question.

## 5. Real Sony a6300 photos

The user's 11 a6300 frames in `Research/data/` (`DSC05123.ARW` … `DSC05403.ARW`,
24 MP). **There are no ground-truth masks for these, so no IoU is reported for
them.** Hand-labelling 11 × 19 classes was out of scope for this spike, and a
number invented from the model's own output would be circular.

Dataset build (`prepare_a6300.swift`): `sips` RAW decode → EXIF orientation baked
in → Vision's largest face → square crop of **1.87 × face width with the face
centre at 54.4 % of the height**. Those two constants are measured off the 30
CelebAMask-HQ frames in `images/gt/`, not guessed — S1's crops are 3.5 × face
width and centred, which would show the parser a face 3.4× smaller in area than
anything it was trained on and make "does it generalise" unanswerable. Provenance
per image is in `a6300/manifest.json`.

What *is* measured (`evaluate_a6300.py` → `a6300/results/a6300_qualitative.json`):

1. **Core ML vs PyTorch pixel agreement on real camera data: 0.9995–0.9999**
   (mean 0.9998). The conversion holds outside CelebA-HQ.
2. **Parts present.** A working parse of a portrait must contain skin, hair, nose,
   both brows, both lips and either eyes or eyeglasses, each ≥ 0.05 % of the crop.
   **9 of 11 frames have all of them.**

The two failures are `DSC05239` and `DSC05259` — the frames with the strongest
head roll (Vision reports **+41.5°** and **−19.7°**). On those the model collapses
the entire face into one flat `skin` region: no nose, no brows, no eyes, no
glasses, and the skin fraction balloons (0.200 and 0.251 against ~0.145 typical).
This is the same failure mode S1 found on the same set from the other direction —
S1's end-to-end landmark error was driven by head roll too (`docs/ADR-0005`).

**Roll-normalising the crop fixes it.** `prepare_a6300.swift --upright` rotates
the crop by −(Vision roll) before writing it; `a6300_upright/results/` then has
**10 of 11 frames fully parsed**, including both former failures, with their skin
fractions back to normal (0.147 and 0.205). The one remaining miss is `DSC05403`
(a two-face frame; the right brow is under hair). Overlays for both sets are in
`a6300/results/overlays/` and `a6300_upright/results/overlays/`.

Note the sign of that rotation was **wrong on the first attempt** and the
parts-present count caught it: rotating by +roll doubled the tilt instead of
undoing it and dropped the count to 7/11. That is what the metric is for; the
overlay confirmed it visually afterwards.

Also worth recording for Phase 2: 9 of the 11 subjects wear glasses, and the model
labels them `eye_g` correctly (≈ 4 % of the crop) while emitting no `l_eye`/`r_eye`
— which is the right answer, but it means **any eye-based slider must handle
"eyes occluded by glasses"**, not assume the eye classes are always populated.

**Consequence for Phase 2:** feed the parser a roll-normalised crop. `FaceCrop`
already builds a rotated ROI for the landmark path, so this is reuse, not new
work.

## 6. Speed

`Research/bench/s2-face-parsing-macos.json`,
`Research/bench/s2-face-parsing-ios-simulator.json`, produced by
`Scripts/bench-s2.sh` scraping the `RPBENCH-S2` line the RPVisionTests benchmark
prints (25 iterations after 5 warm-ups, median).

| Destination | compute units | inference ms | resize + inference ms |
|---|---|---|---|
| macOS 26.3, M-series | `.all` | 5.59 | 6.88 |
| macOS 26.3, M-series | `.cpuAndNeuralEngine` | 5.61 | 6.86 |
| macOS 26.3, M-series | `.cpuOnly` | 14.27 | 15.55 |
| **iOS Simulator, iPhone 17** | `.cpuAndNeuralEngine` | **39.12** | **43.70** |
| iOS Simulator, iPhone 17 | `.cpuOnly` | 39.51 | 45.79 |
| iOS Simulator, iPhone 17 | `.all` | 70.85 | 74.20 (p95 99.3) |

Label decode (reading the 262 144-element `int32` output into bytes) is
**0.42 ms** on the Mac and 0.44 ms on the Simulator, i.e. ~6 % of the total — the
rest is the network.

**The Simulator number is not the device number.** The iOS Simulator has no Neural
Engine and executes on the host Mac; `.all` there falls onto a Metal path that is
both slower and more erratic than the CPU one, which an A-series chip will not be.
Treat 43.7 ms as "an unaccelerated host run is well inside 150 ms", a plausibility
check, not the verdict.

Two measurement traps found here, both recorded in `Scripts/bench-s2.sh` so the
next person does not re-find them:

* **Build configuration dominates.** The label-decode loop is plain Swift, and a
  Debug test bundle spends ~36 ms in it: the same model on the same image measured
  **5.8 ms in an optimised binary and 42 ms in a Debug test bundle**. `bench-s2.sh`
  passes `-configuration Release ENABLE_TESTABILITY=YES` (testability is needed
  because the suites use `@testable import`).
* **Suite parallelism.** `xcodebuild test` runs suites concurrently, so S1's
  landmark benchmark and S2's parsing benchmark contend for the same GPU/ANE.
  `bench-s2.sh` passes `-only-testing:RPVisionTests/FaceParsingModelTests` and
  `-parallel-testing-enabled NO`.
  → **`Scripts/bench-s1.sh` has neither flag.** Its recorded macOS numbers were
  taken when S2 did not exist; now that it does, re-running it as written will
  produce contended figures. Left alone deliberately — changing it would
  invalidate `Research/bench/s1-landmark-*.json` without a re-measurement, which
  is S1's call, not this spike's.

**Blocked:** the < 150 ms bar needs a run on the user's real iPhone. The benchmark
is an ordinary test, so once a device is attached the number comes from
`Scripts/bench-s2.sh ios` with `RP_IOS_DESTINATION='platform=iOS,name=<device>'`.
No new code required.

## 7. Test images

**CelebAMask-HQ — `images/raw/`, `images/gt/`, `images/manifest_celebamaskhq.json`.**
30 portraits, the first 30 of the official test split in ascending index order
(indices 2, 4, 26, 44, 59, 84, 93, 108, 127, 133, 134, 139, 142, 147, 151, 172,
175, 188, 195, 228, 229, 235, 256, 258, 263, 265, 267, 303, 309, 353). Sources are
1024×1024 JPEG; ground truth is 512×512, merged locally from the per-part
annotations. All 30 contain skin, hair, l_eye and r_eye, so no group is scored on
a partial set. **Non-commercial research use only** — this is why the images are
gitignored and regenerated by script rather than committed.

The 3.1 GB dataset zip is never downloaded in full: `remote_zip.py` reads the ZIP
central directory over HTTP range requests and pulls only the ~10 members per
image that are needed (a few MB in total, ~2 minutes for 10 images).

**Real camera — `a6300/`, `a6300_upright/`.** The 11 ARW files in
`Research/data/`, §5.

**Test fixture — `Packages/RPVision/Tests/RPVisionTests/SpikeS2/`.** One 512 px
face crop and its golden label map, 290 KB. The face is `c000.jpg` from S1's
Wikimedia Commons set ("Alex Roessner Headshot 2022", CC BY-SA 4.0, licence
recorded in `Research/spikes/S1-landmark/images/manifest_commons.json`) — a
freely-licensed image, so it can be committed, unlike the CelebA frames.

## 8. How to reproduce

```bash
cd Research/spikes/S2-face-parsing
python3 -m venv .venv && .venv/bin/pip install torch torchvision coremltools pillow "numpy<3"

.venv/bin/python fetch_model.py                 # 79999_iter.pth, SHA-256 checked
.venv/bin/python fetch_celebamaskhq.py 30       # images/raw + images/gt + manifest
.venv/bin/python convert_bisenet_to_coreml.py   # models/FaceParsing19*.mlpackage
.venv/bin/python torch_reference.py             # images/in512 + results/torch_labels
.venv/bin/python verify_coreml_vs_torch.py      # results/coreml_vs_torch.json

cd SwiftHarness
swift run -c release s2harness run   ..            # results/coreml_labels
swift run -c release s2harness run   .. --from-raw # results/coreml_labels_fromraw
swift run -c release s2harness bench ..            # results/bench_macos.json
cd ..
.venv/bin/python evaluate_iou.py                # results/iou.json  <- the pass bar
.venv/bin/python experiment_facecrop.py         # results/facecrop_sweep.json
.venv/bin/python experiment_resolution.py       # results/resolution_sweep.json
```

The real a6300 frames (§5):

```bash
cd Research/spikes/S2-face-parsing
mkdir -p a6300/images/full
for f in ../../data/*.ARW; do
  sips -s format jpeg -s formatOptions best "$f" \
       --out "a6300/images/full/$(basename "${f%.ARW}").jpg"
done
swift prepare_a6300.swift a6300/images/full a6300/images/raw
swift prepare_a6300.swift a6300/images/full a6300_upright/images/raw 1.87 0.544 --upright

for d in a6300 a6300_upright; do
  .venv/bin/python torch_reference.py --dir "$d"
  (cd SwiftHarness && swift run -c release s2harness overlay "../$d")
  .venv/bin/python evaluate_a6300.py --dir "$d"
done
```

Then, from the repo root:

```bash
Scripts/test.sh all
Scripts/bench-s2.sh all
```

Two footguns hit while running this:

* `torch 2.14` prints "has not been tested with coremltools". The conversion works
  and its output is verified against PyTorch in §3a, which is the check that
  matters.
* The first `Scripts/test.sh ios` after adding `SpikeS2` to
  `Packages/RPVision/Package.swift` failed with the fixture missing from the test
  bundle; the identical command passed on the next run. xcodebuild's incremental
  build did not pick up the new SwiftPM resource directory on the first pass. If a
  resource-not-found failure appears right after a `Package.swift` resource
  change, run it again before investigating.

## 9. What landed in the product

`Packages/RPVision/Sources/RPVision/Parsing/` — behind
`RPVisionFeatureFlags.faceParsing19`, **default off**:

* `FaceParsingClass.swift` — the 19-class table (with the upstream attribute name
  per case) and `FaceParsingGroup`, the named unions the render graph wants.
* `FaceParsingMask.swift` — dense byte class map, binary masks per group,
  histogram, IoU. Plain `Sendable` value type, no GPU, no Core ML.
* `FaceParsingModel.swift` — Core ML wrapper. Takes the model **URL**; the model
  is deliberately not bundled with RPVision.
* `FaceParsingRenderer.swift` — Core Image resample into the 512×512 BGRA buffer.

`Packages/RPVision/Sources/RPVision/CompiledModelCache.swift` — the
`.mlpackage` → `.mlmodelc` compile cache, **moved verbatim** out of
`FaceLandmark478Model` so both wrappers share one implementation and one lock.
`FaceLandmark478Model`'s public surface is unchanged.

`RPVisionFeatureFlags.faceParsing19` added next to `faceLandmarks478`. The flags
file still lives under `Landmarks/`, which is now the wrong folder for it; moving
it is a rename of an S1 file and was left for whoever does the Phase 2 tidy.

`FaceAnalyzer` / `FaceAnalysis` / caching are Phase 2 and were not started.

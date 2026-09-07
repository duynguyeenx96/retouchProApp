# ADR-0006 — 19-class face parsing: convert the BiSeNet PyTorch checkpoint with coremltools' traced-torch path

Status: accepted — 2026-09-04
Scope: Phase 0 spike S2 of `docs/PLAN.md` §3 (`RPVision` face-parsing path only —
no `FaceAnalyzer`, no caching, no render integration).

## Context

PLAN §1.2 chooses "BiSeNet CelebAMask-HQ → Core ML" for the 19-class parse that
drives the skin / hair / eye / brow / lip / neck masks, and §6 points at
<https://github.com/zllrunning/face-parsing.PyTorch/issues/27>. It does not say
how to convert, and — unlike spike S1, which had to hand-translate a TFLite
flatbuffer (ADR-0005) — this artefact is a plain PyTorch `state_dict`.

## Decision — `torch.jit.trace` → coremltools, not a hand-written MIL translator

`Research/spikes/S2-face-parsing/convert_bisenet_to_coreml.py` loads the upstream
`BiSeNet` module (vendored verbatim in `vendor/`, MIT), traces it at 1×3×512×512
and hands the `ScriptModule` to `coremltools.convert`. One converter, one hop.

ADR-0005 rejected multi-converter chains for S1 because a TFLite→ONNX→Torch→Core ML
chain has three places to drift. That argument does not apply here: the source
*is* Torch, so the traced path is the shortest chain available, and it is the one
coremltools tests. Writing a second MIL translator by hand would have added risk,
not removed it.

Measured, on identical 512×512 uint8 inputs
(`Research/spikes/S2-face-parsing/results/coreml_vs_torch.json`, 30 images):

| Build | mean abs logit diff | max abs | argmax pixels unchanged |
|---|---|---|---|
| fp32 | 1.96e-6 | 8.0e-5 | 99.99997 % |
| fp16 | 2.2e-3 | 4.5e-2 | 99.976 % |

The fp32 build is numerically the same network; fp16 costs 0.024 % of pixels and
0.03–0.4 % of group IoU. That is the control which says the conversion is not
where error comes from — the same role `coreml_vs_tflite.json` plays for S1.

Three artefacts, mirroring S1's shape:

| File | Precision | Input | Output | Used for |
|---|---|---|---|---|
| `models/FaceParsing19.mlpackage` | fp16 | 512×512 RGB image | `labels` int32 `[1,512,512]` | product + bench, 25 MB |
| `models/FaceParsing19_logits_fp16.mlpackage` | fp16 | `1×3×512×512` MultiArray | `logits` `[1,19,512,512]` | fidelity check |
| `models/FaceParsing19_logits_fp32.mlpackage` | fp32 | same | same | control for that check |

## Decision — preprocessing is folded into the graph, argmax too

Upstream inference is `resize 512 bilinear → /255 → (x-mean)/std (ImageNet) →
net(x)[0] → argmax(dim=1)`.

* **Normalisation inside the model.** A Core ML `ImageType` applies one scalar
  `scale` and a per-channel `bias`; the ImageNet *std* is per-channel
  (0.229/0.224/0.225), so it cannot be expressed there. Doing it in Swift instead
  would put three multiplies in every caller and give the Python reference and the
  Swift path two chances to disagree. `bisenet.NormalisedBiSeNet` does it in the
  traced graph, so the shipped model takes RGB 0–255 and there is nothing to get
  wrong on the Swift side.
* **Argmax inside the model.** Emitting the 19-channel logits would move 19 ×
  512 × 512 floats out of Core ML per image (10 MB at fp16) for a result that is
  immediately reduced to one byte per pixel. `ArgmaxBiSeNet` reduces in-graph;
  the output is `int32 [1,512,512]`, 1 MB. Soft masks, if Phase 2 wants feathered
  edges, should come from a per-class probability slice of the classes actually in
  use, not from shipping all 19.
* **`conv_out16` / `conv_out32` are dropped.** They are deep-supervision heads used
  during training; upstream inference uses `net(x)[0]` only.

## Decision — the class index table is measured, not assumed

The order is `enumerate(atts, 1)` in upstream `prepropess_data.py` — the script
that generated the training labels — with 0 = background:

```
0 background  1 skin   2 l_brow  3 r_brow  4 l_eye  5 r_eye  6 eye_g
7 l_ear   8 r_ear   9 ear_r  10 nose  11 mouth  12 u_lip  13 l_lip
14 neck  15 neck_l  16 cloth  17 hair  18 hat
```

Other published "CelebAMask-HQ 19 classes" listings order these differently. A
wrong table is invisible — every mask still looks like a mask — so it is checked
three ways rather than trusted:

1. `evaluate_iou.py` builds ground truth from the *raw per-part annotation PNGs*
   with upstream's own merge rule, then computes a 19×19 IoU matrix between
   predicted and ground-truth classes. Every class present in both matches itself
   (`mapping_check` in `results/iou.json`).
2. `FaceParsingModelTests.classIndicesMatchUpstream` pins `FaceParsingClass`
   against the table stored in the golden JSON, which the Python side wrote.
3. `FaceParsingModelTests.classGeometryIsSane` asserts hair sits above skin, eyes
   above lips, lips above neck. A permuted table can fake a histogram; it cannot
   fake the geometry.

One class is *not* self-consistent: `neck_l` (necklace) has self-IoU 0.00 across
the 3 frames that contain one. That is the model failing on a rare accessory
class, not an index shift — it does not affect any other class, and nothing in the
plan uses it.

**There is no teeth class in CelebAMask-HQ.** `mouth` (11) is the mouth interior.
PLAN §1.3's "trắng răng" slider has to derive teeth from `mouth` by luminance;
`FaceParsingGroup` documents this so Phase 2 does not go looking for a class that
does not exist.

## Decision — the model does not ship inside RPVision, and is not in the test bundle either

`FaceParsingModel` takes a **URL**, like `FaceLandmark478Model`. Two differences
from ADR-0005:

* The `.mlpackage` is 25 MB (S1's is 2.5 MB), so copying it into the test bundle
  as S1 did is not proportionate for a flag that is off. `RPVisionTests` reads it
  from `Research/spikes/S2-face-parsing/models/` via a `#filePath`-relative path,
  overridable with `RP_S2_MODEL`. Verified to work on both `platform=macOS` and
  the iPhone 17 Simulator.
* The bundle carries only the fixture the golden test needs: one 512 px face crop
  (Wikimedia Commons, CC BY-SA 4.0, reused from S1's vetted set) and its golden
  label map — 290 KB in `Tests/RPVisionTests/SpikeS2/`.

`SpikeS2` is not called `Resources` for the reason ADR-0005 records: that name
produces a test bundle that fails to codesign for the iOS Simulator.

## Decision — default-off flag

`RPVisionFeatureFlags.faceParsing19` gates construction of `FaceParsingModel`;
with the flag off the initialiser throws `RPVisionFeatureDisabled`. It stays off
because the plan's bar is not fully met: **eye IoU is 0.840 against a 0.85 bar**
(§ spike report), and the < 150 ms figure exists only on the Simulator.

Adding the second flag exposed a bug in how the first one was used:
`RPVisionFeatureFlags.resetToDefaults()` clears *every* flag, and the S1 and S2
benchmark tests run concurrently, so S1's teardown switched `faceParsing19` off
mid-run. Tests now restore only the flag they set; `resetToDefaults()` keeps its
public signature but its doc comment says it is not a per-test teardown hook.

## Decision — 512 px input, confirmed by measurement rather than inherited

PLAN §1.4 assumes "parsing 512 px". Swept on the 30-image test set
(`results/resolution_sweep.json`, PyTorch, argmax resized back to the 512 GT grid):

| Input | skin | hair | eye | torch-CPU ms |
|---|---|---|---|---|
| 384 | 0.935 | 0.929 | 0.755 | 69 |
| **512** | **0.944** | **0.937** | **0.822** | **131** |
| 768 | 0.944 | 0.934 | 0.823 | 254 |
| 1024 | 0.935 | 0.924 | 0.816 | 558 |

(means over all 30 images.) 768 buys +0.001 eye IoU for 2× the compute and 1024 is
worse than 512. 512 stays.

## Alternatives rejected

- **A pre-converted Core ML face-parsing model from a model zoo**
  (e.g. `mlboydaisuke/Face-Parsing-CoreML` on Hugging Face). Unknown provenance,
  unknown class order, no way to re-derive. The whole mapping argument above would
  become unfalsifiable.
- **ONNX as an intermediate** (`torch.onnx.export` → `coremltools`). Adds a
  converter for no benefit when the traced path works first try.
- **Shipping the 19-channel logits** — 10 MB per prediction out of Core ML, see
  above.
- **`jonathandinu/face-parsing` (SegFormer-B5)**, which reports much better small-class
  accuracy than BiSeNet. ~85 M parameters against BiSeNet's 13.3 M; the plan's
  budget is a 150 ms mobile inference. Named here as the fallback if Phase 2
  decides eye IoU 0.84 is not good enough, *with* a measurement, not on reputation.

## Consequence for Phase 2 — roll-normalise the crop before parsing

Measured on the user's 11 a6300 frames (spike report §5): fed the frames as
framed, the model produced every expected part on 9/11, and the 2 failures are
the frames with the strongest head roll (Vision: 41.5° and −19.7°), where it
collapses the whole face to one flat `skin` region — no nose, no brows, no eyes.
Rotating the crop by −roll first fixes both: **10/11**. `FaceCrop` already builds
a rotated ROI for S1's landmark path, so Phase 2 gets this by feeding the parser
the same rotated crop rather than an axis-aligned one.

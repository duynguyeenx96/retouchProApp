# ADR-0012 — The "Color" slider group and `ColorRenderNode`

Status: accepted — 2026-09-06
Scope: Phase 2 of `docs/PLAN.md` §3 — the fourth and last slider group of the
phase, at `RenderStage.color`, the **first** stage of the pipeline. The realtime
`MTKView` preview, multi-face canvas selection and the RPUI slider panel are
**not** in this ADR.

## Context

`docs/PLAN.md` Phase 2 lists ten names here — *Exposure, Contrast, Highlights,
Shadows, WB, Vibrance, Saturation, Curves, HSL, Auto D&B* — and §1.3 marks the
row "Core Image + kernel", the only group in the plan not marked pure Metal.
§2 fixes the stage order `Decode → Color → Skin → Warp(MLS) → Eyes/Teeth →
Makeup → Output`, so this node runs before every other slider group: the skin,
reshape and eye work all see the graded picture.

Three constraints were fixed before any code was written:

1. **Every slider is 0–100 with default 0** (project decision, `RPCore/Slider`).
2. **Value space is gamma-encoded sRGB** (`RenderQuality.pixelSpace`, mandatory
   per ADR-0007).
3. **Golden render PSNR ≥ 45 dB against a reference** (PLAN §3, §5).

Constraints 1 and 3 are what decide the two interesting questions below.

## Decision — 18 keys for ten names, and one direction each

`ColorSliders` ships 18 keys. Two of the plan's ten names are sub-groups, exactly
the way the "Mặt" list writes "Mũi (thu nhỏ/sống/đầu)" as one item and ships
three sliders:

* **WB** → `wbTemperature` (warmer) + `wbTint` (toward magenta). A white balance
  control without a green/magenta axis is half a control.
* **HSL** → eight per-hue-band saturation sliders, `hslRed` … `hslMagenta`.

Every slider moves in **one direction**, and that is forced rather than
preferred. `EditSection.setSlider` **deletes** a key set back to 0, so "absent"
and "neutral" have to be the same number; `Slider.clamp` pins the range at 0…100
for every group in the project. A signed exposure, or a temperature slider
centred at 50, would make an *empty* `EditState` a non-identity render — which
breaks the contract every node in the graph is built on (`isIdentity` → the graph
skips the node → bit-exact passthrough, `RenderGraphTests.emptyEditStateIsPassthrough`).

So the direction of each slider is chosen and written down
(`ColorSliders`' doc comment): exposure brightens, highlights recover downward,
shadows lift, WB warms, tint goes magenta, the three saturation controls add.
**There is no darken, no cool, no desaturate.** Getting them needs either a
signed `Slider.range` or a paired key, and both are plan-level decisions about
`RPCore`, not changes to this node — the same disclosure the "Mặt" group makes
about its one-directional reshape sliders (ADR-0010).

## Decision — a Metal kernel, not a CIFilter chain

PLAN §1.3 says "Core Image + kernel". It is a Metal compute kernel. Three
reasons, in order of weight:

### 1. There is no formula to write a reference against

The plan's other Phase 2 bar is a **golden PSNR ≥ 45 dB against a `Double`
reference**, and that is only meaningful if the reference is an independent pass
over a *written specification*. `CIColorControls`, `CIVibrance`, `CIToneCurve`
and `CITemperatureAndTint` publish no formula. A "reference" for them could only
be a second call to the same black box, which measures nothing, or a guess at
their internals, which would break under an OS update — and the group is expected
to render the same picture on macOS 15 and iOS 18 today and after every point
release. This alone settles it.

### 2. Nine of the eighteen sliders have no CIFilter

There is no `CIFilter` for per-hue-band saturation (8 HSL bands) and none for
the two-scale Auto D&B this group ports from `panelpts` — nine sliders in all.
Those nine would need a `CIKernel` anyway — i.e. the "+ kernel" half of the
plan's row — on top of a chain whose other half we could not test.

### 3. The measured cost is not an argument for Core Image either

Measured, on the same textures, in the same process, as a control
(`ColorBenchTests.coreImageControl`, `speed.*.core_image_control` in
`Research/bench/p2-color-macos.json`). The CI chain is
`CIExposureAdjust + CITemperatureAndTint + CIHighlightShadowAdjust +
CIColorControls + CIVibrance + CIToneCurve` — **9 of the 18 sliders**
(exposure, wbTemperature, wbTint, highlights, shadows, contrast, saturation,
vibrance, curves — contrast+saturation share one `CIColorControls` call and
temperature+tint share one `CITemperatureAndTint` call), so it is a *lower
bound* on a CIFilter implementation:

| M1 Pro, Release | this node, 18 sliders | CI chain, 9 sliders |
|---|---|---|
| 2048 px preview | 1.59 ms | 1.25 ms |
| 24 MP | 9.46 ms | 7.64 ms |
| first render (kernel compile) | 0.51 ms library compile, paid once in `prewarm()` | 4.6 ms (preview) / 9.5 ms (24 MP), inside the first `render` |

Per slider that is ~2.4× in this node's favour at 24 MP, but the honest reading
is **"comparable"**: Core Image concatenates its chain into few passes and is not
the naive per-filter round trip it is sometimes assumed to be. Speed is therefore
*not* why this is Metal — reasons 1 and 2 are. What the numbers do rule out is
the opposite claim, that Core Image would have been meaningfully cheaper.

Two smaller consequences, recorded rather than measured:

* Core Image compiles its own kernels on first render, inside the call. That is
  the cost `RenderGraph.prewarm()` exists to keep off the interaction path
  (236 ms cold on macOS, 1798 ms in the Simulator, ADR-0007), and it would come
  back in a form the graph cannot prewarm.
* CI's working colour space would have to be forced to "no colour management" to
  keep constraint 2 (`.sRGBEncoded` data treated as data), which is exactly the
  configuration its documented filter semantics are *not* specified for.

**Nothing in RPEngine imports Core Image.** The control lives in the test target
so the measurement exists without the dependency.

## Decision — the pipeline inside the composite

One pass, one 4 kB LUT, and — only when Auto D&B is up — a small analysis
pyramid. The step order is fixed and the `Double` reference reproduces it step
for step, so it is part of the contract:

1. **Auto D&B** — first, because its analysis was measured on the incoming
   picture: it corrects *this* frame's local luminance error, and everything
   after it is a global grade on the corrected frame.
2. **Exposure + White Balance**, in **linear light**. Both are scalings of the
   light that reached the sensor. This is the one documented exception to
   `pixelSpace == .sRGBEncoded`: the kernel converts, scales and converts back
   inside a single branch, so the transfer function is paid once for both and
   only when one of the three sliders is off 0. Exposure is `exp2(amount)`, i.e.
   +1 EV at 100 (measured: 1.99999972× on a linear mid-grey). White balance is a
   von Kries diagonal `(1 + 0.22a, 1 − 0.12t, 1 − 0.22a)` renormalised by
   `dot(gain, Rec.709)`, so it changes the colour of the light and not the amount
   (measured: mean luminance moves 3.9e-4 at `wbTemperature = 100`).
3. **Highlights** — `pow(c, 1.45)` weighted by `smoothstep(0.45, 1, luma)`.
4. **Shadows** — `pow(c, 0.65)` weighted by `1 − smoothstep(0, 0.55, luma)`.
   Both are endpoint-preserving gammas, so neither can crush black or clip white,
   and a neutral stays neutral. Chosen over the usual "scale the luma, keep the
   chroma ratio" because that form divides by the luma and explodes the chroma of
   a near-black pixel.
5. **Contrast** — `mix(c, smoothstep(0,1,c), 0.5·amount)`. Monotone,
   endpoint-preserving, cannot clip, unlike `pivot + (c − pivot)·gain`.
6. **Curves** — the fixed per-channel film LUT, below.
7. **Vibrance** — saturation scaled by `1 − sat`, damped to 40 % on the skin-tone
   hue band (centre 25°, half-width 40°).
8. **Saturation** — uniform, up to 2× at 100.
9. **HSL** — per-hue-band saturation, below.

## Decision — "Curves" is a per-channel LUT, not a knot editor

One 0–100 slider cannot carry an arbitrary spline, so the slider is the *amount*
of a curve fixed in `ColorToneCurve`, and the machinery around it — 256 RGBA
entries built on the CPU, uploaded once as an RGBA32Float texture, sampled with a
lerp in the shader — is the part a later knot editor needs. Swapping the table
for user knots is then a data change; the kernel does not know where the numbers
came from.

The curve is `toe_c + (1 − toe_c − shoulder_c) · mix(x, smoothstep(x), 0.35)`
with `toe = (0.030, 0.035, 0.045)` and `shoulder = (0.028, 0.020, 0.016)`: a
lifted matte foot, a rolled shoulder, and **cool shadows / warm highlights** from
the per-channel split. That split is why the LUT is genuinely per channel rather
than one curve stored three times, and it is also a stated side effect: at high
values the slider moves the white balance a little. That is what the look is.

Monotonicity and the endpoints are asserted over 1001 samples per channel; the
LUT-plus-lerp costs **3.8e-6** against evaluating the curve exactly
(`curve_lut_max_error`), i.e. ~1/1000 of an 8-bit code value.

## Decision — HSL is eight normalised triangular hue windows

Centres are the classic eight-band split (red 0°, orange 30°, yellow 60°, green
120°, aqua 180°, blue 240°, purple 280°, magenta 320°). Each gets a triangular
window of ±60°, and the eight are **divided by their sum**.

That normalisation is the whole design: the centres are not evenly spaced, so
un-normalised overlapping windows would boost a hue sitting between two centres
twice. Normalised they are a partition of unity, which gives a property worth
testing — **all eight bands at 100 is exactly the plain Saturation slider at
100**, measured max abs difference **0.0** on the chart
(`hslBandsSumToPlainSaturation`).

Per-band *lightness* and *hue rotation* are deliberately not shipped: 16 more
keys, and the band weights the kernel already computes are the whole of the
machinery they would need.

## Decision — Auto D&B is `autoskin.js`'s `dodgeBurnMaps`, on the whole frame

The port is the panel's numbers, not a re-derivation
(`panelpts/RetouchProUXP/autoskin.js:217-238`, `commands.js:445-460`):

| panel | here |
|---|---|
| analysis raster `SMALL_W = 320` wide | `ColorRenderNode.analysisWidth = 320` |
| `rBig = max(3, round(sw · 0.055))` = 18 px | same, 18 px |
| `rSmall = max(1, round(sw · 0.012))` = 4 px | same, 4 px |
| `big = boxBlur(lum, rBig, 2)`, `small = boxBlur(lum, rSmall, 1)` | same, separable H then V |
| `dev = small − big`; `k = strength/50·9` on 0…255 | `dev = small − big`; `min(1, |dev|·18·amount)` on 0…1 |
| dodge curve `[[0,0],[128,146],[255,255]]` | `pow(c, 0.8091)` — fitted so 128/255 → 146/255 |
| burn curve `[[0,0],[128,110],[255,255]]` | `pow(c, 1.2199)` — fitted so 128/255 → 110/255 |

Keeping the analysis on a 320-wide grid is not an approximation of the panel, it
*is* the panel — and it is what makes the slider affordable: **2.4 MB** of
r32Float planes at 24 MP, against 384 MB for the two full-resolution RGBA blur
layers the naive version would need. Allocated on first use, so a document
without the slider pays 4 kB (the LUT) and nothing else — measured, 2 461 696 vs
4 096 bytes.

**Two deviations, both stated:**

* The panel multiplied its dodge/burn masks by the **skin mask**. This runs on
  the whole frame, so on a portrait it will also even out the local luminance of
  hair and background. Masking it would give the entire colour stage a face
  dependency it otherwise does not have, and the colour stage runs *before* the
  skin stage anyway. If this turns out to matter, the honest fix is a second
  skin-masked D&B in the "Da" group, not a face input here.
* The panel blurred the *clamped* mask by 1 px on the analysis grid; here the two
  planes are bilinearly upsampled and the clamp is applied at full resolution.
  Bilinear upsampling from a 320-wide grid is a far stronger smoothing than a
  1 px box on that grid, and the two differ only where the mask saturates.

The two box kernels are new (`rp_color_box_h` / `rp_color_box_v`) rather than
reused from the guided filter: `rp_gf_box_h`/`_v` filter a *pair* of textures at
one radius, and this needs one texture at two different radii, so pairing them
would compute each blur twice.

## Decision — no `FaceRenderInput`, and no shared kernel flag

`ColorRenderNode.isActive(for:)` ignores `request.faces` entirely. A colour grade
is global; none of the 18 sliders has a per-face meaning; and the node therefore
works on a frame with no detected face — a landscape, a product shot, a
back-of-head. That is the behaviour we want, and a forced mask dependency would
have broken it (`noFaceIsStillActive`).

`RPEngineFeatureFlags.colorSliders` is the group's only flag. The node owns all
four of its kernels and borrows neither `guidedFilter` nor `mlsMeshWarp`, so
`disableColorRenderGraph()` is unconditional and still cannot take another group
down — unlike `disableSkinRenderGraph()`, which has to ask whether the
"Mắt / Răng" group still wants the shared kernel flag (ADR-0011), and unlike the
umbrella `renderGraph` flag that was deleted in ADR-0010.
`RenderGraphTests.disablingTheColorGroupLeavesTheOthersRunning` and
`.fourGroupsSortByStage` are the regression tests.

`Render/RenderShaderSources/ColorShaders.metal` is a **fourth** entry in
`MetalContext.shaderSources`, concatenated after `SkinShaders.metal` (whose
`kRPLuma` it reuses) and compiled in the **same** `makeLibrary(source:)` call —
still one compile per process, the property `RenderGraph.prewarm()` depends on
(`shaderSourcesAreAllPresent` now checks four files and nine functions).

## Measurements

`Scripts/bench-color.sh` → `Research/bench/p2-color-{macos,ios-simulator}.json`,
scraped from `RPEngineTests/ColorBenchTests`, Release, so the number filed under
`Research/` is always the number a test measured.

The JSON carries three claims plus the control, deliberately not merged:

* `golden.*` — PSNR against `ColorReference`, a `Double` CPU implementation
  written from this specification. Says the GPU computes the documented formula.
* `behaviour.*` — mean signed luminance change on each end of the ramp, and mean
  |Δ| per labelled region. Says each slider acts on the part of the picture its
  name refers to. **A PSNR cannot say this**: a Highlights slider that computed
  the documented formula against the *shadow* window would score just as well.
* `speed.*` — ms/frame on the real a6300 frame spike S3 uses.
* `speed.*.core_image_control` — the CIFilter chain above.

### Golden — synthetic grading chart, 320×240

Ramp 0.04 → 0.96, eight saturated hue patches, a skin patch, and a bright and a
dark disc at a scale between the two Auto D&B radii.

| level | number |
|---|---|
| all 18 sliders at 0 | max abs **0** (bit-exact identity) |
| composite, fed the GPU's own analysis planes | **137.8 dB** |
| per slider (18 of them) | **143.2 – 168.6 dB**, plus three exactly infinite |
| whole node end-to-end | **136.3 dB**, max abs 9.5e-7 |
| curve LUT vs the exact curve | 3.8e-6 |

Bar is 45 dB. The three infinite per-slider figures (`curves`, `hslGreen`,
`hslAqua`) are not a bug: those sliders only move a handful of flat-coloured
patches on this fixture, and the GPU's float32 and the reference's `Double`
round to the same float32 there. They are filed as the string `"inf"` rather than
clipped to an invented number.

The numbers are two orders of magnitude above the bar because this node is
per-pixel arithmetic with one small resampling step, unlike the guided filter
(79 dB) or the MLS warp (83 dB), both of which resample.

**What the reference proves and does not.** It is a different language, a
different precision and a separate pass over the same written specification, so
it catches a transcription error — a swapped channel, a `min` for a `max`, a
gamma on the wrong branch of a window. It does **not** catch a wrong
specification: if the film curve is ugly, both implementations agree and both are
ugly. Same honest limit as `SkinReference` (ADR-0009), `WarpReference`
(ADR-0010) and `EyesTeethReference` (ADR-0011). The curve LUT is deliberately
*shared* — the reference reads the same uploaded `[Float]` table — so the
comparison measures the kernel's lookup and mix rather than a second
transcription of the curve; `ColorToneCurve` is checked separately for
monotonicity, endpoints and the per-channel split.

### Behaviour — slider at 100

| claim | measured |
|---|---|
| Highlights pulls the bright end down | ramp 0.75–0.95: **−0.0483** luma |
| …and leaves the dark end alone | ramp 0.05–0.25: **0.0** |
| Shadows lifts the dark end | ramp 0.05–0.25: **+0.1059** |
| …and leaves the bright end alone | ramp 0.75–0.95: **0.0** |
| Auto D&B burns a bright blob | **−0.0727** luma |
| …dodges a dark blob | **+0.0738** |
| …and ignores the flat ramp between them | **+0.0013** |
| `hslRed` on the red patch | **0.1162** |
| …on the green patch | **0** |
| …on the aqua patch | **0** |
| …on the skin patch | 0.0325 — correct, skin's 20° hue is inside the red band's ±60° window |
| Exposure = +1 EV | linear ratio **1.9999997** |
| WB is luminance-preserving | mean luma change **−3.9e-4** |
| Vibrance holds back on skin | 0.0283 on a 20° hue against **0.0750** on a 140° hue of identical saturation |
| All 8 HSL bands = plain Saturation | max abs **0.0** |

The two exact zeros are the ±60° window closing, not a fixture artefact: green
(120°) and aqua (180°) are more than 60° from red.

### Speed — real a6300 frame `DSC05123` (4000×6000), Release, wall-clock median

| | M1 Pro | iOS Simulator |
|---|---|---|
| preview 2048 px (1365×2048), all 18 sliders | **1.59 ms → 628 fps** | 3.62 ms → 276 fps |
| preview, tone only (no Auto D&B) | 0.54 ms → 1862 fps | 1.62 ms → 619 fps |
| 24 MP, all 18 sliders | **9.46 ms** | 10.0 ms |
| 24 MP, tone only | 2.78 ms | 3.23 ms |
| 24 MP, every slider at 0 (the graph's copy) | 2.31 ms | 2.72 ms |
| node bytes, all sliders | **2 461 696** | same |
| node bytes, tone only | **4 096** | same |

Bars are ≥ 30 fps preview and < 8 s export. **Not measured on an iPhone** — no
device is attached, the same limitation S1, S2, S3, `FaceAnalyzer`, the Da group,
the Mặt group and the Mắt/Răng group all record. `is_real_device` in the JSON
says which is which, and in the Simulator `gpu_median_ms` is not a GPU time (it
reports 0.07 ms for a 24 MP render); read `wall_*_ms` there.

This is by far the cheapest of the four groups in memory: 2.4 MB against the Da
group's 552 MB and the Mắt/Răng group's 384 MB at 24 MP.

## Known limitations, stated rather than hidden

* Every constant — the stop, the two WB gains, the two tone windows and their
  gammas, the contrast mix, the vibrance protection, the film curve's toe and
  shoulder — is argued from what the operation physically is and is **not tuned
  against a retoucher's eye**. Nobody has looked at a render. What is measured is
  that the GPU computes the documented formula and that each slider lands on the
  right part of the picture.
* Every slider is one-directional; see above.
* **Auto D&B is global, not skin-masked**, unlike the panel it is ported from.
* "Curves" is a fixed film curve, and its per-channel split moves the white
  balance slightly at high values.
* HSL is per-band saturation only.
* The behavioural numbers come from a synthetic chart, not from a graded
  photograph. The claim is "the slider moves this part of a picture that looks
  like this", which is weaker than "it does the right thing to the user's
  photographs".
* The chart's hue patches are fully saturated, so the vibrance `1 − sat` weight
  is exercised at its ends but not across a real image's distribution.

## Alternatives rejected

* **A CIFilter chain** — see above. No published formula to write the 45 dB
  reference against; no filter for 10 of the 18 sliders; measured no faster.
* **Two full-resolution blur layers for Auto D&B** instead of the 320-wide
  analysis grid: 384 MB at 24 MP for one slider, and not what the panel did.
* **Reusing `rp_gf_box_h`/`_v`** for the analysis: they filter a texture *pair*
  at one radius, so two radii would mean computing each blur twice.
* **A `sampler` for the analysis upsample**: sampler interpolation weights are
  fixed-point and implementation-defined, and this value has to be reproducible
  by a `Double` CPU reference to 45 dB. The kernel does the bilinear by hand.
* **Luma-ratio Highlights/Shadows** (`c · L'/L`): divides by the luma and blows up
  the chroma of near-black pixels. Endpoint-preserving gammas instead.
* **Un-normalised HSL windows**: double-boost every hue that sits between two
  centres, and "all eight at 100" would then not equal Saturation at 100.
* **A signed range or a centre-at-50 default** for exposure and WB: breaks the
  "absent key == neutral" contract that makes an empty `EditState` a bit-exact
  passthrough. It is a `RPCore/Slider` decision, not this node's.
* **A skin mask on Auto D&B**: gives the whole colour stage a face dependency,
  for one slider, at a stage that runs before the skin group.

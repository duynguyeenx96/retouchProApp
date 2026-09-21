# ADR-0023 — A real Kelvin white balance, and ±5 EV of exposure

Status: accepted — 2026-09-21
Scope: the two strongest sliders in the "Màu" group, `wbTemperature` and
`exposure`, inside the existing `ColorRenderNode` (docs/ADR-0012) and the
existing −100…100 storage contract (docs/ADR-0016). **`wbTint` is out of scope
and untouched**, and so is every other slider in the group.

## Context — a photographer said it was weak, and the code agreed

The report was specific: *dragging "Nhiệt độ" on a heavily yellow-cast frame
barely does anything*. Reading the shader says why, and the two constants were
sitting next to each other:

```metal
constant float kRPExposureStops = 1.0;        // ±1 EV at ±100
constant float kRPWBTemperatureGain = 0.22;   // pow(1 ± 0.22, amount) on R and B
```

The exposure one is a range decision. The white-balance one is worse than a
range decision: **there was no colour temperature in the white balance at all.**
`pow(1.22, a)` on red and `pow(0.78, a)` on blue is an arbitrary fixed-magnitude
von Kries diagonal. It has the *shape* of warming and cooling, and ADR-0012 was
honest that its constants were "argued from what the operation physically is and
not tuned", but nothing in it refers to a light source, a Planckian locus or a
Kelvin. Asked what colour temperature its endpoints correspond to, the code has
no answer — it can only be measured after the fact, which is what §Measurements
below does.

Measured after the fact, from a D65 neutral (`WhiteBalanceTests.theNewRangeIsMuchWiderThanTheOldGain`):

| the old slider at | R/B gain | ≙ declared illuminant | ≙ mired shift |
|---|---|---|---|
| **+100** (warmest available) | 1.5641 | 9462 K | **+48 mired** |
| **−100** (coolest available) | 0.6393 | 5068 K | **−43 mired** |

A −43 mired shift is a third of an 80A filter. A tungsten cast — a frame lit at
3200 K and developed for daylight — is **159 mired** out. The slider could not
reach a quarter of the way there at full travel. The user was right, and the
complaint was specifically about the **cooling** half.

## Decision 1 — the slider declares a colour temperature, mapped linearly in mired

The slider value is the **colour temperature the user declares the scene light
was**, which is Lightroom's definition of its "Temp" slider. Declare bluer light
than the photo was shot under and the correction warms the picture; declare
warmer light and it cools it. So positive = higher declared Kelvin = warmer
output — which keeps the `+ ấm hơn · − lạnh hơn` direction line ADR-0016 shipped,
even though the Kelvin number underneath moves the other way. That inversion is
the single easiest thing to get backwards here, so it has its own test
(`positiveWarmsAndNegativeCools`, which walks the whole slider and asserts the
white's R/B ratio is monotone).

```
neutralMired  = 10⁶ / neutralKelvin
declaredMired = neutralMired + |amount| · (endpointMired − neutralMired)
    endpoint = 50000 K (20 mired)  when amount > 0   → warms
    endpoint =  2000 K (500 mired) when amount < 0   → cools
```

**Mired, not Kelvin**, for two independent reasons. Equal mired steps are roughly
equal perceptual steps along the Planckian locus and equal Kelvin steps are
emphatically not (2000→3000 K is violent, 24000→25000 K is invisible); and mired
is what makes a range as lopsided as 2000…50000 K expressible on a symmetric
−100…100 control without a hand-rolled non-linearity. The two halves are
deliberately *unequal in strength* — from a 6500 K neutral the cool half is 346
mired wide and the warm half 134 — because that is what the locus is, and it is
also what Lightroom's own 2000…50000 K range does. It happens to put the range
where the complaint was.

### Why relative-to-neutral and not an absolute Kelvin readout

Lightroom itself shows Temperature two ways: **absolute Kelvin for RAW files**,
and a **relative −100…+100 scale for JPEG/TIFF**, because a rendered file carries
no sensor calibration to anchor an absolute number to. This app is, today,
entirely in the second case — and not by oversight:
`Packages/RPEngine/Sources/RPEngine/ImageDecoder.swift` says so in its own doc
comment. It decodes every file, ARW included, with
`CGImageSourceCreateThumbnailAtIndex`, which for a RAW hands back **the camera's
embedded JPEG preview**, not a sensor decode. True RAW development via
`CIRAWFilter` is docs/PLAN.md spike **S4**, deferred and not built. So there is
no per-camera colour matrix and no as-shot sensor white balance anywhere in this
pipeline; every image reaching the render graph is already JPEG-equivalent.

The relative scale is therefore the *correct* choice here rather than a
limitation of the Kelvin/Bradford maths below — it is the same call Lightroom
makes in the same situation. If RAW decode ever ships, an absolute-Kelvin mode
for that path can be added **without touching the `EditState`/`Slider`
−100…100 contract**: it would be a display and input-mode difference in RPUI
(show "5200 K" instead of "−18"), not a change to what is stored. Nothing in
this ADR builds that branch, because there is no RAW decode to hang it off.

### What `amount == 0` means, and why the invariant survives

`RPCore/EditState.swift` states it in words: *"a slider whose neutral is not its
default … is not allowed anywhere."* At `amount == 0` the declared temperature
**is** the neutral, the adaptation is the identity, and the render is bit-exact
the source. The neutral only sets how many mired one slider unit is worth on
either side; it never changes what 0 does. `zeroIsExactlyTheIdentity` checks this
for five different neutrals, and it is *short-circuited* rather than computed —
see "the identity is literal" below.

## Decision 2 — Bradford chromatic adaptation, as a 3×3, from citable constants

`targetK → xy → XYZ → Bradford CAT → linear sRGB`, all of it published:

* **Planckian locus** — Kim et al. (2002)'s cubic-spline approximation, the one
  Wikipedia's *Planckian locus* article and Bruce Lindbloom both print,
  transcribed coefficient for coefficient into
  `WhiteBalance.planckianChromaticity(kelvin:)`.
* **Bradford `M_A` and `M_A⁻¹`, and the sRGB/D65 RGB↔XYZ matrices** — Bruce
  Lindbloom, *Chromatic Adaptation* and *RGB/XYZ Matrices*. `M_A⁻¹` is taken
  from the reference as published rather than inverted numerically, so the
  constants in the file are exactly the citable ones.
* The gain is `M_XYZ→RGB · M_A⁻¹ · diag(ρ_d/ρ_s) · M_A · M_RGB→XYZ`, adapting
  **from the declared illuminant to the photograph's neutral**.

**It is a matrix, not a diagonal.** A Bradford CAT is only diagonal in *cone*
space; reduced to a diagonal in sRGB primaries it explodes, because sRGB's blue
primary barely responds to a 2000 K illuminant — measured, that route wants a
**48.7× blue gain** where Bradford wants **6.45×**. The full 3×3 is also what
every ICC profile does. It is free at runtime: the matrix is uniform over the
frame, so all of the colour science is paid once per render on the CPU
(`WhiteBalance.linearRGBGain`) and the kernel pays one `float3x3` multiply — which
*replaces* three per-pixel `pow()` calls. ADR-0016 filed exactly this hoist as
"a known move, not a discovery"; it is taken now because the maths no longer fits
in the kernel.

`wbTint` is untouched and still lives in the shader: `pow(1 − 0.12, amount)` on
green alone, and the same joint luminance renormalisation
(`gain /= dot(white, kRPLuma)`) wraps both. With `wbTemperature == 0` the matrix
is the literal identity, `M · v` is `1·r + 0·g + 0·b` = `r` exactly, and a
tint-only render is the render it always was.

### The identity is literal, not "within tolerance"

`M_A⁻¹ · M_A` is not exactly `I` — published 7-digit constants round-trip to
**4.4e-7** (`adaptationComposesBackToTheIdentity`), and the two RGB/XYZ matrices
add their own residue. That is a tenth of an 8-bit code value and harmless as a
grade, but "slider at 0 changes nothing" is a **bit-exact** claim in this project,
and a render that moved only Exposure must not pick up a colour cast on the way.
So `linearRGBGain(amount: 0, …)` returns `Matrix3.identity` by a guard, before
any arithmetic happens. That guard is the whole reason
`allSlidersZeroIsBitExactIdentity` still reports max abs **0**.

### On extrapolating past Kim et al.'s stated validity

Kim et al. is stated valid **1667 K … 25000 K**, and the cool ceiling is 50000 K.
Rather than either silently extrapolating or reflexively clamping, the error was
measured two ways:

| check | result |
|---|---|
| vs **published CIE locus chromaticities** at 2000/2856/4000/6500/10000/25000 K | max **0.00059** in `xy`; at 2856 K — CIE Illuminant A, which is *defined* as a 2856 K Planckian radiator at (0.44757, 0.40745) — **0.00050** |
| vs a numerical integration of Planck's law over the CIE 1931 2° observer, inside its stated range (1667–25000 K) | max **0.0047**, at the **1667 K** end |
| the same, **extrapolated** 25000–50000 K | max **0.00040**, i.e. **0.00040 at 50000 K** |
| effect on the shipped gain matrix at 50000 K | max |ΔM| **0.0039**; white gain (1.3292, 0.9576, 0.4507) vs (1.3232, 0.9595, 0.4492) — **0.5 %** |
| effect on the shipped gain matrix at **2000 K** (inside the stated range) | max |ΔM| **0.051**; white gain (−0.3731, 0.8579, 6.4506) vs (−0.3495, 0.8451, 6.508) — **~1 %** |

The reading is the opposite of the intuition: **the extrapolated cool endpoint is
an order of magnitude better behaved than the warm endpoint that sits inside the
fit's stated range.** The fit's error is concentrated at the *hot-orange* end;
past 25000 K the locus has nearly converged (Kim's `T → ∞` limit is
(0.24039, 0.23522) against the locus' true (≈0.2399, ≈0.2343)), so there is very
little left to be wrong about. Clamping the cool end to 25000 K would have cost
15 % of the cool half's travel and bought nothing.

The honest caveat on the second and third rows: the "numerical integration"
control uses the Wyman–Sloan–Shirley (JCGT 2013) analytic fit to the CIE colour
matching functions, which is itself ~1 % accurate, so those two rows are an
*order-of-magnitude* comparison and the first row — against published locus
values, including one the CIE defines exactly — is the one that stands on its
own. It is a scratch measurement, not a shipped test; the shipped test is
`planckianLocusMatchesPublishedChromaticities`.

## Decision 3 — exposure is ±5 EV

`kRPExposureStops` 1.0 → **5.0**, Lightroom's convention. ADR-0012's argument for
1.0 was "a portrait that needs more than a stop needs a re-shoot or a raw
redevelop", and that argument is simply wrong for the one thing this group exists
to do — ADR-0016 already said it out loud: the "Màu" group is *the only one that
also has to correct what is already in the file*. A frame metered two stops down
cannot be rescued by a slider that stops at one, and this app does not have a raw
redevelop to fall back on (spike S4, above).

`exp2(amount · 5)` keeps every property the old constant had: symmetric in stops,
so −100 is exactly 1/32× and the exact inverse of +100's 32×
(measured: **32.000004** and **0.031250** — `exposureIsAStopOfLight`,
`exposureIsSymmetricInStops`).

**What 32× does downstream was checked rather than assumed.** Highlights, Shadows,
Contrast, Curves, Vibrance, Saturation and HSL all read the already-exposed
value, and at +5 EV that value is far outside 0…1 for most of a normal frame:

* `pow(max(c, 0), g)` on a value of 32 is finite in both directions; no NaN.
* the highlight/shadow windows are `smoothstep`, which saturates; Contrast takes
  `saturate(c)` before the S-curve; the curve LUT clamps its input.
* the composite's final `clamp(c, 0, 1)` is unchanged.
* `exposureIsSymmetricInStops` now also sweeps the whole output for a non-finite
  or negative value at −100. None.
* the golden PSNRs did not move (below), which is the strongest statement
  available: the `Double` reference computes the same 32× through the same steps
  and the two still agree.

The measurement ADR-0012 recorded — *"+1 EV at 100 (measured: 1.99999972× on a
linear mid-grey)"* — is stale and is corrected in that file. The probe pixel had
to move too: 32× on a mid-grey is far past white, and a clipped pixel can only
say "≥ 1", so the ratio is now read off a **dark** ramp pixel (linear 0.0101)
with a separate assertion that a mid-grey does reach white. That is not the
slider misbehaving; Lightroom at +5 clips the same mid-grey.

## What EXIF actually has — the investigation, and the honest answer

The question was whether a real a6300 file can tell us its own neutral. Dumped
`CGImageSourceCopyPropertiesAtIndex`, `CGImageSourceCopyProperties` and the whole
`CGImageMetadata` tag tree for `Research/data/DSC05123.ARW` and for a matching
JPEG. The answer:

* **Nothing usable in EXIF, for either format.** `Exif/WhiteBalance = 0` is the
  0-or-1 "auto or manual" flag, not a temperature. `Exif/LightSource = 0` is
  "unknown". There is **no maker-note dictionary at all** in ImageIO's properties
  — no `{MakerSony}`, nothing. What is there is what `MetadataExtractor` already
  reads: make, model, lens, ISO, shutter, aperture, focal length, dates, plus a
  `{PictureStyle}` block of enum names and a `{raw}` block of crop/sensor sizes
  and thumbnail offsets.
* **`CIRAWFilter` does have a number**, and it is a real one: `neutralTemperature`
  reads **6816.29 K** for `DSC05123.ARW`, and across five test files it ranges
  **6071.8 – 7383.0 K**. Core Image decodes Sony's maker note internally; ImageIO's
  property dictionary does not surface it.

**It is not wired in, deliberately.** Three reasons, in order of weight:

1. `CIRAWFilter` *is* the RAW path, which docs/PLAN.md defers to spike **S4**.
   Pulling it into `RPImport` for one scalar would add a Core Image dependency to
   a package that has none and start the RAW work sideways.
2. It costs **~40 ms warm / ~190–230 ms cold per ARW**, measured, on top of an
   import that today parses a header in a few milliseconds.
3. The refinement is invisible. Against the D65 fallback the spread across the
   whole test set is **6072 K (164.7 mired) to 7383 K (135.4 mired)** versus
   D65's 153.8 — at most **19 mired**, which changes how much one slider unit is
   worth by a few percent and changes nothing at all at slider 0.

So **6500 K is what ships**, which is what this task predicted was the likely
outcome. The seam is built and tested:
`RenderRequest.referenceColorTemperatureKelvin: Double?`, `nil` ⇒ D65, read only
by `ColorRenderNode`, following the same "already resolved per shot, the node
reads what it is given" pattern as `bodySkinMask` and `gateMasks`.
`WhiteBalanceTests.theNeutralRescalesButDoesNotMoveZero` drives a non-default
neutral end to end on the maths. **Nothing fills the field today** — not
`LivePreviewController`, not `ExportRenderer` — and the field's own doc comment
says so and names S4 as where the producer belongs. Threading a value through
RPUI that no producer sets would have been dead code.

## Measurements

### Golden — unchanged, which is the point

`Scripts/bench-color.sh` → `Research/bench/p2-color-macos.json`, Release, M1 Pro.
`ColorReference` was extended the same way the kernel was: a **separate**
transcription of Kim et al.'s coefficients, of the four Lindbloom matrices and of
the mired mapping, in `Double`, with its own flat-array matrix arithmetic. It is
a second pass over this written specification, so it catches a transcription
error and cannot catch a wrong specification — the same honest limit ADR-0009 /
0010 / 0011 / 0012 / 0016 all record. For the colour science specifically, the
tests that *can* catch a wrong specification are the ones checking against things
outside this repository: Lindbloom's published D65→D50 matrix and the CIE's own
definition of Illuminant A.

| level | before (ADR-0016) | after | bar |
|---|---|---|---|
| all 18 sliders at 0 | max abs **0** | max abs **0** | must be 0 |
| per slider at +100 (18) | 143.19 – 168.58 dB | **143.19 – 168.58 dB** (`wbTemperature` 144.65, `exposure` 144.16) | 45 dB |
| per slider at −100 (16) | 142.96 – 174.60 dB | **143.81 – 174.60 dB** (`wbTemperature` 143.81, `exposure` 156.16) | 45 dB |
| composite (all positive) | 138.05 dB | **138.36 dB** | 45 dB |
| whole node end-to-end, all positive | 136.58 dB | **136.61 dB**, max abs 1.01e-6 | 45 dB |
| whole node end-to-end, mixed signs | 139.33 dB | **140.03 dB**, max abs 5.96e-7 | 45 dB |
| curve LUT vs the exact curve | 3.80e-6 | **3.80e-6** (untouched) | 1e-5 |
| `ColorParams` stride | 96 B | **144 B** (`wbMatrix`, a `float3x3`) | pinned |

The `wbTemperature` and `exposure` rows are the ones that could have moved and
did not meaningfully: the kernel and a `Double` reference that computes Bradford
and 32× independently still agree to ~144 dB. The float32 `float3x3` handed to
the GPU against the reference's `Double` matrix is where most of that gap comes
from, and 144 dB is three orders of magnitude of margin on a 45 dB bar.

The bit-exact **0** at all-sliders-zero is the load-bearing row, exactly as it
was in ADR-0016: this change rewrites the gain that every render passes through,
and 0 staying at a hard 0 is what says the graph's passthrough contract survived.

### The number the change exists to move — a 3200 K cast

A neutral grey developed for daylight but lit at 3200 K, built from **published**
CIE locus chromaticities so the fixture and the correction cannot cancel a shared
mistake (`WhiteBalanceTests.aTungstenCastIsNeutralised`, on a linear 0.4 grey):

| | channel spread | R/B |
|---|---|---|
| the cast frame | **0.5281** | 5.23 |
| the **old** formula at its −100 endpoint (the strongest cooling it had) | **0.3820** — 28 % of the cast removed | 3.34 |
| corrected, new slider at **−45.9** | **0.00050** | 1.00 |

The correcting slider value is the whole argument in one number. Slider −45.9
declares **3197.6 K** — and the fixture was built at **3200 K**. The semantics
are therefore demonstrably Lightroom's: *to fix a cast from a 3200 K light, tell
the app the light was 3200 K.* Nothing in the test knows that; the mapping, the
locus and the adaptation direction all have to be right independently for those
two numbers to land on each other.

…and through the **real render graph**, on a 64×64 sRGB frame with the cast
applied and one slider in a real `EditState`
(`ColorRenderNodeTests.aYellowCastFrameIsNeutralisedThroughTheGraph`), relative
channel-mean spread in linear light:

| | spread |
|---|---|
| before | **1.402** |
| slider 0 *(control)* | **1.402**, and max abs difference from the source **exactly 0** |
| best over the slider's travel: **−45** | **0.0341** |
| at −100 (overshoot, kept as a datum) | 2.023 |

Two things matter in that table beyond the headline. The correction lands at
**−45**, not at the end of the slider, so there is headroom left for a worse
cast. And the control row is the invariant: a cast frame with the slider at 0 is
returned **bit for bit**.

### Strength, at half travel, in linear light

`ColorRenderNodeTests.whiteBalanceDirectionsAreInverse`, R/B on a mid-ramp
neutral, as a factor of the source's:

| | old (`pow(1 ± 0.22, ±0.5)`) | new |
|---|---|---|
| +50 (warm) | 1.2506× | **1.8341×** |
| −50 (cool) | 0.7996× | **0.1209×** |

The cooling half is **6.6× stronger** at half travel. Expressed the other way
round (`theNewRangeIsMuchWiderThanTheOldGain`): the old slider's **entire** warm
travel is now reached at **+36**, and its entire cool travel at **−12.6**.

### Speed — three `pow()` out, one `float3x3` in

GPU median, M1 Pro, Release, real a6300 frame `DSC05123`
(`Research/bench/p2-color-macos.json`, re-run for this change):

| metric | ADR-0016 | now | |
|---|---|---|---|
| preview 2048, all 18 sliders | 1.449 ms | **1.388 ms** | **−4.2 %** |
| 24 MP, **tone only** (exposure + WB + curves) | 2.662 ms | **2.619 ms** | **−1.6 %** |
| 24 MP, all 18 sliders | 9.538 ms | **9.829 ms** | +3.1 % |
| 24 MP, all sliders **at 0** *(control)* | 2.097 ms | **2.050 ms** | −2.2 % |
| 24 MP, mixed signs | 10.237 ms | **9.845 ms** | −3.8 % |

The two rows that contain the changed code — `preview/all_sliders` and
`tone_only` — both went **down**, which is the expected sign: three per-pixel
transcendentals were replaced by nine multiply-adds. The `+3.1 %` on
`24MP/all_sliders` is inside the **~6 %** run-to-run spread ADR-0016 measured for
exactly that row (and had to take three runs to establish), and the control row
moved −2.2 % in the same session, so it is not read as a regression. Memory is
unchanged: 2 465 792 B with all sliders, 8 192 B tone-only.

Preview is **608 fps** against a 30 fps bar and 24 MP is **9.8 ms** against an 8 s
export bar, so none of this is close to mattering.

Simulator numbers were refreshed in the same run (`bench-color.sh` does both
destinations). Its **golden figures are bit-identical to the Mac's**, which is
the expected and worth-stating property: the accuracy claim belongs to the
shader, not to the GPU. `is_real_device: false` there, and `gpu_median_ms` in the
Simulator is meaningless (0.07 ms for a 24 MP render) — read `wall_*_ms`.
**Still not measured on an iPhone GPU**, the same gap every ADR in this group
records.

## Known limitations, stated rather than hidden

* **Past about −70 the red channel of a neutral clips to 0.** The Bradford
  adaptation to a declared 2491 K asks for a *negative* red gain on a
  D65 white (at −100: white gain **(−0.373, 0.858, 6.451)**), which the
  composite's final `clamp` pins at 0. That is sRGB's gamut, not a bug in the
  adaptation, and Lightroom's Temp 2000 does the same thing to a daylight frame.
  It is asserted (`cool[o] >= 0` — it clamps, it does not go negative) and
  printed rather than left to be discovered. The consequence is real though: the
  bottom quarter of the cool half is an effect, not a correction.
* **±x is no longer a round trip.** ADR-0016 measured 0.00201 for +60 then −60;
  it is now **0.30619** off the clip. The two halves walk different mired
  distances, so they cannot cancel — by design. The residual is still *filed* in
  the bench JSON (`wb_temperature.plus_60_then_minus_60_residual_off_the_clip`),
  relabelled, as the record that this stopped being true rather than deleted as
  an inconvenient number. What replaces it is
  `adaptationComposesBackToTheIdentity` on the maths and the cast test on the
  pixels.
* **The neutral is 6500 K for every photograph**, because nothing fills
  `referenceColorTemperatureKelvin` — see the EXIF section. Every absolute Kelvin
  number the slider implies ("+100 = 50000 K") is therefore only as true as that
  assumption. The *relative* shift is exact either way.
* **Still nobody has looked at a render.** Same disclosure as ADR-0009/0010/0011/
  0012/0016. What is measured is that the GPU computes the documented formula,
  that the formula matches published colour science, and that it neutralises a
  synthetic cast. Whether a real portrait at −45 looks *right* to a retoucher is
  not measured here.
* **`wbTint` is still the untuned 0.12 gain** from ADR-0012, with no Kelvin and
  no green/magenta axis in u′v′. It was explicitly out of scope.
* **The 50000 K endpoint's accuracy rests on an extrapolation** of Kim et al.,
  measured above. The 2000 K endpoint, which is *inside* the fit's stated range,
  is the less accurate of the two.

## Alternatives rejected

* **Keeping a fixed von Kries diagonal and just raising 0.22.** It would have
  made the slider stronger without making it *mean* anything, and the cool and
  warm halves would still have been wrong relative to each other — a colour
  temperature slider's asymmetry is the whole content of the Planckian locus.
* **Making the slider's Kelvin the output white point** (`+100 ⇒ the picture
  renders as a 2000 K white`) rather than the declared illuminant. Self-consistent
  and it also gives "+ = warmer", but it inverts which half gets the range:
  measured, it would have put **+346 mired** on the warm side and only **−114** on
  the cool side, i.e. it would have made the *cooling* direction weaker than the
  one being replaced — the exact opposite of the reported problem. Its +100 is
  also unusable on its own terms: white gain **(2.476, 0.661, 0.016)**, an R/B
  ratio of 154.
* **Clamping the cool ceiling to 25000 K** to stay inside Kim et al.'s stated
  validity. Measured, the extrapolation to 50000 K is off by 0.0004 in `xy`
  against an order of magnitude more at the 2000 K end we ship anyway. Rejected
  on the number, not on the ambition.
* **Embedding the CIE 1931 colour matching functions and integrating Planck's
  law at render time** to avoid any approximation. 243 hand-transcribed
  constants whose typos would be invisible, to move a gain by 0.5 % at one end
  of one slider. The integral is used as a *scratch control* instead, which is
  where it earns its keep.
* **A per-channel diagonal in sRGB primaries** instead of the Bradford matrix.
  Simpler kernel, and it wants a 48.7× blue gain at the cool endpoint. Bradford
  exists precisely to tame that.
* **Wiring `CIRAWFilter.neutralTemperature` into `MetadataExtractor` now.** Real
  data, measured cost and measured benefit — 40–230 ms per ARW for at most 19
  mired. Filed as S4's, with the seam built. See the EXIF section.
* **Changing `wbTemperature`'s stored range** to Kelvin, or to anything other
  than −100…100 with 0 neutral. Forbidden by `RPCore/EditState.swift`, would
  reinterpret every `edits/*.json` already written, and is unnecessary: the fix
  is in what −100…100 *maps to*.

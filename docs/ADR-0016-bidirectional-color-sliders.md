# ADR-0016 — Bidirectional (−100…100) sliders, scoped to the "Màu" group

Status: accepted — 2026-09-08
Scope: Phase 2 of `docs/PLAN.md` §3. Amends **ADR-0012**'s "one direction each"
decision for the "Màu" group only, and the `Slider` range contract in
`RPCore/EditState.swift` that made it a project-wide rule. The "Da" (ADR-0009),
"Mặt" (ADR-0010) and "Mắt / Răng" (ADR-0011) groups are **unchanged and stay
0…100** — that is half the point of this ADR.

## Context

ADR-0012 shipped 18 colour sliders, each moving in one direction, and said so
plainly: *"There is no darken, no cool, no desaturate. Getting them needs either
a signed `Slider.range` or a paired key, and both are plan-level decisions about
`RPCore`, not changes to this node."* This ADR is that plan-level decision.

The reason to make it now, rather than leave it in the "known limitations" list,
is that a one-directional colour group cannot express the most common real edit
in this app's workflow. A frame off the a6300 — or worse, a JPEG that has already
been through somebody else's preset — arrives *over*-exposed, *over*-saturated,
too warm, too contrasty. The fix is **less** than the file has. With a 0…100
range, the only way to reach "less" is to not have added it in the first place,
which is not available for pixels that arrived that way. Every other slider group
in the project is an *effect* whose absence is the neutral state (smooth the skin
by 0 = don't smooth); the colour group is the only one that also has to *correct*
what is already in the file.

ADR-0012 argued the range was "forced rather than preferred". That argument was
half right, and the half that was wrong is what unblocks this:

> `EditSection.setSlider` **deletes** a key set back to 0, so "absent" and
> "neutral" have to be the same number.

True, and still true. But that constraint requires **default == neutral ==
identity**, and says nothing at all about whether values exist on *both* sides of
it. 0 is still the default, still deleted from the JSON, still a bit-exact
passthrough. What the constraint really forbids is a slider whose neutral is not
its default — a temperature control centred at 50, where an empty `EditState`
would be a non-identity render. That is still forbidden, and there is still none.

## Decision — the range is per (section, parameter), not global

`Slider.range` stays `0...100` and stays the default. A second constant
`Slider.signedRange = -100...100` is added, and one lookup decides which applies:

```swift
Slider.range(for parameter: String, in section: String) -> ClosedRange<Double>
```

with two small tables driving it — `bidirectionalSections` (exactly one member,
`color`) and `oneDirectionalParameters` (the two exceptions below). Everything
that clamps now goes through it: `EditState.setSlider(_:in:to:)`,
`EditSection.init(sliders:in:)`, `ColorSliders`' initialiser and subscript, and
the UI's `SliderParameter.range`.

**Why not simply widen `Slider.range` to −100…100 globally?** Because it would
compile, pass most tests, and be wrong. A "Mặt" reshape slider at −100 would mean
"widen the jaw by the same amount you would have narrowed it" — a value
`FaceReshape` has no meaning for, that no MLS control-point offset was designed
for, and that nothing in ADR-0010 measured. Skin smoothing at −100 would mean
"add noise". The range is a statement about what the *node reading the value* can
do with it, so it belongs next to the node, not in one global constant. A signed
value has to mean something; `SliderRangeScopeTests` (RPCore) and
`SliderPanelLayoutTests` (RPUI) pin every non-colour group at `0...100` so a
future tidy-up cannot quietly widen them.

The tables live in RPCore because that is where the clamp on save happens, but
the two exception strings are RPEngine's `ColorSliders.Key` values and RPCore
cannot import RPEngine. `ColorRenderNodeTests.rangesAreScopedToTheColorGroup`
pins the two lists together so they cannot drift.

## Decision — 16 of the 18 are signed; what each negative half means

Each direction is chosen and written down, the same way ADR-0012 wrote down each
positive one. The `direction` string in the UI names **both** ends on these rows.

| slider | at +100 | at −100 | Vietnamese direction line |
|---|---|---|---|
| `exposure` | brighter, +1 EV (2.0×) | darker, −1 EV (0.5×) | `+ sáng hơn (+1 EV) · − tối hơn (−1 EV)` |
| `contrast` | more contrast (S-curve mixed in) | flatter, toward mid-grey (S-curve extrapolated away from) | `+ tương phản mạnh · − phẳng lại` |
| `highlights` | highlights pulled **down** (recovery) | highlights pushed **up** | `+ kéo vùng sáng xuống · − đẩy lên` |
| `shadows` | shadows pulled **up** (lift) | shadows pushed **down** (deepen) | `+ nâng vùng tối lên · − dìm xuống` |
| `wbTemperature` | warmer (R×1.22, B×0.78) | cooler (the exact channel-wise inverse) | `+ ấm hơn · − lạnh hơn` |
| `wbTint` | toward magenta (G×0.88) | toward green (G×1/0.88) | `+ ngả magenta · − ngả lục` |
| `vibrance` | more saturation, weighted by `1 − sat` | less, same weighting and same skin damping | `+ đậm · − nhạt, mạnh nhất ở màu nhạt` |
| `saturation` | 2× saturation | 0× — grayscale | `+ đậm đều · − nhạt đều (−100 = trắng đen)` |
| `hslRed` … `hslMagenta` (8) | more saturation in that hue band | less, down to grey in that band at −100 | `+ đậm · − nhạt ở dải màu này` |
| `curves` | more of the fixed film curve | **not available — stays 0…100** | `đường cong film rõ hơn (chỉ một chiều)` |
| `autoDodgeBurn` | more local-luminance evening | **not available — stays 0…100** | `đều sáng tối hơn (chỉ một chiều)` |

### The two that stay one-directional

These are argued, not omitted. Both would compile fine with a signed range; both
would be wrong.

* **`curves`** is the *amount* of one fixed film look (`ColorToneCurve` — lifted
  toe, rolled shoulder, cool shadows, warm highlights). The opposite of a look is
  not a look; there is no meaningful "anti-film-curve". And mechanically the
  extrapolation clips: the curve lifts the toe to 0.030 at input 0, so
  `mix(c, curve(c), −1)` maps black to **−0.030**, crushing the bottom 3 % of the
  range to a flat black — exactly the clipping this node's endpoint-preserving
  design exists to avoid. The bidirectional version of "Curves" is a knot editor
  with a draggable curve, which ADR-0012 already deferred; it is not this slider
  with a minus sign.
* **`autoDodgeBurn`** is a **correction**, not an effect. It measures *this
  frame's* local luminance error at two scales and reduces it. Negated, it would
  amplify the very blotchiness it exists to remove — it would find the patches
  that are darker than their surroundings and darken them further. Nobody
  dragging a control labelled "Dodge & Burn tự động" to the left is asking for
  that. If "more local contrast" is ever wanted, it is a different slider with a
  different name and its own analysis, not this one's negative half.

Keeping these two at 0…100 is also why the range lookup needed a
per-**parameter** exception list and not just a per-section flag.

### The sign convention on `highlights` / `shadows` is deliberately not Lightroom's

Positive `highlights` pulls highlights **down** (recovery), which is the opposite
of Lightroom, where +highlights brightens them. ADR-0012 shipped that convention
and values are already written to `edits/*.json` under it. Flipping it now would
silently reinterpret every existing document — a saved `highlights: 60` would
change meaning without the file changing — so the convention is kept and written
down here and in the UI's direction line instead. This is a compatibility
decision, not a claim that ours is the better convention.

## Decision — each negative half is symmetric in the space the operation lives in

The lazy implementation of "bidirectional" is to mirror the positive formula
around 0. For four of these sliders that is measurably wrong, so the negative
half is built in whatever space makes ±x actual inverses:

| slider | naive mirror | what shipped | why |
|---|---|---|---|
| `exposure` | gain `1 + a` → −100 is 0.0× (black) | `exp2(a · stops)` | symmetric in **stops**: −100 is 0.5×, the exact inverse of +100's 2× |
| `wbTemperature`, `wbTint` | gain `1 ± k·a` → cooling by x does not undo warming by x | `pow(1 ± k, a)` | symmetric in **log gain**; endpoints still exactly the 1.22 / 0.78 / 0.88 of ADR-0012, and −x is the exact channel-wise inverse of +x |
| `highlights`, `shadows` | mix weight `a` extrapolating past the gamma → a near-black pixel goes **below 0** | gamma `g` for +, `1/g` for −; `\|a\|` is the mix weight | symmetric in the **exponent's log space**, and stays inside [0,1] by construction, so neither end can crush or clip |
| `saturation` | — | linear in the multiplier, `1 + a` | deliberately *not* exponential: `2^a` would only reach 0.5× at −100 and never actually reach grayscale. Linear lands exactly on 0× |

`contrast` is the one place extrapolation is correct rather than dangerous:
mixing *away* from the smoothstep S flattens toward mid-grey, and because
`S(0)=0` and `S(1)=1` hold for any mix weight, both directions stay
endpoint-preserving and monotone. The slope bottoms out at
`1.5 − 0.5·max S' = 0.75 > 0` at −100, so it cannot fold. Measured below.

## Decision — every `> 0` test became `!= 0`, and every "is anything on" sum became a sum of **absolute** values

This is the subtle part, and it is a correctness bug rather than a tidy-up. The
kernel and `ColorSliders` are full of skip tests, all written when values could
only be positive:

```metal
float active = prm.exposure + prm.contrast + ... + hslTotal;
if (active <= 0.0) { return src; }   // bit-exact passthrough
```

With signed amounts, a perfectly ordinary grade — exposure +50, contrast −50 —
sums to **zero** and takes the passthrough branch, returning the source image on
a picture the user has actively graded. The same trap sits in
`ColorSliders.hslTotal` (renamed `hslAbsoluteTotal`) where `hslRed +50` and
`hslAqua −50` cancel, and in `needsLinearLight`, where `exposure > 0` would skip
the linear-light round trip for a *darkening* exposure.

So: `needsLinearLight` is `!= 0`, the composite's `active` and `hslTotal` are
sums of `fabs(...)`, and each per-step branch is `!= 0` with the sign selecting
the constant inside. `needsDodgeBurnAnalysis` stays `> 0` — correctly, because
`autoDodgeBurn` is one of the two sliders that never goes negative.

Two tests pin this rather than trusting the reading:
`slidersThatCancelInASignedSumStillChangeThePicture` drives exposure +50 /
contrast −50 and `hslRed +50 / hslAqua −50` and asserts the output actually
moved — **max abs change 0.1418** and **0.3023** respectively, not 0.

## Measurements

`Scripts/bench-color.sh` → `Research/bench/p2-color-{macos,ios-simulator}.json`,
scraped from `RPEngineTests/ColorBenchTests`, Release, so the number filed under
`Research/` is the number a test measured. macOS host, Apple M1 Pro, macOS 26.3.

The JSON gained `bidirectional_slider_count` (16), `one_directional_sliders`
(`["curves","autoDodgeBurn"]`), `golden.per_slider_negative_psnr_db`,
`golden.signed_*`, the `behaviour.*_minus_100` entries and
`speed.*.all_sliders_mixed_sign`.

### Golden — the negative halves against the `Double` CPU reference

`ColorReference` was extended the same way the kernel was, and remains a separate
pass over this written specification.

| level | number | bar |
|---|---|---|
| all 18 sliders at 0 | max abs **0** — bit-exact identity, unchanged | must be 0 |
| per slider at **−100**, 16 sliders | **142.96 – 174.60 dB** (min `wbTemperature`, max `hslBlue`), plus `hslAqua` / `hslGreen` exactly infinite | 45 dB |
| per slider at **+100**, 18 sliders | **143.19 – 168.58 dB** — unchanged from ADR-0012 where the formula did not change | 45 dB |
| composite, mixed signs | **138.05 dB** | 45 dB |
| whole node end-to-end, all positive | **136.58 dB**, max abs 8.3e-7 | 45 dB |
| whole node end-to-end, **mixed signs** | **139.33 dB**, max abs 5.4e-7 | 45 dB |
| curve LUT vs the exact curve | 3.8e-6 | 1e-5 |

The two infinite figures are the same `hslAqua` / `hslGreen` case ADR-0012 filed:
those bands only touch flat patches on this fixture and float32 and `Double` round
identically there. Filed as the string `"inf"`, not an invented number.

**The identity at 0 is the load-bearing one.** Widening a range is exactly the
change that could break "empty `EditState` → bit-exact passthrough", so
`all_sliders_zero_max_abs_diff` staying at a hard **0** is the number that says
the graph contract survived.

### Behaviour — the negative halves act on the right pixels, in the right direction

A PSNR cannot say this: a −100 Highlights that computed the documented formula
on the *shadow* window would score just as well.

| claim | measured |
|---|---|
| Highlights −100 pushes the bright end **up** | ramp 0.75–0.95: **+0.0360** luma (vs −0.0483 at +100) |
| …and still leaves the dark end alone | ramp 0.05–0.25: **0.0** |
| Shadows −100 **deepens** the dark end | ramp 0.05–0.25: **−0.0755** (vs +0.1059 at +100) |
| …and still leaves the bright end alone | ramp 0.75–0.95: **0.0** |
| …without crushing to black | darkest pixel **0.00757 > 0**, **0** channels clipped |
| Exposure −100 is exactly −1 EV | linear 0.21540 → 0.10770, ratio **0.49999995** |
| Saturation −100 is true grayscale | worst residual chroma **0.0** |
| …and the 8 HSL bands at −100 partition to the same thing | max abs diff vs Saturation −100 **3.0e-8** |
| Contrast −100 flattens the ramp | spread 0.6478 → **0.5596** (and 0.7360 at +100) |
| …and stays monotone | minimum slope **0.750** |
| WB ±60 round-trips | max abs residual **0.00201** off the clip; 0.0347 including 2880 channels that clipped at the fixture's saturated patches |
| Cancelling sliders still change the picture | **0.1418** (exposure/contrast), **0.3023** (HSL) |
| Curves / Auto D&B refuse a negative value | clamped to 0 by `Slider.range(for:in:)` |

The WB round-trip residual is the honest one to read: 0.002 is float32 through
two linear-light round trips and a luminance renormalisation, not an exact
inverse, and the 0.035 figure is what happens when a channel saturates at 1.0 on
the way out and cannot come back. Both are filed rather than the smaller one
alone.

### Speed — real a6300 frame `DSC05123` (4000×6000), Release, GPU median, M1 Pro

Bidirectional work is not free: three `pow()` per pixel replaced three
multiply-adds in the white-balance block. **Three consecutive runs** were taken
because the first single-run reading (+14 % at 24 MP) was inside the noise and
would have been wrong to report:

| metric | ADR-0012 (HEAD) | run 1 | run 2 | run 3 (filed) | vs baseline |
|---|---|---|---|---|---|
| 24 MP, all 18 sliders | 9.197 ms | 10.088 | 9.966 | **9.538** | **+8 %** (median of runs) |
| 24 MP, all sliders **at 0** *(control)* | 2.078 ms | 2.075 | 2.112 | **2.097** | **+1 %** |
| 24 MP, tone only | 2.548 ms | 2.698 | 2.668 | **2.662** | +4.6 % |
| preview 2048, all 18 sliders | 1.340 ms | 1.380 | 1.450 | **1.449** | +6 % |
| 24 MP, all sliders **mixed sign** | — | 10.000 | 10.311 | **10.237** | ≈ same as all-positive |

**Run-to-run spread on `all_sliders` is ~6 %**, which is why the control row
matters: `all_sliders_at_zero` exercises the passthrough branch, whose only
change is the `fabs()` sum, and it moved **+1 %** — i.e. the machine is not
drifting, and the ~8 % on the graded path is a real cost attributable to the
`pow()`s rather than measurement noise. `tone_only` (+4.6 %, consistent across
all three runs) contains exposure and WB and no HSL/D&B, which is where the
`pow()`s are, and corroborates it.

Against the plan bars this is irrelevant: **9.54 ms at 24 MP against an 8 s
export bar**, and 1.45 ms GPU / 1.72 ms wall at 2048 px = **581 fps against a
30 fps preview bar** (`all_sliders_fps` in the JSON is wall-derived, the same
basis ADR-0012 quoted; the table above is GPU median on both sides so the
comparison with the baseline is like-for-like). Mixed signs cost the same as
all-positive, which is the point — there is no slow path for negative values.

Memory is unchanged: 2 461 696 bytes with all sliders, 4 096 tone-only.

The iOS Simulator file was re-run against the same build (`iPhone 17`, iOS 26.3.1)
so both files carry the new schema. Its **golden numbers are bit-identical to the
Mac's** — 0 at all-sliders-zero, 142.96–174.60 dB per negative slider, 138.05 dB
composite, 139.33 dB signed end-to-end — which is expected and worth stating: the
accuracy claim is a property of the shader, not of the GPU it ran on. Wall-clock
there is 11.6 ms at 24 MP / 4.6 ms at preview, and `gpu_median_ms` is meaningless
in the Simulator (`is_real_device: false`).

**Available optimisation, deliberately not taken here.** The three `pow()` calls
have *uniform* arguments — `pow(1.22, wbTemperature)` is the same value for every
pixel in the frame — so they could be computed once on the CPU and passed in as a
`float3` gain. That is a ~0.8 ms/frame win at 24 MP, but it changes `ColorParams`'
meaning (the field would carry a gain, not an amount) and the struct layout that
`ColorRenderNodeTests` pins, and `ColorReference` would have to mirror it. With
three orders of magnitude of headroom against the export bar, that churn is not
worth it inside this change. Filed here so it is a known move, not a discovery.

## UI

`SliderParameter` gained a `range`, read from `RPCore.Slider.range(for:in:)`
rather than written in the panel, so the control cannot offer a value the
document would clamp away. `RPSliderRow` / `RPSliderTrack` draw the neutral 0 in
the **middle** of the track for a bidirectional row and fill from the centre
outward; the numeric readout carries an explicit `+` on those rows only, so a
glance says which half the thumb is on. Accessibility value reads
`"+40, từ -100 đến 100"` instead of `"40 trên 100"`, and the increment/decrement
action clamps to `range.lowerBound` rather than a hardcoded 0.

`EditorModelTests.aNegativeValueSurvivesInTheMàuGroupAndIsClampedAwayInDa` drives
the real model end-to-end: −40 written to `color.exposure` survives to disk, −40
written to a "Da" slider clamps to 0 and the key is deleted.

## Known limitations, stated rather than hidden

* **Nobody has looked at a −100 render.** The negative halves carry the same
  untuned constants as the positive halves, argued from what the operation
  physically is. Same disclosure ADR-0009/0010/0011/0012 all make. The golden
  proves the GPU computes the documented formula; it does not prove the formula
  is pretty.
* **The reference cannot catch a wrong specification.** If the −100 contrast
  flattening is ugly, `ColorReference` and the kernel agree and both are ugly.
* **WB ±x is not a bit-exact round trip** (0.002 off the clip, worse where a
  channel saturates). It is an inverse in the gain, not in the clipped output.
* **`curves` and `autoDodgeBurn` have no negative half**, by the argument above.
  A user who wants "less film look than the file already has" cannot get it here;
  that needs the deferred knot editor.
* **Only the "Màu" group is signed.** "Da", "Mặt" and "Mắt / Răng" keep their
  one-directional disclosure from ADR-0009/0010/0011 unchanged.
* **Not measured on an iPhone GPU.** The macOS numbers above are M1 Pro; the
  iOS-simulator figures in the JSON are not GPU times (`is_real_device` says
  which is which — read `wall_*_ms` in the Simulator).

## Alternatives rejected

* **Widen `Slider.range` to −100…100 globally.** One-line change, compiles,
  and gives −100 a meaning in `FaceReshape` and `SkinSliders` that nothing
  implements or measured. Rejected for the per-(section, parameter) lookup.
* **Paired keys** (`exposureUp` / `exposureDown`, ADR-0012's other suggestion).
  Doubles the key count to 36, makes "both set" a state that has to be defined
  and clamped, and doubles the preset surface — all to avoid a minus sign.
* **A slider centred at 50** with 0…100 kept. Breaks "absent == neutral": an
  empty `EditState` would render non-identity and the graph could no longer skip
  the node. Still forbidden.
* **Mirroring the positive formula around 0** for every slider. Measurably wrong
  for exposure (−100 = black), WB (±x does not round-trip) and highlights/shadows
  (a near-black pixel extrapolates below 0). See the symmetry table above.
* **Exponential saturation** (`2^a`), for symmetry with exposure. Never actually
  reaches grayscale at −100 (0.5×), and "desaturate fully" is the single most
  useful thing the negative half of that slider does.
* **Flipping `highlights`/`shadows` to Lightroom's sign convention** while
  touching them anyway. Would silently reinterpret every value already in
  `edits/*.json`. Rejected in favour of writing the convention down.
* **Signed sums for the "is anything on" skip test.** Returns the source image on
  a genuinely graded picture whenever sliders cancel. This was the actual bug the
  `fabs()` change fixes.

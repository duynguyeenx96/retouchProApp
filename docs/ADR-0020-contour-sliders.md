# ADR-0020 — "Tạo khối" (Contour): landmark-anchored lobes gating the dodge/burn LUT

Status: accepted — 2026-09-15
Scope: Phase 6 §6.2, "Tạo khối". **Engine only this round**: three sliders, the
lobe builder, one extra branch inside the colour composite, and the numbers.
There is no UI — nothing in RPUI exposes the three keys, `RailLayout.swift` is
untouched — and `RPEngineFeatureFlags.contourSliders` ships **off**.

> **Addendum 2026-09-21 — the UI exists now; the flag does not move.** The two
> sentences above about "no UI" were true of the engine round and are superseded
> by the "UI (2026-09-21)" section at the end of this file. Everything else here
> — every decision, constant and measured number — is unchanged, because the
> wiring added no engine code at all.

## Context

docs/PLAN.md §6.2 files "Tạo khối" as the cheap item of Phase 6 (~0.5 tuần) and
fixes its shape in advance, including the confirmation it wanted from whoever
built it:

> Xác nhận đúng hướng đã đoán ở HANDOFF: `ColorRenderNode` hiện tại của Auto D&B
> **đã global, chưa mask** (đọc code xác nhận). Chỉ cần thêm: vài mask
> ellipse/radial mềm neo tại index landmark 478 điểm sẵn có … rồi nhân mask đó
> vào đúng công thức dodge/burn LUT đã có. Không landmark mới, không model mới,
> không kernel Metal họ mới.

**The guess was right.** `ColorRenderNode`'s Auto D&B step is
`mix(c, pow(c, γ), w)` with `γ = kRPDodgeGamma` / `kRPBurnGamma` and `w` from the
frame's own two-scale local luminance error — computed over the whole frame, with
no mask anywhere and no read of `request.faces` (ADR-0012 says so as a decision,
not as an accident). So a contour is that exact step with a *different source for
`w` and for the direction*. Nothing else about the group is new.

This ADR records what the plan did not settle: where the lobes sit, how they are
uploaded, and why the group is inside an existing node instead of beside it.

## Decision

### 1. A contour is the existing dodge/burn step with a mask supplying `w`

`rp_color_composite` step 1b, immediately after Auto D&B and before the grade:

```metal
if (prm.contourLobeCount > 0u) {
    float m = rp_contour_mask(contourLobes, prm.contourLobeCount, gid);
    float w = fabs(m);
    if (w > 0.0) {
        float g = (m > 0.0) ? kRPDodgeGamma : kRPBurnGamma;
        c = mix(c, pow(max(c, 0.0), float3(g)), w);
    }
}
```

Same two gammas, same endpoint-preserving mix, same constants — the difference
from the two lines above it is only that `w` and the sign come from geometry
instead of from the frame's local luminance error. That is why §6.2 needed **no
new kernel family**, and it is why this group inherits ADR-0012's already
measured LUT step instead of re-proving it.

It sits *after* Auto D&B and *before* exposure/WB for the same reason Auto D&B
does: both are modelling corrections of the incoming picture, and everything from
step 2 on is a global grade of the corrected one.

### 2. Eleven soft ellipses per face, every length a fraction of `faceWidth`

`ContourMask.lobes(faces:sliders:)` builds, per face:

| Slider | Lobes | Anchors (all already computed by `FaceReshape`) |
|---|---|---|
| **Gò má** `contourCheek` | 4 | highlight at `tEyeLine + 0.62·(tCheekLine − tEyeLine)`, shadow at `tCheekLine + 0.34·(tMouthLine − tCheekLine)`, one pair per side, each side offset by *its own* `u(cheek extreme)` |
| **Sống mũi** `contourNose` | 1 | the `tNasion → tNoseTip` span, on the midline, along `frame.down` |
| **Hàm** `contourJaw` | 6 | `FaceMesh.faceOval` between the cheek extreme and the chin, three segments per side, pushed `0.03·faceWidth` inside the oval |

Every half-extent, offset and inset is a fraction of `faceWidth` (or of a `t`
span, which is itself derived from the mesh), never a pixel constant. That is the
property that makes the three numbers **transferable through a preset**
(docs/PLAN.md §2), and it is measured rather than asserted:
`lobesScaleWithSliderAndFaceWidth` doubles the face and checks every half-extent
doubles to within 1e-3 while every strength is unchanged.

Using each side's *own* `u(cheek extreme)` rather than a shared half-width is
ADR-0010's rule for the same reason: on a three-quarter view the near and far
cheek are not the same distance from the midline. Floored at `0.15·faceWidth` so
a near-profile face cannot collapse both lobes onto the midline.

### 3. Falloff is `1 − smoothstep(0, 1, r)`, the sum is ordered, the clamp is last

```
a = dot(p − centre, axisU) / halfExtent.x
b = dot(p − centre, perp(axisU)) / halfExtent.y
r² = a² + b²;  outside r² ≥ 1 the lobe contributes exactly nothing
m += strength · (1 − r²(3 − 2r))          // summed in buffer order
mask = clamp(m, −1, 1)                     // once, at the end
```

C¹ at both ends, so two overlapping lobes blend instead of meeting at a crease
and a lobe's rim never shows as an edge. Three properties are load-bearing and
each is tested:

* **Outside a lobe the contribution is exactly 0**, not merely small — the `r² ≥
  1` early-out, not a tail that decays. `w` is then exactly 0 and `mix(c, …, 0)`
  returns `c` bit for bit, which is what makes "the forehead centre moved by
  exactly 0" a *measurement* rather than a tolerance.
* **Summation order is the buffer's order** in both languages, because a
  different order is a different float32 sum.
* **One clamp, at the end.** Clamping per lobe would make the result depend on
  the order in a way the reference could not reproduce.

`ContourMask.value(at:lobes:)` is the `Double` CPU twin and does the same three
things in the same order. It reads the **`Float` fields the GPU was handed**, not
the `CGFloat` geometry they came from, so the golden comparison measures the
kernel and not the float conversion — the arrangement `ColorRenderNode.curveTable`
already uses for the curve LUT.

### 4. The mask is analytic, not rasterised — this is not a `MaskRasteriser` case

ADR-0009's `MaskRasteriser` / `RenderMaskKind` path is right for a mask that comes
out of a model (BiSeNet parsing) or out of a finger (ADR-0019's brush): the
payload genuinely is a bitmap. Eleven ellipses are not. Rasterising them to an
`r8Unorm` full-frame texture would cost ~24 MB of upload at export size to store
what three floats per lobe already say exactly, and would quantise a mask that is
otherwise exact. So the lobes go up as a **4 kB buffer** (`ContourMask.maxLobes ×
32 B`, allocated once for the life of the node, `.storageModeShared`, memcpy
before the encoder is made) and the kernel evaluates the ellipse per pixel.

It is still the same *gating* idea — "multiply a mask into the effect's weight" —
applied to a Color-stage effect; only the representation differs.

The cap is a **cost** ceiling, not an allocation one: the kernel loops over every
lobe for every pixel. 128 lobes ≈ 11 faces, and a frame with twelve faces in it is
not a portrait retouch. Faces are admitted whole or not at all
(`severalFacesAndTheCap` checks `count % lobesPerFace == 0`), because a
half-drawn face would be a visible asymmetry.

### 5. The three keys live in `EditState.SectionKey.face`, and RPCore needed no change

`contourCheek` / `contourNose` / `contourJaw`, 0…100, default 0, in the **face**
section next to the reshape sliders — because contour is a per-face effect whose
every length is a fraction of `faceWidth`, which is exactly what makes the "Mặt"
section preset-transferable.

Not in the `color` section, even though the kernel that applies them is the
colour composite: that section is bidirectional (−100…100, ADR-0016) and none of
these three has a meaningful negative half. "Negative Gò má" is not "shadow where
the highlight was"; it is nothing.

`Slider.range(for:in:)` already returns `0...100` for any parameter of a
non-bidirectional section, so **`EditState.swift` and `Slider.swift` are
untouched** — the same outcome ADR-0019 reached for the brush, and deliberate:
those two files are the ones every group routes through. The `contour…` prefix
keeps the keys from colliding with `FaceSliders.Key` (`cheekbone`, `jaw`, `chin`),
which lives in the same section and means something else entirely;
`slidersAreZeroToOneHundredInTheFaceSection` checks `FaceSliders(state)` is still
identity after all three are written.

### 6. Amounts ride in `strength`, not in `ColorParams`

Each lobe belongs to exactly one of the three regions, so its region's amount is
already baked into its signed `strength` (`±amount × peakStrength`). The kernel
therefore learns nothing about the three sliders beyond `contourLobeCount`, and
`ColorParams` grew by one `uint` — into the 4 bytes of tail padding it already
had, so **the stride the colour group pinned at 96 is unchanged**
(`ColorRenderNodeTests.parameterStructsMatchShaderLayout` still passes untouched).

The sign of `strength` is the direction, and it is the only thing that makes one
kernel step do both jobs: `+` dodges (cheekbone, nose bridge), `−` burns (cheek
hollow, jaw).

`ContourLobe`'s stride is pinned at 32 with an explicit `pad: Float` rather than
relying on either compiler's tail padding — it is an *array* in the shader, so a
stride the two sides disagreed about would make every lobe after the first read a
garbage centre. `lobeStructMatchesShaderLayout` pins the number; the golden PSNR
proves the number is the right one, exactly the pairing ADR-0019 used for
`ManualMaskStamp`.

### 7. This amends ADR-0012's "no `FaceRenderInput`" — narrowly, and it says so

ADR-0012 decided `ColorRenderNode.isActive(for:)` ignores `request.faces`
entirely, so the node grades a landscape, a product shot, a back-of-head. Contour
is per-face, so that sentence is no longer true of the whole node. The amendment
is deliberately as small as it can be:

* `isActive` still returns `true` for any non-identity colour slider **without
  consulting `faces`**; the face list is only reached when every colour slider is
  0 and the contour group has something to draw. `noFaceIsStillActive` — ADR-0012's
  own regression test — is untouched and still passes.
* Nothing here reads a *parsing* mask (`FaceRenderInput.masks`), so contour works
  on a face BiSeNet failed on, and the node still needs no mask dependency.
* With the flag off or the three amounts at 0, the face list is never touched at
  all.

The second half of ADR-0012's decision — "no shared kernel flag" — is preserved
exactly: `contourSliders` is one bit that borrows nothing, and
`disableContourRenderGraph()` clears **only** that bit, leaving `colorSliders`
alone even though `enableContourRenderGraph()` set it. That asymmetry is the
lesson `disableSkinRenderGraph()` records: `colorSliders` is shared with the
eighteen colour sliders, so clearing it from here would let the contour group
switch the colour group off behind its back.

### 8. The flag is read per render, not in `init`

`contourSliders` is checked inside `ColorRenderNode.contourLobes(for:)`, not in
the node's initialiser. Contour is an addition to a node that already **ships**,
so turning the flag off has to leave the "Color" group constructible and
bit-exact what it was — not throw `RPEngineFeatureDisabled` at a caller who only
wanted Exposure. That is the opposite of ADR-0019's brush, where the flag gates
construction because the whole producer is new; the difference is which of the
two situations you are in, and it is worth naming so the next group picks the
right one.

No `RenderGraph.standard` change: `ColorRenderNode` is already registered under
`colorSliders`, and contour rides inside it. The node-registration point and its
ordering guarantees are untouched.

## Measurements

`Scripts/bench-contour.sh` → `Research/bench/p6-contour-{macos,ios-simulator}.json`,
scraped from `RPEngineTests/ContourBenchTests`, Release — so the number filed
under `Research/` is always the number a test measured (docs/PLAN.md §5).

Fixture: a synthetic 384×448 skin-tone field with a gentle vertical ramp (no
pixel at 0 or 1, where every gamma is a fixed point and a mask error would be
invisible) plus a `SyntheticFaceMesh` at `faceWidth = 200 px`. The picture is
featureless on purpose: contour is a mask, so what has to be measured is *where*
the effect lands, and a textured photograph would make every per-region mean
depend on the texture instead. The probe discs are cut from the lobes the
production code builds, never from hand-written coordinates — a hand-written
probe would keep measuring the old geometry after a constant moved.

### Golden — GPU vs the `Double` CPU reference (bar: the plan's 45 dB)

| Case | PSNR | max abs diff |
|---|---|---|
| All three at 100 | **162.98 dB** | 8.94e-08 |
| Gò má 100 alone | 164.84 dB | — |
| Sống mũi 100 alone | 175.77 dB | — |
| Hàm 100 alone | 167.74 dB | — |
| All three at 40 | 163.57 dB | — |
| All three at 100 **under a full 18-slider grade incl. Auto D&B** | 136.78 dB | 6.56e-07 |

The last row is the one that matters most: the contour step and the global
dodge/burn step run on the same pixels, so a mix-up between the two would show
there and nowhere else.

### Default off — all three are exactly 0, not approximately

| Claim | max abs diff vs the source |
|---|---|
| `contourSliders` off, all three at 100 | **0** |
| flag on, all three at 0 | **0** |
| flag on, all three at 100, no face in the request | **0** |

And with the flag off plus a colour grade on top, the graded picture is bit-exact
the one the colour group shipped before this group existed
(`flagOffIsBitExactTheOldRender`).

### Selectivity — mean signed luminance change per zone, worst |Δ| per control

| Slider at 100 | its own zone | forehead centre | frame corner | the other zones |
|---|---|---|---|---|
| Gò má | highlight **+0.0364**, hollow **−0.0405** | **0** | **0** | nose **0** |
| Sống mũi | bridge **+0.0324** | **0** | — | cheek **0**, hollow **0** |
| Hàm | jaw band **−0.0382** | **0** | **0** | nose **0** |

"Exactly 0" is available, rather than a tolerance, because of decision 3. This is
ADR-0011's shape ("changes the teeth region, changes the gums region by exactly
0") restated for a face's contour zones, and it is the claim a PSNR **cannot**
make: a mask computing the documented falloff in the wrong place scores just as
well on PSNR.

### Locality — §6.2's "theo mesh, không toàn khung", as a number

One face, all three sliders at 100, in a 384×448 head-and-shoulders crop:

| threshold | fraction of frame |
|---|---|
| \|mask\| > 0 | **0.1038** |
| > 0.10 | 0.0585 |
| > 0.25 | 0.0334 |
| > 0.50 | 0.0072 |

A contour that covered the frame would be Auto D&B under another name.

### Speed — real a6300 frame `DSC05123`, Release, macOS host (M1 Pro)

Wall-clock median, one face, all three amounts at 100 = 11 lobes:

| case | 2048 px preview | 24 MP (4000×6000) |
|---|---|---|
| everything at 0 | 0.57 ms | 2.30 ms |
| contour only | 1.20 ms | 5.33 ms |
| colour grade only (18 sliders) | 2.06 ms | 9.53 ms |
| contour + colour grade | 2.80 ms | 13.47 ms |
| **marginal cost of the eleven lobes** | **0.75 ms** | **3.94 ms** |

The separate off/on pair exists so that marginal number is visible rather than
buried in the colour grade's cost. Both are far inside the plan's bars (30 fps
preview, 8 s export). The iOS-Simulator file records the same work on the host
GPU: 1.90 ms marginal at preview, 3.27 ms at 24 MP.

Node memory grew by exactly the 4 kB lobe buffer and by nothing else
(`node_bytes` 2 461 696 → 2 465 792 with the analysis pyramid live), which is why
`ColorRenderNodeTests.analysisIsAllocatedLazily` now compares against a *fixed*
baseline of LUT + lobe buffer instead of the LUT alone.

### The colour group did not move

`Scripts/bench-color.sh` re-run on both destinations after this change:
`composite_psnr_db` 138.045, `end_to_end_psnr_db` 136.584,
`signed_end_to_end_psnr_db` 139.328, and all three max-abs-diff figures 0.0 —
**identical to the values committed before this group existed**, digit for digit,
on macOS and in the Simulator. The only field that moved in `p2-color-*.json` is
`node_bytes`, by exactly 4096.

## Known limitations, stated rather than hidden

* **Every geometric constant is untuned.** The positions, half-extents, tilts and
  the four peak strengths are argued from where the anatomy is (a cheekbone
  highlight sits under the eye and outboard of the nose; a jaw shadow sits just
  inside the oval) and have **not** been judged by a retoucher's eye. The same
  disclosure ADR-0010 / ADR-0011 / ADR-0012 make. What is measured is that the GPU
  computes the documented mask, that the mask covers the region its slider is
  named after, and that it changes an unrelated region by exactly zero.
* **No iPhone number.** The ms/frame above is a Mac figure; the Simulator figure
  in the JSON is also the host GPU's, so it is not a second machine. Required
  before the flag is turned on, per the project's rule — and it is why
  `contourSliders` ships off. Every earlier node in this project (ADR-0007 …
  ADR-0019) carries the same gap.
* **The mask is anatomical, not photometric.** It does not know where the light
  already is, so a face lit hard from one side gets the same symmetric pair of
  cheek lobes as a flat-lit one. Making the strength respond to the existing
  shading is a different feature (and would start to look like Auto D&B again).
* **Cost is linear in lobes × pixels.** Eleven lobes per face, every pixel, no
  bounding-box early-out. At the 128-lobe cap that is ~12× the measured marginal
  cost; the cap is what keeps it bounded, not a spatial structure.
* ~~**No UI.** Three keys exist in `EditState` that no panel writes yet.~~
  **Closed 2026-09-21** — see "UI (2026-09-21)" below. The limitation that
  remains is the one above it: no iPhone number, so the flag is still off.

## Alternatives rejected

* **A new render node.** It would duplicate the LUT step, and then two nodes would
  own the same two gamma constants.
* **Rasterising the lobes into an `r8Unorm` mask** and going through
  `MaskRasteriser` — decision 4: ~24 MB of upload at export size to say what 352
  bytes already say exactly, plus quantisation of an otherwise exact mask.
* **Putting the three keys in the `color` section.** Decision 5: that section is
  bidirectional and these have no negative half, and a per-face effect belongs in
  the per-face section for preset transfer.
* **Passing the three amounts to the kernel as scalars.** Decision 6: a lobe
  belongs to exactly one region, so the amount is already in its `strength`, and
  three more floats in `ColorParams` would have pushed the pinned stride.

## UI (2026-09-21) — a wired panel in front of a flag that is still off

No engine file changed for this: it is `SliderPanelLayout` + one rail entry.

### A panel of its own, the third over `EditState.SectionKey.face`

`SliderPanelLayout.PanelKey.contour` — "Tạo khối", three rows: **Gò má**
(`contourCheek`), **Sống mũi** (`contourNose`), **Hàm** (`contourJaw`), keys read
from `ContourSliders.Key.all` and ranges from `RPCore.Slider`, exactly as every
other panel builds itself.

Not three more rows at the bottom of "Hình dáng mặt", even though decision 5 put
the keys in that namespace: they share the namespace because both tools are
per-face and measured in `faceWidth` (which is what makes them preset-transferable),
but *shading* a cheekbone and *narrowing* one are different tools, and a panel
that answers one question with another tool's controls is the 2026-09-18
"Răng opens an eye panel" bug. `storageKey` already existed for exactly this —
the split is UI-only, nothing on disk moved, and `sections(touchedBy:)` filters
by parameter so a preset carrying only `contourCheek` summarises as "Tạo khối".

### The flag is reported, not obeyed by locking

`SliderSectionDescriptor.gatedBy` (new, one case: `PanelFeatureGate.contourSliders`)
is read per render by `GroupAvailability.blockedReason`, **before** the "no face"
check — a build with the effect off cannot be fixed by importing another photo.
The rail item is therefore *not* locked: it opens the panel, the three rows draw
with their real keys, and the group is disabled under one line —
"Tạo khối đang tắt trong bản dựng này — chưa đo tốc độ trên iPhone thật."

The two alternatives were both already in the codebase and both are wrong here:

* **Lock the rail item**, as "Cọ mask" does via `RailPresentation.isAvailable`.
  That is for an item with *nothing* behind it; here it would hide a working
  panel and trip `RailLayoutTests.noWorkingSectionIsOrphaned`, which exists to
  catch precisely a working panel with no affordance.
* **Mark the panel locked**, as Trang điểm / Tóc are. That says "these sliders do
  not exist", which is false — they exist, they are measured, and the honest
  sentence is about this build rather than about the phase.

`contourSliders` is **not** flipped by this round. Turning it on is still a
product decision waiting on an iPhone number (see "Known limitations"), and it is
now a one-bit change with no UI work behind it.

### No detection notice

`notifiesFromNodeNamed` stays `nil`. Contour is landmark geometry: there is
nothing it can fail to detect beyond the face itself, which the panel already
reports through `needsFace`.

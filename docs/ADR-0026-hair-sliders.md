# ADR-0026 — The "Tóc" (hair) slider group and `HairRenderNode`

Status: proposed — 2026-09-28 (cloud session; **not built, not run, not measured**)
Scope: docs/PLAN.md Phase 5, *"hair: bóng, tối/sáng, đổi màu"*. Flyaway hair
("Tóc con bay", LaMa inpainting) stays in Phase 6 and is not here.

## Context

Everything the group needs already exists: RPVision's BiSeNet parsing produces
`FaceParsingGroup.hair`, the app bridge (`App/FaceAnalysisRenderBridge.groups`)
already maps it to `RenderMaskKind.hair`, and "Đầu" (ADR-0022) already asks for
that mask. So this is a render node and nothing else — no model, no new
detection, no App-target change. The providers learn to fetch the mask through
`RenderMaskRequirements.forEnabledGroups()` when the new flag is on.

## Decision — five one-directional sliders

`EditState.SectionKey.hair`, keys from `HairSliders.Key`:

| key | label (UI branch) | what it does at 100 |
|---|---|---|
| `gloss` | Bóng tóc | local contrast ×1.6 against a `0.08 × faceWidth` box blur, plus a lift toward white of up to 25 % on pixels brighter than that blur |
| `lighten` | Sáng tóc | luma exponent 0.65 |
| `darken` | Tối tóc | luma exponent 1.8 |
| `dye` | Nhuộm màu | 85 % of the chroma replaced by the tone's, luma kept |
| `dyeTone` | Tông màu | *modifier* — position on a 5-colour palette (ash brown → copper → burgundy → violet → ash grey-blue); does nothing while `dye` is 0 |

**"Tối / sáng" is two sliders, not one signed slider.** Only `color` is signed
(ADR-0016); making `hair` signed is an RPCore format decision (clamping, preset
scaling, `isDefault`), not a side effect of a render node. Two amounts keep
"0 = untouched" trivially true, and they compose: their exponents multiply,
interpolated in log space.

**The tone is a modifier** because a hue has no neutral value; a colour slider
whose 0 is a colour would break the 0-is-identity rule every group keeps. This
is the "Giữ texture" arrangement of the Da group.

## Decision — lightness on luma, not per channel

`c' = c · min(y^e / y, 4)` with `y` the Rec.709 luma. Per-channel gamma shifts
the hue (a darkened brown drifts red, a lightened one yellow) — the same defect
that made the removed "Tự động" D&B turn portraits yellow (docs/PLAN.md §6.5,
2026-09-28). The ratio cap stops near-black noise with a little chroma from
turning into coloured speckle at "Sáng tóc" 100.

## Decision — dye at constant luma

`dyed = tint · y`, with `tint` normalised to luma 1 on the CPU
(`HairSliders.dyeTint`) and handed to the shader, so the palette has one
definition a test can read. Consequence, stated rather than hidden: on
near-black hair the dye is nearly invisible. That is also what real dye without
bleach does; a "lift then tint" mode would be a separate decision.

## Decision — the node runs before the warp (`RenderStage.hair = 250`)

The parsing mask is computed on the unwarped frame, and "Đầu" moves the hairline
by tens of pixels. A colour change applied before the warp travels with the hair;
applied after, it would be off by exactly the displacement. docs/PLAN.md §2 had
no hair stage; the new one sits between "Da" (200) and "Mặt" (300).

## Decision — structure copied from `EyesTeethRenderNode`

One `MaskRasteriser` (`rp_skin_mask`), one lazily allocated guided-filter layer
(ε = 1e6, i.e. a double box blur) that only "Bóng tóc" needs, one composite
kernel `rp_hair_composite` in `HairShaders.metal`, appended **last** to
`MetalContext.shaderSources` (still one compile per process). No gate masks, like
"Mắt / Răng": the hair mask is the whole selection.

`detectionNotice(for:)` returns **"Không phát hiện được tóc."** when a hair slider
is non-zero, there is at least one face, and no face carries a hair mask with
mean coverage above 0.1 %. Silent with the flag off and at slider 0.

## Flags

`RPEngineFeatureFlags.hairSliders`, **default off**, plus the shared
`guidedFilter` kernel flag (`enableHairRenderGraph()` sets both). The kernel
flag now has three groups on it, so every disable helper that clears it checks
all three group flags first (`HairSlidersTests.sharedKernelFlagSurvivesOtherGroups`).

## What is measured, and what is not

Written in a Linux cloud session with no Xcode: **nothing here has been compiled
or run.** The tests exist and say what they will measure:

* `golden` — `HairRenderNodeTests.compositeMatchesReference`: GPU composite vs
  `HairReference` (`Double`), fed the node's own mask and blur, six slider
  settings, bar 45 dB.
* `identity` — all sliders 0 (with a tone set) is bit-exact; pixels outside the
  mask are bit-exact under every slider.
* `selectivity` — on the synthetic fixture: "Sáng tóc" raises mean hair luma by
  > 30 %, "Tối tóc" lowers it by > 20 %, the dye keeps it within 0.01 and moves
  red/blue toward copper, gloss lifts the bright half more than the dark half.

Not measured, and blocking the flag: **speed** on a Mac and a real iPhone
(`Research/bench/p5-hair-*.json`, the ADR-0011 bench pattern), and **a human
looking at real a6300 renders** — every constant above is argued, none is tuned.

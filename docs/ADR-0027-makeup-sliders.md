# ADR-0027 — The "Trang điểm" (makeup) slider group and `MakeupRenderNode`

Status: proposed — 2026-09-28 (cloud session; **not built, not run, not measured**)
Scope: docs/PLAN.md Phase 5, *"Makeup sliders"*. Builds on ADR-0026 (same
branch stack) for the before-the-warp placement and the luma-ratio rule.

## Context

The locked "Trang điểm" panel has listed six planned names since Phase 2:
*Nền, Má hồng, Son môi, Phấn mắt, Kẻ mắt, Lông mày*. A slider needs a region to
act on, and the regions available today are the BiSeNet classes plus the
478-point mesh:

| planned | region source | v1? |
|---|---|---|
| Son môi | BiSeNet `lips` | **yes** |
| Lông mày | BiSeNet `brows` | **yes** |
| Má hồng | mesh-anchored ellipses (the "Tạo khối" lobes) × BiSeNet `skin` | **yes** |
| Nền | — it is "Đều màu da" of the Da group under a makeup name | no — would duplicate a working slider |
| Phấn mắt, Kẻ mắt | need an eyelid / lash-line band; the `eyes` class is the opening, not the lid | no — needs a new mask derived from the mesh's lid contour, a separate piece of geometry work |

## Decision — four sliders, one modifier

`EditState.SectionKey.makeup`, keys from `MakeupSliders.Key`, all 0–100, 0 = untouched:

| key | label (UI branch) | what it does at 100 |
|---|---|---|
| `lipstick` | Son môi | 80 % of the lip colour replaced by the tone's colour, at a luma pulled 40 % of the way to that colour's own luma |
| `lipTone` | Tông son | *modifier* — nude → coral → red → berry → plum |
| `blush` | Má hồng | 35 % (at the lobe centre) of the cheek's chroma moved to a muted rose, luma kept, skin pixels only |
| `brows` | Lông mày | luma exponent 1.6, one ratio for all channels, never below 25 % |

**Lipstick moves luma, the hair dye does not.** A red lipstick at the lips' own
luma reads as pink; lipstick is opaque enough to change how light the lips are.
The pull is 40 %, not 100 %, so the lips' own highlights and creases (60 % of the
variation) survive and it looks applied rather than painted flat.

**Blush keeps luma and is gated by skin.** It cannot darken a cheek, and a lobe
that overlaps an eye, a nostril or a strand of hair across the cheek does not tint
it — the lobe value is multiplied by the rasterised `skin` mask.

## Decision — blush reuses the "Tạo khối" lobes

`BlushMask.lobes` builds two `ContourLobe`s per face (apple of the cheek: 45 % of
the way from the eye line to the mouth line, 55 % of that side's own cheek
distance from the midline, 0.17 × 0.11 face widths, tilted 20° toward the
temple). The shader evaluates them with ColorShaders' own `rp_contour_mask`, and
the CPU reference with `ContourMask.value(at:lobes:)` — one falloff, one
definition. Per-side distances mean a three-quarter view puts the far cheek's
blush on the far cheek, as ADR-0020 does for contour.

## Decision — the stage moves before the warp

`RenderStage.makeup` goes from 500 (after Eyes/Teeth, where docs/PLAN.md §2 first
put it) to **270**, after "Tóc" (250) and before "Mặt" (300). The lips mask is
computed on the unwarped frame, and "Môi đầy" / "Rộng miệng" move the lip edge;
applied after the warp, lipstick would miss exactly the band those sliders move
out. `RenderGraphTests.nodesAreSortedByStage` now pins
`color → hair → makeup → warp → eyesTeeth`.

## Decision — no blur, no shared kernel flag

Every step is per pixel, so the node owns one kernel (`rp_makeup_composite`,
`MakeupShaders.metal`, appended last) and three `MaskRasteriser`s used only for
the sliders in play. `RPEngineFeatureFlags.makeupSliders` is the only flag it
reads — like `colorSliders`, nothing shared to reason about when it is turned off.
**Default off.** No detection notice: every region comes from face parsing, and
"no face" is already the panel's own `needsFace` line.

## What is measured, and what is not

Nothing has been compiled or run (Linux cloud session). The tests:

* `golden` — `MakeupRenderNodeTests.compositeMatchesReference`: five slider
  settings against `MakeupReference`, fed the node's own masks and lobes, ≥ 45 dB.
* `identity` — amounts 0 (tone set) bit-exact; outside the skin ellipse
  bit-exact; blush with an all-zero skin mask bit-exact; absent lips/brows masks
  make those sliders inactive.
* `selectivity` — red lipstick raises lip R/G by > 30 % and lowers lip luma
  without touching the cheeks; brows darken by > 20 % without touching the lips;
  blush raises cheek R−G by > 0.02 at luma within 0.01.
* `geometry` — two lobes, one each side of the midline, symmetric on a frontal
  face, between the eye and mouth lines, scaling with face width.

Not measured, and blocking the flag: speed on a Mac and a real iPhone, and a
retoucher's eye on real a6300 portraits — the palettes, the 80 / 40 / 35 %
strengths and the lobe placement are all argued, none tuned.

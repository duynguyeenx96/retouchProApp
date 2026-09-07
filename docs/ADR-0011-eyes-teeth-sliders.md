# ADR-0011 — The "Mắt / Răng" (eyes / teeth) slider group and `EyesTeethRenderNode`

Status: accepted — 2026-09-06
Scope: Phase 2 of `docs/PLAN.md` §3 — the third of the four slider groups, at
`RenderStage.eyesTeeth`. The Color group, the realtime `MTKView` preview and
multi-face canvas selection are **not** in this ADR.

## Context

`docs/PLAN.md` Phase 2 lists four sliders here: *Sáng mắt, Trắng lòng trắng, Nét
mắt, Trắng răng.* Two constraints on them were fixed before any code was
written, both by spike S2 (`docs/ADR-0006`), and both are about a mask that does
not exist:

1. **There is no teeth class.** CelebAMask-HQ's 19 classes have `mouth`, which is
   the mouth *interior* — the gap between the lips, containing teeth, gums,
   tongue and shadow. The plan states it directly: "slider trắng răng phải suy ra
   từ **độ sáng (luminance)** trong vùng `mouth`, không dùng mask parsing."
   `RenderMaskKind` has deliberately never had a `.teeth` case
   (`Packages/RPEngine/Sources/RPEngine/Render/FaceRenderInput.swift:58-66`), and
   `ParsedFace` deliberately exposes `mouthInterior()` rather than anything named
   "teeth"
   (`Packages/RPVision/Sources/RPVision/Analysis/ParsedFace.swift:44-45`).
2. **Eye masks must be feathered.** S2 measured eye IoU at 0.84 against a 0.85
   bar and proved it is the checkpoint's ceiling (the PyTorch original scores
   0.8401 too) because an eye averages 1 365 px of 262 144 — a ~1 px boundary
   error on a ~15 px object. Invisible through a soft mask, obvious through a
   hard one.

The same argument as (1) produces a third constraint nobody had written down:
**there is no sclera class either.** `l_eye`/`r_eye` are the whole eye opening,
sclera *and* iris *and* pupil. "Trắng lòng trắng" therefore has the same shape of
problem as "Trắng răng" and gets the same shape of solution.

## Decision — one composite, two masks, one blurred layer

`EyesTeethRenderNode` (`Packages/RPEngine/Sources/RPEngine/Render/EyesTeethRenderNode.swift`)
follows the `RenderNode` pattern ADR-0009 fixed. Its inputs:

| input | how | what it is |
|---|---|---|
| `eyeMask` | `MaskRasteriser` over `RenderMaskKind.eyes` | feathered `l_eye + r_eye` |
| `mouthMask` | `MaskRasteriser` over `RenderMaskKind.mouth` | feathered `mouth`, the interior |
| `low` | `GuidedFilter`, radius `0.050 × faceWidth`, **ε = 1e6** | a plain double box blur (`GuidedFilterTests.hugeEpsilonIsDoubleBox`), ~half an eye wide |

`low` is the local reference every non-trivial slider in the group compares
against. "Brighter than its own surroundings" is what separates sclera from iris
and teeth from lips, gums, tongue and shadow, and it is measured against a local
mean rather than an absolute threshold so the heuristic survives exposure and
skin tone. Reusing the guided filter at ε = 1e6 is the same trick
`SkinRenderNode` uses for its own `low` layer, so **this group adds no second
blur kernel**.

The radius is a fraction of `FaceRenderInput.faceWidth`, never a pixel count —
docs/PLAN.md §2's condition for a preset transferring between images and for a
2048 px preview agreeing with a 24 MP export.

`low` is allocated **on first use**, and so are the guided filter's
intermediates: "Sáng mắt" alone is a gamma lift that needs no neighbourhood, and
the two together are 192 MB + 144 MB at 24 MP. Measured: 384 MB with every
slider up, **24 MB with only "Sáng mắt"** (`node_bytes_*` in
`Research/bench/p2-eyes-teeth-macos.json`).

## Decision — the sclera and teeth heuristic

One formula, two knees (`Render/RenderShaderSources/EyesTeethShaders.metal`):

```
lift    = saturate((luma(c) − luma(low)) / 0.06)
sat     = (max(rgb) − min(rgb)) / max(rgb)
neutral = saturate(1 − sat / satKnee)          // 0.60 sclera, 0.40 teeth
weight  = lift · neutral
```

and the whitening itself is chroma removal at constant luma followed by a small
lift toward white:

```
whiten(c) = w + (1 − w) · 0.10   where   w = mix(c, luma(c), 0.85)
```

Splitting it that way is what keeps a yellow tooth from turning grey-brown: the
desaturation runs on the luma-preserving axis, so only the cast goes.

The teeth knee is tighter than the sclera knee because the competition differs.
Inside the mouth interior it is lips, gums and tongue, all strongly red; a yellow
tooth sits well below 0.40. Inside the eye opening the competition is the iris,
which is rejected by the *luma* term, so the saturation term can stay loose — and
must, because a bloodshot or pink sclera is exactly the case the slider exists
for and its own tint must not exclude it.

### What the heuristic gets wrong

Stated here, in the node's doc comment and in the bench script, rather than
implied by the slider names:

* A **specular catchlight on the iris** is bright and neutral, scores as sclera
  and gets whitened. It is already near-white so the visible effect is nil, but
  the slider is not doing what its name says there.
* A **pale grey or blue iris in bright light** partially qualifies and will be
  slightly desaturated at high values. A brown iris does not.
* A **bloodshot sclera** under-corrects, for the reason above. The loose knee
  limits this; it does not remove it.
* **Metal fillings and teeth in deep shadow** score low and are left alone; a
  bright lower-lip highlight inside the mouth-interior mask can score high. The
  mask is the interior only, so the lip body is out of scope either way.
* Every constant is argued from what the objects physically are and is **not
  tuned against a retoucher's eye** — the same disclosure the "Mặt" group makes
  about its amplitudes (ADR-0010). Nobody has looked at a render.

## Decision — "Nét mắt" is local contrast, not a pixel-scale sharpen

It pushes the pixel away from the same `low` layer the whitening uses, at
~half-an-eye radius, so it separates iris from sclera and lashes from lid. It
cannot add detail the lens did not resolve and will not crisp a lash at pixel
scale. A true unsharp mask needs a *second* blurred layer at a small radius —
another 192 MB at 24 MP for one slider, which is not a trade this group can make
on an iPhone. The slider is named for what it does.

## Decision — a shared `MaskRasteriser`, extracted from `SkinRenderNode`

This group needs two full-resolution coverage masks. `SkinRenderNode.encodeMask`
was ~80 lines doing exactly that for one kind, so it became
`Packages/RPEngine/Sources/RPEngine/Render/MaskRasteriser.swift` and both nodes
use it. One instance per kind, so an eye mask that has not changed is not
re-uploaded because the mouth mask did.

The kernel is still `rp_skin_mask` in `SkinShaders.metal`, unrenamed: it never
had anything skin-specific in it, and renaming a shader function means touching
the shipped node, its golden tests and ADR-0009's prose for no behaviour change.

Two consequences, both checked:

* the "Da" group's golden numbers are **bit-identical** across the refactor
  (`end_to_end_psnr_db` 79.02303884377761, `composite_psnr_db`
  151.79566853244586 and `mask_max_abs_diff` 0.0024063442094761633 before and
  after, `Research/bench/p2-skin-macos.json`), and so is its speed (24 MP
  33.77 ms before, 33.92 ms after);
* `SkinRenderNode.allocatedBytes` now also counts the 512²-per-face parsing-crop
  array that the rasteriser holds, which it did not before: **+262 144 bytes**,
  i.e. 552 000 000 → 552 262 144 at 24 MP.

`MaskRasteriser.encode` returns `nil` — allocating and dispatching nothing — when
no face carries its kind. The node then forces that kind's slider amounts to 0
and binds the *other* kind's texture in its place, the same substitution
`SkinRenderNode` makes when it binds `source` for an unused blur layer. Both
kinds absent is rejected earlier, so at least one binding is real, and no 24 MB
texture is ever allocated and cleared just to be multiplied by zero.

## Decision — default-off flags, and the shared kernel flag

`RPEngineFeatureFlags.eyesTeethSliders` is owned entirely by this group.
`enableEyesTeethRenderGraph()` sets it together with `guidedFilter`, whose own
gate is not bypassed. `RenderGraph.standard` registers the node only when the
flag is on, so with every group off the graph is empty and copies the picture
through.

**The `guidedFilter` kernel flag is now shared by two groups**, and that needed a
fix rather than a shrug. Until this task `disableSkinRenderGraph()` cleared it
unconditionally, which would have recreated exactly the failure the umbrella
`renderGraph` flag was deleted for in ADR-0010: turning the "Da" group off would
have made `RenderGraph.standard()` **throw** for the "Mắt / Răng" group, which
was still enabled and had nothing to do with it.

Both disable helpers now clear the kernel flag only when no other group still
wants it
(`Packages/RPEngine/Sources/RPEngine/Spike/RPEngineFeatureFlags.swift`).

This is **not** the refcount ADR-0010 rejected. That rejection was "refcounting
the groups behind the bit would only have fixed the path through these two
helpers — a caller setting `skinSliders = true` directly would still have been
switched off by an unrelated group's disable." The condition here reads the
authoritative group flags themselves, so a caller who sets
`eyesTeethSliders = true` by hand, never touching a helper, is still respected.
A caller who sets `guidedFilter = false` directly is taken at their word and both
groups refuse to build: that is a kernel gate meaning what it says.
`RenderGraphTests.disablingTheSkinGroupLeavesTheEyesTeethGroupRunning` is the
regression test.

## Decision — no new compile, a third file in the same library

`Render/RenderShaderSources/EyesTeethShaders.metal` is a third entry in
`MetalContext.shaderSources`, concatenated after `SkinShaders.metal` and compiled
in the **same** `makeLibrary(source:)` call — still one compile per process,
which is the property `RenderGraph.prewarm()` depends on (1.8 s cold in the
Simulator, ADR-0007). Because it is one translation unit the new file reuses
`kRPLuma` and `rp_skin_mask` from `SkinShaders.metal` rather than redeclaring
them, which is why the order in `shaderSources` is fixed and documented.

## Measurements

`Scripts/bench-eyes-teeth.sh` → `Research/bench/p2-eyes-teeth-{macos,ios-simulator}.json`,
scraped from `RPEngineTests/EyesTeethBenchTests`, Release, so the number filed
under `Research/` is always the number a test measured.

The JSON carries **three separate claims**, deliberately not merged:

* `golden.*` — PSNR against `EyesTeethReference`, a `Double` CPU implementation
  written from the specification. Says the GPU computes the documented formula.
* `selectivity.*` — mean |Δ| per known region of a synthetic portrait. Says the
  formula lands on the right pixels. **A PSNR cannot say this**: a slider that
  whitened the whole mouth-interior mask uniformly would score just as well
  against a reference that did the same thing.
* `speed.*` — ms/frame on the real a6300 frame spike S3 uses.

### Golden — synthetic portrait, all four sliders at mid values

| level | number |
|---|---|
| eye mask vs `Double` affine + bilinear + max | max abs **2.08e-3** |
| mouth mask, same | max abs **2.08e-3** |
| composite, fed the GPU's own `low` layer | **158.9 dB** |
| per slider (brighten / sclera / definition / teeth) | 159.7 / 163.8 / 178.0 / 166.7 dB |
| whole node end-to-end | **89.9 dB**, max abs 4.0e-4 |
| whole node at `s = 2` (the non-default subsample) | 90.0 dB |

Bar is 45 dB. The mask figure is dominated by `r8Unorm`'s own 1/255 = 3.9e-3
quantisation.

**What the reference proves and does not.** It is a different language, a
different precision and a separate pass over the same written specification, so
it catches a transcription error — a swapped channel, a `min` for a `max`, a
missing `saturate`, a knee in the wrong term. It does **not** catch a wrong
specification: if the documented formula is a bad way to find teeth, both
implementations agree and both are wrong. Same honest limit as `SkinReference`
(ADR-0009) and `SpikeS3Support` (ADR-0007). Its local-mean layer deliberately
reuses `SkinReference.fastGuidedFilter`, already an independent implementation of
He & Sun 2015 — this node runs the same kernel with the same ε, so a second copy
would only be a second chance to typo the paper.

### Selectivity — mean |Δ| per region, slider at 100

The fixture is a synthetic portrait whose regions are known by construction:
skin 54 648 px, sclera 2 728, iris 1 072, pupil 224, teeth 1 688, gums 1 080.

| slider | teeth | gums | sclera | iris | pupil | skin |
|---|---|---|---|---|---|---|
| `teethWhiten` | **0.0249** | **0** | 0 | 0 | 0 | 3.9e-7 |
| `scleraWhiten` | 0 | 0 | **0.0151** | **0** | 0 | 2.8e-9 |
| `eyeBrighten` | 0 | 0 | 0.0173 | 0.0543 | 0.0270 | 3.1e-4 |
| `eyeDefinition` | 0 | 0 | 0.1474 | 0.2378 | 0.0533 | 2.8e-4 |

Read: teeth whitening moves teeth and leaves the gums in the same mask
**completely** alone; sclera whitening moves sclera and leaves the iris
completely alone. The two zeros are exact on this fixture because its gums
(saturation 0.516) and iris are past their knees by a margin — a real gum in
shadow or a very pale iris would not be, which is the limitation stated above,
not a claim this measurement refutes. The non-zero skin figures are the
**feather ramp** reaching just past the hard ellipse, which is correct behaviour
and is ~64 000× smaller than the in-mask effect.

`eyeBrighten` moves the iris *more* than the sclera: that is the shape of a gamma
lift, and `eyeBrightenCoversTheWholeOpening` asserts it so a later "improvement"
that quietly restricts the slider to the sclera is a failure rather than a silent
change.

### Speed — real a6300 frame `DSC05123` (4000×6000), Release, wall-clock median

| | M1 Pro | iOS Simulator |
|---|---|---|
| preview 2048 px, all four sliders | **1.86 ms → 538 fps** | 5.16 ms → 194 fps |
| preview, "Sáng mắt" only | 0.56 ms → 1779 fps | 1.94 ms → 516 fps |
| 24 MP export, all four | **19.9 ms** | 17.5 ms |
| 24 MP, "Sáng mắt" only | 3.56 ms | 3.47 ms |
| node bytes, 24 MP, all four | 384 524 288 | same |
| node bytes, 24 MP, "Sáng mắt" only | 24 262 144 | same |

Bars are ≥ 30 fps preview and < 8 s export. **Not measured on an iPhone** — no
device is attached, the same limitation S1, S2, S3, `FaceAnalyzer`, the Da group
and the Mặt group all record. `is_real_device` in the JSON says which is which,
and in the Simulator `gpu_median_ms` is not a GPU time (it reports ~0.07 ms for a
24 MP render); read `wall_*_ms` there.

## Known limitations, stated rather than hidden

* Every constant — both knees, the chroma fraction, the lift, the definition
  gain, the brighten gamma — is argued from physics and untuned by eye.
* "Nét mắt" is local contrast at eye scale, not a sharpen.
* All four sliders are one-directional (0–100 is a fixed project decision); the
  signed versions are a UI/plan change, not a change to this node.
* The selectivity numbers come from a synthetic portrait, not from a parsed real
  face — there is no per-pixel teeth/sclera ground truth in the project to score
  against, and building one means hand-labelling. The claim is therefore "the
  heuristic separates these regions when they look like this", which is weaker
  than "it separates them on the user's photographs".
* Memory: 384 MB at 24 MP with every slider up, on top of the Da group's 552 MB
  if both run in one export. That total has to be re-checked on a real iPhone
  before either group is enabled by default.

## Alternatives rejected

* **A per-region statistics pass** (mean/σ/max luma inside each mask, then a
  threshold from those) instead of a local mean. More principled in principle,
  but it needs an atomic reduction whose `uint32` accumulator overflows at 24 MP,
  and the local mean already carries the exposure/skin-tone invariance that was
  the reason to want statistics.
* **A second small-radius blur layer** for a true unsharp "Nét mắt": +192 MB at
  24 MP for one slider.
* **An absolute luminance/saturation threshold** for teeth and sclera: fails on
  the first under- or over-exposed frame.
* **A `teeth` case in `RenderMaskKind`** filled by thresholding inside the node:
  it would let a later node assume a mask nothing can produce.
  `EyesTeethRenderNodeTests.maskKindsExist` and
  `FaceAnalysisRenderBridgeTests.eyesTeethNodeMaskKindsAreFeathered` both assert
  no such case exists.
* **Clearing `guidedFilter` unconditionally** in the disable helpers: see above.

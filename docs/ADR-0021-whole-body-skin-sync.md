# ADR-0021 — "Sửa da": whole-body skin sync, and why it widens *before* the gates narrow

Status: accepted — 2026-09-15
Scope: Phase 6 §6.2, "Sửa da — đồng bộ da toàn thân". **Engine only this round**:
a port of the UXP panel's skin classifier, one new Metal kernel that merges its
whole-frame coverage with the per-face BiSeNet coverage, and the numbers. There
is no UI — nothing in RPUI exposes a toggle, `RailLayout.swift` is untouched —
and `RPEngineFeatureFlags.bodySkinSync` ships **off**, for reasons the
measurements below make concrete.

## Context

docs/PLAN.md §6.2 fixes the meaning of "Sửa da" (chốt 2026-09-11) and it is not a
new slider group:

> **Không phải bộ slider mới.** Mở rộng đúng 8 slider Da hiện có … từ
> mask-chỉ-trong-mặt ra một mask da-toàn-thân, dùng **cùng giá trị** người dùng
> đã chỉnh cho mặt — để da cổ/vai/tay lộ trong khung không bị lệch tông/độ mịn
> so với mặt vừa beauty.

and it names the technique and the architectural wrinkle:

> Rẻ nhất, không cần model mới: **skin-color classification cổ điển** … `SkinRenderNode`
> hôm nay chỉ nhận mask **theo từng mặt** … cần mở seam để node nhận thêm 1 mask
> phụ whole-frame, hợp nhất trước khi dispatch (không phải viết kernel mới,
> `SkinRenderNode`'s kernel đã đo 79 dB, chỉ đổi input mask).

Between the writing of that row and this work, Phase 6.1 shipped
`RenderGateMask` (ADR-0019): a **shared slot** on `RenderRequest` for
"whole-frame masks that belong to no face", already carrying the hand-painted
brush and set up to carry "Khoá nền"'s subject mask (ADR-0018). Its doc comment
explicitly nominated §6.2's skin mask as its third consumer. This ADR records
why that nomination was declined, and what was done instead.

## Decision

### 1. The whole-frame skin mask is **not** a `RenderGateMask`

`RenderGateMask`'s contract is *narrowing*: `GateMaskCompositor` is a multiply,
`coverage x gate`, and every consumer relies on the consequence — "no gates ⇒
exactly the pre-6.1 render", which is what keeps ADR-0009 … ADR-0012's golden
numbers valid.

A whole-body skin mask has to do the opposite. The per-face BiSeNet coverage is
zero everywhere outside the parsing crop, so intersecting it with a whole-body
mask is nonzero only where **both** already say skin — i.e. inside the face crop,
which is exactly the area this feature exists to grow beyond. A multiply cannot
add area. A type conforming to `RenderGateMask` in order to widen would be
*lying about what it does*, and the lie would be silent: the render would simply
never reach the neck and no test would obviously fail.

So it stays a field of its own, `RenderRequest.bodySkinMask`, and
`RenderGateMask.swift`'s doc comment was corrected rather than left contradicting
what shipped.

### 2. Union first, gates second — widen, then narrow

`SkinRenderNode.encode` builds the coverage in two steps, in this order:

1. **widen** — `rp_body_skin_union` merges the per-face coverage with the
   whole-frame coverage;
2. **narrow** — the unchanged `applyGates(...)` multiplies in every live
   `RenderGateMask`.

Read aloud: *find skin everywhere it plausibly is, then restrict to where the
user and the subject mask say is fair game.* The other order is not a stylistic
alternative, it is a bug: gate-then-union would let the whole-frame mask re-add
precisely the area a brush stroke had just erased, so a brush would visibly fail
to protect a shoulder. `BodySkinUnionTests.gateNarrowsTheUnionedRegion` is the
test that tells the two apart — it gates the bottom half shut and requires
**0** touched pixels there, where the wrong order leaves 35 345.

With no gate and no body mask the bound texture is still the per-face coverage,
byte for byte, which is what keeps ADR-0009's 79.0 dB valid.

### 3. The merge is not `max(face, body)`

The two masks do not have equal standing. Inside a parsing crop the BiSeNet mask
is authoritative — it knows lips, eyes, brows, hair and glasses are not skin, and
the colour classifier does not (lips sit inside the CbCr skin ellipse, so a plain
`max` would smooth the mouth). Outside every crop the BiSeNet mask does not exist
and the colour mask is all there is. `rp_body_skin_union` therefore computes

```
authority = smoothstep over the signed distance to the crop border, in mask px
out       = max(face, body * (1 - authority))
```

with the ramp `0.150 x faceWidth` wide — the same fraction as the node's
large-blur radius, because a step in the mask narrower than that blur is a step
the eye can find. On a CelebAMask-HQ-framed crop (1.87 x face width) the ramp
runs across the neck, which is the seam docs/PLAN.md §6.2 asks to be feathered.
The `max` with the face mask keeps a hard guarantee: the union is `>=` the face
mask at every pixel, so switching the feature on can never take smoothing away
from a face that already had it.

### 4. The classifier is `skincore.js`, transcribed, not re-derived

`SkinCore.swift` is a port of `panelpts/RetouchProUXP/skincore.js` — the file the
panel shipped *and* the file `panelpts/research/eval.js` scored — as
`.claude/agents/coder.md` §"Reuse before writing" requires. Every constant (the
Kovac RGB rules, the CbCr ellipse 102/153 ± 28/22, the 1.35 cut-off, the x1.6
gain, the 0.35 back-projection gamma, the 135/90/45 luminance knees, the 6/12
yellowness knee, the 2 % component floor, the top-5 % normalisation) is
transcribed.

"Identical numerics" is pinned as an **exact** equality, not a tolerance, by
`SkinCoreTests` against a fixture generated by running the real JS under Node
(`Scripts/skincore-js-fixture.js`). Three JS-isms are asserted individually
because each could have diverged silently: `Math.round` rounds half towards +∞;
`boxBlur` truncates on store because it writes into a `Uint8Array`; `median`
takes the **upper** middle of an even count.

A fourth one was found by the fixture and fixed: `skincore.js` holds Cb/Cr in a
`Float32Array`, so every later use sees a single-precision value. Holding them as
`Double` in Swift agreed on the fixture's coverage bytes but moved the reported
medians in the sixth decimal, and a histogram bin boundary is where that would
eventually land differently. `SkinCore` now stores them as `Float`.

Two parts of `classify` are deliberately **not** ported: the `ps` (Photoshop
"Skin Tones") and `subj` (subject mask) priors — there is no Photoshop here, and
the subject prior is §6.1's "Khoá nền", which §6.2 itself calls an optional v2 —
and the texture penalty, which is `enabled: false` in the JS because it had no
ground truth. Both enter as per-pixel multipliers, so adding them later is one
multiply.

### 5. The flag ships off, and this is the reason

`Research/bench/p6-skin-sync-{macos,ios-simulator}.json`, produced by
`Scripts/bench-skin-sync.sh`. Read the caveat first:

**docs/PLAN.md §6.2's "đo IoU trên bộ ảnh test nhiều tông da khác nhau trước khi
ship" is NOT satisfied.** The only labelled data the project can reach is
`panelpts/research/data`, and it has no `_gt.bmp` in it — running
`node panelpts/research/eval.js` today prints *"4 ảnh, 0 có ground truth …
CHƯA CÓ GROUND TRUTH — các số trên chỉ là độ phủ, KHÔNG phải độ đúng."* Someone
has to paint ground-truth masks before a photographic IoU exists. The JSON says
so in `human_ground_truth_available: false`.

What was measured, on a **constructed** synthetic truth across a six-step skin
tone ladder, at eval.js's threshold of 127 (macOS, Release, M1 Pro):

| tone | clean IoU | cluttered IoU | wood leak |
|---|---|---|---|
| I very light (255,219,172) | 0.988 | 0.610 | 0.60 |
| II light (241,194,125) | 0.978 | 0.530 | 0.87 |
| III medium (224,172,105) | 0.977 | 0.572 | 0.86 |
| IV olive (198,134,66) | 0.970 | **0.000** | 0.84 |
| V brown (141,85,36) | 0.982 | 0.602 | 0.70 |
| VI deep (91,60,17) | **0.000** | **0.000** | 0.75 |

"clean" is skin against a cool background — the *detection* question. "cluttered"
adds a rattan/wood block and a beige wall — the *rejection* question. Two
failures, both real, both inherited from the shipped panel rather than introduced
here:

* **Tone VI is invisible to the classifier at all.** `skinScore` rejects
  `R <= 95` outright (Kovac), and (91,60,17) never gets past the first line. A
  feature that silently does nothing for deep skin tones must not be on by
  default.
* **Skin-coloured wood outscores mid skin.** (196,150,96) lands closer to the
  CbCr ellipse centre than (198,134,66) does, so on the cluttered frame the
  per-image back-projection learns the *wood*, the yellowness knee then penalises
  the real skin, and the 2 % component floor keeps the wood and drops the model —
  hence IoU 0.000 for tone IV with the mask still claiming 22 % of the frame.

§6.2's own optional v2 — intersecting with `VNGeneratePersonSegmentationRequest`
("Khoá nền", §6.1, already built and already a `TextureGateMask`) — is aimed at
exactly this, and these numbers are the argument for doing it **before** any
toggle ships.

Cost, for completeness (macOS Release, M1 Pro):

| | |
|---|---|
| classifier, 2048 px preview | 17.8 ms, **once per image**, not per frame |
| classifier, 24 MP | 90.1 ms, once per image (bar: 5–8 s for a whole export) |
| union dispatch, 2048x1365 | +0.43 ms/frame marginal (4.36 → 4.79 ms) |
| port exactness | coverage max abs diff **0**, 0/109 probe mismatches, medians bit-equal |
| flag off vs no mask | max abs diff **0** |
| union vs face mask | worst loss **0** (never narrows) |
| gate after union, shut half | **0** px touched |

## Consequences

* The eight "Da" sliders, `rp_skin_composite` and its 79.0 dB (ADR-0009) are
  untouched. The only thing that changed is which texture is bound at index 3.
* `MetalContext.shaderSources` gained a seventh file, appended **last** so no
  earlier file's line numbers move; `RenderGraphTests.shaderSourcesAreAllPresent`
  was updated from 6 to 7 and now also resolves `rp_body_skin_union`.
* `SkinRenderNode` owns a second `MaskRasteriser`, built through
  `MaskRasteriser(wholeFrame:)` — the constructor "Khoá nền" added for masks that
  belong to no face — so the body mask is handed over directly rather than
  smuggled through a `FaceRenderInput` with a `faceWidth` no face ever had. Its
  upload cache invalidates independently of the face masks'.
* Nothing computes a `BodySkinMask` yet in the app: `RenderRequest.bodySkinMask`
  is `nil` on every path today. Wiring it (and the toggle) is the next piece of
  work, and should not start before the segmentation intersection above.

## What is still open

1. **Human ground truth.** Until `panelpts/research/data` has `_gt.bmp` layers,
   there is no photographic IoU and the plan's ship criterion is unmet.
2. **Deep skin tones.** The Kovac gate is the blocker; lifting it is a change to
   the *shipped panel's* maths and therefore needs its own measurement pass, not
   a quiet edit.
3. **Subject intersection.** Wiring "Khoá nền"'s mask as a gate on this node is
   free (it is already a `TextureGateMask` and the gate step already runs after
   the union) but changes the numbers above, so it needs a re-measure.

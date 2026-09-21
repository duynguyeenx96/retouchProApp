# ADR-0021 — "Sửa da": whole-body skin sync, and why it widens *before* the gates narrow

Status: accepted — 2026-09-15; amended 2026-09-16 (see "v2 — the
person-segmentation intersection"); UI wired 2026-09-21 (see "UI (2026-09-21)")

> **Addendum 2026-09-21 — there is a UI now; the flag still does not move, and
> neither does the deep-tone gap.** The "there is no UI" sentence below was true
> of the engine rounds and is superseded by the "UI (2026-09-21)" section at the
> end of this file. Every decision, constant and measured number above it is
> unchanged: the wiring added no engine math, and **tone VI is still 0.000 IoU**.
> What changed is that the failure is now spoken out loud in the panel instead of
> looking exactly like a success.
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
  **Superseded 2026-09-16** — the wiring landed with v2 below; the toggle did
  not.

## v2 — the person-segmentation intersection (2026-09-16)

Amendment, not a rewrite: everything above still holds, including the
limitations. This section adds what was built for failure (2) of §5 — "skin
coloured wood outscores mid skin" — and states, with numbers, which half of it
was actually fixed.

### What was built

| | |
|---|---|
| `App/PersonSegmenterSubjectMaskProvider.swift` | new. `RPEngine.SubjectMaskProviding` on top of `RPVision.PersonSegmenter`. Cache key `<contentHash>@<w>x<h>@<quality>`, concurrent callers coalesced onto one run, one `AppLog` line per request. The **first** thing in the app to call `VNGeneratePersonSegmentationRequest` at all — ADR-0018 built `PersonSegmenter` and `BackgroundLockMaskSource` and nothing ever invoked either. |
| `BodySkinMask.make(…, subject:)` | the multiply, on both byte overloads plus a new `make(image:subject:)` for the canvas. |
| `BodySkinMask.intersect(…)` | the resampling: working grid → image px → subject px, bilinear, clamped at the edges. |
| `LivePreviewController` | asks for a subject mask and computes a `BodySkinMask` **once per shot**, and puts the result in `RenderRequest.bodySkinMask`, which until now was `nil` on every path in the app. |
| `AppEngineSetup.enableKey` (`RPEnableExperiments`) | the developer switch that turns the path on for a launch, since the feature flag stays off. |
| `App/BodySkinSelfTest.swift` (`RP_BODYSKIN_SELFTEST`) | the device hook, in the shape `RP_FACE_SELFTEST` already established: open a real photo through the product objects and write what came out to `session.log`. |

The multiply is at the `BodySkinMask` layer, **not** inside `SkinCore.classify`.
That was §4's reservation and it is kept: `SkinCore` remains the transcription of
`skincore.js` that `SkinCoreTests` pins byte for byte against a Node-generated
fixture, and nothing in this change moves it (`port.coverage_max_abs_diff` is
still 0).

### Why the resampling is not a scale factor

The two masks agree on nothing. The classifier's grid is 320 px wide and follows
the frame's aspect; `VNGeneratePersonSegmentationRequest` returns a fixed 4:3 (or
3:4) grid with the picture **stretched** into it — a 2048x1365 frame comes back
as 512x384 (`PersonSegmenter`'s own measured note). So each working pixel goes
through `coverageToImage` and then `subject.imageToMask`, and the subject is
sampled bilinearly at that point, with the nearest edge texel used outside the
mask. `BodySkinSubjectMaskTests` pins the two things that would otherwise be
silent: a saturated mask is the **identity at four different resolutions**, and a
top-half / left-half mask clears the *other* half (a y-flip or a transpose would
be invisible in a coverage fraction).

### The numbers

`Research/bench/p6-skin-sync-{macos,ios-simulator}.json`, same fixture as §5,
same threshold 127, with a `v2_subject_mask` block beside every v1 block. The
subject mask there is **constructed** from the frame's own silhouette (dilated
4 px, rendered at 96x72 so the resampling is exercised) — a synthetic frame has
no person in it for Vision to find, and the Simulator cannot run the request at
all — so these are an **upper bound** on what v2 buys in the field, not a
measurement of Vision's mask quality.

| tone | clean v1 → v2 | cluttered v1 → v2 | wood leak v1 → v2 |
|---|---|---|---|
| I very light | 0.988 → 0.988 | 0.610 → **0.989** | 0.60 → 0.00 |
| II light | 0.978 → 0.978 | 0.530 → **0.872** | 0.87 → 0.00 |
| III medium | 0.977 → 0.977 | 0.572 → **0.941** | 0.86 → 0.00 |
| IV olive | 0.970 → 0.970 | **0.000 → 0.000** | 0.84 → 0.00 |
| V brown | 0.982 → 0.982 | 0.602 → **0.983** | 0.70 → 0.00 |
| VI deep | **0.000 → 0.000** | **0.000 → 0.000** | 0.75 → 0.00 |

Every clean-frame number is unchanged **to the last digit**. That is the control:
where there is nothing to remove, the resampled multiply is an identity, and a
half-pixel error in it would have shown up here as a dimmed edge.

Cost: the multiply itself is inside the noise (17.8 → 17.8 ms at a 2048 px
preview, 93.8 → 92.1 ms at 24 MP — it runs on the 320 px grid, not on the frame).
The mask it needs is not: a `.balanced` segmentation request is ~17 ms
(`Research/bench/p6-background-lock-macos.json`), once per shot. Quality
`.balanced` is a measured choice, not a middle one — `.fast`'s 256x192 mask
averages 0.90 coverage inside a face box (0.71 on one frame), and this mask is a
*multiplier* on skin coverage, so a boundary error there deletes skin rather than
blurring an edge.

### On real photos, and how the alignment was checked without a picture

The tone ladder is synthetic. `RP_BODYSKIN_SELFTEST` (`App/BodySkinSelfTest.swift`,
the "Sửa da" sibling of `RP_FACE_SELFTEST`) runs the real path —
`LivePreviewController.open` — on a photo from the library and writes the result
to `session.log`. Four photos on macOS, two portrait, one landscape, one a6300
ARW:

| photo | frame | frame coverage v1 → v2 | **inside the detected face box** v1 → v2 |
|---|---|---|---|
| DSC00657.jpg | 1365x2048 | 0.160 → 0.020 | 0.354 → **0.350** |
| DSC05122.ARW | 1365x2048 | 0.045 → 0.015 | 0.284 → **0.284** |
| 3Q6A0510.jpg | 1365x2048 | 0.032 → 0.029 | 0.189 → **0.185** |
| DSC01660.jpg | 2048x1365 | 0.159 → 0.113 | 0.429 → **0.426** |

The second column is the one that matters, and it is why the self-test logs it.
A subject mask that is flipped, transposed or scaled wrong lowers the coverage
figure *exactly like one that is working*, so a single number cannot tell them
apart. The face box can: it is unambiguously skin and unambiguously inside the
subject, and it keeps ~99 % of its coverage on every photo while the frame as a
whole loses 12–87 %. Both orientations are in the table on purpose — the
landscape frame is 3:2 against Vision's 4:3 grid, which is where a single-scale
affine would go wrong.

Vision's mask came back 384x512 for the portrait frames and the classifier's grid
was 320x480, i.e. neither the same size nor the same aspect on either axis, which
is the case the resampling exists for.

### Two things v2 does not fix, stated plainly

1. **Deep skin tones are unchanged, and cannot be changed from here.** Tone VI
   (91,60,17) is rejected by `SkinCore.skinScore`'s Kovac `R <= 95` line, which
   runs *before* any per-image learning and long before this multiply. A multiply
   removes false positives; it can never add a pixel the colour rule already
   scored 0. Tone VI is 0.000 IoU with and without the subject mask, on both the
   clean and the cluttered frame, and
   `BodySkinSubjectMaskTests.deepToneIsUnchangedByTheSubjectMask` asserts it so
   that a future change cannot quietly claim otherwise. The one thing that does
   move is the *shape* of the failure: on the cluttered frame v1 claimed 12.5 % of
   the frame (all of it wood) and v2 claims 0.0 %, so the feature now does nothing
   instead of smoothing the furniture.
2. **Tone IV on the cluttered frame is still 0.000, and this ADR predicted
   otherwise.** §5 said the segmentation intersection "is aimed at exactly this".
   It is aimed at it and it misses, for a reason worth recording: the wood does
   not merely leak into the output, it **steals the calibration**. By the time
   `SkinCore` returns, the back-projection has learned the wood and the 2 %
   component floor has dropped the skin component, so there is no skin coverage
   left for a multiply to keep — v2 removes the wood (coverage 0.217 → 0.077,
   wood leak 0.84 → 0.00) and what remains never crosses the 127 threshold.
   `skincore.js` puts its own `subj` prior at **step 3, before the step-4
   learning**, which is precisely why it works there and not here. Porting that
   step-3 prior is the next move, and it changes a file pinned as an exact
   transcription of the shipped panel — so it needs its own decision, its own
   fixture case and its own measurement pass, not a quiet edit.

### The flag stays off

`RPEngineFeatureFlags.bodySkinSync` is still `false` and there is still no UI
toggle. Four of six tones got materially better on a cluttered frame and none got
worse, but two of six are still a silent 0.000 and one of them is the deepest
skin tone on the ladder. Shipping that on by default would be shipping a feature
that does nothing for some users and says nothing about it. `RPEnableExperiments`
exists so the wiring can be exercised on a real device without a rebuild and
without shipping it on:

```
defaults write com.duynguyen.RetouchPro RPEnableExperiments -string "bodySkinSync"
```

It sets `RPEngineFeatureFlags.bodySkinSync` **and**
`RPVisionFeatureFlags.personSegmentation`, because neither package writes the
other's store and the app is the only place that links both.

### What could not be verified

**None of this ran on the iPhone.** The App Group provisioning-profile mismatch
that has blocked every real-device build in this repo since the Share Extension
landed is still there — `xcodebuild -destination 'platform=iOS,id=…'` fails at
`GatherProvisioningInputs` with *"Provisioning profile … doesn't match the
entitlements file's value for the com.apple.security.application-groups
entitlement"*, and clearing it needs one pass through the Xcode GUI. What was
done instead: the iOS **device slice** compiles
(`-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`), the full suite
is green on the Simulator, and the feature was exercised end to end on macOS
against real photos as above. That is a real substitute for the sandbox-shaped
risks and **not** a substitute for the one risk specific to iOS here: Vision's
segmentation request has no Simulator implementation at all, so the iPhone is the
only place its cost and its mask resolution can be measured. `RP_BODYSKIN_SELFTEST`
exists so that is one command when the profile is fixed.

## What is still open

1. **Human ground truth.** Until `panelpts/research/data` has `_gt.bmp` layers,
   there is no photographic IoU and the plan's ship criterion is unmet.
2. **Deep skin tones.** The Kovac gate is the blocker; lifting it is a change to
   the *shipped panel's* maths and therefore needs its own measurement pass, not
   a quiet edit. **v2 did not touch this** — see §v2.
3. ~~**Subject intersection.**~~ Done — see the v2 section above. What it left
   behind is item 5.
4. ~~**A UI notice for the silent cases.**~~ Done — `RenderNode.detectionNotice(for:)`
   landed 2026-09-16 and the panel that shows it landed 2026-09-21; see "UI
   (2026-09-21)" below. The *cause* is untouched: a deep tone still produces no
   coverage, it is now simply reported.
5. **The `subj` prior inside the classifier.** The step-3 multiply
   `skincore.js` already has, which is what would fix tone IV on a cluttered
   frame. Deliberately not done here, because it edits the file this project
   pins as an exact port.
6. **"Khoá nền" itself.** `BackgroundLockMaskSource` still has no node reading
   its texture and no UI; it can now share
   `PersonSegmenterSubjectMaskProvider` when it is wired.

## UI (2026-09-21) — a switch that can say it found nothing

No engine math changed for this round: it is `SliderPanelLayout` + one rail entry
+ one new document value (`RPEngine.BodySkinSync`) + the one line of request
assembly that reads it. `SkinCore`, `BodySkinMask`, `rp_body_skin_union` and
`SkinRenderNode`'s kernel are untouched, so every number in §5 and §v2 still
describes what ships.

### Why it could ship now, when the reviewer had blocked it

The earlier ruling was *"don't ship silently-broken-for-some-users"*, and it was
right: §v2 leaves two of six tones at 0.000 IoU (tone VI always, tone IV on a
cluttered frame) and neither is fixable from this feature's side — the Kovac
`R <= 95` reject and the calibration theft both happen upstream of anything this
ADR multiplies. **None of that is fixed here and this section does not claim
otherwise.**

What changed is the *shape* of the failure, structurally:
`SkinRenderNode.detectionNotice(for:)` (2026-09-16) returns
"Không phát hiện được da." whenever the body coverage is below
`minimumBodySkinCoverage` (0.001 — a floor just above exact zero, not a tuned
operating point), and `SliderSectionDescriptor.notifiesFromNodeNamed` now carries
that sentence into the panel. So the deep-tone case is no longer *silent*: the
user is told the classifier found nothing on this photo, in the same one-line
`info.circle` treatment the panel already uses for "no face detected", live per
render. A feature that fails visibly and says so is a different product decision
from one that fails invisibly, and it is that difference — not a fix — that lets
the toggle exist.

`BodySkinSyncTests.deepToneFramePublishesTheNotice` asserts this end to end on a
real classification of a (91,60,17) frame, with a tone-III frame as the control,
rather than on a hand-made zero mask.

### The toggle is a **document** value, not a flipped build flag

`RPEngine.BodySkinSync` — `EditState.sections["mask"]["bodySkinSync"] = true`,
absent means off — modelled on `BackgroundLock` one key over, in the namespace
RPCore already documents as *"where an effect is allowed to act … not a set of
sliders"*. It is a section rather than `perImage` because it transfers: "also fix
the neck and arms" says nothing about which photo it was said on, so a preset
carries it.

A build-time flag alone could not be this. The flag answers *"does this build
ship the effect"*; the switch answers *"does the user want it on this picture"*,
and there is no toggle without the second. Both are required, and
`BodySkinSync.mask(for:bodySkinMask:)` is where they meet — at request assembly,
the mirror of `BackgroundLock.gateMasks(for:subjectGate:)`, deliberately **not**
inside `SkinRenderNode`: the node's union, its kernel and ADR-0009's 79.0 dB stay
exactly as measured, and "no body mask" is a state it has always rendered as
"bind the per-face coverage, byte for byte".

`RPEngineFeatureFlags.bodySkinSync` is **not** flipped. The iPhone bar from §"What
could not be verified" is unchanged and is sharper here than for ADR-0018/0020:
`VNGeneratePersonSegmentationRequest` has no Simulator implementation at all, so
the ~35 ms/shot this path spends has never been measured on an A-series chip. The
panel therefore opens and says so —
"Sửa da đang tắt trong bản dựng này — chưa đo tốc độ trên iPhone thật." —
the same `PanelFeatureGate` treatment ADR-0020 §UI introduced.

### A panel of its own, and why not a row inside "Mịn da"

`SliderPanelLayout.PanelKey.skinFix` — "Sửa da", one switch labelled
**"Đồng bộ da toàn thân"**, the first panel in the app with no slider in it and
the first over `EditState.SectionKey.mask`. The rail's "Sửa da" leaf (a child of
"Da" since the rail was written, described there as this group's scope switch)
points at it instead of being locked.

The row could have gone inside "Mịn da" / "Kiềm dầu", the two panels it widens.
It did not, for a reason that is not layout: `notifiesFromNodeNamed` **disables
the group it is attached to**, and "Không phát hiện được da." must not disable the
seven face-smoothing sliders — those still work perfectly on the face when only
the *body* classifier came back empty. The notice belongs on the control it is
about. `DetectionNoticeWiringTests.theShippedTableNamesOnlySkinFix` pins that
scoping.

Consequences of the toggle-only panel, all small and all tested:
`SliderSectionDescriptor.isLocked` became "no control of **either** kind" rather
than "no sliders"; `activeParameterCount`, `isNeutral` and `sections(touchedBy:)`
count switches too, by key, so "Sửa da" never claims "Khoá nền"'s boolean in the
same namespace; and `SliderPanelLayout.storageKeys` now carries one namespace more
than `EditState.SectionKey.all`, which is why the coverage test asserts the slider
namespaces rather than the whole list.

### The switch stays usable while the notice shows

`GroupAvailability.blockedReason` disables a group's **sliders**; it does not
disable its **switches** (`GroupAvailability.togglesEnabled`). A slider whose
group cannot work is disabled because dragging it would write a value nothing
reads. A switch is the user's stated intent, and turning an intent back off has
to stay possible on the very photo where it could not be carried out — otherwise
a user who switches "Sửa da" on and then opens a deep-tone photo is stuck with it
on. The one exception is the build gate: with `bodySkinSync` off the value has
nothing to mean in this build, so the row is inert like the gated sliders in
"Tạo khối".

Answer order inside the panel is build → face → node, and it is deliberate: a
build with the effect off cannot be fixed by importing another photo, and with no
face at all there is no skin group to widen.

### What this round did **not** do

* It did not improve deep-tone detection. Tone VI is 0.000 IoU, before and after.
* It did not touch `SkinCore` — open item 5 (the step-3 `subj` prior, the thing
  that would fix tone IV on a cluttered frame) is still open and still needs its
  own decision, fixture case and measurement pass.
* It did not turn the feature on: both the engine flag and the document switch
  default to off, so a shipping build renders exactly what it rendered
  yesterday.
* It was verified on macOS only (`Scripts/test.sh macos`). The iPhone gap above
  is unchanged, and it is the reason the flag is still off.

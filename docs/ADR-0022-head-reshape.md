# ADR-0022 — "Đầu": warping the head by its hair silhouette

Status: accepted — 2026-09-15
Scope: Phase 6 §6.2, "Đầu (head reshape) — warp cả khung đầu/viền tóc, không chỉ
landmark mặt". **Engine only this round**: a CPU trace of the parsing model's
hair mask, three sliders, and the control points they become inside the warp node
that already exists. There is no UI — nothing in RPUI exposes these sliders,
`RailLayout.swift` is untouched — and `RPEngineFeatureFlags.headSliders` ships
**off**, for reasons the measurements below make concrete.

> **Addendum 2026-09-21 — the UI exists now; the flag does not move.** The
> sentences above about "there is no UI" were true of the engine round and are
> superseded by the "UI (2026-09-21)" section at the end of this file, which also
> records the **product sign-off on the preview round-trip error** this ADR left
> open ("the choice belongs to whoever wires the UI, with this number in hand").
> Everything else here — every decision, constant and measured number — is
> unchanged, because the wiring added no engine code at all.

## Context

docs/PLAN.md §6.2 fixes both the problem and the technique:

> Vision không có API viền đầu/tóc riêng, nhưng RPVision **đã có** —
> `FaceParsingClass.hair`/`FaceParsingGroup.hair` từ BiSeNet (ADR-0006/S2). Dò
> biên ngoài của mask tóc (`VNContoursRequest` hoặc trace CPU/Metal) làm control
> point MLS thêm, kết hợp mở rộng vòng oval mặt (478 điểm) ra ngoài theo tỉ lệ
> neo vào biên tóc đó — cùng họ với `FaceReshape` (identity handle + vùng trọng
> số) hơn là một bài toán model mới. Cần vòng đo mới kiểu ADR-0010 (chưa có
> ground-truth viền tóc trên ảnh a6300 thật).

So: no new model, no new kernel, a new *consumer* of a mask the pipeline already
produces — and a new measurement round, because nobody has drawn a hairline by
hand on these frames.

## Decision

### 1. The trace is ours, and it is checked against something that is not

`HairBoundary` thresholds the feathered hair mask at 128, takes the largest
**4-connected** component by breadth-first search, and walks its outer ring with
a Moore-neighbour trace using Jacob's stopping criterion. `VNContoursRequest` was
rejected — the input is a `[UInt8]` coverage buffer and an affine, not an image;
the request is an edge detector with its own undocumented binarisation and
polygon approximation, and for a warp a control point's *position* is the answer;
and RPEngine deliberately does not import Vision. That argument is recorded in
full in `HairBoundary.swift`'s own doc comment.

The cost of writing it ourselves is that it has to be verified, and verified
against a **different algorithm** rather than against itself:
`Research/bench/hair-boundary-reference.py` labels components by NumPy label
propagation (no queue, no traversal order) and describes the boundary as the
per-row and per-column extremes of that component (no ring walk at all). The two
meet at a theorem, not at an implementation: the leftmost member of a row is
reachable from outside by walking west, so it lies on the *outer* boundary, and
likewise for the other three extremes. Every one of them must therefore appear in
the Swift ring, and the ring's own extremes must be exactly those numbers.

That is what `HeadReshapeGeometryTests` compares, over 7 synthetic shapes (disc,
annulus with a hole, two components, a component cut by the frame edge, a single
pixel, a one-pixel bridge, a concave comb) and all **11 real a6300 hair masks**.
Result: **exact, 0 px deviation, on all of them**, and the component pixel counts
agree exactly too (`reference.max_extreme_deviation_px: 0`,
`component_pixel_mismatches: 0`).

The comparison is deliberately *not* set equality of boundary pixels: a hole
inside the hair has a boundary too, and the trace returns the outer ring only.

### 2. Three sliders, each of which needs the silhouette

`HeadSliders` lives in `EditState.SectionKey.face` with the reshape and contour
sliders (`headSize`, `headWidth`, `headVolume`; no RPCore change —
`Slider.range(for:in:)` already gives a non-bidirectional section `0...100`).
Each one is something the 478-point mesh cannot express on its own:

| slider | what it does | why it is not a "Mặt" slider |
|---|---|---|
| **Thu nhỏ đầu** (`size`) | scales the whole head — mesh, ring and hair together — about a pivot a quarter of a face length below the chin | moving the mesh alone slides the face inside hair that stays put |
| **Hẹp đầu** (`width`) | narrows the skull laterally, full weight at and above the eye line, zero at the cheek line | "Bóp mặt" is the jaw and below; "Thái dương" pushes the temples *out*; neither touches the cranium, where the mesh is one thin arc and the hair is everything |
| **Phồng tóc** (`volume`) | pushes the silhouette outward from the head centre above the eye line, with the face pinned | it is a statement about two regions at once, so both have to be handles |

The bands do not overlap the "Mặt" group's, so "Đầu" cannot quietly re-slim a
face. Every magnitude is a dimensionless gain on a landmark-derived distance
(`sizeGain`, `widthGain`) or a fraction of face width (`volumeFraction`), so the
whole group is exactly scale-invariant — measured at 8.5e-14 px over a 3x
rescale, and rotation-equivariant at 5.6e-14 px over a 0.4 rad roll.

**The magnitudes are not tuned.** Nothing has measured what looks right; that
needs a human comparing renders. The bench says so in
`"constants_are_tuned": false`, as ADR-0010 … ADR-0021 do for their groups.

### 3. The expanded ring is what makes "volume" smooth

§6.2's "mở rộng vòng oval mặt ra ngoài theo tỉ lệ neo vào biên tóc" is
implemented literally: for each face-oval landmark at or above the cheek line, a
ray from the head centre through it, the first hairline crossing beyond it, and a
point half way there. Those ring points take **half** the silhouette weight, so
`volume` ramps 0 → ½ → 1 from the face to the hairline instead of stepping
across whatever gap the hairstyle leaves — which MLS would otherwise shear.

Two guards, both stated as constants: a ray whose hit is more than 0.9 face
widths from its landmark is discarded (on long hair a ray past the jaw leaves the
head and lands on hair over a shoulder), and segments with a clipped endpoint are
skipped (there the polygon is the edge of the parsing crop, not a hairline).

### 4. One solve, in the node that already exists

The head handles go into `WarpRenderNode`'s **single** `ControlPoints`, not a
second warp pass — two passes are two full-frame resamples, which is the same
argument that node already makes for solving every face at once.

The two groups compose instead of fighting. For a landmark both touch, the head
field is applied on top of the reshaped destination, evaluated at the
*undeformed* point:

```
destination(i) = FaceReshape.destination(i) + Field.displacement(at: landmarks[i])
```

so there is exactly one handle per landmark, the contributions stay linear and
independent, and the composition order does not change the answer. With the head
sliders at 0, `HeadReshape.handles` returns `FaceReshape`'s output verbatim — a
strict superset, asserted element by element, not "approximately the same".

Ring and hair points closer than 0.05 face widths to a mesh handle are dropped
(`minSeparationFraction`). Two handles a few pixels apart with different
destinations is an ill-conditioned solve *and* a visible shear, and at the
hairline that is exactly what `volume` creates. The silhouette gives way there,
which is also the right picture: hair volume grows at the crown, not out of the
forehead. A taste parameter, stated rather than hidden. Measured: a median of 20
of 96 resampled points dropped this way per frame.

### 5. The flag is read per render, and off is bit-exact

`RPEngineFeatureFlags.headSliders` is checked inside `isActive` and
`headControlPoints`, never in `init` — the `contourSliders`/`ColorRenderNode`
arrangement (ADR-0020). With it off, the node builds, activates and solves
exactly the handles it solved before this ADR: `HeadReshapeRenderTests
.flagOffIsBitExactTheOldRender` renders the same picture from an `EditState`
carrying head sliders at full and from one that has never heard of them and
compares the buffers with `==`, not with a PSNR.

`enableHeadRenderGraph()` sets `headSliders` **plus** the "Mặt" group's
`warpSliders` and `mlsMeshWarp`, because the head handles are solved by that
node. `disableHeadRenderGraph()` clears `headSliders` and nothing else — the
asymmetry `disableContourRenderGraph()` established, so this group cannot switch
another one off behind its back.

`RenderMaskRequirements.forEnabledGroups()` asks for `.hair` on `headSliders`,
not on `warpSliders`: the "Mặt" sliders are landmarks only and must not start
paying 4.1 ms per face to feather a mask nothing reads.

### 6. The silhouette is cached by **value**

The trace costs 1.37 ms (median, Release, M1 Pro, 512² mask) and the whole handle
build 1.50 ms, against a 2048 px preview render of 0.83 ms. A slider drag changes
the sliders and nothing else, so recomputing an identical silhouette 60 times a
second would cost nearly twice the render. `isActive` needs the same answer (see
the hat case below), so it shares the cache rather than tracing on its own.

`HeadReshape.SilhouetteCache` memoises it, keyed on **full value equality** of the
mask and the mesh — `RenderMask` is `Equatable` and comparing 262 kB of `values`
is a memcmp at ~20 µs, three orders of magnitude below the trace. No hash, no
identity token, no buffer address: a cache that serves a stale hairline would warp
this photo with the previous photo's head, and nothing that can collide is
acceptable for that. Measured: **1.50 ms cold → 0.036 ms warm**, and
`theSilhouetteIsTracedOncePerMask` pins both halves (ten drags, one trace; one
changed byte, a second trace).

## Measurements

`Research/bench/p6-head-reshape-macos.json` and `-ios-simulator.json`, produced
by `Scripts/bench-head-reshape.sh`; `Research/bench/p6-head-hairline-reference.json`
by `Research/bench/hair-boundary-reference.py`. Mac / Simulator numbers, as for
every other node in this project.

| claim | number (macOS, Release, M1 Pro) |
|---|---|
| trace vs the NumPy reference | **0 px** deviation, 11/11 real frames, 7/7 synthetic shapes |
| golden PSNR vs the `Double` CPU rasteriser (DSC05123, real hair mask) | **69.5 dB** (bar: 45) |
| GPU lattice vs the `Double` CPU solve | 0.0032 px preview / 0.0060 px export |
| landmark round trip, export (grid 129) | 0.0080 x face width |
| landmark round trip, preview (grid 65) | **0.023 x face width** — see below |
| trace, 512² hair mask | 1.37 ms median, 1.51 ms p95 |
| handle build, cold → cached | 1.50 ms → 0.036 ms |
| 2048 px preview, "Mặt" only → "Mặt" + "Đầu" | 0.825 → 0.912 ms wall (+0.047 ms GPU) |
| 24 MP export, "Mặt" only → "Mặt" + "Đầu" | 2.75 → 2.92 ms wall (bar: 8 s) |
| control points | 150 mesh + 9 ring + 71 hair + 16 border (DSC05123) |
| derotation sign of the test fixture's affine | IoU 0.663 vs 0.634 flipped; the chosen sign wins 11/11 |

The iOS Simulator run agrees where it can: 69.4 dB golden, 0 px against the
reference, the same round-trip figures (the geometry is CPU and identical), trace
2.51 ms, 2048 px preview 2.11 ms wall, 24 MP 4.81 ms wall. Read `wall_*_ms` and
ignore `gpu_median_ms` there, per ADR-0009. **Neither is a real device**, the
limitation every bench in this project records.

## What is honestly wrong with this

Three things, none of them hidden, all of them measured.

### The preview and the export of a head edit are not the same shape

The worst landmark round trip is **2.3 % of face width at preview quality**,
against the "Mặt" group's < 1 %. This is not a bug and it is not a bound chosen
to pass: MLS round-trip error on a fixed lattice grows with the displacement per
cell, and this group's displacements are an order of magnitude larger than the
reshape sliders' (0.17 x face width at the crown against ~0.02). The export grid
(129) halves the cell and lands back at 0.8 %.

Consequence: on a 600 px face, a head slider's preview can put the hairline ~14 px
from where the export will. Fixing it means either a denser preview lattice for
head edits (a change to `RenderQuality.meshGrid`, which the "Mặt" group shares and
ADR-0007 fixed on its own measurement) or accepting it. **This ADR accepts it and
records it**; the choice belongs to whoever wires the UI, with this number in hand.

> **Signed off 2026-09-21: accepted, by the user, explicitly.** See
> "UI (2026-09-21) → The preview wobble is accepted" below. The three sliders
> drag live like every other slider in the app — no denser lattice, no debounce,
> no commit-on-release.

### The parsing crop cuts the silhouette on 10 of 11 real frames

The BiSeNet crop is 1.87 x the face box, which is not a head-and-hair crop.
Measured over the 11 a6300 frames: **10 of 11** have hair running off the crop
(all ten at the bottom, where hair reaches the shoulders) and **3 of 11** are cut
across the *crown* — the exact part "Thu nhỏ đầu" and "Phồng tóc" move most. A
median of 22 % of the 96 resampled boundary points are clipped, up to 39 %.

Clipped points are dropped, so the silhouette is anchored only where it was
actually seen and the warp interpolates the rest. That is the honest behaviour,
but it means the group's accuracy on a real head is bounded by a crop chosen for
face parsing, not by anything measured here. The fix is a wider crop for the hair
class (a change in RPVision's `CropRegion`, and a re-measurement of ADR-0006's
IoU), which is deliberately **not** in this round.

Its visible consequence is already in the numbers: the expanded ring gets a median
of **9** points on a real frame against 16 on a synthetic head, and as few as 4
(DSC05259), because rays that hit a clipped segment are discarded.

### A subject in a hat, or with no visible hair, gets nothing

CelebAMask-HQ has a separate `hat` class (18) and `FaceParsingGroup.hair` does not
fold it in. With no usable hair mask — a hat, a shaved head, a parsing failure —
there is no silhouette, and `HeadReshape` returns **no handles at all**: the
sliders do nothing.

`isActive` says so too, so the edit costs nothing — **not even the full-frame
`encodeCopy` that a scheduled-then-empty node would run**. Getting that right
needed a correction after review, and the correction is worth recording because
the first version was wrong in a way no unit test caught. `isActive` originally
asked `masks[.hair] != nil`, i.e. *was a mask attached*. But
`FaceAnalysisRenderBridge` attaches a `.hair` mask to **every** face whose
parsing succeeded, for every requested kind — so in production that key is always
present, and for a hat it is present and entirely below
`HairBoundary.coverageThreshold`. The node was therefore scheduled, found no
silhouette inside `encode`, and fell back to `RenderGraph.encodeCopy`: a real GPU
pass to produce a picture identical to its input. The test that was meant to
cover this used `masks[.hair] = nil`, a shape the app cannot produce, and so
confirmed nothing.

`isActive` now asks the real question — is there a silhouette — through the same
`SilhouetteCache` `encode` uses, so it is not a second trace: the first
`isActive` of a shot pays ~1.4 ms once, and every call after it, active or not,
is a cache hit. `HeadReshapeRenderTests
.aHeadOnlyEditWithoutAUsableSilhouetteIsInactive` builds the mask the bridge
actually produces (present, correctly placed, every byte below the threshold),
checks the node stays inactive and the render bit-exact, and checks that ten
`isActive` calls during a drag trace once. It fails against the old
presence-check, which is what makes it a regression test rather than a claim.

Doing nothing here is deliberate. The alternative — warping the face oval alone —
would slide the face inside a hairline that stays put, which is visibly worse
than doing nothing. But "the slider silently does nothing on some photos" is a
product problem, not just an engine one, and it is the second reason the flag is
off: a UI that shows this group must first decide how it tells the user *why* it
is inert.

## Alternatives rejected

* **`VNContoursRequest`** — wrong input shape, an edge detector rather than a
  region tracer, unspecified vertex positions, and a Vision import in RPEngine.
  Argued in full in `HairBoundary.swift`.
* **A second warp pass for the head** — two full-frame resamples and two chances
  to soften the picture, for a deformation that a single MLS solve expresses
  exactly.
* **Caching the silhouette by hash or buffer identity** — cheaper than value
  equality, and capable of serving the previous photo's hairline. The thing being
  cached is geometry the render is about to trust absolutely.
* **A whole-frame hair mask (a new segmentation)** to escape the parsing crop —
  a new model-conversion project (S1/S2 scale) for a slider group whose maths is
  otherwise free. Recorded as the known ceiling on this group's accuracy instead.
* **Tuning `sizeGain` down** so the preview round trip falls under the "Mặt"
  group's 1 % bound — that is fitting a constant to a test rather than measuring,
  and it would make the group weaker for no reason other than the number.

## Consequences

* `RPEngineFeatureFlags.headSliders` is off. With it off, every number in
  ADR-0007, ADR-0009 … ADR-0021 is untouched **by construction** (the flag is read
  before any head code runs), not by promise.
* `WarpRenderNode` now reads `FaceRenderInput.masks[.hair]`. It is the first
  consumer of that mask kind; the app-side bridge already maps
  `FaceParsingGroup.hair → RenderMaskKind.hair`, so no new plumbing was needed.
* The next steps this group needs before a UI, in order: decide the preview-grid
  question above; decide what the UI says when there is no hair; consider a wider
  parsing crop for the hair class. **The first two are decided below
  (2026-09-21); the third is still open.**

## UI (2026-09-21) — a wired panel, a flag that is still off, and one accepted wobble

No engine *source* file changed for this: it is `SliderPanelLayout` + one rail
entry, plus tests in RPUI and RPEngine. It is the last of the Phase 6 UI-wiring
queue and the third of the three Phase 6.2 groups that had an engine and no
panel, after "Tạo khối" (ADR-0020 §UI) and "Sửa da" (ADR-0021 §UI); it reuses
both of their mechanisms rather than inventing a third.

### A panel of its own, the third over `EditState.SectionKey.face`

`SliderPanelLayout.PanelKey.head` — "Đầu", header "Tạo hình khung đầu", three
rows whose keys come from `HeadSliders.Key.all` and whose ranges come from
`RPCore.Slider`:

| row | key | direction line |
|---|---|---|
| **Thu nhỏ đầu** | `headSize` | cả đầu nhỏ lại — mặt, viền tóc cùng một tỉ lệ |
| **Hẹp đầu** | `headWidth` | hộp sọ hẹp lại từ ngang mắt lên, không đụng hàm / má |
| **Phồng tóc** | `headVolume` | tóc phồng ra phía đỉnh đầu, khuôn mặt giữ nguyên |

The direction lines say what each slider does *and* what it deliberately leaves
alone, because §2's whole argument is that these are not reshape sliders: "Hẹp
đầu" is not "Bóp mặt" (jaw and below) and not "Thái dương" (which pushes the
temples *out*).

Its own panel rather than three more rows under "Hình dáng mặt", for the reason
"Sửa da" got one (ADR-0021 §UI) rather than a layout preference: **a detection
notice disables the group it is attached to**, and this group is the only one on
the `face` namespace that depends on a detection. Sharing a panel would let a
subject in a hat switch off fifteen reshape sliders that never needed a hairline.

### The flag is reported, not obeyed by locking

`RPEngineFeatureFlags.headSliders` is **not** flipped — there is still no number
from a real iPhone, the standing blocker ADR-0018 set and the other two groups
are held to. So the panel takes the `SliderSectionDescriptor.gatedBy` treatment
"Tạo khối" introduced: `PanelFeatureGate.headSliders`, read per render by
`GroupAvailability.blockedReason` ahead of the "no face" check, which draws the
three real rows disabled under one line —

> Đầu đang tắt trong bản dựng này — chưa đo tốc độ trên iPhone thật.

The rail item is **not** locked. A locked item with a working three-slider panel
behind it is the orphan `RailLayoutTests.noWorkingSectionIsOrphaned` exists to
catch, and this panel is exactly what a later flag flip has to light up with no
further wiring.

### "What does the UI say when there is no hair" — answered

The second open question above. The answer is the notice the engine already
publishes: `WarpRenderNode.detectionNotice(for:)` → `RenderReport.notices["warp"]`
→ `SliderSectionDescriptor.notifiesFromNodeNamed: "warp"` → the panel's own
`info.circle` line, identical in treatment to "no face detected":

> Không phát hiện được viền tóc.

So the hat / shaved-head / parsing-miss case from §"A subject in a hat" is no
longer "the slider silently does nothing"; it is a stated fact that disappears on
its own when the user opens a photo where the trace works. The answer order in
the panel is **build → face → node**, the same three steps "Sửa da" pinned.

**The notice is scoped to this panel, and that is the load-bearing part.**
`"warp"` is also "Hình dáng mặt"'s node, and "Hình dáng mặt" names no node at
all, so the fifteen reshape sliders stay enabled on a frame with no traceable
hairline — they are landmarks only and work perfectly there. This is the same
isolation rule ADR-0021 §UI established for `"skin"` / "Mịn da", one node over.
`DetectionNoticeWiringTests.theShippedTableNamesTwoNodes` and
`RailLayoutTests.headOpensAPanelScopedToItsOwnNotice` assert both halves.

Driven end to end on a **real a6300 frame** rather than on a compile check:
`DetectionNoticeTests.aRealFrameWithNoHairPublishesTheNoticeThroughTheGraph`
takes the frame's real 512² BiSeNet label map, reads the `.hair` mask out of
**class 18 (`hat`)** — the class the model fills for a hat and leaves empty on
these bare-headed subjects, so the buffer is a real parsing output of an empty
class, present, correctly sized and carrying the real derotated affine — and asks
`RenderGraph.standard` what it would tell the user. It answers
`["warp": "Không phát hiện được viền tóc."]`. The same frame's real class-17
plane is the control (no notice), and the same failing frame with the sliders
back at 0 is the second control (no notice: nothing was asked for).

### The preview wobble is accepted

The first open question above — the 2.3 % preview round trip against "Mặt"'s
< 1 % — was put to the user on 2026-09-21 and **the decision is to accept it and
ship**. The three sliders are wired exactly like the fifteen reshape ones next to
them: live drag, every frame, no debounce, no commit-on-release, and no per-group
override of `RenderQuality.meshGrid`.

The reasoning, recorded plainly because this ADR flagged it as needing sign-off
and this is that sign-off:

* **The export is not affected.** At the export grid (129) the round trip is
  0.8 % of face width, inside the bar every other group meets. What is imprecise
  is the *preview*, and only while a head slider is being dragged — the picture
  the user keeps is accurate.
* **The visible size of it is known and was stated**: up to ~14 px of hairline on
  a 600 px face, i.e. the preview shows the edit slightly off from where the
  export will land. It is a wobble, not a different edit — direction, magnitude
  and shape are right.
* **Both fixes cost more than the defect.** A denser preview lattice means
  changing `RenderQuality.meshGrid`, which the "Mặt" group shares and ADR-0007
  fixed on its own measurement, so it needs a new measurement round for two
  groups plus a re-check of every warp number in ADR-0007/0010. A head-only
  debounce or commit-on-release means one slider group in the app behaving
  differently from every other under the finger — a UX inconsistency traded for a
  preview-only error.
* **Speed to ship won**, deliberately and with the number in hand rather than by
  not looking at it. If it turns out to bother someone in use, the denser-lattice
  path is still open and unchanged.

This is a user decision, not an engineering conclusion: nothing measured here got
better.

### What this round did not do

* `RPEngineFeatureFlags.headSliders` stays off. Every number in this ADR and in
  ADR-0007 … ADR-0021 is untouched, by construction.
* No engine code changed: no node, no kernel, no constant, no `EditState` key.
  `HeadSliders`, `HairBoundary`, `HeadReshape` and `WarpRenderNode` are exactly
  as the engine round left them.
* The parsing crop is still 1.87 × the face box, so §"The parsing crop cuts the
  silhouette" stands as the group's known accuracy ceiling — the one open item of
  the three.

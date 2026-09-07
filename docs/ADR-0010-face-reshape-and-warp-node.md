# ADR-0010 — The "Mặt" (face reshape) slider group and `WarpRenderNode`

Status: accepted — 2026-09-06
Scope: Phase 2 of `docs/PLAN.md` §3 — `RenderStage.warp` on the `RenderGraph`
ADR-0009 built, plus the second of its four slider groups. Mắt-Răng / Color, the
realtime `MTKView` preview and multi-face canvas selection are **not** in this ADR.

## Context

Spike S3 (`docs/ADR-0007`) verified `MLSMeshWarp` — an MLS grid solve plus a mesh
draw — against a `Double` CPU reference and left it behind a default-off flag,
driven by a two-slider harness (`FaceReshape` in `Research/spikes/S3-…`) that
existed to produce a *plausible* deformation for a benchmark, not a product.
ADR-0009 built the graph the kernel plugs into and shipped the "Da" group at
`RenderStage.skin`. `FaceAnalyzer` (`docs/ADR-0008`) supplies the 478-point mesh,
and `FaceRenderInput.landmarks` already carries it into RPEngine.

What was missing is the entire middle: **which landmarks does "Gò má" move, how
far, and in which direction** — fifteen sliders' worth, in a form that survives a
preset moving between images.

## Decision — the slider maths is a pure function, tested without a GPU

`FaceReshape` (`Packages/RPEngine/Sources/RPEngine/Render/FaceReshape.swift`)
takes `[CGPoint]` + `faceWidth` + `FaceSliders` and returns
`MLSDeformation.ControlPoints`. No Metal, no state. Everything that can be wrong
about a reshape slider — the index list, the magnitude, the direction, the
scaling rule — is decided there and asserted in `FaceReshapeTests` (15 tests, no
GPU, no fixtures) and `FaceMeshGeometryTests` (6 tests, on the 11 real a6300
meshes).

`WarpRenderNode` is thin by comparison: it calls `FaceReshape`, picks the grid
from `RenderQuality`, and hands both to `MLSMeshWarp`.

## Decision — a face-local frame, not image x/y

`FaceMeshFrame` puts the origin at the forehead centre (`p[10]`), `down` along
`p[10] → p[152]` and `lateral` perpendicular to it. Two reasons, at two very
different levels of evidence:

* **Roll — verified.** A tilted head slims along *its* width for free, and
  `FaceReshapeTests.reshapeFollowsTheHeadRoll` asserts it: rotate the whole mesh
  by 0.4 rad and every handle's displacement *magnitude* is unchanged to
  `1e-9 × faceWidth`, with the same index list.
* **Yaw — observed, not validated.** On a three-quarter view the projected
  midline is off-centre, and a frame built on `p[10] → p[152]` follows it: the
  subject's left cheek takes **0.480…0.683** of the face width over the 11 a6300
  frames, against 0.5 for a frontal face, so "pull toward the midline" moves the
  far cheek further than the near one while a frame built on the image's vertical
  would move them equally. **Whether that amount is geometrically right is not
  measured** — that needs a ground-truth head pose this project does not have,
  and it is out of scope for "Phase 2 cốt lõi". What is measured is that the
  frame responds to pose at all.

  An earlier draft of this ADR cited a different number as proof: that on
  `DSC05123` the two cheeks measure `+0.67` and `−0.33 × faceWidth`, "summing to
  exactly 1". That is not evidence, and review round 3 was right to call it a
  "measure before ship" violation. `u(454) − u(234)` is the projection of the
  vector between the two cheek landmarks onto `lateral`, and `faceWidth` is the
  Euclidean distance between the same two points; the two coincide whenever the
  cheeks sit at about the same `t`, which is anatomy, not yaw handling. Measured
  now instead of asserted: the sum is 1 to within **1.6e-3 on all 11 frames**
  (worst `|Δt|` between the cheeks 0.053), *including* the near-frontal
  `DSC05259` at `+0.4998 / −0.5000`, where there is no asymmetry to compensate
  for. A frame with no yaw compensation at all would score the same.
  `FaceMeshGeometryTests.cheekSplitIsAnAnatomyIdentity` files both numbers and
  says why they prove nothing.

Positions along the frame are `t` (fraction of the forehead→chin distance) and
`u` (pixels across, compared against `faceWidth`). No slider carries a `t`
constant: every band is anchored to a *landmark-derived* level — `tEyeLine`,
`tCheekLine`, `tMouthLine`, `tNasion`, `tNoseTip`, `tNoseBase` — so a long face
and a round one get the same anatomy. Measured spread over the 11 frames: eye
line 0.295–0.320, cheek line 0.404–0.463, mouth line 0.669–0.736.

## Decision — the mapping

Six outline sliders share the 36-point `FACEMESH_FACE_OVAL`; what separates them
is where along `t` their weight lives (raised cosine for a band, Hermite ramp for
an end).

| slider | landmarks | weight | at 100 |
|---|---|---|---|
| **Bóp mặt** `slim` | face oval | `ramp(t, eyeLine → chin)²` | 0.045 × faceWidth toward the midline |
| **Gò má** `cheekbone` | face oval | `band(t, cheekLine, ±0.18)` | 0.035 × faceWidth in |
| **Hàm** `jaw` | face oval | `band(t, cheekLine + 0.55·(1−cheekLine), ±0.22)` | 0.050 × faceWidth in |
| **Cằm** `chin` | face oval | `ramp(t, mouthLine + 0.35·(1−mouthLine) → 1)` | 0.045 × faceWidth **up** the axis |
| **Trán** `forehead` | face oval | `1 − ramp(t, 0 → 0.55·eyeLine)` | 0.045 × faceWidth **down** the axis |
| **Thái dương** `temple` | face oval | `band(t, 0.60·eyeLine, capped before cheekLine)` | 0.030 × faceWidth **out** |
| **Mũi thu nhỏ** `noseShrink` | 32 nose points | uniform | scale 0.88 about the nose centroid |
| **Mũi sống** `noseBridge` | 32 nose points | `1 − ramp(t, nasion → noseTip)` | 0.020 × faceWidth in |
| **Mũi đầu** `noseTip` | 32 nose points | `ramp(t, ½(nasion+tip) → noseBase)` | 0.020 up + 0.012 in, × faceWidth |
| **Mắt to** `eyeSize` | 2 × 16 ring + 5 iris | uniform | scale 1.18 about each eye's centre |
| **Mắt khoảng cách** `eyeSpacing` | same | uniform | 0.030 × faceWidth apart |
| **Mắt nghiêng** `eyeTilt` | same | uniform | 4.0° about each eye's centre, outer corner up |
| **Miệng to** `mouthSize` | outer + inner lip rings | uniform | scale 1.10 about the mouth centre |
| **Miệng cười** `mouthSmile` | outer + inner lip rings | `(u−ū)/halfWidth)²` | 0.030 up + 0.010 out, × faceWidth |
| **Môi đầy** `lipFullness` | outer ring moves, **inner pinned** | proportional to axial offset | outer ring's height × 1.22 |

Three details are load-bearing:

* **A slider contributes its whole region as handles**, including the points its
  weight curve leaves at zero. Those identity handles are what make "Môi đầy"
  thicken the lip without opening the mouth and what stops "Bóp mặt" dragging the
  temples in. Spike S3's harness used the same construction.
* **Displacements accumulate**, in `FaceSliders.values`' declaration order, and
  handles are emitted sorted by index. Both orders are part of the contract: a
  sum of floats is not associative, and one `EditState` has to mean one mesh.
* **A lateral move is capped at half the point's own distance from the midline**
  (`FaceMeshFrame.towardMidline`), and is scaled to zero for points within
  `0.15 × faceWidth` of it. Without the second rule the chin tip and the forehead
  centre (`u ≈ 0`) get pushed sideways by whichever side landmark noise puts them
  on, which reads as a wobble rather than a slim.

### The temple band is derived, not tuned

A fixed half-width of 0.25 reached `t = 0.398` on `DSC05123` against a cheek line
at 0.422 — inside the raised cosine's tail, so "Thái dương" moved landmarks 234
and 454 by 0.06 px. Those two points *define* `faceWidth`, i.e. the denominator
of every other slider. `FaceReshape.templeBandHalfWidth` derives the width from
`tCheekLine` so the coupling cannot exist, rather than picking a constant that
happens to avoid it on this set of faces.

## Decision — the index lists are measured, not remembered

`FaceMesh` holds the MediaPipe lists. The oval and the two eye rings come from
spike S3's `FaceReshape`, which already checked them geometrically. The **lip**
and **nose** lists were chosen against the real meshes rather than from memory,
by dumping `(t, u/faceWidth)` for every candidate index over the 11 a6300 frames:

* the inner lip ring is inside the outer ring at **20/20 points on 11/11 frames**;
* the nose list is 32 points spanning `t = 0.271…0.600`, with bridge and
  columella within `0.079 × faceWidth` of the midline and the two alae strictly
  on opposite sides of it on every frame. Two candidate *pairs* (45/275,
  237/457) were **dropped**: `FaceReshape` reads `sign(u)` to decide which way to
  push an ala, so a point whose side is not fixed across poses is unusable.

  The original rejection was done in a scratch dump that was not kept, so review
  round 3 asked for it to be either committed or softened. It is re-measured
  instead, by `FaceMeshGeometryTests.rejectedNoseCandidatesFailTheSideTest`, and
  the corrected numbers over the 11 real meshes are:

  | index | measured `u / faceWidth` | verdict |
  |---|---|---|
  | 45 | −0.113 … −0.033 | fine on its own |
  | **275** | **−0.033 … +0.052** | changes side (negative on 4 of 11 frames) |
  | 237 | −0.130 … −0.060 | fine on its own |
  | **457** | +0.0035 … +0.078 | never crosses, but comes to `0.0035 × faceWidth` of the midline — **5× closer than the worst shipped ala point** (0.0175) |

  So the earlier phrasing ("their measured `u` ranges overlapped zero") was true
  of 275 and wrong of 457: 457 is disqualified for being a midline point within
  landmark noise, not for crossing. Either way the *pair* is unusable, which is
  what mattered — but the ADR now says what was actually measured.

A region rule was tried first (a `t` band plus a lateral limit, minus the known
rings) and rejected: at the lateral limit that keeps the real alae it swept in
60–110 cheek points.

`FaceMeshGeometryTests` re-runs all of it and `WarpBenchTests` files the numbers,
because **a wrong index still produces a warp** — of the wrong part of the face —
with every other number in this project still green.

### Iris points are assigned by distance

MediaPipe's "left iris" is the image's left, i.e. the subject's right. Getting it
backwards would grow one eye and shrink the other by the iris's contribution and
still look plausible. `FaceReshape.eyeGroups` assigns each of 468…477 to the
nearer eye centroid; `SyntheticFaceMesh` lays them out in the opposite order on
purpose so the test would fail if the code trusted the naming.

The same applies to `eyeTilt`'s direction: the sign that lifts the **outer**
corner is derived per face by rotating that corner and checking which way it went
along the face axis, not hard-coded per eye.

## Decision — one-directional sliders, stated

Several of these are bidirectional elsewhere ("eye distance" wider *or*
narrower). The project's fixed decision is `0–100, default 0`, so each slider is
the one direction a retoucher reaches for and its doc comment names it: **Cằm**
shortens, **Trán** lowers the hairline, **Thái dương** fills (pushes out) while
`slim` narrows lower down, **Mắt khoảng cách** moves the eyes apart. A signed
−100…100 range would need no change to `FaceReshape` — every displacement it
builds is already linear in the slider value — but it is a plan and UI decision,
not this node's.

`Mũi sống` is named for what a 2D warp can do: **narrow** a bridge. *Raising* one
is a shading change (dodge the bridge, burn the sides) and belongs to a later
group.

## Decision — magnitudes are relative to the face, and this is a test

Every magnitude is either `fraction × faceWidth` or a dimensionless gain on a
landmark-derived distance. Neither carries a pixel constant, so

```
f(k · landmarks, k · faceWidth) == k · f(landmarks, faceWidth)
```

exactly. `FaceReshapeTests.displacementsScaleWithTheFace` asserts it at
k = 0.25 / 1 / 3.7 / 11 to `1e-9 × faceWidth`. That equation *is* docs/PLAN.md
§2's "reshape lưu delta tương đối theo face width": it is what lets a preset move
between images and what makes a 2048 px preview and a 24 MP export the same
shape. A single pixel constant anywhere in `FaceReshape` breaks it and nothing
else in the suite would notice.

The magnitudes themselves are **not tuned**. They are plausible retouch amounts
of the same order as spike S3's `maxSlimFraction = 0.040`; what looks right needs
a human comparing renders, which is a later task with a UI. What is measured is
that they behave — `Research/bench/p2-warp-*.json` `handles.per_slider_at_100`
records what each slider actually moves on the real meshes, and the largest is
`jaw` at 0.0500 × faceWidth.

## Decision — no new Metal, and one `MLSMeshWarp` per destination format

`rp_mls_grid`, `rp_warp_vertex` and `rp_warp_fragment` are already in
`Spike/MetalSources/Shaders.metal`. This node adds **no third `.metal` file**:
`MetalContext.shaderSources` still has two entries and the library is still
compiled exactly once per process (ADR-0009).

`MLSMeshWarp` bakes its `MTLRenderPipelineState`'s colour-attachment format in at
construction, and the graph's destination is `rgba16Float` in production and
`rgba32Float` in `RenderGraph.renderPixels`. `WarpRenderNode` therefore keeps one
`MLSMeshWarp` per destination format, both built by `prewarm()`. That is two
pipeline-state objects and **no change to the spike class**; the alternative —
making `encodeDraw` throw and look a pipeline up per frame — puts a pipeline
compile on the interaction path, which is the thing `prewarm()` exists to prevent.

`WarpRenderNode` is also the first node whose destination must carry
`.renderTarget`: its second pass is a render pass, not a compute one.
`RenderGraph`'s intermediate pool and `renderPixels`' destination already declare
it.

## Decision — one MLS solve for every face

All faces' handles go into one `ControlPoints`. MLS weights as `1/d⁴` (α = 2), so
a handle on one face is worth `(d₂/d₁)⁴` less at the other, and each face
contributes its own identity handles. Two separate warp passes would mean two
full-frame resamples and two chances to soften the picture.

## Decision — `RenderGraph.standard` registers the groups whose flags are on

It used to build `SkinRenderNode` unconditionally and throw if `.skinSliders` was
off. With two independently shippable groups that is wrong: a caller who enabled
only the warp path would get a throw about the skin one. `standard` now appends
each node only if its own flag is set; `RenderReport.nodes` says which ran and
`activeNodes(for:)` says which would. The same argument, applied one level up,
is why there is no longer an umbrella flag on the graph itself — see "default-off
flags" below.

## Measurements

`Research/bench/p2-warp-macos.json`, `Research/bench/p2-warp-ios-simulator.json`,
written by `Scripts/bench-warp.sh` from `RPEngineTests/WarpBenchTests`.

### Why three accuracy levels and not one PSNR

The Da group is a per-pixel filter, so one PSNR against a `Double` CPU
implementation says everything. A warp is *geometric*: an output image can be
pixel-perfect against a reference that solved the wrong deformation, and a
deformation can be exactly right while the rasteriser puts it on screen upside
down. So:

| level | what it compares | covers |
|---|---|---|
| 1 | GPU `rp_mls_grid` vs `MLSDeformation.grid` (`Double`), in px | the solve — spike S3's `mls_gpu_vs_cpu.json` comparison, re-run on production handles |
| 2 | bilinear lattice interpolation at each moved handle vs the `q_i` the slider asked for | the **grid density** — the quantity ADR-0007 fixed at 65/129 |
| 3 | rendered image vs `WarpReference` (`Double` CPU scanline raster of the same mesh), PSNR | triangulation, clip-space mapping, y flip, uv assignment, sampler |

Level 3's GPU side is Metal's hardware rasteriser, so the reference is not a
transcription of it; only the triangle list and the sampler's rules are shared,
and both are read out of `Shaders.metal`'s stated behaviour.

### Results — 11 real a6300 meshes, all fifteen sliders at mid values

| | preview (grid 65) | export (grid 129) |
|---|---|---|
| level 1, GPU vs `Double` grid | **1.52e-3 px** | **3.29e-3 px** |
| level 2, worst landmark round trip | 3.55 px = **0.0067 × faceWidth** | 2.62 px = **0.0043 × faceWidth** |
| level 2, mean landmark round trip | 0.50 px | 0.20 px |

Level 1 against spike S3's run (1.11e-3 px preview / 3.34e-3 px export, on 84
handles from the two-slider harness), stated as a delta rather than as "about
the same":

| | S3, 84 handles | production, 150 handles | change |
|---|---|---|---|
| preview, grid 65 | 1.11e-3 px | **1.52e-3 px** | **+37%** |
| export, grid 129 | 3.34e-3 px | **3.29e-3 px** | −1.5% |

The preview number moved by over a third and the ADR should say so. The likely
cause is the handle count: `rp_mls_grid` accumulates one weighted term per handle
in float32, so 1.79× the handles is 1.79× the terms in the same accumulator, and
the export grid — where the per-vertex error is dominated by the larger
coordinates, not by the summation — barely moves. That is a hypothesis, not a
measurement; nothing here isolates it. **No shipping risk either way**: the test
bound is 0.01 px (the same bound `MLSWarpTests` uses), so preview is 6.6× under
it and export 3.0× under it, and both are three orders of magnitude below the
lattice error that level 2 measures.

Level 2 is worth reading carefully. The worst case is `DSC05172`, whose face
fills the frame (`faceWidth` 1294 px in a 2048 px preview, i.e. a 32 px mesh cell
against a 1294 px face). Going from 65 to 129 vertices only improves it 1.4×, not
the 4× a smooth field would give — because with α = 2 the deformation varies
sharply within a few pixels of a handle and no practical lattice resolves that.
0.0067 × faceWidth is ~4 px on a 600 px face, i.e. the landmark ends up 0.67% of
a face width from where the slider asked — well under the amount the slider moved
it (the largest single-slider displacement is 0.050 × faceWidth). **It is a
property of the lattice, not of this node**, and it is the number to revisit if
the warp ever needs to be handle-exact.

Level 3, on the real `DSC05123` frame at 640² with all fifteen sliders (150
handles, max displacement 6.58 px):

| | macOS | iOS Simulator |
|---|---|---|
| rendered PSNR vs `WarpReference` | **82.7 dB** | 82.6 dB |
| max abs difference | 1.8e-3 | 1.9e-3 |
| max change vs the unwarped source | 0.75 | 0.75 |

docs/PLAN.md's bar is 45 dB. The last row is there so a node that did nothing
could not score infinity.

### Geometry, over the 11 real meshes

| check | measured |
|---|---|
| oval encloses the other landmarks | ≥ 0.941 |
| eye separation / faceWidth | 0.434 … 0.461 |
| nose width / faceWidth | 0.261 … 0.337 |
| nose `t` span | 0.271 … 0.600 |
| bridge + columella off-midline | ≤ 0.079 × faceWidth |
| alae and eyes straddle the midline | true, 11/11 |
| inner lip ring inside the outer | true, 11/11 (20/20 points) |
| iris points inside their eye | true, 11/11 (10/10 points) |
| the four regions are disjoint | true |

### Speed — real a6300 frame `DSC05123`, Release, wall-clock median

The 24 MP figures use the **real** 24 MP frame with the real mesh moved into it
by `manifest.json`'s `crop_rect` (the 2691² crop was cut at native resolution
with no resampling), so the handles are not an invented rescale.

| | 2048² preview, grid 65 | 24 MP export, grid 129 |
|---|---|---|
| **M1 Pro**, all fifteen sliders | **0.88 ms → 1142 fps** | **2.79 ms** |
| M1 Pro, Bóp mặt only | 0.72 ms → 1380 fps | 2.57 ms |
| M1 Pro, every slider at 0 (passthrough copy) | 0.57 ms | 2.33 ms |
| **iOS Simulator**, all fifteen | 2.68 ms → 374 fps | 4.21 ms |
| node scratch | **166 kB** | **659 kB** |

The node is cheap in both time and memory: a solve of 166 control points over
65² or 129² vertices plus one full-screen textured mesh draw. Its scratch is the
lattice only — 659 kB at 24 MP, against `SkinRenderNode`'s 552 MB — because
nothing here is a full-resolution intermediate.

Both plan bars are cleared by a wide margin at these sizes — but **on a Mac**. No
iPhone is attached, the same limitation S1, S2, S3, `FaceAnalyzer` and the Da
group all record; `is_real_device` in the JSON says which environment produced
the number. Read `wall_*_ms` in the Simulator file and ignore `gpu_median_ms`
(ADR-0009).

## Decision — default-off flags, and the umbrella flag is removed

`RPEngineFeatureFlags.warpSliders` gates the node, separate from `.skinSliders`,
so either group can ship while the other is off. `WarpRenderNode` owns an
`MLSMeshWarp`, whose own `.mlsMeshWarp` gate is **not** bypassed;
`enableWarpRenderGraph()` / `disableWarpRenderGraph()` set `warpSliders +
mlsMeshWarp`, mirroring `enableSkinRenderGraph()`'s `skinSliders + guidedFilter`.

The first version of this shipped with those helpers also setting an umbrella
`RPEngineFeatureFlags.renderGraph`, which `RenderGraph.init` gated on. Review
round 3 found that this made the two groups anything but independent:

```
enableSkinRenderGraph()    // renderGraph = true, skinSliders = true
enableWarpRenderGraph()    // renderGraph = true (already), warpSliders = true
disableWarpRenderGraph()   // renderGraph = false  ← and the Da group is dead
```

`RenderGraph.standard()` then threw `RPEngineFeatureDisabled("renderGraph")` with
`skinSliders` still `true`. No test walked that ordering, so the suite was green.

**The flag is deleted rather than refcounted.** Tracking "how many groups are
active" behind the same bit would only have fixed the path through these two
helpers: a caller who set `skinSliders = true` directly would still have been
switched off by an unrelated group's `disable…`, because the hazard is *two
independent switches sharing one stored bit*, not the helpers. The alternative —
making `renderGraph` a computed `skinSliders || warpSliders` — removes the
desync but leaves a gate that asks the wrong question (`RenderGraph(context:,
nodes: [someFutureNode])` would then depend on whether the *Da* group is on).

What has to be gated is the measured algorithm, and each of those already lives
in a node with its own flag. `RenderGraph` with no registered node is a
stage-ordered list plus one copy pass whose behaviour is itself asserted
bit-exact (`RenderGraphTests.emptyEditStateIsPassthrough`,
`noGroupFlagMeansAnEmptyGraph`). So `RenderGraph.init` is now non-throwing and
unconditional, `standard(context:)` with every group off returns an **empty graph
that copies the picture through** instead of throwing, and each group's
`disable…` touches only its own two flags.

`RenderGraphTests.disablingOneGroupLeavesTheOtherRunning` walks exactly the
ordering above in both directions and checks the surviving group's node still
registers. Re-introducing the shared bit fails it with the original error
message; that was confirmed by putting the old code back and running it.

**docs/PLAN.md correction:** the Phase 2 "Da" bullet says the group ships behind
`RPEngineFeatureFlags.renderGraph` + `.skinSliders` (+ `.guidedFilter`). The
first of those no longer exists — the Da group is behind `.skinSliders` +
`.guidedFilter`, the Mặt group behind `.warpSliders` + `.mlsMeshWarp`.

## Known limitations, stated rather than hidden

* **Nothing here is tuned for taste.** Every magnitude constant is a plausible
  retouch amount, and the first thing a UI task should do is put them in front of
  a person.
* **α = 2 is inherited, not measured.** ADR-0007 already flagged it: the paper
  uses 1, face implementations commonly use 2, and which one *looks* right needs
  a human. It is the main lever on level 2's round-trip error.
* **A warp resamples the whole frame.** Where the deformation is the identity the
  bilinear sample lands on a texel centre and is lossless (spike S3 measured
  identity-warp PSNR > 60 dB), but MLS's far field is only asymptotically the
  identity: with `lipFullness = 100` on the 640² fixture the deformation is
  4.42 px at the lip and 0.17 px worst beyond 1.5 × faceWidth from the mouth.
  Locality is asserted on the deformation, not on pixel deltas, because a
  quarter-pixel move across an eyelash is a large pixel delta and a property of
  the photograph rather than of the warp.
* **No node yet handles occlusion or the frame edge.** A face near the image
  border is pinned by the border anchors, which stiffens the deformation there.
  Measured, not fixed: it is the reason `borderAnchorsPerEdge` is a named
  constant.

## Alternatives rejected

* **A geometric region rule for the nose** (t band + lateral limit, minus the
  known rings). At the limit that keeps the real alae it swept in 60–110 cheek
  points; the curated 32-point list is checked against the same measurements.
* **Making `MLSMeshWarp.encodeDraw` throw and cache pipelines by format.** It
  would put a pipeline compile on the interaction path and change a spike API the
  `Research/` harness calls. Two `MLSMeshWarp` instances cost two pipeline-state
  objects and touch nothing.
* **One warp pass per face.** Two full-frame resamples, two chances to soften.
* **Hard-coding `eyeTilt`'s sign per eye and the iris rings by name.** Both are
  right for exactly one handedness of the coordinate system and one reading of
  "left"; both are derived instead.
* **Asserting locality by counting pixels over a threshold.** 29% of the pixels
  that changed by more than 0.02 with `lipFullness = 100` were nowhere near the
  mouth — all of them sub-pixel moves across high-contrast detail. The energy
  ratio (near mean 0.0485 vs far mean 0.00026, i.e. 188×) and the deformation
  itself say what was meant.

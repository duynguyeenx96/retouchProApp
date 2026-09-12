# ADR-0019 — "Cọ mask thủ công": the hand-painted mask, its storage, and the shared gate slot

Status: accepted — 2026-09-13
Scope: Phase 6 §6.1, shared infrastructure. **Engine + storage this round**: the
brush, its rasteriser, the PNG-in-the-bundle storage and one gated node
(`SkinRenderNode`). There is no UI yet — nothing in RPUI captures a touch, and
`RPEngineFeatureFlags.manualMask` ships **off**.

## Context

§6.1 names the manual mask brush as the prerequisite for every future "chế độ
Thủ công" tool and for the brush heal/clone in Phase 5's acne removal. The plan
settled most of it in advance, and this ADR records the decisions it did *not*
settle, plus the one it explicitly deferred to whoever built the brush: the
shape of the `RenderRequest` mask slot that "Khoá nền" (ADR-0018) stopped short
of adding, so that the two features would share one slot rather than add one
each.

## Decision

### 1. Strokes are plain value types, not PencilKit

Settled by the plan and repeated here because it is the kind of thing that gets
re-litigated: a stroke is `BrushStroke` — radius, hardness, flow, mode and a
`[BrushPoint]` of `(location, pressure)`. Not `PKStroke`, not `PKCanvasView`.
Apple's own documentation says mutating a `PKStroke` breaks `UndoManager`, and a
canvas that owns the ink is the wrong object for a mask that the render graph
owns. RPUI will capture raw `UITouch` / `NSEvent` and hand points in.

`location` is in **mask pixels**, y down — the same space the coverage texture
is in. Converting from view points is the UI's job, because only the UI knows
the zoom and the pan.

### 2. Stamps combine with `max` / `min`, not by accumulating alpha

`rp_manual_mask_splat` expands each point into evenly spaced soft discs
(plateau out to `hardness x radius`, smoothstep to 0 at `radius`) and combines
them with `max` for add, `min(existing, 1 - coverage)` for subtract.

This is the load-bearing decision of the whole design. `max`/`min` are
idempotent, associative and commutative, so *any* batching of the same stamps
produces the same pixels. That is what makes the plan's undo — "replay the
stroke list from the start" — **exact** rather than merely close: a live drag
rasterises the 3 stamps that just arrived, a replay rasterises all 43 at once,
and the two agree bit for bit (`ManualMaskTests.liveDragMatchesAReplay`). An
alpha-accumulating brush would darken wherever consecutive stamps overlap, i.e.
everywhere, and the live result would drift from the replayed one — undo would
then change pixels the user did not undo.

Measured: `rp_manual_mask_splat` against a `Double` CPU reference written from
the specification (not transcribed from the kernel) — **max abs diff 0.0** on
macOS, i.e. bit-exact after r8 quantisation.

### 3. Undo replays; it does not snapshot

Per the plan. `ManualMaskSession` keeps `committed: [BrushStroke]` as the truth
and the texture as derived state. The alternative, one texture snapshot per
stroke, costs 2.8 MB of GPU memory *per undo step* at a 2048 px preview (20
steps = 56 MB, on a phone already holding hundreds of megabytes of skin-node
scratch at export size) and is not faster: a replay is a handful of batched
dispatches over one r8 texture, and undo is not a per-frame operation.

A mask loaded from disk has no strokes behind it, so its pixels become the
`baseline` a replay starts from and the floor undo walks back to. Undo does not
reach past a document that was just opened — the same thing every raster editor
does.

### 4. The coverage is a GPU handle, not a `RenderMask`

`RenderMask` — the value type every *parsed* mask arrives as — carries `[UInt8]`
on the CPU, which is right for a mask produced once per shot by Core ML.
A painted mask is produced *while a finger is moving*: a CPU value type would
mean a read-back plus a re-upload of the whole mask per frame of the drag
(2.8 MB each way at 2048 px) to hand the GPU back what it had already computed.
So `ManualMaskCoverage` is a class holding two `r8Unorm` textures and the CPU
reads it only when it is actually needed on the CPU — once, when the stroke ends
and the PNG is written.

**Two textures, ping-ponged**, because `access::read_write` on `r8Unorm` needs
`MTLReadWriteTextureTier2` (Apple silicon has it, older Intel Macs do not) and
read+write bindings of one texture in one dispatch is undefined behaviour in
Metal. Stamps go in batches of 64 so the copy cost is amortised: one dispatch
per stamp would cost a thousand encoder set-ups for a long stroke, one dispatch
for a thousand stamps would make every thread walk a thousand distances.

### 5. One shared gate slot on `RenderRequest`, and gates intersect

**This is the decision ADR-0018 deferred.** `RenderRequest` gains
`gateMasks: [any RenderGateMask]` — one slot for every whole-frame mask that
belongs to no face:

* the hand-painted brush (`ManualMaskCoverage` conforms directly);
* "Khoá nền"'s subject mask — `BackgroundLockMaskSource.encode(…)` already
  returns a full-resolution `r8Unorm` texture in image space, which is exactly
  `TextureGateMask(texture:)` with the identity transform. **Nothing in
  `BackgroundLockMaskSource` has to change when its UI lands**, which is what
  "plugs in without rework" was supposed to mean;
* §6.2's planned full-frame skin mask, when it arrives.

Three separate `RenderRequest` members would have meant three `if let` chains in
every node and three answers to "what happens when two are set". One array
answers it once: **gates intersect, in order, by multiplication**. If the user
has painted a region *and* locked the background, the effect belongs where both
say yes; multiplying two 0…1 coverages is the same arithmetic the `MaskRasteriser`
path has done since ADR-0009, applied once more. Measured on the composed path:
brush alone changed 5024 pixels, a left-half subject mask alone 19854, the two
together exactly 2512 — the intersection, and a subset of each
(`ManualMaskTests.gateMasksIntersect`).

**An empty array is not an all-zero mask.** No gates means "nothing narrows this
render", i.e. exactly the pre-6.1 behaviour. Reading "no mask" as "select
nothing" would silently switch off every mask-driven slider in every document
that never used a brush, and would invalidate the golden numbers in
ADR-0009 … ADR-0012 for every existing render.

The protocol carries `gateMaskToImage` rather than assuming identity, because a
mask painted on the 2048 px preview has to be re-used against the
full-resolution frame at export time, and inferring a scale from an aspect ratio
is how a mask ends up half a frame out of place.

### 6. Gating a node changes no node maths

`SkinRenderNode` keeps its kernels, its constants and its measured behaviour.
The only thing that changes is the coverage texture it binds: `rp_skin_mask`'s
output when there is no gate, `coverage x gate₀ x gate₁ …` when there is. This
is the plan's *"không phải kỹ thuật mới, chỉ thêm 1 nguồn mask nữa"* taken
literally — one extra `rp_manual_mask_modulate` dispatch on an r8 texture before
the composite, one per gate, ping-ponging between two scratch textures (the
second only allocated when a request actually carries two gates).

Two properties are asserted rather than asserted-by-comment:

* with no gate, the node is **bit-identical** to its pre-6.1 self — max abs
  difference 0 against a control run with the feature flag off entirely
  (`noManualMaskChangesNothing`);
* with a gate, every pixel the brush did not paint is **bit-identical to the
  source** — 0 unpainted pixels changed out of 76 800, while 2456 painted ones
  did (`manualMaskNarrowsTheSkinNode`).

So ADR-0009's golden PSNR is untouched by construction, not by promise.

### 7. The flag gates the **producer**, not the consumer

`RPEngineFeatureFlags.manualMask` is checked in
`ManualMaskCoverage.init`, `ManualMaskSession.init` and
`ManualMaskRasteriser.init`. With it off, no `ManualMaskCoverage` can be built,
so no `RenderRequest` can carry one, so every node renders what it rendered
before Phase 6.1 — by construction.

The flag is re-read at encode time too, but **per gate**, through
`RenderGateMask.isGateEnabled` (the painted mask answers `manualMask`, anything
else defaults to `true`), not as one check in the node. A single
`if RPEngineFeatureFlags.manualMask` around the whole gate step would be wrong
in the other direction: it would silently ignore "Khoá nền"'s subject mask,
which answers to `backgroundLock` and has nothing to do with the brush. For the
same reason the *gating* kernel lives in `GateMaskCompositor`, which carries no
flag at all, while the *painting* kernels stay in the flagged
`ManualMaskRasteriser`. Asserted both ways in `ManualMaskTests`: switching
`manualMask` off with a painted gate still in the request puts `SkinRenderNode`
back to its ungated output bit for bit.

It is its own flag and borrows none: painting a mask is useful with *any*
mask-driven group on, so it is deliberately not folded into `skinSliders`.
It sits beside `backgroundLock` with no interaction — the two features share the
gate slot, not a bit.

### 8. Storage: PNG in the bundle, id in the JSON

Per the plan, and worth spelling out because it is a document-format change:

```
<project>.rpproj/
  masks/<shot id>/<mask id>.png      <- new, alongside originals/previews/edits/presets
  edits/<shot id>.json               <- holds only { "perImage": { "manualMask": "<mask id>" } }
```

Three reasons this is not a matter of taste:

* `edits/<shot id>.json` is rewritten on **every slider release**. A base64
  bitmap in it would turn a 200-byte write into a multi-megabyte one, tens of
  times per session.
* `EditState` is `Hashable` and compared on the interaction path
  (`LivePreviewController.update(editState:)` returns early when unchanged).
  Hashing megabytes of mask per slider tick is not free.
* A PNG is far smaller than the same coverage as JSON text and is readable by
  anything.

`MaskID` is an `Identifier`, i.e. a validated safe path component, so a corrupt
document carrying `"../../../etc/passwd"` fails to decode long before it reaches
a URL. A reference that does not parse reads as **absent**, not as an error: a
document whose mask file the user deleted must still open.

The reference lives in `EditState.perImage`, which `Preset` drops — same reason
`FaceSelection` gives for `"selectedFace"` (ADR-0013). A mask id inside a preset
would point every shot the preset touches at one shot's `masks/` folder.
Asserted in `ManualMaskStorageTests.presetsDropTheReference`.

Masks are derived data keyed by a shot, so `removeShot` deletes
`masks/<shot id>/` the way it already deletes `edits/<shot id>.json`. The
imported file under `originals/` still is not deleted.

The PNG is 8-bit **device gray**, unmanaged, on both encode and decode: the mask
is coverage, not a picture — 128 means "half selected", not "mid gray" — and a
colour-managed space would invite CoreGraphics to apply a transfer function on
one side and not the other, so 0.5 coverage would come back as 0.73. Asserted
byte-exact in `ManualMaskTests.pngRoundTripIsExact`.

## Consequences

* One more `.metal` file in the single `makeLibrary(source:)` call
  (`ManualMaskShaders.metal`), appended last so no earlier file's line numbers
  move. Its three kernels compile at prewarm **only when a gate source is on** —
  the two painting ones behind `manualMask`, the gating one behind
  `manualMask || backgroundLock`.
* Memory: two `r8Unorm` textures per painted mask (5.6 MB at a 2048 px preview)
  plus one r8 scratch frame per gated node, and a second scratch only when two
  gates are in play.
* `RenderRequest` gained a member with a default, so every existing construction
  site compiles unchanged.

## What is deliberately not done here

* **No UI.** Nothing in RPUI captures a touch, no brush controls, no mask
  overlay, no "Xoá mask" button. `ManualMaskSession` is the API that UI will
  drive, and the rail item stays locked.
* **No `LivePreviewController` wiring.** `gateGeneration` exists so the canvas
  can tell "the mask moved" from "the same mask again" without comparing pixels,
  but nothing reads it yet.
* **"Khoá nền" is still not wired to a node.** The slot it needs now exists and
  the adapter (`TextureGateMask`) is tested; making the UI produce one is that
  feature's follow-up, not this one's.
* **No per-frame device benchmark.** The measurements above are correctness
  numbers (max abs difference, changed-pixel counts) taken on macOS and the iOS
  Simulator. There is no ms/frame for the brush on an iPhone, because the
  session this landed in was explicitly restricted from building to the physical
  device. The flag being off is what makes that acceptable for now; a ms/frame
  on an A-series part is required before it is turned on, the same rule every
  other node followed.

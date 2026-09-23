# ADR-0019 — "Cọ mask thủ công": the hand-painted mask, its storage, and the shared gate slot

Status: accepted — 2026-09-13; **UI landed and flag turned on — 2026-09-18**
(see §UI, 2026-09-18, at the end of this file).
Scope: Phase 6 §6.1, shared infrastructure. **Engine + storage this round**: the
brush, its rasteriser, the PNG-in-the-bundle storage and one gated node
(`SkinRenderNode`). There is no UI yet — nothing in RPUI captures a touch, and
`RPEngineFeatureFlags.manualMask` ships **off**.

> **2026-09-18.** The paragraph above describes the state this ADR was written
> in and is left as written. Both of its claims have since changed: RPUI captures
> the touch (`CanvasView` / `CanvasEventCatcher`), and the flag is on in the app
> because the measurement this ADR made the condition for turning it on now
> exists. The addendum at the end says what was built and what it measured.

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

---

## UI, and the device measurement that turned the flag on — 2026-09-18

Everything in this section is an addendum. Nothing above it was rewritten.

### 1. The rail entry is a **mode**, not a screen and not a slider group

`RailLayout` gained a twentieth item, "Cọ mask" (`id: "manualMask"`), appended
after "Khoá nền" so the design canvas's own members keep their relative order.
It carries a `RailPresentation` — the second case, `.manualMaskBrush` — rather
than a `sectionKey`, because there is no `EditState` namespace behind it and
there must not be one: a brush radius in `EditState` would be a brush radius in
every `Preset`, and "64 px" is meaningless on another image. Tapping it toggles
`EditorChrome.isBrushing`; tapping it again puts the brush away, and **the slider
panel stays where the user left it**, which is the whole point — a painted mask
is only useful with some group turned up.

`RailPresentation` grew `isAvailable`, so a presentation can be locked the way a
section can: with `RPEngineFeatureFlags.manualMask` off the item is dimmed and
inert and says *"Phase 6.1 · cọ mask đang tắt trong bản dựng này"* instead of the
generic "chưa khả dụng". That is the second `lockedReason` in the rail, after
"Khoá nền"'s.

The label is shortened from the plan's "Cọ mask thủ công" to fit a 58 pt chip;
the full name is the brush bar's title, where there is room for it.

### 2. The brush bar borrows the panel's slot

`ManualMaskBrushBar` (add / erase, three ordinary 0–100 rows, undo · làm lại ·
xoá mask) stands **in place of** the slider list in both shells — the phone's
tool sheet and the Mac's right-hand panel — rather than floating over the
picture. A palette would sit on exactly the region being painted, and the user
moves between the brush and the sliders constantly, so sharing one slot keeps
that one tap. It reuses `RPSliderRow` unchanged, which is why
`ManualMaskBrushSettings` is 0–100 and converts to the engine's mask pixels and
0…1 in one place.

**No detection notice**, and that is not an omission:
`SliderPanelLayout`'s `notifiesFromNodeNamed` has no entry for this feature
because a brush detects nothing. What the bar *does* say is when there is no
picture or no GPU preview — a fact about the canvas, not about a detector.

### 3. The overlay draws the strokes, not the coverage texture

`ManualMaskOverlay` re-draws the geometry the session was given
(`BrushStroke.points`, scaled from mask pixels into view points), with
`.destinationOut` for erase strokes so they cut in stroke order. It does **not**
read the coverage texture back: §4 above is explicit that a CPU read-back per
frame of a drag is the thing this design exists to avoid.

So the overlay is an *indication of where the stroke went*, not a rendering of
the mask — a flat translucent band rather than the splat kernel's smoothstep
falloff, and overlapping strokes do not darken. The truth of what is selected
remains the gated node's own output: turn a Da slider up and the effect appears
inside the painted region, which is the check the device run makes. If a future
phase needs a pixel-accurate mask overlay (a "show mask" toggle), the honest way
is a read-back **on stroke end only**, not per frame.

### 4. Where the session lives, and the one rule that keeps it safe

`LivePreviewController` owns one `ManualMaskSession` per shot, built in `open`
at the decoded preview's size — which is what keeps `maskToImage` the identity
and means a brush point needs no rescaling, the same property `faces` and
`bodySkinMask` already rely on. It is dropped in `close` and whenever another
shot opens, because masks are per shot (§8).

The load-bearing rule is in `renderRequest`:

```swift
if let manualMask, !manualMask.isEmpty {
    request.gateMasks.append(manualMask.coverage)
}
```

An armed-but-unpainted session must **not** reach `gateMasks`. A gate
multiplies, so an all-zero coverage would switch every mask-driven slider off in
every shot the brush was merely armed on — the same trap §5 records for an empty
*array*, one level down. `ManualMaskBrushWiringTests` asserts it directly.

The paint API (`beginManualMaskStroke` / `extendManualMaskStroke` /
`endManualMaskStroke` / undo / redo / clear) lives in
`LivePreviewController+ManualMask.swift` and compares the session's `generation`
around each call, bumping the controller's `version` only when the pixels
actually moved — `generation` is the redraw signal this ADR already defined, and
nothing else was invented to replace it.

### 5. Gesture capture: what the brush takes and what it leaves

| input | not brushing | brushing |
|---|---|---|
| one-finger drag / mouse drag | pan | **paints** |
| pinch, ⌥scroll, two-finger scroll | zoom / pan | unchanged |
| press and hold | show the original | off (a slow stroke must not flash the original) |
| double click / double tap | fit ⇄ 100 % | off on the Mac (the second click of a dab is a dab) |

The Mac's Trước | Sau comparison is where a stroke would land half a frame out,
so the edited pane's origin is a parameter (`ManualMaskBrushGeometry.maskPoint`)
rather than an assumption, and a point in the untouched "Trước" pane is refused
rather than mapped.

### 6. The measurement this ADR asked for, on the phone

The blocker above was explicit: *"a ms/frame on an A-series part is required
before it is turned on"*. Two things were built to answer it, because one was not
enough:

* `ManualMaskBenchTests` + `Scripts/bench-manual-mask.sh` — paint ms/touch-event,
  gated vs **ungated** SkinRenderNode ms/frame (the control), and an undo replay,
  at a 2048 px preview. Files `Research/bench/p6-manual-mask-{macos,ios-simulator}.json`.
* `App/ManualMaskSelfTest.swift` (`RP_BRUSH_SELFTEST`) — the same three
  measurements **inside the app on the device**, driving the product objects.
  It exists because `xcodebuild` refuses tool-hosted testing on a device
  destination, so a package test bundle cannot run on a phone at all — the wall
  `App/BodySkinSelfTest.swift` already documents.

| | macOS (M1 Pro, Release) | iOS Simulator (Release) | **iPhone (IphoneDuy, iOS 27, Debug)** |
|---|---|---|---|
| main thread per touch event | 0.166 ms | 0.354 ms | **0.084 ms** |
| SkinRenderNode, no gate (control) | 4.69 ms | 6.47 ms | **6.23 ms** |
| SkinRenderNode, one painted gate | 4.76 ms | 7.79 ms | **6.33 ms** |
| the gate's marginal cost | 0.07 ms | 1.32 ms | **0.09 ms** |
| gated redraw | 210 fps | 128 fps | **158 fps** |

The device figures are at a 1151×2048 preview of a real photo with one detected
face, with the skin node actually running (`nodes skin`, `gates 1` in the log
line filed in `Research/bench/p6-manual-mask-device.json`). A second launch
reproduces the paint and undo figures to the digit and puts the gate's marginal
cost at −0.03 ms, which is the honest reading of both runs: **one extra r8
dispatch is below the noise of a 6 ms skin composite.**

**On that evidence `RPEngineFeatureFlags.manualMask` is on in the app**, set in
`AppEngineSetup.enableRenderGraph` alongside the four slider groups and
switchable off per launch with `RPDisableGroups=manualMask`. The library default
is unchanged: the flag is still `false` in `RPEngineFeatureFlags`, so every
flag-gating test still means what it meant.

### 7. One honest cost this measurement found: deep undo

The undo replay is **linear in stamps**, and the macOS bench's deep case makes
that visible: nineteen full-frame strokes replayed cost **426.9 ms** (Simulator
400.6 ms), against 30.1 ms for the device's single-stroke case. §3's reasoning
still holds — a snapshot per stroke costs 2.8 MB of GPU memory per step and undo
is not a per-frame operation — but "single-digit milliseconds", written when the
replay was measured at a 160×120 test size, is not true at a 2048 px preview
with a deep history.

It is recorded rather than fixed because the fix is a real change with its own
measurement: dispatch each stamp batch over the **bounding box of its stamps**
instead of the whole texture, which is where essentially all of that time goes
(every thread of a 2.8 M-pixel grid currently walks up to 64 stamps, most of them
far away). That belongs in its own change, behind its own number.

### 8. Still not done

* **The UI does not write `masks/<shot id>/<mask id>.png`.** The storage half of
  this ADR (§8) is built and tested in RPCore, and `EditState.perImage` carries
  the reference, but nothing in RPUI saves or loads yet: a painted mask lives for
  as long as the shot is open and is gone when the user moves to the next frame.
  That is the next piece of work on this feature, and it is a document-format
  path (save on stroke end, load on open, size-mismatch handling) rather than a
  gesture one.
* **No brush cursor.** There is no ring showing the brush's footprint before the
  finger lands; the size row shows the radius in pixels instead.
* **No pressure.** `BrushPoint.pressure` is 1 for every point a `DragGesture` or
  an `NSEvent` delivers here. The stroke model supports it (§1) and a stylus
  would fill it in.

---

## Overlay visibility and the layer list — 2026-09-21

Everything in this section is an addendum. Nothing above it was rewritten.

**The problem, reported by the user from real use:** §3 above shipped the tint
staying on screen for as long as the brush was armed — painting, adjusting
sliders, everything. The report was blunt and correct: dragging a Da slider to
judge "how strong should this be" is exactly the moment the tint's opaque paint
sits on top of the one thing that judgement needs, the real pixels underneath.
The ask, in the user's words, was "giống Lightroom" — the tint shows while
painting, and once a stroke is done adjusting a slider must never bring it back
on its own.

**What changed, UI-only, no engine/storage change:**

* `EditorChrome.previewedMaskStrokeIndex: Int?` replaces the brush being the
  sole source of "should the tint be on screen". The canvas's `maskOverlay` now
  shows it in exactly two cases: a stroke is in flight (`liveStroke != nil`,
  unchanged from §3), or this index is set. Never merely because
  `isBrushing == true` — that was the whole bug.
* **The brush bar gained a layer list**, "Các nét đã vẽ" — one row per finished
  `BrushStroke`, oldest first, read straight off `live.manualMaskStrokes` (§1's
  existing array; no new session-side grouping concept). Hovering a row on Mac
  (`.onHover`) or tapping it on the phone (`.onTapGesture`, no hover there) sets
  `previewedMaskStrokeIndex`, and the overlay then draws **only that one
  stroke** — `ManualMaskOverlay(strokes: [stroke], liveStroke: nil, …)` — not
  the union, because the question a hover answers is "what does this one do",
  not "what's painted so far".
* A stroke is the layer unit, not a paint-then-adjust cycle, even though that
  is closer to the user's own phrasing ("mỗi khi vẽ overlay xong và tiến hành
  điều chỉnh thì sẽ là 1 layer"). The session already tracks strokes
  individually for undo/redo; grouping consecutive strokes into a coarser
  "layer" would be a second concept with nothing in the engine backing it, for
  a distinction the hover-to-preview affordance does not actually need.
* `EditorChrome.disarmBrush()` now also clears `previewedMaskStrokeIndex`, so a
  preview left on from one session cannot leak into the next time the brush is
  armed.
* **The brush bar also gained the active group's own sliders** (`GroupSliderList`
  for `chrome.activeSection`) directly beneath its own controls, so intensity
  can be tuned without leaving the mode to tap "Xong" and re-arming it
  afterward — the loop the user was stuck in when the tint problem above was
  reported.

No `RenderGraph` node, no `EditState` field, no `ManualMaskSession` API changed.
`Packages/RPUI/Tests/RPUITests/ManualMaskBrushWiringTests.swift` gained one test
pinning the disarm-clears-preview behavior; the rest of the suite (203 RPUI
tests) is unchanged and green.

---

## Addendum 2026-09-23 — the brush is saved, and reaches the export

Everything above is unchanged; this records what filled in §8 "Still not done" (first bullet).

* **Saved**: `masks/<shot id>/brush.png` (one fixed `MaskID` per shot, `RPUI.ProjectManualMaskStore`), written through
  `ProjectStore.saveMask` after every stroke / undo / redo, **deleted** when the session becomes empty or "Xoá mask"
  is pressed, and loaded as the session's baseline when the shot is reopened. File present ⇔ the canvas gates.
* **Deviation from §8: no `perImage["manualMask"]` reference is written.** Since 2026-09-22 `EditState` has its own
  undo stack, separate from the brush's stroke replay. A reference in `edits/<id>.json` could be rolled back by a
  slider undo while the pixels stayed, and the canvas (which reads the session) and the export (which would read the
  reference) would disagree. With one fixed id per shot the file itself is the reference. `ManualMaskReference`
  stays in RPCore unused.
* **Export**: `ExportJob.masks` (`RPEngine.ExportMasks`) carries the brush (and the "Khoá nền" / body-skin masks) with
  its reference size; `ExportRenderer` scales it per axis to the render and applies it only while
  `RPEngineFeatureFlags.manualMask` is on. Measured in `ExportMasksTests` and on the real Mac app (docs/PLAN.md
  Phase 3, 2026-09-23).

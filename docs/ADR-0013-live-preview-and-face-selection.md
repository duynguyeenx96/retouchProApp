# ADR-0013 — Live `MTKView` preview, and the multi-face selection state model

Date: 2026-09-07
Status: accepted
Phase: 2, item "Preview realtime `MTKView`, multi-face chọn trên canvas"

Supersedes nothing. Builds on ADR-0007 (guided filter / MLS constraints),
ADR-0009 (RenderGraph + Da), ADR-0010 (Mặt), ADR-0011 (Mắt/Răng), ADR-0012
(Color) — the four slider groups this item finally puts on screen.

---

## 1. Context

Before this item, every measured piece of Phase 2 existed and none of it was
reachable from the app:

* `RenderGraph` with four nodes, each behind a default-off flag, each with a
  golden PSNR against a `Double` CPU reference and a bench file;
* `FaceAnalyzer` producing `FaceAnalysis`, cached by content hash;
* `App/FaceAnalysisRenderBridge` converting that into `FaceRenderInput`;
* an editor UI whose canvas showed `PassthroughPreviewRenderer`'s output — the
  decoded original — and whose slider panel was a list of **disabled**
  placeholder rows writing nothing.

So the work is wiring, and wiring has exactly three ways to go wrong: it can
corrupt the pixels (colour space, orientation, bit depth), it can put per-shot
work on the per-frame path, and it can invent state that does not belong in the
document.

---

## 2. Decision 1 — the preview is an `MTKView`, and the CGImage path stays

**Decided.** The edited side of the canvas is an `MTKView` driven by a new
`RPEngine.LivePreviewRenderer`: the shot is decoded and uploaded **once**, the
render graph runs into a `rgba16Float` texture the renderer keeps, and a compute
pass (`rp_preview_present`) places that texture into the drawable at whatever
zoom and pan the canvas asks for. `PassthroughPreviewRenderer` stays exactly
where it was, feeding the filmstrip thumbnails and the before/after "before"
side.

### Why not render through `PreviewRendering` and hand back a `CGImage`

`PreviewRendering` is a `URL + EditState → CGImage` seam. Using it for the live
canvas would mean, per slider tick: read back the GPU texture, build a `CGImage`,
hand it to SwiftUI, let SwiftUI upload it again for compositing. The readback
alone is the largest single cost in the loop and it is pure waste — the pixels
are already on the GPU that is going to display them. The measured redraw with
all four groups on is **8.03 ms** on macOS / **7.47 ms** on iOS Simulator
(`Research/bench/p2-live-preview-{macos,ios-simulator}.json`, `redraw[].label
== "all four groups"`); the upload alone, which a `CGImage` round trip pays
again every frame, is **11.54 ms** on macOS / **37.1 ms** on iOS Simulator
(`per_shot.upload_median_ms` in the same files) — several times the redraw
itself, before any `CGImage` construction or SwiftUI re-upload is even counted.

The seam is still right for what it now does. A filmstrip thumbnail and the
"before" side want *the untouched file*, which is precisely what a renderer with
`appliesEditState == false` returns. Making it apply edits would also break the
`PreviewImageCache` key, which folds the `EditState` fingerprint in as soon as
`appliesEditState` is true — every thumbnail would re-render on every tick.

### Colour space and bit depth (the reviewer's checklist)

* The graph works in **sRGB-encoded** values (`RenderQuality.pixelSpace`, forced
  by ADR-0007), in `rgba16Float`.
* The drawable is **`bgra8Unorm` with the layer's colour space set to sRGB** —
  deliberately *not* `bgra8Unorm_srgb`, which would apply the sRGB encode a
  second time to values that already carry it and wash the canvas out.
* So the preview *shown* is 8-bit while the pipeline behind it is 16-bit float.
  Export (Phase 3) reads the texture, never the drawable.
* `rp_preview_present` samples **nearest** at 1:1 and above and **linear** below
  it: at 100 % zoom the user is pixel-peeping and a bilinear tap would show them
  a blur that is not in their file.

Pinned by `RPEngineTests/LivePreviewRendererTests`:

| claim | measured |
|---|---|
| the wired path == `RenderGraph.renderPixels`, same request, same output format | **max abs difference 0.0** |
| the shipping 16-bit output vs that float32 control | max abs 4.88e-4 (one half-float step), **74.45 dB** |
| present at 1:1 into a same-size texture | **max abs difference 0.0** |
| empty `EditState` through the whole live path | bit-exact passthrough |

The first row is the one that matters: a stray colour-space conversion, a
vertical flip or an 8-bit round trip in the UI layer cannot produce a zero.

---

## 3. Decision 2 — the four slider-group flags go **on in the app target**, and stay **off in the packages**

**Decided.** `RPEngineFeatureFlags.{colorSliders, skinSliders, warpSliders,
eyesTeethSliders}` keep their `false` default. `App/AppEngineSetup.swift` turns
all four on at launch, and a developer can turn any of them back off without a
rebuild:

```
defaults write com.duynguyen.RetouchPro RPDisableGroups -string "skin,warp"
RP_DISABLE_GROUPS=warp ./RetouchPro          # or from the environment
```

### Why not flip the defaults in RPEngine

The flag rule in docs/PLAN.md §2 is *"a new mask/landmark/filter algorithm ships
behind a default-off flag until it has a number"*. That is a statement about the
**library**: `import RPEngine` + `RenderGraph.standard()` must not start
allocating 24 MP Metal textures for a caller who never asked. It is also what
makes the flag-gating tests mean anything —
`RenderGraphTests.noGroupFlagMeansAnEmptyGraph`,
`.disablingOneGroupLeavesTheOtherRunning`, `GuidedFilterTests.flagGatesConstruction`
all assert behaviour that a flipped default would delete.

The **app** is the other side of that rule: it is where a measured algorithm gets
to be used. All four groups have their numbers —
`Research/bench/p2-{color,skin,warp,eyes-teeth}-{macos,ios-simulator}.json`,
golden PSNR 79.0 / 82.7 / 89.9 / 136.3 dB against `Double` references, all far
above the plan's 45 dB bar. Leaving them off in the app would mean shipping an
editor whose sliders do nothing, which is not what "default-off" was protecting
anyone from.

### What is deliberately **not** turned on

**Export.** Every number above is a 2048 px preview. ADR-0011 records that at
24 MP the Da group's scratch is 552 MB and the Mắt/Răng group's 384 MB, ~936 MB
together, and that this "must be checked on a real iPhone before enabling both by
default". This ADR only enables the *preview* path — `LivePreviewRenderer` is
built with `RenderQuality.preview` and nothing here constructs an export
renderer. That call belongs to Phase 3, with a device in hand.

**Bundling the Core ML models.** Still open, still deliberately (ADR-0008; the
parsing model alone is 25 MB). `AppEngineSetup.models()` looks in
`RP_MODELS_DIR`, then the app bundle, then `Research/spikes/*/models/` next to
the source tree — the app is a Development-signed local build (PLAN §Context),
so on the machine it is developed on the third path hits. On a machine with no
models the face pipeline simply stays unavailable: the Color group still works
(it never reads a face), and the three face-dependent groups are disabled in the
panel **with the reason written out**, instead of offering a control that
silently does nothing.

---

## 4. Decision 3 — the multi-face selection state model

**Decided.** Sliders stay **global per shot**. The only new state is a single
integer, `EditState.perImage["selectedFace"]`, meaning *which detected face the
face-dependent groups act on*. Absent = every face, which is what the renderer
already did.

`RPCore/EditState` had no notion of a selected face; it does now, but not as a
new type in RPCore — the reader/writer is `RPEngine.FaceSelection`, alongside
`SkinSliders`/`FaceSliders`/`ColorSliders`, which are likewise RPEngine types
reading an RPCore document.

### The three options, and why this one

1. **A slider set per face** (`sections` keyed by face index). Rejected: a
   `Preset` is defined as "EditState minus the per-image fields"
   (docs/PLAN.md §2) and a per-face slider set cannot transfer to a photo with a
   different number of faces in a different order. It would also change the shape
   of every group that already exists.
2. **Global sliders + a selected-face index.** Chosen.
3. **No selection; every group always acts on every face.** The behaviour before
   this item, and still the default. It is wrong as the *only* option: a
   two-person portrait where one subject wants slimming and the other does not is
   the ordinary case, and there was no way to express it.

### Why `perImage` and not `sections`

`PerImageState`'s doc comment, written in Phase 1, names this exact case as a
future owner: *"per-face-instance bindings when an image has several faces"*.
That is not just tidy, it is load-bearing: `Preset.make` **drops** `perImage`. A
face index must not travel in a preset — "face 2" on a two-person portrait means
nothing on the next frame, where face 2 may be a different person or may not
exist. Storing it in `sections` would let a preset silently retarget every
reshape slider onto the wrong person.
`FaceSelectionTests.presetsDoNotCarryTheSelection` is the proof.

### Semantics, and the two edge cases that had to be decided

* **Absent ⇒ all faces.** So no saved document changes meaning, and
  `EditState.isDefault` still means "untouched" — the same rule
  `EditSection.setSlider` follows when a slider goes back to 0.
* **A stale index falls back to all faces** (`resolved(faceCount:)`). If the shot
  is re-analysed and finds fewer faces, the alternative — rendering nothing —
  looks exactly like a broken render graph. Anything unreadable in the JSON (a
  string, a negative, a fraction) reads the same way.
* **The selection narrows the request, not the nodes.**
  `RenderRequest(editState:allFaces:)` applies it once, so `RenderGraph`,
  `SkinRenderNode`, `WarpRenderNode` and `EyesTeethRenderNode` are **unchanged**
  by this feature and every number they were measured at still stands. A node
  cannot tell "this photo has one face" from "one face is selected".
* **It narrows all three face-dependent groups**, not only Mặt and Mắt/Răng. The
  Da group is mask-driven per face too, and "smooth everyone's skin but reshape
  only her face" is a surprising split to impose silently. Color is never
  narrowed: it has no face input at all and works on frames with no face in them.

### The UI

Two ways in, one state:

* **On the canvas** — when a shot has more than one detected face, each gets a
  numbered outline (the mesh bounding box padded by 12 % of face width). Tapping
  one selects it; tapping the selected one clears back to "All", the same
  "second tap undoes it" rule the filmstrip uses for ratings and flags. The
  overlay is mounted **above** the platform input layer, because on macOS
  `CanvasEventCatcher` is an `NSView` that would otherwise swallow the click.
* **In the panel** — an "All / Face 1 / Face 2 …" segmented control, shown only
  when the count is > 1.

Hit-testing prefers the **smallest** containing box, so a child in front of an
adult stays selectable. The mapping image-pixels → view uses the very
`CanvasViewport.imageFrame` the picture is drawn with, so an outline cannot drift
from the face under it at any zoom or pan (`FaceOverlayGeometry`, tested without
a GPU).

---

## 5. Decision 4 — where per-shot work happens, and how that is held in place

Face analysis is ~36 ms per image (cold 46.7 ms, warm 0.052 ms —
`Research/bench/p2-face-analyzer-*.json`) and a drag issues tens of redraws a
second. So:

* `LivePreviewController.open(_:contentHash:editState:)` — once per shot: decode
  (**117.4 ms** macOS / **464.8 ms** iOS Simulator for a 24 MP JPEG at 2048 px),
  upload (**11.5 ms** macOS / **37.1 ms** iOS Simulator), analyse.
* `LivePreviewController.update(editState:)` — per slider tick: bumps a version
  counter. The `MTKView` redraws, the graph runs, nothing else.
* A pan or a zoom runs **only** the present pass (**0.39 ms** macOS / **0.53 ms**
  iOS Simulator), because the graph's output stays in a texture the renderer owns.
* The `MTKView` is `isPaused = true` + `enableSetNeedsDisplay = true`. A photo
  canvas is static between interactions; a display-link treadmill would burn an
  iPhone's battery redrawing an unchanged picture.

Held in place by
`RPUITests/LivePreviewWiringTests.analysisRunsOncePerShot`: opening a shot calls
the provider once, **100 slider changes call it zero more times**, re-opening the
same content hash calls it zero more times, and a different hash calls it once.

The face provider is a new seam, `RPEngine.FaceInputProviding`, implemented in
the app target (`FaceAnalyzerFaceInputProvider`) for the same reason
`FaceAnalysisRenderBridge` lives there: RPEngine must not link Core ML. Its cache
key is `"<contentHash>@<width>x<height>"` — the pixel size **has** to be in the
key, because the same file analysed at 2048 px and at 24 MP is two different
answers and Phase 3's export will ask for the second one.

### Slider writes do not hit the disk

A drag mutates `EditorModel.activeEditState` only; `edits/<id>.json` is written
once on `onEditingChanged(false)`, and again if the user leaves the shot
mid-drag. A crash mid-drag loses the drag, which is what every editor does.

---

## 6. Measurements

`Scripts/bench-live-preview.sh` → `Research/bench/p2-live-preview-{macos,ios-simulator}.json`,
scraped from `RPEngineTests/LivePreviewBenchTests`. Real a6300 frame
(`DSC05123.jpg`, 4000×6000) with the real 478-point mesh measured on it, rendered
at 1365×2048, face width 229.8 px.

**Not an iPhone.** The plan's ≥ 30 fps bar is stated for an iPhone and no device
is attached — the same disclosure S1, S2, S3, `FaceAnalyzer` and all four slider
groups carry. `is_real_device` is in the JSON. Release configuration, wall clock
medians of 30 redraws.

| what | macOS (M1 Pro) | iOS Simulator |
|---|---|---|
| redraw, empty `EditState` (passthrough) | 0.51 ms → 1973 fps | 0.93 ms → 1071 fps |
| redraw, Color only | 1.64 ms → 610 fps | 5.03 ms → 199 fps |
| redraw, Da only | 3.26 ms → 307 fps | 4.18 ms → 239 fps |
| redraw, Mặt only | 0.71 ms → 1406 fps | 0.89 ms → 1126 fps |
| redraw, Mắt/Răng only | 1.88 ms → 532 fps | 2.25 ms → 444 fps |
| **redraw, all four groups** | **8.03 ms → 125 fps** | **7.47 ms → 134 fps** |
| present only (zoom / pan), 2048×1400 drawable | 0.39 ms | 0.53 ms |
| **60-frame drag, render + present each frame** | **8.25 ms/frame → 121 fps** | **8.97 ms/frame → 111 fps** |
| per shot: decode 24 MP JPEG → 2048 px | 117.4 ms | 464.8 ms |
| per shot: upload to the GPU | 11.5 ms | 37.1 ms |
| per process: graph prewarm | 0.12 ms | 1.37 ms |

macOS numbers above are a re-run (a normal ~10–15% run-to-run variance from the
original 7.00 ms/143 fps measurement — both comfortably clear the 30 fps bar);
the file cited throughout this ADR is the one on disk, and this table matches it
number-for-number.

Read `wall_*_ms` in the Simulator and ignore `gpu_median_ms`: it reports 0.05–0.13 ms
for renders that take milliseconds of wall clock, which is not a GPU time — the
same artefact ADR-0009 … ADR-0012 record.

Two things the table says that the per-node benches could not:

* the four groups **compose** at roughly the sum of their parts (1.61 + 3.36 +
  0.73 + 1.89 = 7.59 vs 7.00 measured), so the graph's ping-pong is not adding a
  hidden cost;
* the per-shot work is **11–40× one redraw** on macOS and far more in the
  Simulator, which is the whole argument for doing it once per shot rather than
  per frame.

---

## 7. Known limitations

* **No iPhone number.** As above.
* **The redraw blocks the main thread.** `RenderGraph.render` ends in
  `waitUntilCompleted`, and the draw callback runs on the main thread. At ~9 ms
  for all four groups that is comfortable at 60 Hz on this machine and it is a
  real risk on a slower one; the fix (present the previous frame while the next
  is in flight) is a change to `RenderGraph`, not to the UI, and it should be
  made with a device's numbers rather than guessed at.
* **The canvas is 8-bit.** Stated above; the pipeline is not.
* **Face outlines are boxes, not contours.** A mesh silhouette would look better
  and would cost a shape per face per frame; the box is what makes hit-testing
  and the "which face is this" label obvious.
* **Nobody has judged the render by eye.** Every constant in all four groups is
  still untuned (ADR-0009 … ADR-0012 each say so). This item makes them
  *visible*, which is the precondition for tuning them, not the tuning.
* **No RAW development.** `ImageDecoder` still hands back the camera's embedded
  preview for an ARW (its own doc comment says so); `CIRAWFilter` is Phase 2's
  S4 line and is not in this item.

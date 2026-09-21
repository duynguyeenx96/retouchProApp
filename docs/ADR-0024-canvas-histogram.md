# ADR-0024 — The live RGB histogram on the macOS canvas

Status: accepted — 2026-09-21.
Scope: a read-only overlay. **No render node, no change to any kernel that puts
pixels in the picture.** One new Metal compute pass reads the graph's *output*
texture; nothing it does can alter a render. Every golden number in ADR-0009 …
ADR-0023 is untouched by construction.

## Context

The user — a working photographer — asked for a "biểu đồ màu histogram" floating
in a corner of the image area, "trong không gian hiển thị hình trên **MacOS**".
Confirmed with them that this means the ordinary Lightroom-style plot: three
overlapping translucent channel distributions, 256 bins, computed from the
picture as edited rather than from the original file.

Nothing like it existed. The only "histogram" in the codebase was
`SkinCore.swift`'s internal 256-bin CPU histogram for skin-tone classification,
which is a different computation on different data and is not reusable.

The data is already there: `LivePreviewRenderer.outputTexture`, the graph's
result at preview resolution, `rgba16Float`, sRGB-encoded. The obvious way to
read it is also already there and is already disqualified —
`readOutputPixels()`'s own doc comment says "Test / bench only — it stalls the
GPU", and it moves 22 MB per call.

## Decision

### 1. Bin the **encoded** value, not linear light

`bucket = min(floor(clamp(v, 0, 1) * 256), 255)` on the value as it sits in the
output texture.

That texture holds sRGB **code values** (`RenderQuality.pixelSpace`, ADR-0007) —
the same numbers that go to the drawable — so bin *b* counts the pixels whose
8-bit display value would be *b*. This is what every photo application's
histogram shows, and it is the only reading that lines up with the picture on
screen: binning linear light would push a normally-exposed portrait's mass into
the bottom fifth of the plot, and the user would be told their correctly-exposed
frame is underexposed.

Values outside `[0, 1]` exist in a float texture (a slider can push a highlight
past 1.0). They are **clamped into the end bins, not dropped**, so clipping reads
as the spike at 255 a photographer expects.
`HistogramTests.valuesOutsideZeroOneClampIntoTheEndBins` pins this with 2.5 and
−0.75 in the texture.

Luma (Rec. 709 `kRPLuma`, on the same encoded values) is binned in the same pass
as a fourth channel. It costs one more atomic per pixel and it is what tells a
blown highlight from a merely saturated one.

### 2. A threadgroup-local atomic histogram, merged once per threadgroup

`rp_histogram_accumulate` gives each 16×16 threadgroup its own copy of the 1024
counters in threadgroup memory (4 KB, against a 32 KB limit), accumulates into
it, and then merges into the `device atomic_uint` buffer with at most 1024 atomic
adds per group.

The naive form — four `device` atomic adds per pixel — contends hard: a flat grey
area is 2.8 M increments on *one* address. With the local copy, contention scales
with the number of threadgroups rather than the number of pixels.

`rp_histogram_clear` zeroes the 1024 device counters. Both dispatches go in
**one** compute encoder: `makeComputeCommandEncoder()` is serial by default, so
the clear is ordered before the accumulate without a second encoder.

The threadgroup shape is **fixed at 16×16**, not taken from
`threadExecutionWidth`, because the same threads clear and merge the local
histogram and a reproducible shape is what makes the filed number comparable
between machines.

### 3. Non-blocking readback: a 4 KB shared buffer and a completion handler

`HistogramSampler.sample(texture:step:completion:)` encodes, commits and
**returns** — no `waitUntilCompleted` anywhere on the interactive path. The
counters live in `.storageModeShared` `MTLBuffer`s the CPU reads directly in the
command buffer's `addCompletedHandler`; on Apple silicon that is the same memory
the GPU wrote, with no blit and no synchronise step.

Because a completion handler runs after the caller has moved on, the sampler
rotates through a **ring of 3 buffers** and refuses (`Failure.busy`) when all
three are outstanding, so a handler can never be reading counters another
dispatch is writing.

`sampleSynchronously` — tests and bench only — has a **fourth buffer of its
own, outside the ring**. That was not foresight: the first run of
`HistogramTests.ringRefusesWhenFull` failed because the blocking path drew from
the ring, and a blocking call waits on its own command buffer rather than on
anyone else's completion *handler*, so it could overwrite counters a handler was
mid-read of. One extra 4 KB buffer removes the whole question.

### 4. Throttling: one reading in flight, with a trailing re-sample — no timer

`RPUI.HistogramController` is the policy:

* a redraw while nothing is outstanding samples immediately;
* a redraw while one is outstanding sets a pending flag and returns — nothing
  is queued;
* when the outstanding reading lands, the pending flag re-issues **once**, so
  the plot always settles on the *last* state of the picture instead of whatever
  frame won the race.

This self-throttles to whatever rate the GPU sustains and needs no debounce
constant. A fixed "every N ms" timer was considered and rejected: it has to be
tuned for the slowest machine, and it still leaves the plot stale at the end of a
drag unless a trailing fire is added — at which point the timer is doing nothing
the pending flag does not already do.

**A stride knob exists and is not used.** `HistogramParams.step` lets the pass
read every second pixel (measured below at less than half the cost). It ships at
`step = 1` because the full-rate number is already far inside budget; the knob is
there so a future iPhone port has something to turn rather than a rewrite.

### 5. Preview resolution by construction, not by choice

Nothing here picks a resolution. `LivePreviewRenderer.outputTexture` is the size
of the uploaded source, and the canvas uploads the decoded preview
(`RenderQuality.preview.preferredLongEdge`, 2048 px — `CanvasView.load()` passes
that long edge to `model.previewRequest`). Export re-renders at full size on a
different renderer, which no histogram reads. So "compute at preview resolution"
is a property of where the texture comes from, and there is no code path that
could accidentally run this over 24 MP during editing.

### 6. Placement: top-trailing, and macOS only

Top-right of the picture, 12 pt in. `docs/design/RetouchPro.dc.html` says nothing
about a histogram, so there is no house convention to follow; Lightroom, Capture
One and Camera Raw all put it top-right, which is where a working photographer's
eye already goes. In the Mac's dual-pane comparison the right half of the canvas
*is* the edited ("Sau") pane, so top-right is over the picture the plot
describes — the same reasoning that puts the face chips at the bottom-left of the
edited pane.

Hidden while the canvas shows the untouched original full-frame (`\` / press and
hold): the plot is of the edited texture, and leaving it up over the "Trước"
image would be a caption describing a different picture.

**macOS only**, per the user's own framing. `HistogramController.swift` and
`HistogramOverlayView.swift` are each wrapped entirely in `#if os(macOS)` — not
just their bodies — so on iOS the types do not exist, no pipeline is built and no
dispatch is ever encoded. `CanvasView.showsHistogram` defaults to `false` and
only `MacEditorView` (screen 1b) passes `true`; `PhoneEditorView` does not and
could not. The one shared file that changed for both platforms is
`LivePreviewMetalView`, which gained an optional `onDidRender` closure that is
`nil` on iOS.

### 7. No feature flag

The "measure before ship" rule (docs/PLAN.md §2) gates *algorithms that change
the picture* behind a default-off flag until they have a number. This pass writes
no pixel into the picture — it reads the finished texture into 4 KB of counters —
so the failure mode a flag protects against does not exist here. What the rule
does demand is the number, and there is one, below, with a control run.

## Measured

`Research/bench/p6-histogram-macos.json`, filed by `Scripts/bench-histogram.sh`
(xcodebuild, `-configuration Release`, `-parallel-testing-enabled NO`).
M1 Pro, macOS 27.0, 2048×1365 preview — the size the canvas actually renders.

| | ms | note |
|---|---|---|
| Histogram pass alone, every pixel | **1.071** | includes commit + `waitUntilCompleted`, so an upper bound on GPU time |
| Histogram pass alone, stride 2 | 0.470 | the unused knob |
| 60-redraw drag, **no** histogram (control) | **0.950** /redraw | same renderer, same fixture, same run |
| 60-redraw drag, histogram attached | **1.548** /redraw | 646 fps |
| **Marginal cost of a live histogram** | **+0.599** /redraw | |
| Main-thread encode + commit | **0.00095** | what the draw callback pays |
| `readOutputPixels()` (control) | **7.079** | the stalling path, 22.4 MB |
| **Speed-up vs the stalling readback** | **7423×** | |

The marginal figure (0.599 ms) is *below* the standalone pass (1.071 ms) because
the sample never waits: it overlaps the next redraw, and a redraw that arrives
while one is outstanding coalesces instead of issuing. That is the throttling
policy showing up in the measurement rather than being asserted.

1.548 ms/redraw is 646 fps against docs/PLAN.md §1.4's 30 fps bar, asserted in
the bench itself (`#expect(withHistogram < 33)`), so no time-based throttle is
warranted. Memory: 4 × 4 KB = 16 KB, against `SkinRenderNode`'s 552 MB at 24 MP.

### Correctness, which no timing number says anything about

`RPEngineTests/HistogramTests` — 10 tests, all against real GPU output on
textures whose answer is known by construction:

* half pure red / half black → exact counts in bins 0 and 255 of red, every
  pixel in bin 0 of green and blue, and luma of pure red in bin
  `floor(0.2126 × 256) = 54`;
* 256 columns at bucket-centre values → **exactly one column per bin**, which is
  what would break if the arithmetic were `v × 255` or the clamp were off by one;
* 2.5 and −0.75 → the end bins;
* a 2048×1365 frame → `sum(bins) == sampleCount` per channel, i.e. the
  threadgroup merge drops nothing;
* the async path returns counts **identical** to the blocking path on the same
  texture.

`RPUITests/HistogramOverlayTests` — 9 tests: the plot's geometry (it spans the
frame, closes on the baseline, uses a √ vertical scale so a quarter-peak bin
draws at half height), the empty and out-of-range cases, the VoiceOver string,
and the controller's coalescing policy end to end.

### A vacuous green, and the guard added because of it

The first version of `rp_histogram_accumulate` declared
`uint3 [[threads_per_threadgroup]]` next to a `uint2 [[thread_position_in_grid]]`.
MSL rejects that — every grid/threadgroup positional attribute in one signature
must have the same component count — so `makeLibrary(source:)` threw, and
`MetalContext.shared` was `nil`. Every GPU test in this package guards with
`guard let context = SpikeS3Support.context else { return }`, so **all ten tests
reported a pass without dispatching anything.**

The kernel was only caught by compiling the concatenated library by hand. Both
suites now use a `requireContext()` that records an issue and throws when the
machine *has* a Metal device and the context is `nil` anyway. A shader that does
not compile must not look like a shader that is correct.

## Consequences

* One new `.metal` file, appended **last** in `MetalContext.shaderSources` so no
  earlier file's line numbers move. Still **one library compile per process**;
  the two pipelines are built once per editor in `HistogramController.prepare`,
  off the draw callback.
* `HistogramSampler` reads any `MTLTexture` and knows nothing about the graph, so
  a Phase 3 export path or a before/after histogram is a call site, not a change.
* `ImageHistogram.clippedHighlightFraction` is computed and unused — the number a
  clipping indicator would read, if one is ever asked for.
* **Not done, deliberately**: no iPhone layout and no iPhone number; no
  interaction (no click-to-set-black-point, no channel toggles, no clipping
  badges); no histogram of the *original* for comparison; no RGB parade or
  waveform.
* **Unverified on a real device.** The feature is macOS-only, so there is nothing
  to verify on the iPhone — but the iOS build must still compile with the shared
  `LivePreviewMetalView` change, which `Scripts/test.sh ios` would confirm and
  which was not run this round (macOS-only is the standing default, 2026-09-19).

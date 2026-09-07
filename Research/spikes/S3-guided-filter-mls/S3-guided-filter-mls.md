# Spike S3 — Guided filter + MLS mesh warp in Metal, on 24 MP

Phase 0, `docs/PLAN.md` §3. Status: **both kernels are correct against
independent references and both are far inside the plan's budget on the machine
that could be measured; the plan's bars are stated for an iPhone and no iPhone
is attached to this environment, so the mobile verdict is unverified in exactly
the way S1's and S2's were.**

| Plan pass bar | Measured | Verdict |
|---|---|---|
| preview 2048 px **≥ 30 fps** while dragging a slider | guided filter (s=4) + MLS warp (grid 65) chained = **1.84 ms → 545 fps** on an M1 Pro; **4.11 ms → 244 fps** (p95 8.17 ms → 122 fps) on an iOS *Simulator* | **NOT VERIFIED on device** — 18× of headroom against the bar on the host; §6 |
| export 24 MP **< 8 s** | GPU work **16.4 ms**; whole round trip incl. JPEG decode, upload and readback **≈ 187 ms** on the M1 Pro, **≈ 1.1 s** on the Simulator (decode-dominated) | **NOT VERIFIED on device** — 43× of headroom on the whole round trip; §6 |
| guided filter is the filter it claims to be | max abs diff **2.1e-6** against a `Double` CPU transcription of He, Sun & Tang 2010 | PASS, §3 |
| MLS is the deformation it claims to be | GPU vs `Double` CPU on the real 84-handle reshape, 11 frames: **max 1.11e-3 px** at the 2048 px preview (grid 65), **max 3.34e-3 px** at 24 MP (grid 129) — `results/mls_gpu_vs_cpu.json`; reproduces a global rigid motion to 1e-8; `f(p_i) = q_i` exactly | PASS, §4 |
| control points come from a real face | S1's 478-point mesh on all 11 a6300 frames; index lists verified geometrically, 11/11 | §5 |

Every number cited is in `results/*.json` or `Research/bench/s3-*.json`.

---

## 1. What was built

`Packages/RPEngine/Sources/RPEngine/Spike/` — behind
`RPEngineFeatureFlags.guidedFilter` and `.mlsMeshWarp`, **both default off**:

| File | What |
|---|---|
| `RPEngineFeatureFlags.swift` | the two flags, `RPEngineFeatureDisabled` |
| `MetalContext.swift` | device, queue, run-time-compiled shader library, pipeline cache |
| `MetalSources/Shaders.metal` | all kernels; a resource, not a build input — §2 |
| `SpikeTextureIO.swift` | CGImage ↔ MTLTexture with the pixel space made explicit, PSNR/max-abs |
| `GuidedFilter.swift` | fast guided filter driver, reusable intermediates |
| `MLSDeformation.swift` | `Double` CPU MLS (the reference), control points, border anchors, grid interpolation |
| `MLSMeshWarp.swift` | GPU grid solve + mesh render pass |

Nothing is wired into `PreviewRendering` or a `RenderGraph` — that is Phase 2.
`RPEngineModule.info.dependsOn` is still `["RPCore"]` and
`RPTestKitTests/LayeringAuditTests` still passes: **RPEngine does not import
RPVision.** The landmark → control-point bridge is a JSON file written by the
harness (§5), which is why the harness may depend on both and the product may
not.

Measurement code: `Research/spikes/S3-guided-filter-mls/SwiftHarness`
(`s3harness`), plus `RPEngineTests/SpikeS3BenchTests` for the cross-destination
number and `Scripts/bench-s3.sh` to file it.

## 2. Two build systems, one `.metal` file

This cost more time than the algorithms did and is recorded so it is not
rediscovered.

* **`swift build` does not compile `.metal` at all.** It reports the file as
  "found 1 file(s) which are unhandled" and produces no `default.metallib`, so
  `makeDefaultLibrary(bundle: .module)` fails — and the spike harness under
  `Research/` is built with `swift build`.
* **`xcodebuild` compiles any `.metal` it can see, including one listed under
  `resources:`.** On Xcode 26 `CompileMetalFile` needs the separately
  downloadable **Metal Toolchain** component; this machine does not have it, and
  the failure is not a warning:
  `error: cannot execute tool 'metal' due to missing Metal Toolchain; use: xcodebuild -downloadComponent MetalToolchain`,
  which failed the entire `xcodebuild test` run.

Resolution: the file lives in a directory that is copied as an **opaque
resource** (`resources: [.copy("Spike/MetalSources")]`) — neither build system
looks inside a copied directory — and `MetalContext` compiles it with
`MTLDevice.makeLibrary(source:)`, the run-time compiler inside the Metal
framework, which needs no toolchain. One code path for `swift build`,
`xcodebuild -destination 'platform=macOS'` and the iOS Simulator.

Cost, measured: **236 ms** on the first compile of a process, **0.6–0.7 ms**
once Metal's own on-disk source cache is warm, **1798 ms** cold in the iOS
Simulator. Paid once in `MetalContext.shared` and excluded from every per-frame
number below.

**For Phase 2:** either install the Metal Toolchain component and move the
kernels into the app target (which does get a `default.metallib`), or cache an
`MTLBinaryArchive`. Not doing so leaves a ~1.8 s first-launch stall on iOS.

## 3. Guided filter

Self-guided, per channel, `q = mean_a·I + mean_b` with
`a = var/(var+ε)`, `b = mean_I(1−a)` — the five lines from He, Sun & Tang 2010.
Colour is filtered per channel rather than with the cross-channel 3×3 covariance
form; that is the cheaper variant and the one skin smoothing wants, because a
cross-channel fit lets a red blemish borrow structure from the green channel.

### 3a. Correctness — the control

`GuidedFilterTests.exactFilterMatchesReference` runs the Metal kernel at
`subsample = 1` (no fast-path approximation) against a `Double` CPU
implementation written from the paper, on identical half-float-quantised input,
into an RGBA32Float target so half-float output rounding is out of the
comparison.

| Check | Result |
|---|---|
| Metal vs `Double` CPU reference, ε = 1e-3, r = 5 | **max abs diff 2.1e-6** |
| ε = 1e6 vs an independently written double box blur | max abs diff 3.1e-7 |
| `amount = 0` | bit-identical to the source |

The second row is a second closed form (as `ε → ∞`, `a → 0` and the filter
degenerates to `box(box(I))`), so a coefficient pass wired backwards would fail
it even if it happened to match a mistranscribed reference.

### 3b. The fast (subsampled) path

`s` is He & Sun's 2015 subsampling factor: everything from `I` down to
`box(a), box(b)` is computed at 1/s resolution and `a`, `b` are bilinearly
upsampled for the final combine. Measured on all 11 a6300 frames at a 2048 px
preview, r = 16, ε = 4e-3, against `s = 1` (`results/accuracy.json`):

| s | PSNR vs exact (mean / worst) | max abs diff (mean / worst) | preview ms | 24 MP ms | 24 MP intermediates |
|---|---|---|---|---|---|
| 1 | — | — | 19.5 | 417 | **2 304 MB** |
| 2 | 69.1 / 66.8 dB | 0.010 / 0.036 | 3.75 | 58.2 | 576 MB |
| **4** | **59.8 / 58.0 dB** | 0.030 / 0.080 | **1.44** | **14.0** | **144 MB** |
| 8 | 52.7 / 51.1 dB | 0.060 / 0.124 | 1.00 | 7.0 | 36 MB |
| 16 | 46.6 / 45.0 dB | 0.119 / 0.191 | — | — | — |

Reading:

* **`s = 4` is the operating point.** 13.5× faster than exact at preview, 30×
  at 24 MP, and 59.8 dB against the exact filter — well above the 45 dB the plan
  sets for Phase 2's golden renders. `s = 8` still clears 45 dB and is another
  2× faster if a slower device needs it.
* **The exact filter is not an option at 24 MP on a phone regardless of speed.**
  Its float32 intermediates are **2.3 GB**; it only ran here because an M1 Pro
  has 16 GB of unified memory. Even `s = 2`'s 576 MB is not a sane iPhone
  allocation. This is a memory finding, not a speed one, and it is the reason
  `subsample` is a first-class option rather than a tuning knob.
* The `max abs diff` column is the worst single pixel, not the typical one; at
  `s = 4` it is 0.030 (≈ 8/255), and it lands on the highest-contrast edges,
  which is where the guided filter's own output is least well defined.

### 3c. Was `MPSImageGuidedFilter` the right answer instead?

MPS ships a guided filter, so not using it needs a measurement.
`s3harness mps` → `results/mps_control.json`, 2048 px preview, same radius and ε,
per-channel regression with source = guidance:

| Implementation | ms (median wall) | PSNR vs RPEngine exact |
|---|---|---|
| `MPSImageGuidedFilter`, full-res regression | **123.3** | 68.2 dB |
| RPEngine, `s = 1` (exact) | **19.6** | — |
| `MPSImageGuidedFilter`, 1/4-res regression | **1.37** | 48.5 dB |
| RPEngine, `s = 4` | **1.56** | 61.1 dB |

* At full resolution MPS is **6.3× slower** than the hand-written kernel for the
  same answer (68 dB apart is "the same answer").
* At the fast operating point MPS is **0.19 ms faster (12 %)** and **12.6 dB
  further** from the exact filter.

So MPS is not leaving performance on the table, and it has three practical
problems for this app: no `amount` blend (the sliders are 0–100), a
cross-channel regression form that has to be worked around, and `epsilon`
semantics tied to its own internal formulation. **Decision: keep the Metal
kernels.** Recorded in `docs/ADR-0007`.

### 3d. sRGB or linear light? It matters, and here is by how much

`CIRAWFilter` hands back linear-light pixels; the Photoshop panel this retouch
logic is ported from (`panelpts/RetouchProUXP/commands.js`) worked on
display-referred sRGB. The guided filter's `ε` is a variance threshold on
whatever numbers it is given, so the two are not interchangeable. Same image,
same r and ε, filtered in each space, the linear result re-encoded to sRGB for
comparison (11 frames, `results/accuracy.json`):

* **PSNR between the two results: 31.4–40.1 dB** (mean 36.7), max abs difference
  0.165–0.245 in sRGB units. That is far below the 45 dB Phase 2 calls "the
  same picture" — this is a real, visible choice, not a rounding detail.
* Mean absolute change the filter makes, by luminance decile of the source,
  averaged over 11 frames:

| source luma decile | 0 (darkest) | 8 |
|---|---|---|
| filtered in sRGB | 0.0153 | 0.0129 |
| filtered in linear | 0.0394 | 0.0085 |
| ratio linear/sRGB | **2.58×** | **0.66×** |

In linear light the same `ε` smooths shadows **2.6× harder** and highlights
**1.5× less**. For skin that is the wrong way round: shadow detail under the
eyes and along the jaw is exactly what over-smoothing destroys.

**Recommendation for Phase 2: run the skin filter on gamma-encoded (sRGB)
values**, i.e. apply the output transfer function before the skin stage rather
than after. It matches the numerics of the ported panel logic and it puts `ε`'s
sensitivity where the tones the slider is judged on live. This is a measurement
of the difference plus an argument about which side of it to be on — the
aesthetic half has not been checked with a human and should be before it is
locked.

## 4. MLS mesh warp

Moving Least Squares (Schaefer, McPhail & Warren 2006), implemented with complex
arithmetic: minimising `Σ w_i |a·p̂_i − q̂_i|²` over a complex `a` has the closed
form `a = Σ w_i conj(p̂_i) q̂_i / Σ w_i |p̂_i|²`, and `f(v) = q* + a(v − p*)`. The
**similarity** variant uses that `a`; the **rigid** variant normalises the same
numerator to unit modulus, which is the paper's eq. (8) rewritten. Two lines
each, and it makes the properties below provable rather than plausible.

The warp is the forward construction from the paper's §5: a vertex sits at
`f(v)` and carries the **undeformed** texture coordinate `v`, so the rasteriser
performs the inverse mapping and no per-pixel inverse of `f` is ever solved.

### 4a. Correctness — the controls

`MLSWarpTests`, all on the CPU reference and/or the GPU kernel:

| Property | Result |
|---|---|
| `q == p` ⇒ `f(v) == v` everywhere, both variants | max error < 1e-9 |
| interpolation: `f(p_i) = q_i` | exact at the handle, < 1e-2 px at `p_i + 1e-4` |
| a global rotation + translation is reproduced everywhere, both variants | < 1e-8 |
| similarity reproduces a uniform scale ×1.25; rigid must not | similarity < 1e-8; rigid > 10 px off |
| GPU float32 kernel vs `Double` CPU, synthetic 21 handles, 1200×900, 33×25 lattice | max **2.47e-4 px** (similarity), 2.49e-4 px (rigid) |
| GPU float32 kernel vs `Double` CPU, **real 84-handle reshape**, 11 frames | max **1.11e-3 px** at 2048 px / grid 65; max **3.34e-3 px** at 24 MP / grid 129 |
| identity warp round-trips the image | PSNR = ∞ (bit-identical) |

**The GPU-vs-CPU row, in full.** `s3harness mlsgpu` →
`results/mls_gpu_vs_cpu.json` runs both transcriptions of `f(v)` — the float32
Metal kernel `rp_mls_grid` and `MLSDeformation.grid` in `Double` — over the same
lattice, with the real 84 control points `s3harness controlpoints` derived from
S1's mesh (face-oval slim + two eye rings + 16 border anchors), on all 11 a6300
frames, at both operating points and both variants. Worst frame, worst vertex:

| resolution | grid | similarity | rigid | worst / long edge |
|---|---|---|---|---|
| 2048 px preview | 33 | 9.30e-4 px | 8.66e-4 px | 4.5e-7 |
| **2048 px preview** | **65** | **1.11e-3 px** | 1.04e-3 px | 5.4e-7 |
| 2048 px preview | 129 | 1.13e-3 px | 1.04e-3 px | 5.5e-7 |
| 24 MP | 33 | 2.48e-3 px | 2.54e-3 px | 4.2e-7 |
| 24 MP | 65 | 2.88e-3 px | 2.95e-3 px | 4.9e-7 |
| **24 MP** | **129** | 3.19e-3 px | **3.34e-3 px** | 5.6e-7 |

The error is float32 rounding and nothing else: expressed as a fraction of the
long edge it sits in 4.1e-7…5.6e-7 across every configuration, i.e. it tracks
coordinate magnitude and not lattice density or the size of the deformation.
That is also why the 24 MP figure is 13× the 21-handle synthetic one — 6000 px
coordinates instead of 1200 px (5×), on 84 handles instead of 21 (more terms in
each sum). Even the worst of them is **500× below** the mesh-interpolation error
of §4b (1.68 px at grid 65), so the transcription contributes nothing measurable
to the warp's total error. `MLSWarpTests.gpuGridMatchesCPUOnRealFaceHandles` is the
regression guard, at a 0.01 px bound and reading the same `control/*.json`; it
prints the two numbers and skips when the gitignored fixtures are absent.

The scale test is the one that decides which variant a slider may use: "mắt to"
is a uniform enlargement, and only `.similarity` can express one. If `.rigid`
had silently reproduced scale, the two would be interchangeable and the API's
doc comment would be a lie.

**The coordinate-space test.** `translationMovesContentTheRightWay` applies a
pure `+16, +8` px translation and asserts the content moved **right and down by
exactly that much** — measured error **0.0** over the whole interior — and
separately that it did *not* land at the y-flipped position or the x/y-swapped
position. A y flip, an axis swap or an inverted mapping all still produce a
plausible-looking warped face; only an explicit directional assertion catches
them. There is exactly one y flip in the code, in `rp_warp_vertex`, and this
test is what pins it.

`SpikeTextureIOTests` does the same job one layer down: a marker drawn at the
top-left of a `CGImage` must arrive at buffer index 0 and at texel `(0,0)`.

### 4b. How dense does the mesh have to be?

Measured two ways on all 11 frames at a 2048 px preview
(`results/accuracy.json`): geometrically, as the distance between the
rasteriser's piecewise-bilinear interpolation of the lattice and the exact MLS
map evaluated in `Double`; and photometrically, as PSNR against a 1025×1025
lattice (cells under 2 px, the closest thing to per-pixel that can be
rendered).

| grid | mean err in face box (px) | max err in face box, mean / worst (px) | max err / face width | PSNR vs grid 1025, mean / worst |
|---|---|---|---|---|
| 17 | 0.736 | 4.64 / 7.11 | 0.021 | 45.4 / **39.7** dB |
| 33 | 0.355 | 3.07 / 3.58 | 0.015 | 49.9 / **43.8** dB |
| **65** | **0.141** | **1.68 / 2.10** | 0.0084 | **56.3 / 54.1 dB** |
| 129 | 0.045 | 0.80 / 1.21 | 0.0043 | 65.1 / 63.2 dB |
| 257 | 0.013 | 0.28 / 0.51 | 0.0015 | 74.9 / 71.3 dB |

**65×65 is the smallest grid that clears 45 dB on every frame**, with 9 dB of
margin; 33×33 clears it on average and fails on the worst frame (43.8 dB), which
is why the average is not the number to quote. Cost between 65 and 129 is 0.04 ms
at preview and 0.12 ms at 24 MP (§6), so **grid 129 for export and 65 for
preview** buys the margin for nothing. Probes are reported separately at the
handles, inside the face bounding box and across the frame, because the error is
concentrated where the deformation is — a uniform sample over the whole frame
reads 0.006 px at grid 65 and would flatter every coarse grid.

### 4c. What the mesh buys — the control

Evaluating the same MLS per pixel instead of per lattice vertex, 84 control
points (`per_pixel_solve` in `results/bench_macos.json`):

| | mesh solve (grid 65 / 129) | per pixel | ratio |
|---|---|---|---|
| 2048 px preview | 0.29 ms | **8.36 ms** | 29× |
| 24 MP | 0.33 ms | **68.6 ms** | 208× |

At 24 MP a per-pixel MLS alone would be 4× the entire mesh-warp pipeline. The
mesh solve is also almost independent of image size (0.29 → 0.33 ms), because it
scales with lattice vertices × control points, not with pixels — which is what
makes a 24 MP export cheap.

## 5. The control points are a real face, not made-up handles

`s3harness controlpoints` runs S1's pipeline (Vision face detection → rotated
crop → Core ML 478-point mesh, `RPVisionFeatureFlags.faceLandmarks478`) on all
**11 full-resolution a6300 frames** and builds two of PLAN §1.3's sliders:

* **Bóp mặt** — the lower face-oval contour is pulled toward the face's own
  forehead→chin midline, ramping as `t²` from 0 at the eye line to full at the
  chin, by `slider/100 × 0.040 × faceWidth`;
* **Mắt to** — each eye ring is scaled about its own centroid by
  `1 + slider/100 × 0.20`.

At the modelled setting (slim 60, eyes 40) the largest handle displacement is
**2.4 % of face width**, i.e. 8.2–40.4 px depending on how big the face is in
the frame. Both deltas are fractions of face width, which is what PLAN §2
requires for a preset to transfer between images. **The magnitudes are plausible,
not tuned** — this spike measures cost and accuracy, not taste.

16 identity handles on the image border are appended
(`ControlPoints.pinningBorder`). Without them MLS's far field converges to a
single similarity transform fitted to every handle and a face-local slim visibly
shifts the background.

**The hard-coded MediaPipe index lists are verified, not trusted.** A wrong ring
still produces a warp, just of the wrong part of the face
(`results/control_points.json`, 11 frames):

| check | result |
|---|---|
| the 36 `FACEMESH_FACE_OVAL` points enclose the other 442 landmarks | **97.8 % mean, 92.5 % worst** (the shortfall is ear/temple points that sit *on* the ring) |
| each eye ring's centroid is below the forehead point and above the chin | 11/11, 11/11 |
| the two eye rings are on opposite sides of the forehead→chin midline | **11/11** |
| eye-centroid separation / face width | 0.450 mean (anatomically right for this ratio) |

All 11 frames yielded a face; `DSC05403` has two and the largest is taken, the
way an editor defaults to the subject.

## 6. Speed

`results/bench_macos.json` (harness, 3 frames × 40/8 iterations),
`Research/bench/s3-guided-mls-macos.json` and
`Research/bench/s3-guided-mls-ios-simulator.json` (`Scripts/bench-s3.sh`
scraping the `RPBENCH-S3` line that `RPEngineTests/SpikeS3BenchTests` prints).
Wall time = command buffer commit → `waitUntilCompleted`, which is what a frame
loop feels. Image `DSC05123`, 4000×6000, 84 control points.

### Preview, 2048 px long edge (1365×2048)

| Stage | M1 Pro | iOS Simulator (iPhone 17) |
|---|---|---|
| guided filter, s = 1 (exact) | 19.48 ms | 20.76 ms |
| guided filter, s = 4 | **1.44 ms** | **1.95 ms** |
| MLS warp, grid 65 (solve + draw) | **0.60 ms** | **1.13 ms** |
| MLS grid solve alone, grid 65 | 0.29 ms | — |
| **chained (guided s=4 → MLS grid 65)** | **1.84 ms → 545 fps** | **4.11 ms → 244 fps** (p95 8.17 ms → 122 fps) |

### Export, 24 MP (4000×6000)

| Stage | M1 Pro | iOS Simulator |
|---|---|---|
| guided filter, s = 4, r = 47 | 14.03 ms | 15.11 ms |
| MLS warp, grid 129 | 2.62 ms | 3.34 ms |
| **chained** | **16.4 ms** | **17.4 ms** |
| JPEG decode + orient (stand-in for RAW) | 72 ms | 1009 ms |
| CGImage → float32 → float16 → texture | 48 ms | — |
| texture → float32 readback | 50 ms | — |
| **whole round trip** | **≈ 187 ms** | **≈ 1.1 s** (decode-dominated) |

### What these numbers are and are not

* **The Simulator figure is not the device figure**, the same caveat S1 §5 and
  S2 §6 carry. The iOS Simulator executes on the host Mac's GPU (`metal_device`
  reads `Apple iOS simulator GPU`), so it measures this Mac with an extra
  translation layer, not an A-series chip. Its `gpuStartTime`/`gpuEndTime` are
  also not usable — they read 0.08–0.11 ms for work that takes 4–17 ms of wall
  time — so only the wall column is reported for it.
* **The plan's bars are not met on the plan's hardware, because that hardware is
  not here.** What can be said honestly: the preview pipeline has **18× of
  margin** against 33 ms on the host and the export has **43×** against 8 s, so
  an A-series GPU would have to be more than an order of magnitude slower than
  an M1 Pro at bandwidth-bound image work to miss either. That is an
  extrapolation, not a measurement, and the spike does not claim otherwise.
* **The measured stage is the GPU work only.** A real Phase 2 frame also carries
  colour, eyes/teeth, makeup and the `MTKView` present; §7 says what is left in
  the budget.
* Both configurations were measured with the intermediates **already
  allocated**, which is the steady state of a slider drag. Allocation is
  0.06–0.14 ms and is reported separately in `bench_macos.json`.

## 7. What this leaves for Phase 2

At 2048 px on the host, the S3 stages use **1.84 ms of a 33 ms frame — 5.6 %**.
Even at 5× that on a phone it is 28 %. The remaining stages of PLAN §2's graph
(Decode → Color → Skin → Warp → Eyes/Teeth → Makeup → Output) have to fit in the
rest, and none of them is as expensive as a 33-tap separable box filter.

Concrete carry-overs:

1. **Use `subsample = 4`, radius in full-resolution pixels, and scale the radius
   with resolution.** The export radius must be `preview_radius / preview_scale`
   (47 px here for a 16 px preview radius) or the export is sharper than the
   preview the user approved.
2. **Mesh grid 65 for preview, 129 for export.** §4b.
3. **Filter skin in gamma-encoded sRGB, not linear light.** §3d.
4. **Never allocate the exact (`s = 1`) filter at 24 MP** — 2.3 GB of
   intermediates. Keep the memory estimate (`Resources.byteCount`) as a
   precondition on mobile.
5. **Precompile the shaders**, or eat 1.8 s on first launch on iOS. §2.
6. **The warp needs border anchors**, always. §5.
7. `.similarity`, not `.rigid`, for any slider that enlarges. §4a.
8. **Get the two flags on a real iPhone.** `Scripts/bench-s3.sh ios` with
   `RP_IOS_DESTINATION='platform=iOS,name=<device>'` produces the number with no
   new code.

## 8. How to reproduce

```bash
cd Research/spikes/S3-guided-filter-mls

# 24 MP fixtures from the user's ARW files (~178 MB, gitignored)
mkdir -p images/full
for f in ../../data/*.ARW; do
  sips -s format jpeg -s formatOptions best "$f" \
       --out "images/full/$(basename "${f%.ARW}").jpg"
done

cd SwiftHarness
swift run -c release s3harness controlpoints ..   # -> control/*.json, results/control_points.json
swift run -c release s3harness bench         ..   # -> results/bench_macos.json
swift run -c release s3harness accuracy      ..   # -> results/accuracy.json
swift run -c release s3harness mlsgpu        ..   # -> results/mls_gpu_vs_cpu.json
swift run -c release s3harness mps           ..   # -> results/mps_control.json
```

Then, from the repo root:

```bash
Scripts/test.sh all
Scripts/bench-s3.sh all
```

`s3harness controlpoints` needs S1's converted model at
`Research/spikes/S1-landmark/models/FaceLandmark478.mlpackage`.
`bench` and `mps` default to the first 3 frames; `S3_BENCH_IMAGES=11` uses all.
`mlsgpu` needs only `control/*.json` (it compares two evaluations of `f(v)`, not
two renders), so it runs on all 11 frames without the 178 MB of JPEGs.

Footguns hit while running this, recorded so they are not re-found:

* **`CGColor(red:green:blue:alpha:)` has no colour space** and resolves to
  Generic RGB (gamma 1.8). A test fixture filled with "0.5 grey" reads back as
  **0.573** through an sRGB context — a correct conversion of the wrong colour.
  Build fixture colours with `CGColor(colorSpace:components:)`.
* **A CGFloat boxed in `Any` does not satisfy `as? Double`.** The
  CGFloat/Double implicit conversion added in Swift 5.5 is compile-time only;
  dynamic casts stay exact. This silently made one aggregate in
  `control_points.json` read `0`.
* The Metal Toolchain problem in §2.

## 9. Known limitations, stated plainly

* **No device number.** §6. Same blocker as S1 and S2.
* **The guided filter is only the smoothed layer.** PLAN §1.3's slider is
  *guided filter + high-pass giữ lỗ chân lông × skin mask*; the high-pass
  recombination and the skin mask are Phase 2 and are not implemented or timed
  here. They are cheap relative to the filter (one more full-res pass each), but
  "cheap" is an estimate until it is measured.
* **`alpha` (the MLS weight exponent) is not measured.** It is set to 2.0
  because a face has dozens of handles a few pixels apart and the paper's 1.0
  lets a jaw handle tug on an eyelid. Which value *looks* right needs a human,
  not a metric.
* **The slider magnitudes in §5 are plausible, not tuned.** They exist so the
  benchmark deforms a real face by a realistic amount.
* **No RAW decode.** The fixtures are `sips`-decoded JPEGs; `CIRAWFilter` is
  spike S4's subject. The decode row in §6 is listed as context for the 8 s
  budget, not as a RAW measurement.
* **Only two of the reshape sliders are modelled.** Gò má, hàm, trán, thái
  dương, mũi, miệng, môi all reduce to more handles on the same mesh; the cost is
  the control-point count, which the grid solve is linear in and which is 0.29 ms
  at 84 handles.
* **The pixel-space recommendation (§3d) has a measurement behind the
  *difference* but only an argument behind the *choice*.** Confirm with a human
  before Phase 2 locks it.

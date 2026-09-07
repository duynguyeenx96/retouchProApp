# ADR-0007 — Guided filter and MLS mesh warp: hand-written Metal kernels, run-time-compiled, behind default-off flags

Status: accepted — 2026-09-04
Scope: Phase 0 spike S3 of `docs/PLAN.md` §3 (`RPEngine` algorithm layer only —
no `RenderGraph`, no `PreviewRenderer`, no slider wiring).

## Context

PLAN §1.3 names two algorithms the Phase 2 sliders stand on:

* "Mịn da giữ texture" = **guided filter** + high-pass × skin mask;
* "Bóp mặt, gò má, cằm, mũi, mắt to…" = **mesh warp Moving Least Squares** from
  the 478 landmarks, with the delta relative to face width.

PLAN §2 puts both in `RPEngine` ("RenderGraph Metal+Core Image … Warp(MLS)").
It does not say how to implement them, and §3's pass bar is a speed bar:
2048 px preview ≥ 30 fps, 24 MP export < 8 s.

## Decision — hand-written Metal, not `MPSImageGuidedFilter`, not Core Image

Measured, 2048 px preview, r = 16, ε = 4e-3, 3 real a6300 frames
(`Research/spikes/S3-guided-filter-mls/results/mps_control.json`):

| Implementation | ms | PSNR vs the textbook filter |
|---|---|---|
| MPS, full-res regression | 123.3 | 68.2 dB |
| RPEngine, exact (`s = 1`) | 19.6 | — |
| MPS, 1/4-res regression | 1.37 | 48.5 dB |
| RPEngine, fast (`s = 4`) | 1.56 | 61.1 dB |

MPS's guided filter solves a related but different problem: its regression fits
a **cross-channel** affine map from an RGB guide to a single-channel source and
does not box-filter the coefficients — the smoothing of `a`/`b` is meant to come
from upsampling a low-resolution coefficient texture. That is right for
alpha-matte upsampling, which is what it was built for. For self-guided skin
smoothing it is 6.3× slower at full resolution for the same answer, and at the
fast operating point it is 0.19 ms faster (12 %) while sitting 12.6 dB further
from the exact filter.

It also lacks the things the sliders need: no `amount` blend (every slider is
0–100 and must interpolate), and an `epsilon` whose meaning is tied to its own
formulation rather than to the pixel values the rest of the graph works in.

Core Image was not a candidate for either algorithm: it has no guided filter,
and a per-pixel `CIWarpKernel` cannot express a mesh warp without solving the
inverse map per pixel, which §"MLS" below prices at 208× the mesh cost at 24 MP.

## Decision — the *fast* guided filter, with `subsample` a first-class option

He & Sun 2015: compute `a` and `b` at 1/s resolution, bilinearly upsample them,
combine at full resolution. Measured on all 11 frames
(`results/accuracy.json`, `results/bench_macos.json`):

| s | PSNR vs exact | preview ms | 24 MP ms | 24 MP intermediates |
|---|---|---|---|---|
| 1 | — | 19.5 | 417 | **2 304 MB** |
| 2 | 69.1 dB | 3.75 | 58.2 | 576 MB |
| **4** | **59.8 dB** | **1.44** | **14.0** | **144 MB** |
| 8 | 52.7 dB | 1.00 | 7.0 | 36 MB |

`s = 4` is the default. The load-bearing reason is not speed but **memory**: the
exact filter's float32 intermediates at 24 MP are 2.3 GB, which only ran at all
because the measuring machine has 16 GB of unified memory. `s` must therefore be
a parameter with a memory estimate attached (`GuidedFilter.Resources.byteCount`),
not a constant.

## Decision — MLS in complex arithmetic, similarity and rigid

The similarity solution has a two-line closed form when 2D points are read as
complex numbers: minimising `Σ w_i |a·p̂_i − q̂_i|²` over complex `a` gives
`a = Σ w_i conj(p̂_i) q̂_i / Σ w_i |p̂_i|²` and `f(v) = q* + a(v − p*)`. The rigid
variant is the same numerator normalised to unit modulus — Schaefer's eq. (8)
rewritten. This is shorter than the paper's 2×2-matrix formulation and it makes
the properties testable as identities rather than as tolerances:

* `q == p` ⇒ identity map (< 1e-9);
* `f(p_i) = q_i` exactly (the weights diverge at a handle, so this needs an
  explicit special case, and without it the handles do not land where the UI
  drew them);
* a global rigid motion is reproduced everywhere by both variants (< 1e-8);
* **`.similarity` reproduces a uniform scale and `.rigid` does not** — which is
  what decides that "mắt to" and "thu nhỏ mũi" must use `.similarity`.

The GPU float32 kernel agrees with the `Double` CPU implementation on the real
84-handle face reshape (11 a6300 frames, both variants,
`Research/spikes/S3-guided-filter-mls/results/mls_gpu_vs_cpu.json`, written by
`s3harness mlsgpu`): worst vertex of the worst frame **1.11e-3 px** at the
2048 px preview with grid 65, **3.34e-3 px** at 24 MP with grid 129. The error
is float32 rounding — as a fraction of the image's long edge it stays in
4.1e-7…5.6e-7 in every configuration measured, independent of lattice density
and of the deformation — and it is 500× below the grid's own interpolation error
(1.68 px at grid 65, next section), so the kernel contributes nothing measurable
to the warp. `MLSWarpTests.gpuGridMatchesCPUOnRealFaceHandles` guards it at a
0.01 px bound; the synthetic 21-handle case in the same suite reads 2.47e-4 px.

## Decision — forward mesh warp, grid 65 preview / 129 export

Vertices sit at `f(v)` and carry the **undeformed** texture coordinate `v`, so
the rasteriser performs the inverse mapping and no per-pixel inverse of `f` is
solved (Schaefer §5). Grid density, measured against the exact `Double` map and
against a 1025×1025 reference render, 11 frames at 2048 px:

| grid | max geometric error inside the face (mean / worst) | PSNR vs grid 1025 (mean / worst) |
|---|---|---|
| 33 | 3.07 / 3.58 px | 49.9 / **43.8** dB |
| **65** | **1.68 / 2.10 px** | **56.3 / 54.1 dB** |
| 129 | 0.80 / 1.21 px | 65.1 / 63.2 dB |

65 is the smallest grid that clears PLAN §3's 45 dB golden bar on **every**
frame. 129 costs 0.04 ms more at preview and 0.12 ms more at 24 MP, so export
uses it.

The control points must include **identity handles on the image border**
(`ControlPoints.pinningBorder`). MLS's far field converges to one similarity
transform fitted to all handles, so without them a face-local slim shifts the
background.

## Decision — the skin filter runs on gamma-encoded sRGB, not linear light

`ε` is a variance threshold on whatever numbers the filter is handed, so the
choice of pixel space changes the result. Measured, same r and ε, both spaces,
the linear result re-encoded for comparison (11 frames, `results/accuracy.json`):

* PSNR between the two results **31.4–40.1 dB** — far below "the same picture";
* mean absolute change by source luminance decile: in linear light the filter
  smooths the darkest decile **2.58× harder** and the 9th decile **0.66×** as
  hard as in sRGB.

For skin that is the wrong way round — shadow detail under the eyes and along
the jaw is what over-smoothing destroys first. sRGB also matches the numerics of
`panelpts/RetouchProUXP/commands.js`, which the retouch logic is ported from and
which operated on 8-bit display-referred data.

**The difference is measured; the choice of side is an argument.** It should be
confirmed with a human before Phase 2 locks it.

## Decision — shaders compiled at run time from a copied directory

`Spike/MetalSources/` is declared `resources: [.copy(...)]` and `MetalContext`
calls `MTLDevice.makeLibrary(source:)`. This is not the ideal shipping
arrangement; it is the only one that works in both build systems today:

* `swift build` does not compile `.metal` at all (it reports the file as
  "unhandled" and emits no `default.metallib`), and the `Research/` spike
  harness is built with `swift build`;
* `xcodebuild` compiles any `.metal` it can see — **including one listed under
  `resources:`** — and on Xcode 26 that needs the separately downloadable Metal
  Toolchain component. Without it, `xcodebuild test` fails to build outright:
  `error: cannot execute tool 'metal' due to missing Metal Toolchain`.

Neither build system looks inside a copied *directory*, so the directory form
sidesteps both. Cost: 236 ms per process cold, 0.6 ms warm on macOS, **1798 ms
cold in the iOS Simulator**.

**Phase 2 must fix this**, either by installing the Metal Toolchain component and
moving the kernels into the app target, or by caching an `MTLBinaryArchive`.
Shipping as-is leaves a ~1.8 s first-launch stall on iOS.

## Decision — default-off flags, and RPEngine still does not import RPVision

`RPEngineFeatureFlags.guidedFilter` and `.mlsMeshWarp` gate construction of
`GuidedFilter` and `MLSMeshWarp`; with a flag off the initialiser throws
`RPEngineFeatureDisabled`. Same reason as `RPVisionFeatureFlags`: the plan's
bars are stated for an iPhone and only a Mac and an iOS Simulator could be
measured.

The flags are a copy of `RPVisionFeatureFlags`' shape rather than a shared type.
Hoisting a flag registry into RPCore so two sibling packages can share three
lines would put a process-global mutable store at the bottom of the dependency
graph. `resetToDefaults()` carries the same warning ADR-0006 records: it is not
a per-test teardown hook, because suites run concurrently.

`MLSMeshWarp` takes `[CGPoint]` control points, not a `FaceLandmarks478`.
`RPTestKitTests/LayeringAuditTests` forbids `RPEngine` from importing
`RPVision`, and that rule is kept: the spike harness under `Research/` depends on
both, runs S1's landmark pipeline, and writes the handles to
`control/*.json`, which `RPEngineTests` then reads. Phase 2's `RenderGraph` will
need the same seam — a plain value type between `FaceAnalysis` and the warp.

## Alternatives rejected

* **`MPSImageGuidedFilter`** — measured above.
* **A bilateral filter or `CIBilateralBlur`-style approximation** for skin. The
  plan says guided filter, and the guided filter's `O(1)`-per-pixel box
  formulation is what makes a 47 px radius at 24 MP affordable at all; a
  bilateral of that radius is not.
* **Per-pixel MLS in a compute kernel.** Measured as the control: 8.36 ms at
  2048 px and **68.6 ms at 24 MP** against 0.29–0.33 ms for the mesh solve,
  i.e. 29× and 208×. It also cannot be used directly for a forward map.
* **Solving the inverse deformation per pixel** (so the warp could be a
  `CIWarpKernel`). MLS has no closed-form inverse; it would need an iterative
  solve per pixel on top of the cost above.
* **A precompiled `.metallib` checked into the repo.** Would work, but it is a
  build artefact whose source could drift from the `.metal` file, and it would
  have to be built for macOS and iOS separately on a machine with the toolchain
  this one does not have.

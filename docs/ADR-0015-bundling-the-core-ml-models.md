# ADR-0015 — Bundling the three Core ML models into the app

Status: accepted, 2026-09-07.
Supersedes the "where the models ship is still open" note in ADR-0005 §Decision,
ADR-0006 and ADR-0008 §Notes.

## Problem

On a real iPhone every face-dependent slider group (Da / Mặt / Mắt-Răng) did
nothing, silently. Color kept working, because it is whole-frame and needs no
face.

The models were never in the app. Nothing referenced them in
`RetouchPro.xcodeproj/project.pbxproj` — no `PBXFileReference`, no build phase —
and `Packages/RPVision/Package.swift` declares them only on the **test** target.
`AppEngineSetup.models()` therefore fell through to a dev-machine fallback that
resolved `Research/spikes/*/models/` from `#filePath`. That path exists on the
Mac and in the iOS Simulator, because both share the Mac's filesystem, and does
not exist inside a device's sandboxed container. `models()` returned `nil`,
`FaceAnalyzerFaceInputProvider.standard()` returned `nil`, and the app ran with
`NoFaceInputProvider` without saying so anywhere a user or a reviewer would look.

Measured before/after on the same iPhone (`session.log` pulled with
`devicectl device copy from`):

```
2026-09-07T07:04:44Z  ... | face analysis: unavailable (no Core ML models)     ← old build
2026-09-07T07:25:41Z  ... | face analysis: available
2026-09-07T07:25:41Z  face models: app bundle — BlazeFaceShortRange.mlmodelc,
                      FaceLandmark478.mlmodelc, FaceParsing19.mlmodelc          ← this build
```

A second bug was found on the way and is part of the same fix: the name list in
`models()` put `BlazeFaceShortRange_fp16.mlpackage` and
`FaceLandmark478_fp16.mlpackage` **first**, and those are the `MLMultiArray`-input
builds the conversion scripts keep only as numeric controls against TFLite.
`BlazeFaceModel.predict(image:)` hands Core ML a `CVPixelBuffer` for a feature
called `image`, so those builds cannot be used at all — they construct fine and
throw on the first photo. On this Mac, `models()` really was returning them
(`APPTEST models: BlazeFaceShortRange_fp16.mlpackage,
FaceLandmark478_fp16.mlpackage, FaceParsing19.mlpackage`), so the face path was
broken on macOS too, in a different way and for a different reason.

## Decision 1 — the app target compiles the models, from where they already are

The three `.mlpackage`s are build inputs of the `RetouchPro` target's **Sources**
phase. Xcode's `com.apple.compilers.coreml` rule (`CoreML.xcspec`, file type
`folder.mlpackage`) turns each into `$(ProductResourcesDir)/<name>.mlmodelc/`,
which is `Contents/Resources/` on macOS and the bundle root on iOS — in both
cases exactly `Bundle.main.resourceURL`, which `AppEngineSetup` already searched.

Verified rather than assumed, because SwiftPM's handling of Core ML resources is
the thing this ADR was warned about:

```
$ find <DerivedData>/Build/Products/Debug-iphoneos/RetouchPro.app -maxdepth 1 -iname '*.mlmodelc*'
.../RetouchPro.app/FaceLandmark478.mlmodelc
.../RetouchPro.app/FaceParsing19.mlmodelc
.../RetouchPro.app/BlazeFaceShortRange.mlmodelc
```

* **Sources phase, not Copy Bundle Resources.** The Core ML spec is a *Compiler*;
  in Resources the `.mlpackage` would be copied verbatim and the app would pay
  `CompiledModelCache`'s compile at first use, per launch-install.
* **`COREML_CODEGEN_LANGUAGE = None`.** RPVision loads by URL
  (`FaceLandmark478Model(url:)`), so the generated model classes are dead code.
* **Referenced in place, under `Research/spikes/*/models/`, not copied into
  `App/`.** Those are the same directories every bench and every RPVision test
  loads; they are tracked by git (`.gitignore` excludes only the fp32 / logits
  comparison builds). A second copy would be 28 MB and a second thing to keep in
  sync with `convert_tflite_to_coreml.py` / `convert_blazeface_to_coreml.py` /
  `convert_bisenet_to_coreml.py`. The consequence to know about: those three
  directories are now **product inputs**, not only research artefacts.

Rejected: declaring them as `.copy`/`.process` resources on the RPVision library
target. It would put them in `RPVision_RPVision.bundle` and split the answer
between `Bundle.module` and `Bundle.main` for no gain — and RPVision's API takes
a URL precisely so it does not own this question.

## Decision 2 — one variant per network, and it is the unsuffixed one

| shipped | input | rejected siblings |
|---|---|---|
| `BlazeFaceShortRange.mlpackage` 348 KB | 128 px RGB image, fp16 | `_fp16`, `_fp32` (MultiArray), `_fp32_image` |
| `FaceLandmark478.mlpackage` 2.7 MB | 256 px RGB image, fp16 | `_fp16`, `_fp32` (MultiArray) |
| `FaceParsing19.mlpackage` 25 MB | 512 px RGB image, fp16, `labels` out | `_logits_fp16`, `_logits_fp32` |

These are the builds the conversion scripts label "the one RPVision loads" and
the ones the measurements were taken on: BlazeFace fp16 costs 0.001–0.002 px of
end-to-end landmark error against an fp32 image-input control (ADR-0008), and
`FaceParsing19` is the one ADR-0006 marks "product + bench". Total added to the
app: **28 MB** (`RetouchPro.app` is 36 MB).

`AppEngineSetup.ModelName` now holds the three stems and the extension order
(`mlmodelc` before `mlpackage`), and a test asserts no chosen URL ever contains
`_fp16`, `_fp32` or `logits`.

## Decision 3 — search order, all-or-nothing, and a loud failure

`AppEngineSetup.modelSources()`:

1. `RP_MODELS_DIR` — explicit override. Nothing in the repository sets it.
2. **the app bundle** — what every real build uses, on every platform.
3. `Research/spikes/{S1-landmark,S2-face-parsing}/models/` from `#filePath` —
   **last resort**, and it stays only because the app-target test bundle has no
   `TEST_HOST`, so its `Bundle.main` is the test runner and can never hold the
   models. It is deliberately *after* the bundle so it cannot mask a broken
   embed, which is what it was doing before.

A source must supply **both detectors or nothing**: two models from the bundle
plus a third from the source tree is precisely the shape of failure that works
on the developer's Mac and not on a device. `ModelDiscovery.summary` names the
source and the files on success, and on failure lists every directory tried and
what was missing there; `AppContainer.startupLog` writes it to `session.log` on
every launch. The old code produced no line at all.

`FaceAnalyzerFaceInputProvider` also logs each analysis —
`face analysis: 1 face(s) in <key> — 556.9 ms, first box (849,886)-(1005,1042)
478 landmarks` — because "0 faces on this photo" and "this build has no models"
used to look identical. `LivePreviewController` additionally mirrors a failure to
the unified log, since a message that lives only in a SwiftUI overlay is not one
anybody reads when the complaint is "the sliders do nothing".

## Decision 4 — `RP_FACE_SELFTEST`, so a device run can be scripted

The workflow rule this bug produced ("build to the real device and exercise the
feature") cannot be met by a test bundle: `xcodebuild` rejects tool-hosted test
bundles on a device destination (*"Tool-hosted testing is unavailable on device
destinations"*), and even if it did not, their `Bundle.main` is the test runner —
they can never see the embedded models, the exact thing under test. The
alternative was asking a human to tap a thumbnail on every device check.

So `App/FaceSelfTest.swift`: when `RP_FACE_SELFTEST` is set, one analysis runs at
launch through the **product** objects — the same `PreviewRendering` decode, the
same `FaceInputProviding`, the same models out of `Bundle.main` — and the result
goes to `session.log`. Off unless the variable is set, read-only, after the UI is
on screen. The value is `first-shot`, an absolute path, or a bare file name
looked up in the project library (which is how a photo pushed with
`devicectl device copy to` is named). Path resolution is a pure function with
unit tests; the run itself is only ever exercised on a device.

```
xcrun devicectl device process launch --console --device <udid> \
  --environment-variables '{"RP_FACE_SELFTEST":"DSC05259.jpg"}' com.duynguyen.RetouchPro
```

## Numbers this produced — first real-iPhone measurements of the face pipeline

Every previous phase note ends "chưa đo trên iPhone thật". iPhone (IphoneDuy,
iOS 26.6), 2048 px preview of a real a6300 frame, all four slider groups on so
the parsing masks are requested:

| step | iPhone | M1 Pro (`Research/bench/p2-face-analyzer-macos.json`) |
|---|---|---|
| decode `DSC05259.jpg` 6000×4000 → 1365×2048 | 66.5 ms | 117.4 ms (ADR-0013, from ARW) |
| Vision + BlazeFace + mesh + parsing, cold | **556.9 ms** | 36.4 ms |

Three further cold runs through the real editor UI on the user's own photos:
552.1 / 538.2 / 440.5 ms, 1 face each, 478 landmarks each. So the pipeline is
**~15× slower on the iPhone than on the Mac**. It is once per shot and cached
(warm 0.052 ms on the Mac), so a slider drag is unaffected, but half a second of
latency between opening a shot and the face-dependent sliders taking effect is a
real, visible cost and is **not** what PLAN §Phase 0 asked for (S1's bar was
< 40 ms/face, S2's < 150 ms). Which of the four stages spends it is not measured
here — that needs a per-stage bench on the device and is left open.

## Consequences

* The app is 36 MB, 28 of it models. Not a concern for a locally-signed build.
* `Research/spikes/*/models/{BlazeFaceShortRange,FaceLandmark478,FaceParsing19}.mlpackage`
  are product inputs. Deleting or regenerating one changes what the app ships;
  `.gitignore` must keep tracking them.
* Anyone re-running a conversion script must rebuild the app, not just the bench.
* The ~550 ms on-device analysis is recorded, not fixed.

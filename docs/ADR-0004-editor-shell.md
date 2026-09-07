# ADR-0004 — Editor shell: layout, project ownership in the UI, and the render seam

Status: accepted — 2026-09-04
Scope: Phase 1 item 4 of `docs/PLAN.md` (`RPUI`, plus a stub protocol in
`RPEngine` and the app's `RootView`/`AppContainer`).

## Context

PLAN Phase 1 item 4 is one line: *"UI khung Evoto: filmstrip (rating/flag),
canvas zoom/pan, before/after, panel slider trống."* PLAN §Context fixes the
arrangement — filmstrip left, canvas centre, slider panel right, preset bar top
— and §2 fixes where the code lives (`RPUI`, depending downward only).

Everything the sliders will *mean* is Phase 2; preset application is Phase 3;
`RPEngine` is still the empty stub from item 1. So this is chrome and
navigation: the shell those phases plug into.

## Decisions

### 1. `RPUI` depends on `RPImport` — flagged for review

ADR-0003 §12 introduced `ProjectMutating` / `ProjectSession` because the
asynchronous importers cannot hold an `inout Project`, and it says explicitly
that the app's observable model should conform to the same protocol. Those two
types live in `RPImport`.

The UI is now the *other* writer of a `Project` (ratings and flags from the
filmstrip). It has to use the same ownership model or the race ADR-0003 §12
describes comes straight back through the front door. So `RPUI` declares
`.package(path: "../RPImport")` and `EditorModel`:

- holds a `ProjectSession` as the authoritative owner,
- routes **every** write through `session.withProject`,
- keeps a `project` snapshot for SwiftUI to observe, re-read after each write,
- conforms to `ProjectMutating` itself by forwarding to the session, so a
  `FolderWatcher` started from the editor can be handed the model.

The edge is downward (`RPUI → RPImport → RPCore`), so it breaks no layering
rule, `RPTestKit.SourceAudit` still passes, and ADR-0003 §Consequences already
predicted item 4 wiring `FilesImporter` / `PhotosImporter` / `MTPCameraImporter`
/ `FolderWatcher` into this layer.

**What is worth a second opinion:** `ProjectMutating` is about *project
ownership*, not about importing, and it now has two consumers in different
packages. The tidier home is `RPCore`, next to `ProjectStore`. Moving it would
touch `RPCore` and `RPImport`, which this task was told not to modify, so it was
not done. If a later phase agrees, the move is mechanical — the protocol has no
`RPImport` dependencies — and `RPUI`'s `RPImport` edge would then only be needed
once the import UI lands (which it will, in this same package).

Rejected: giving RPUI its own ownership type. That is the "two writers, last
save wins" bug ADR-0003 §12 exists to prevent, written a second time.

### 2. The render seam: `PreviewRendering` in `RPEngine`, with a passthrough

The canvas needs pixels and there is no render graph. Two ways to do that:

- **Rejected** — load the file directly in `RPUI`. Every call site would then be
  written against a `URL`, and Phase 2 would have to rewrite the canvas, the
  filmstrip, the projects grid and the before/after control.
- **Chosen** — declare the seam now:

  ```swift
  public protocol PreviewRendering: Sendable {
      var appliesEditState: Bool { get }
      var preferredPreviewPixelSize: Int { get }
      func renderPreview(_ request: PreviewRequest) async throws -> PreviewImage
  }
  ```

  with `PreviewRequest(originalURL:editState:maxPixelSize:)` and one Phase 1
  conformance, `PassthroughPreviewRenderer`, backed by a decode-only
  `ImageDecoder` (ImageIO `CGImageSourceCreateThumbnailAtIndex`).

**This is new code in `RPEngine`, and it is deliberately not rendering.**
`PassthroughPreviewRenderer` ignores `PreviewRequest.editState` entirely; there
is no filter, no Metal, no Core Image. A test asserts it — same file, two
different `EditState`s, byte-identical output
(`PreviewRendererStubTests.passthroughIgnoresEditState`). Phase 2 replaces the
conformance injected in `AppContainer` and no view changes.

ImageIO rather than `CIRAWFilter`: it is decode-only, identical on both
platforms, and for an ARW it hands back the camera's embedded preview instead of
developing the mosaic — right for a thumbnail, honest as a canvas placeholder,
and explicitly *not* a RAW pipeline. PLAN spike S4 and Phase 2 own that.

`previews/` is still written by nobody. `EditorModel.thumbnailURL(for:)` prefers
`Shot.previewRelativePath` when the file exists and falls back to the original,
so the day RPEngine starts writing previews the filmstrip picks them up with no
call-site change (test:
`EditorModelTests.thumbnailFallsBackToOriginal`).

### 3. Before/after is wired and inert, and the UI says so

The two sides of the comparison are the same `PreviewRendering` call with
different `EditState`s (`request` and `request.original`). With the passthrough
renderer those are the same pixels — so:

- `PreviewImageCache` folds the `EditState` into its key **only when**
  `renderer.appliesEditState` is true. Today the "before" and "after" requests
  hit one cache entry instead of decoding the same file twice
  (`PreviewImageCacheTests.passthroughCollapsesBeforeAndAfter`).
- The canvas status bar shows *"Preview: original file — edits render in
  Phase 2"* whenever `appliesEditState` is false.

The alternative — drawing a fake difference, or hiding the control until Phase 2
— was rejected in both directions: a fake diff is a lie, and hiding the control
means its interaction (split handle, side-by-side, hold-to-see-original) is
never exercised until the phase that can least afford surprises. Split,
side-by-side and hold are all implemented; only the pixel difference is missing.

### 4. Custom `HStack`, not `NavigationSplitView`

`NavigationStack` is used **once**, in `RetouchProRootView`, for Projects →
Editor. That is a genuine hierarchy.

The editor itself is a plain `VStack { PresetBar; HStack { Filmstrip; Canvas;
SliderPanel } }`. `NavigationSplitView` was rejected for three reasons:

1. **It collapses at compact width** into push navigation. The entire point of
   this screen is that the filmstrip, the canvas and the panel are on screen
   together; a layout that silently becomes "tap a row to see the photo" is not
   the Evoto layout the user fixed.
2. **Its columns are a navigation hierarchy** (sidebar / content / detail). The
   slider panel is an *inspector on the same subject as the canvas*, not a
   destination; and the preset bar spans all three columns, which a split view
   has no place for.
3. **Column widths and visibility belong to the user** in a split view. Here
   they are fixed by `EditorMetrics` (filmstrip 168, panel 288).

Narrow windows are handled by `EditorLayout.forWidth(_:)`: at ≥ 900 pt the three
panes; below, canvas with the filmstrip as a horizontal strip underneath and the
panel behind a toolbar button. The rule keys off the **measured width**, not
`horizontalSizeClass` — that environment key does not exist on macOS, and a
700 pt Mac window has exactly the same problem an iPhone does. One rule, one
code path, and it is a pure function so it is unit-tested
(`EditorLayoutTests`).

### 5. The slider panel shows disabled parameter names, not nothing

PLAN says "panel slider trống". The panel renders the six
`EditState.SectionKey` namespaces as collapsible groups, each listing its
planned Phase 2 / Phase 5 parameters as **disabled** rows with a `SwiftUI.Slider`
pinned at `RPCore.Slider.defaultValue` (0) over `RPCore.Slider.range` (0…100).

Empty groups would have said nothing about the panel's eventual shape;
working-looking sliders that do nothing would be worse than an obviously
unfinished panel. Disabled rows plus a "Phase 2" tag on each group are the
honest middle.

`SliderPanelLayout` is *data*, and a test asserts it covers exactly
`EditState.SectionKey.all` in order — so a namespace added in RPCore without a
home in the UI fails a test instead of silently never appearing.

### 6. `EditorModel` holds its own `ProjectStore` value

Under Swift 6, an actor's stored `let` is actor-isolated, so
`session.store` cannot be read synchronously from the main actor and the views
cannot derive file paths. `EditorModel` therefore holds an equal
`ProjectStore` of its own, constructed from the same bundle URL.

That is sound precisely because ADR-0002 §10 made `ProjectStore` a *value*
holding a URL and a writer: two equal stores are interchangeable, and every
*mutation* still goes through the session, which passes its own store into the
body. It is not a second source of truth — `Project` still has exactly one owner.

### 7. macOS gets a real AppKit event view for canvas input

SwiftUI has no scroll-wheel event on macOS, and `MagnifyGesture` alone leaves
the Mac with no way to pan a 24 MP frame with a trackpad. `CanvasEventCatcher`
(`#if os(macOS)`, ~60 lines) overrides `scrollWheel`, `magnify`, `mouseDragged`
and double-click: scroll = pan, ⌥/⌘ + scroll = zoom about the pointer, pinch =
zoom about the pointer, drag = pan, double-click = fit ⇄ 100 %. iOS uses
`DragGesture` + `MagnifyGesture`. RPUI is the only package allowed to see AppKit
(ADR-0001 §2), and the audit test enforces that.

All the arithmetic is in `CanvasViewport`, which has no SwiftUI and no AppKit,
so the anchor-stability property (*the image point under the cursor stays under
the cursor*), the clamping and the fit rule are tested directly rather than by
looking at a window.

`CanvasViewport.zoom` is the scale **relative to the image's own pixels** —
`1.0` is 100 %, one image pixel per point — not relative to a fit baseline. That
is what makes the "38 %" readout mean something, and it makes `zoom == 1`
identical in every window size.

### 8. The projects library is `<Documents>/Retouch Pro Projects`

One path expression that resolves to the app container on sandboxed macOS and to
the app's Documents on iOS, reachable without a security-scoped bookmark.
Opening a bundle from anywhere else needs a picker and a bookmark; that is the
Files-import path and it is not built yet (see Consequences).

`createProject` appends " 2", " 3"… on a name clash rather than failing —
creating "Studio" twice in one day should not require a new word.
An unreadable bundle is **listed** with its error, not hidden: hiding a project
because this build cannot parse its manifest looks like data loss.

### 9. What is deliberately not here

- **No import UI.** Phase 1 item 3 built the importers; wiring a file picker, a
  `PHPickerViewController`, a device list and a folder picker to them — and
  rendering `ImportReport` — is not in this task's scope. `EditorModel`
  conforming to `ProjectMutating` is the hook that work plugs into, and
  `ImportReport.summary` / `detailedDescription` (ADR-0003 §2) are still
  unconsumed.
- **No preset application.** The preset bar lists `presets/` read-only and says
  "Applying presets is Phase 3" on screen.
- **No shot removal from the UI.** `ProjectStore.removeShot` exists and
  `FilmstripSelection` already handles the active shot disappearing, but no
  control calls it yet — deleting a frame deserves the confirmation UI that
  ADR-0002 §8's "removing a shot never deletes the file" distinction implies.

## Consequences

- Phase 2 swaps one line in `AppContainer` (`previewRenderer:`) and the whole
  UI starts showing rendered edits, including the before/after diff and the
  cache's per-`EditState` keying.
- Phase 2's sliders write into `EditorModel.activeEditState` and save through
  `ProjectStore.saveEditState`; `SliderPanelView`'s disabled rows become real
  ones and `SliderPanelLayout` stays the grouping.
- Phase 3 hangs "apply preset" on `PresetBarView`'s existing selection and
  auto-apply on `Project.autoApplyPresetID`, which the bar already displays.
- The import UI adds views to `RPUI` and needs nothing new from RPImport, but
  `App/` still needs the Info.plist usage string and the two sandbox
  entitlements from ADR-0003 §5 before Photos or camera import can run.
- `RPUIModule.info.dependsOn` is now `[RPEngine, RPImport, RPCore]`; the
  layering audit and `ModuleGraph.isWellFormed` still pass.

## Amendment — Phase 1 review, 2026-09-04

**§1 is superseded: `RPUI` no longer depends on `RPImport`.**

§1 flagged the edge for review and named the tidier home itself: `RPCore`, next
to `ProjectStore`. The review agreed, and the move was made —
`ProjectMutating` and `ProjectSession` are now
`Packages/RPCore/Sources/RPCore/ProjectSession.swift` (see ADR-0003 §A3). The
edge existed only to reach them, and `EditorModel` needed nothing else from
`RPImport`, so `.package(path: "../RPImport")` is gone from `RPUI/Package.swift`
and the UI layer no longer links PhotoKit / ImageCaptureCore.

Everything §1 says about *ownership* is unchanged: `EditorModel` still holds a
`ProjectSession`, still routes every write through `session.withProject`, and
still conforms to `ProjectMutating` — the app target, which links `RPImport`
directly, is what hands a `FolderWatcher` or `MTPCameraImporter` the model.

Consequently `RPUIModule.info.dependsOn` is `[RPEngine, RPCore]`, and
`LayeringAuditTests` now asserts that `RPUI` does not import `RPImport`, so the
edge cannot come back by accident. When the import UI lands in `RPUI`, adding it
back is a deliberate one-line decision, not an inherited one.

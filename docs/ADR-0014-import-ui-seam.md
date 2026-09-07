# ADR-0014 — Import UI: a seam in RPUI, the RPImport call in the app target

Status: accepted — 2026-09-07
Scope: bug fix, not a phase item. Two defects found the first time the app was
run on a physical iPhone: a duplicate back button in the editor, and **no way at
all to get photos into a project**. Phase 1 item 3 built `RPImport`; Phase 1
item 4 shipped the editor shell and explicitly left the import UI undone
(docs/ADR-0004 §9, "No import UI"). Nothing since wired them together, so
manual testing of the app was blocked on it.

## Context

`RPImport` has `FilesImporter`, `PhotosImporter`, `MTPCameraImporter` and
`FolderWatcher`, all tested (docs/ADR-0003). `RPUI` has the Evoto shell. A grep
for `RPImport` in `Packages/RPUI` returned nothing: the two halves had never
been joined, and `ProjectsView`'s empty state told the user to "import from
Files, Photos or a camera" with no control that could.

The obstacle is a decision that was made deliberately and is asserted by a test.
`RPUI` used to depend on `RPImport`; the Phase 1 review removed the edge
(docs/ADR-0004 amendment, docs/ADR-0003 §A3) because it existed only to reach
`ProjectMutating`, which moved to `RPCore`. `LayeringAuditTests.noUpwardImports`
now fails if `RPUI` imports `RPImport`. That ADR also wrote down what to do when
this day came: *"When the import UI lands in RPUI, adding it back is a
deliberate one-line decision, not an inherited one."*

## Decision

**Do not add the edge back. Declare a protocol in RPUI and implement it in the
app target.**

```swift
// Packages/RPUI/Sources/RPUI/Model/ShotImporting.swift
public protocol ShotImporting: Sendable {
    func importFiles(at urls: [URL], into host: any ProjectMutating) async -> ShotImportSummary
    func importPhotos(withLocalIdentifiers: [String], into host: any ProjectMutating) async
        -> ShotImportSummary
}
```

`App/RPImportShotImporter.swift` conforms, using `FilesImporter` /
`PhotosImporter`. `AppContainer` builds it, `RootView` passes it to
`RetouchProRootView`, which passes it to `EditorModel`.

This is the third instance of a pattern the codebase already has twice, not a
new idea:

| Seam | Declared in | Implemented in | Why |
|---|---|---|---|
| `PreviewRendering` (ADR-0004 §2) | RPEngine | RPEngine / app | keeps `URL`-decoding out of every view |
| `FaceInputProviding` (ADR-0013) | RPEngine | app (`FaceAnalyzerFaceInputProvider`) | RPEngine must not link Core ML |
| **`ShotImporting`** | RPUI | app (`RPImportShotImporter`) | RPUI must not link PhotoKit / ImageCaptureCore |

Reasons for the seam over the edge, in order of weight:

1. **The picker UI is not the importer.** The SwiftUI half — `.fileImporter`,
   `.photosPicker`, the toolbar menu, the filmstrip's empty state — belongs in
   RPUI and stays there. The only thing that has to cross is "here are some URLs
   / asset identifiers, put them in the project". That is a five-line protocol
   over plain values; an entire package dependency to carry it is the wrong
   size.
2. **RPUI's test bundle stays free of PhotoKit and ImageCaptureCore.** 79 RPUI
   tests run in 0.2 s with no framework that wants a signed bundle or a device.
3. **The audit test keeps its meaning.** No rule is loosened, so nothing else
   can drift through the same hole later.

Cost, stated plainly: `ShotImportSummary` duplicates five fields of
`ImportReport`. It is accepted because the two strings that matter — `message`
and `detail` — are `ImportReport.summary` and `.detailedDescription` passed
through **verbatim** by the adapter, so the banner and the log cannot say
different things. What the UI loses is the per-item outcome list, which it was
never going to render anyway (ADR-0003 §2 designed those two strings for exactly
this).

Rejected: re-adding `.package(path: "../RPImport")` to `RPUI/Package.swift` and
deleting the `"RPUI": ["RPImport"]` rule from `LayeringAuditTests`. It is what
ADR-0003 §Consequences and ADR-0004 §1 both originally imagined, and it is
simpler by one file — but it links PhotoKit and ImageCaptureCore into the view
layer to save a 30-line value type, and it removes an assertion instead of
satisfying it.

## What was wired, and what was not

**Wired:** Files and Photos, end to end.

- Toolbar `Menu` in `EditorView` (`.primaryAction` group) → "From Files…" /
  "From Photos…"; and the same two as buttons in `FilmstripView`'s empty state,
  which is where a project with nothing in it puts them in front of the user.
  Import is *in the editor* and not on the projects grid because photos go into
  an open project, and the fixed Evoto layout (preset bar top, filmstrip left,
  canvas centre, panel right) has no other home for a global action.
- `.fileImporter` with `allowedContentTypes:` derived from
  `ProjectBundle.importableExtensions` (`ImportFileTypes.allowed`) plus
  `public.image`, so RPCore's allow-list and the panel's filter cannot drift.
- `.photosPicker(… photoLibrary: .shared())`. The `photoLibrary:` argument is
  **required**, not decoration: it is what makes `PhotosPickerItem.itemIdentifier`
  (the `PHAsset.localIdentifier`) non-nil, and the identifier is what lets
  RPImport export the asset's **RAW** resource (ADR-0003 §6). The
  `loadTransferable` route a plain `PhotosPicker` offers cannot promise that.
- After a run, `EditorModel.runImport` pulls the snapshot (`refresh()`) and, only
  if the active shot actually moved, reloads the `EditState`. That is what makes
  an import into an empty project land on the new shot with the GPU canvas
  loaded, without closing and reopening the project.

**Not wired, unchanged by this task:** `MTPCameraImporter` (camera / card over
USB) and `FolderWatcher` (watch a folder → auto-import). Both are built and
tested in RPImport and still have no UI. They are a bigger surface — a device
list, a folder picker with a persisted security-scoped bookmark, batch progress —
and Files + Photos is what unblocks manual testing. When they land they add two
methods to `ShotImporting`, not a new mechanism.

## Sandbox and privacy

- `INFOPLIST_KEY_NSPhotoLibraryUsageDescription` added to both app-target
  configurations. Without it, requesting Photos authorization terminates the
  process.
- `com.apple.security.personal-information.photos-library` is a **macOS-only**
  sandbox entitlement (ADR-0003 §5), so the target now has two entitlement
  files: `App/RetouchPro.entitlements` (shared / iOS) and
  `App/RetouchPro-macOS.entitlements`, selected by
  `"CODE_SIGN_ENTITLEMENTS[sdk=macosx*]"`. Putting the key in the shared file
  would ship an entitlement in the iOS binary that no provisioning profile
  grants. Verified on the built products: the macOS `.app` carries the key, the
  iOS one does not, and both carry the usage string.
- `com.apple.security.files.user-selected.read-write` was already there and is
  what makes the file panel's URLs readable. **No security-scoped bookmark is
  created or needed**: RPImport brackets each picked URL in
  `startAccessingSecurityScopedResource()` for the duration of the copy
  (`ImportOptions.usesSecurityScopedAccess`, `ShotIngestor.ingest`), and the
  copy is finished before the import returns. Bookmarks are for access that must
  outlive the picker — opening a `.rpproj` from outside the library folder
  (`ProjectLibrary.defaultRoot()`'s doc comment) and `FolderWatcher`'s watched
  folder. Neither is part of this fix.
- **Folders are deliberately not offered in the file panel** (`.folder` is not in
  `allowedContentTypes`) even though `ShotIngestor.expand` can walk one. In a
  sandbox the children of a picked directory are not independently scoped:
  `expand` opens and closes the directory's scope during the walk, and `ingest`
  then re-opens scope on each child, which fails. Making folder picking work is
  a change to RPImport's scoping, not to this UI, so it is left out rather than
  shipped broken. Dropping a folder on the Mac window (PLAN Phase 1 item 3's
  "drag-drop Mac") is not wired either.

## The other bug: two back buttons

`RetouchProRootView` pushes `EditorView` with `.navigationDestination`, so UIKit
supplies a back chevron; `EditorView.toolbarContent` adds its own at
`.cancellationAction` because leaving has to run `close()`, which releases the
open shot's GPU textures. On iPhone that is two chevrons side by side.

Fix, in two parts:

1. `.navigationBarBackButtonHidden(true)` on `EditorView`'s body, inside
   `#if os(iOS)` — the same shape as the `navigationBarTitleDisplayMode` block
   directly above it, and necessary because the modifier does not exist on
   macOS.
2. **The cleanup moved off the button and onto the route.** `RetouchProRootView`
   now does it in `.onChange(of: route)` when the route becomes `nil`, and
   `EditorView`'s button only clears the route. Hiding a system back button also
   disables iOS's swipe-back gesture, and macOS draws its own back control that
   this app cannot hide — so tying "give the textures back" to one specific
   button was fragile in both directions. Now no way out of the editor can skip
   it.

**Open, needs a human on a Mac:** macOS `NavigationStack` draws its own back
control for a pushed destination, and there is no macOS equivalent of
`navigationBarBackButtonHidden`. The Mac may therefore still show a system
chevron *and* the "Projects" button. That is now purely cosmetic — thanks to (2),
either control does the right thing — and the fix if it is confirmed is one
`#if os(macOS)` around the `.cancellationAction` item. It was not done blind,
because if some macOS configuration turns out **not** to draw a back control,
removing ours would strand the user in the editor with no way back, which is a
far worse bug than a duplicate chevron.

## Consequences

- Phase 3's "auto-apply a preset to every new shot" hangs off
  `ShotImportSummary.importedShotIDs`, which is carried across the seam for that
  reason.
- MTP and FolderWatcher UI extend `ShotImporting`; `EditorModel` already
  conforms to `ProjectMutating`, which is what those two need.
- `RetouchProAppTests` now links RPImport and RPUI and compiles
  `App/RPImportShotImporter.swift` and `App/AppLog.swift` into itself, keeping
  the "app-target code that no package test can reach is still tested" rule that
  `FaceAnalysisRenderBridgeTests` established.

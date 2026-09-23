# ADR-0025 — A project is a session: per-shot history and where the user left off

Status: accepted — 2026-09-23 (rule set by the user, not open for re-debate)

## Context

The user's rule: a `.rpproj` is a **self-contained work session**, like a Lightroom catalog or a CapCut project. It
holds the originals, the preview/reference files and every shot's editing **metadata as a snapshot**, and opening it
restores the session exactly as it was left. An exported file is a finished product: opened in the app, it becomes a
new original in a new project, with no link back. Edits are metadata, never baked pixels. Derived data (previews,
face/subject analysis) may be cached but must always be recomputable.

Before this change, two things broke that rule. Undo history lived in memory in `EditorModel`, reset on shot switch
and was lost on quit (the 2026-09-22 PLAN note described that reset as intended). The canvas position (open shot,
selection, zoom, tab) was not stored at all. The brush half of the rule (strokes instead of a PNG) is recorded in
ADR-0019's last addendum.

## Decision

### 1. Layout

```
<project>.rpproj/
  session.json                  where the user left off (optional)
  edits/<shot id>.json          slider document (unchanged)
  edits/<shot id>.strokes.json  brush strokes, normalised (ADR-0019 addendum)
  history/<shot id>.json        the shot's undo/redo timeline
```

Every file carries a `formatVersion` (1), is written through `AtomicFileWriter`, and is **optional**. An absent file
is the normal empty state. A corrupt or future-version file is logged and treated as empty (`EditorModel` catches the
loader's throw), so a damaged side file never stops a document from opening, and the next write replaces it.
`removeShot` deletes a shot's strokes and history with its edits. `ProjectManifest.formatVersion` is unchanged:
older builds ignore the new files.

### 2. History: one timeline per shot, slider edits and brush strokes together

`RPCore.ShotHistory` has an undo stack and a redo stack of `ShotHistoryStep`. Each step is the **operation that takes
the snapshot (`EditState` + strokes) the other way**, and applying a step returns its inverse, which goes on the other
stack:

| step | written when | carries |
|---|---|---|
| `edit(EditState)` | a commit (slider release, preset, paste, reset, face pick, toggle) | the replaced document (~0.3–2 KB) |
| `removeLastStroke` | a finished stroke | nothing (the stroke is the last entry of the strokes file) |
| `appendStroke(stroke)` | redo side of the above | the one stroke |
| `replaceStrokes([…])` | "Xoá mask" (undo side) / its redo (`[]`) | the cleared list, the one step that has to |

**One timeline, not a stack per tool.** Undo means "take back the last thing I did", and on a shot that may be a
stroke or a slider. Two stacks would make ⌘Z skip whatever it doesn't own. So the toolbar's Hoàn tác / Làm lại, ⌘Z
and the brush bar's own buttons all call `EditorModel.undo/redo`. In brush mode the bar's "Hoàn tác" undoes a slider
if that was the last action, which matches the brush bar also hosting the active group's sliders (ADR-0019,
2026-09-21). "Xoá mask" became undoable.

**Cap: 100 steps per stack** (`ShotHistory.maximumSteps`), oldest dropped first. That is Lightroom's practical depth,
and it bounds the file (≤ ~200 KB even with EditState-heavy histories). Strokes past the cap stay painted; they just
can't be undone any more.

**Batch writes are history steps on their target shots.** Paste settings and "apply preset to every shot" write
documents of shots that aren't open, so they use `ProjectStore.saveEditStateRecordingHistory`, which records an
`edit(previous)` step in that shot's `history/` file. Otherwise that shot's next undo would jump past the paste.

A step that no longer applies (e.g. `removeLastStroke` with no strokes, after a crash between the two writes) is
skipped, not fatal.

The history is **per shot and persisted**: switching shots and reopening the project both bring it back, so undo
walks back past the reopen. This replaces the 2026-09-22 "history resets on shot switch" behaviour.

### 3. Session position — `session.json`

`RPCore.SessionPosition` stores the open shot, the batch selection, the tab (`EditorChrome.Tab.rawValue`) and the
viewport (zoom, offset in points, fits-window flag). RPCore stays UI-agnostic because these are all plain values.
`EditorModel.open` restores it before loading the active shot. Ids no longer in the project are dropped
(`FilmstripSelection.restore`, which keeps the active-is-selected invariant). `EditorView` starts on the restored tab.

**Written debounced**: 600 ms after the last change (`EditorModel.sessionSaveDelay`). A pinch mutates `viewport` every
frame, and each frame only stamps a time; one task writes once things settle. It is also written synchronously when
there may be no "later": the editor disappearing, the scene leaving `.active`, and
`NSApplication.willTerminateNotification` on macOS.

### 4. Exports carry nothing back

`ExportRenderer`'s ImageIO write passes only the image and the lossy quality to ImageIO: no project path, shot id or XMP.
Checked for this ADR, and nothing changes.

## Consequences

* A slider release now writes two small files (`edits/<id>.json` and `history/<id>.json`), and a stroke writes the
  strokes file and the history. All side-file writes are queued in order off the main actor
  (`EditorModel.enqueueWrite`); `flushPendingWrites()` drains them before an export reads other shots from disk.
* Tests: RPCore `ProjectSessionFilesTests`, RPUI `UndoRedoTests` (persisted, interleaved, capped, corrupt-tolerant,
  batch paste) and `SessionPositionTests` (restore, debounce, stale ids, corrupt/future file).
* Not done: iOS device verification of the new files in the sandboxed container (macOS-only by standing rule), and no
  history UI (list/jump) — just undo/redo.

## Review follow-up — 2026-09-23

* **Write order.** Every per-shot file write — `edits/<id>.json` included, which used to be its own detached
  task — now goes through `EditorModel`'s one ordered queue. **The history step is queued before the change it
  undoes** (commit: history → document; stroke / "Xoá mask": history → strokes file), and
  `ProjectStore.saveEditStateRecordingHistory` writes history before the document too. A crash between the two
  leaves at worst an undo step for an edit that never landed, never an edit nothing can undo.
  `lastSavedEditState` is still assigned before the await. Pinned by `UndoRedoTests.historyIsWrittenBeforeTheChange`
  and `ProjectSessionFilesTests.batchWriteOrdersHistoryFirst` (order observed through `AtomicFileWriter.beforeCommit`).
* **`ManualMaskReference` removed** (RPCore): nothing wrote `perImage["manualMask"]` after strokes replaced the PNG.
* **Bounding-box splat at the borders**: `ManualMaskTests.splatAtTheBordersMatchesReference` has strokes whose discs
  overflow every edge and corner, including one that runs entirely off the mask and an erase across a corner. It
  compares them against the Double reference: max abs diff 1/255, i.e. r8 quantisation only.

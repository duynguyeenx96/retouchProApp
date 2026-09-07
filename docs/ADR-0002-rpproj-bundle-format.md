# ADR-0002 — `.rpproj` bundle format and the EditState / Preset envelope

Status: accepted — 2026-09-04
Scope: Phase 1 item 2 of `docs/PLAN.md` (`RPCore` only — no UI, no import, no engine).

## Context

PLAN §2 fixes the pieces (`Project`, `Shot`, `EditState`, `Preset`,
`ProjectStore`) and Phase 1 fixes the directory names
(`originals/`, `previews/`, `edits/*.json`, `presets/`). It fixes two rules
about content: **EditState is plain JSON**, and **Preset = EditState minus the
per-image fields**, with reshape stored relative to face width and skin/makeup
mask-driven so a preset transfers between images.

Everything below is a decision the plan does not make. Phase 2 owns the actual
slider list, so this phase deliberately defines the *envelope* and leaves the
contents open.

## Decisions

### 1. Layout — a plain directory, one manifest

```
Wedding 2026-09-04.rpproj/
  manifest.json            format version + generator + the whole Project
  originals/               imported files, immutable
  previews/                derived, safe to delete
  edits/<shot id>.json     one EditState per shot
  presets/<preset id>.json
```

`manifest.json` is the single source of truth for identity, shot order,
ratings/flags and capture metadata; the directories hold the payload. The
alternative — deriving everything from the file system, no manifest — cannot
express filmstrip order, ratings or stable ids across a rename, and the
alternative of one JSON per shot's *metadata* would multiply the number of
writes per import for no gain.

The bundle is a plain directory, not a macOS "file package". Whether Finder
shows it as one opaque document depends on a document type in the app's
Info.plist, which is `App/`'s business; nothing in RPCore assumes it, and RPCore
keeps working after a user has browsed inside the folder.

### 2. Two version numbers, not one

- `ProjectManifest.formatVersion` — the *bundle layout*. A manifest with a
  higher value than the build supports refuses to load, so an old build cannot
  rewrite a newer bundle into a lossy shape.
- `EditState.schemaVersion` / `Preset.schemaVersion` — the *document contents*.
  Never a load barrier; unknown content is preserved instead (§3).

They move for different reasons: adding `masks/` to the bundle is not the same
event as adding a slider group.

### 3. Forward compatibility is preservation, not tolerance

Swift's synthesised `Codable` already ignores unknown keys — and then silently
**drops** them on the next save. For a document the user keeps for years and
opens from two machines running different builds, that is data loss.

Every persisted type (`EditState`, `Preset`, `Project`, `Shot`,
`CaptureMetadata`, `ProjectManifest`) therefore decodes its declared keys and
sweeps the rest into an `additionalValues: [String: JSONValue]` that is written
back out verbatim. `EditSection` and `PerImageState` are *entirely* open — they
serialise as the bare JSON object — so a Phase 2 slider or a Phase 5 makeup
parameter needs no change to this layer at all.

Tested both ways: decoding a document with future keys must not throw, and
re-encoding it after an edit must still contain them
(`EditStateTests.unknownTopLevelKeyIsPreserved`, `PresetTests.forwardCompatible`,
`ProjectStoreTests.manifestForwardCompatibility`).

### 4. Sliders: 0–100, default 0, absent means 0

`EditSection.setSlider` clamps to 0…100 and **removes** the key when the value
returns to 0, and an empty section is removed from `EditState.sections`. A saved
document lists only what the user changed, so an untouched shot has no
`edits/` file at all and `loadEditState` returns a default `EditState`. That is
why a missing edits file is not reported as an anomaly by `load()`.

Phase 1 declares only the section *namespaces* (`skin`, `face`, `eyesTeeth`,
`color`, `makeup`, `hair` — the groups in PLAN Phase 2/3), never the parameters.

### 5. `perImage` is the strip boundary

`EditState.perImage` is an open namespace with nothing declared in it yet. It
exists so the "minus per-image fields" rule is a *mechanism* rather than a
future judgement call: `Preset(name:from:)` drops `perImage` and keeps
everything else. The contract for later phases is explicit — crop/straighten
(Phase 2), heal & clone strokes (Phase 5) and per-face-instance bindings must go
under `perImage`, or they will leak into presets. `applying(_:)` never touches
`perImage`, so applying a preset cannot move someone else's crop.

### 6. `JSONValue` unifies numeric equality

JSON has one number type: a `Double` 40 is written `40` and reads back as an
`Int`. `.int` and `.double` are kept as separate cases (so values above 2^53
keep their precision) but compare and hash by value, and `JSONValue.number(_:)`
canonicalises integral values to `.int`. Without this, every save/load cycle
would make a document look modified. Found by a round-trip test, not by review.

### 7. Atomic writes are explicit, not `Data.write(.atomic)`

`AtomicFileWriter` does write-temp → `fsync` → `rename(2)` → `fsync` the
directory. `Data.write(options: .atomic)` does the rename but neither fsync, and
gives no way to observe the temp file. Explicit matters because:

- an `EditState` is written on every slider release — a truncated file there
  loses the shot's edits;
- PLAN Phase 4 requires "ghi file atomic + fsync" for tethered import, and this
  is the same primitive.

The temp file is a sibling of the destination (prefix `.rp-tmp-`) so the rename
never crosses a volume and never degrades to a copy. A `beforeCommit` hook lets
tests throw at the exact moment between "temp file complete" and "rename", which
is how the interruption tests assert that the previous version survives intact
and no debris is left.

### 8. Removing a shot never deletes the imported file

`originals/` is immutable. `removeShot` deletes the shot's `edits/` document and
cached preview, drops the manifest entry, and leaves the file. To stop the next
load from re-adopting the orphan and resurrecting the shot, the removed path is
recorded in `Project.removedOriginalPaths` (tombstones). Reclaiming the space is
a separate call, `deleteOriginalFile(at:)`, fenced to paths inside `originals/`
— the only method in RPCore that destroys an imported file.

Alternative rejected: moving the file to a `trash/` subfolder. It changes the
bytes' location, which breaks the "originals are untouched" promise the user is
relying on when they import a RAW they have no other copy of.

### 9. Load reconciles with disk but never writes

`load()` reads the manifest, reports shots whose original is missing (keeping
the shots — losing edits because a volume was ejected would be worse), and
adopts importable files sitting in `originals/` with no manifest entry. Adoption
is in-memory only; nothing is persisted until the caller saves, so opening a
project cannot damage it. Adoption covers a crashed import and a user dragging
files into the folder, and is the hook FolderWatcher (item 3) plugs into.
"Importable" is an extension allow-list (JPEG/HEIF/TIFF/PNG/WebP + common RAW
including ARW); anything else is left alone rather than guessed at.

### 10. `ProjectStore` is a value, `Project` is passed in and out

The store holds a URL and a writer, no cached project. The caller owns the
`Project` struct and hands it back to save. This makes the store trivially
`Sendable` under Swift 6 strict concurrency with no actor or lock, keeps "what
the user sees" and "what is on disk" comparable instead of a single object that
can silently drift, and leaves the choice of observable wrapper to RPUI.

Mutating calls (`addShot`, `removeShot`) take `inout Project`, write the
manifest atomically and stamp `modifiedAt`, so the model and the disk cannot
disagree after a successful call.

### 11. Identifiers are validated file-name components

`Identifier<Tag>` (→ `ProjectID`, `ShotID`, `PresetID`) rejects anything that is
not a safe single path component — no `/`, no `..`, no leading dot. Ids are used
directly as file names (`edits/<shot id>.json`), so a corrupt or hostile
manifest must not be able to steer a write outside the bundle. Decoding an
invalid id throws.

### 12. Dates: ISO-8601 with fractional seconds; JSON is sorted + pretty

`RPJSON.encoder`/`decoder` are the single configuration for every document:
`.sortedKeys` + `.prettyPrinted` so files are diffable, reviewable, and
byte-identical for equal values (which is what lets tests assert the exact
format). Dates are ISO-8601 with milliseconds — readable in a text editor,
unambiguous across platforms. The cost is up to 1 ms of precision loss;
`RPJSON.dateResolution` names the tolerance for comparisons.

## Consequences

- Phase 2 adds sliders by writing keys into `EditState.sections[...]`. No change
  to the file format, no migration, no change to `ProjectStore`.
- Phase 3's grouped presets are already expressible:
  `Preset(name:from:limitedTo:)` plus `PresetApplyMode.merge`.
- Phase 1 item 3 (import) should call `addShot(copyingOriginalAt:into:)` for
  Files/Photos/MTP, and use `load()`'s adoption path for FolderWatcher.
  Note the one non-atomic seam: if the process dies between the file copy and
  the manifest write, the file is in `originals/` without a manifest entry —
  which the adoption path then picks up on the next load. That is deliberate.
- `previews/` is written by nobody yet; `ProjectStore.previewURL(for:)` names
  the location for RPEngine.
- The exact bytes of all three document kinds are pinned by
  `BundleFormatTests`; changing them is a deliberate act that fails a test.

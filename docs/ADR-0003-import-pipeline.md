# ADR-0003 — Import pipeline: one ingest path, four sources, per-file results

Status: accepted — 2026-09-04
Scope: Phase 1 item 3 of `docs/PLAN.md` (`RPImport` only — no UI, no engine).

## Context

PLAN Phase 1 item 3 names four sources — Files, Photos (giữ RAW), drag-drop on
Mac, MTP camera via ImageCaptureCore, and a FolderWatcher for a chosen folder or
card. PLAN §2 puts them all in `RPImport`, which depends on `RPCore` only.

ADR-0002 §Consequences fixes the contract they have to honour: import calls
`ProjectStore.addShot(copyingOriginalAt:into:)`, and the non-atomic seam between
"file copied into `originals/`" and "manifest written" is recovered by
`load()`'s orphan adoption.

Everything below is a decision the plan does not make.

## Decisions

### 1. One ingest path — `ShotIngestor` is the only caller of `addShot`

Files, Photos, MTP and FolderWatcher all end in
`ShotIngestor.ingest(fileAt:…)`. Nothing else in RPImport touches
`ProjectStore.addShot`, and nothing anywhere in RPImport writes into
`originals/` directly.

That is what keeps three promises in one place instead of four:

- **RAW is copied, never re-encoded.** There is no image pipeline in the ingest
  path at all — the only byte-moving call is RPCore's `copyItem`. A test hashes
  a 4 KiB non-image byte pattern through a full import and compares
  (`FilesImporterTests.rawIsPreservedByteForByte`); any codec in the path would
  fail it.
- **The ADR-0002 seam stays owned by RPCore.** A crash mid-import leaves an
  orphan in `originals/` that `load()` adopts, exactly as documented, because
  RPImport never invented its own copy step.
- **The importable-extension gate is `ProjectBundle`'s allow-list**, the same
  one adoption uses. A file an importer accepts is a file a reopened project
  would also accept; they cannot drift apart.

Photos and MTP therefore stage the asset to a temp file first and hand *that*
to `addShot`, costing one extra copy. Rejected alternative: give
`PhotosImporter` and `MTPCameraImporter` a direct write into `originals/` to
save the copy. It would put four different pieces of code in charge of the
crash-recovery invariant, and the copy is not the bottleneck — a USB 2.0 a6300
download is.

### 2. Failures are values, not thrown errors

`ImportReport` is a list of `ImportItemResult`, one per input, in attempt order.
No importer throws for a bad file and none stops early: one unreadable frame on
a card must not abort the other 399.

Three outcomes, and the distinction between the last two matters:

| Outcome | Meaning | UI |
|---|---|---|
| `.imported(shotID:originalRelativePath:)` | in `originals/`, in the manifest | — |
| `.skipped(ImportSkipReason)` | a deliberate decision: wrong type, duplicate, still being written | not an error |
| `.failed(ImportFailure)` | the user asked for it and did not get it | needs saying |

`ImportFailure` is a closed `Codable`/`Equatable`/`Sendable` enum, not
`any Error`. A report gets stored, compared in tests and (Phase 1 item 4) shown
and logged; `any Error` is none of those things. `ImportFailure.wrapping(_:as:)`
keeps `ProjectStoreError`'s own wording rather than flattening it to
`String(describing:)`.

**Flagged for review:** with no UI yet, nothing consumes a report. The contract
chosen is that importers *return* a report and never log or present — the app
layer decides. `ImportReport.summary` ("12 imported, 3 skipped, 1 failed") and
`detailedDescription` (one line per item) exist so item 4 does not have to
invent that formatting. If Phase 1 item 4 wants a different shape, this is the
type to change, and it is only consumed by tests today.

### 3. De-duplication by SHA-256, on by default

`ImportOptions.computeContentHash` fills `Shot.contentHash` (which RPCore
declares as "hook for … import de-duplication. Filled by `RPImport`"), and
`skipDuplicates` skips a file whose hash already belongs to a shot.

This is what makes re-plugging a card idempotent, which the plan's workflow
needs: "cắm → đổ vào project" run twice must not double the project. It matches
on content, not name, so a card whose counter wrapped to `DSC00001.ARW` again is
still handled correctly.

Cost is one extra full read of every source file. Measured rather than assumed:
`Research/bench/hash-chunk-bench.swift` → `Research/bench/rpimport-hash.json`,
48 MiB file, median of 5 after a warm-up, with a read-only control.

| chunk | hash (ms) | read-only control (ms) | throughput |
|---|---|---|---|
| 256 KiB | 34.2 | 10.6 | 1404 MB/s |
| **1 MiB** | **30.7** | 16.0 | **1566 MB/s** |
| 4 MiB | 31.0 | 15.3 | 1547 MB/s |
| 16 MiB | 32.7 | 13.1 | 1466 MB/s |

`ContentHash.chunkBytes = 1 MiB`; 0.65 s/GB warm. All four sizes are within
~10 %, so the choice is not load-bearing — but 256 KiB is measurably worst and
the number is now on file instead of in someone's head. `ImportOptions.fastest`
turns hashing and EXIF off for callers who want the minimum.

### 4. EXIF via ImageIO, behind a protocol

`CaptureMetadataExtracting` with `ImageIOMetadataExtractor` as the default and
`NullMetadataExtractor` for tests. ImageIO is identical on macOS and iOS, reads
Sony ARW, and parses headers without decoding pixels. Failures collapse to empty
metadata — a file whose EXIF cannot be read is still a perfectly good import.

`DateTimeOriginal` has no time zone and the a6300 does not write
`OffsetTimeOriginal`, so it is parsed as local wall-clock time. That is the same
choice Photos and Lightroom make and the only one available; it is wrong by the
offset if a shoot's files are opened in a different zone. Phase 2 can revisit
when `CIRAWFilter` metadata is on the table.

### 5. Platform sources are protocols; the platform half is not unit-tested

`PhotoLibrarySource` and `CameraDeviceSource`/`CameraSession` are protocols with
plain-value descriptors (`PhotoAssetDescriptor`, `CameraItemDescriptor`). The
real implementations — `PhotoKitLibrarySource`, `ImageCaptureCameraSource` — are
kept as thin as they can be: map platform object → descriptor, write one file to
disk. Every decision lives above them, in `PhotosImporter` /
`MTPCameraImporter`, which the tests drive against fakes.

**Say it plainly: no test in this repo talks to PhotoKit or to a camera.** A
`PHPhotoLibrary` needs a signed bundle, an `NSPhotoLibraryUsageDescription` and
a user tapping "Allow"; `ICDeviceBrowser` needs an a6300 on a cable. Those two
files are verified by hand and by PLAN Phase 0 spike S5. What the fakes *do*
pin down is the part that rots silently: bytes reaching `originals/` unchanged,
the asset's own file name surviving the staging round trip, a denied library
producing failures rather than an empty success, a failing item not aborting the
batch, and the session always being closed.

Two consequences for `App/` (not done here, not this task's scope):

- Info.plist needs `NSPhotoLibraryUsageDescription`.
- The macOS sandbox needs
  `com.apple.security.personal-information.photos-library` for Photos and
  `com.apple.security.device.usb` for ImageCaptureCore.

### 6. Photos exports the RAW resource, not the `.photo` resource

In a RAW+JPEG pair PhotoKit stores the RAW as `.alternatePhoto` and the JPEG as
`.photo`, so the obvious choice throws the RAW away. `preferredResource` picks
any resource whose UTI conforms to `UTType.rawImage` first, then `.photo`, then
`.fullSizePhoto`.

The export uses `PHAssetResourceManager.writeData(for:toFile:options:)`, which
writes the resource **as stored**. It is the only PhotoKit call that does;
`requestImageDataAndOrientation` and `PHImageManager` can re-render, which would
destroy a RAW. `isNetworkAccessAllowed = true`, or a partially-offloaded iCloud
library fails at random.

### 7. Nothing is ever deleted from a camera

`CameraSession` has no delete, rename or format method — the guarantee is
structural, not a rule someone has to remember. `requestDeleteFiles` appears
nowhere in RPImport, and the download options set
`deleteAfterSuccessfulDownload: false` explicitly rather than omitting it. PLAN
Phase 4 states this for tethering ("không xoá gì trên máy"); it applies just as
much to MTP import, because the card is often the only copy of the shoot until
export finishes.

`MTPCameraImporter` also filters by extension *before* downloading, so a 1 GB
movie is never pulled over USB only to be rejected.

### 8. FolderWatcher polls; kqueue is only a latency optimisation

`FSEventStream` is macOS-only, so it cannot be the mechanism in a package that
builds for iPadOS. `DispatchSource.makeFileSystemObjectSource` (kqueue) exists
on both, but a directory kqueue fires only for that directory's own entries —
not a subdirectory — and is unreliable on removable and network volumes, which
is precisely the card-reader case.

So the watcher **polls** every `pollInterval` (default 2 s; a scan is one `stat`
per candidate) and *additionally* arms a kqueue purely to cut latency: when it
fires, the next scan happens immediately. Correctness never depends on the
kqueue.

### 9. A file is imported only after its size and mtime hold still

A 24 MP ARW copied off a slow card exists at its final path, with a growing
size, for seconds. Importing on appearance would copy a truncated RAW into
`originals/` — and `originals/` is immutable (ADR-0002 §8), so that damage is
permanent.

Rule: import when two observations at least `stabilityInterval` apart (default
1.5 s) report the **same size and the same modification date**. Anything else is
reported as `.skipped(.stillBeingWritten(observedBytes:))` and retried. A first
sighting is never imported immediately, however complete the file looks.

Rejected alternatives: `open(O_EXLOCK|O_NONBLOCK)` to detect a writer (does not
work over SMB and not all writers take a lock); watching for a `rename` into
place (cameras and card copies write in place, and `cp` does not rename).

`stabilityInterval` is injected along with a `now` closure, so the tests drive
the rule with a fake clock and no sleeping. One test asserts the thing that
matters: the bytes that reach `originals/` are the whole 3072, not the 1024 that
existed at first sighting.

### 10. Unmount / remount — decided here, flagged for review

PLAN does not say what a watcher should do when a card is ejected. Chosen
behaviour:

- The folder disappearing is **not** an error and does not stop the watcher. It
  emits `.becameUnavailable(url)` once, keeps polling, and emits
  `.becameAvailable(url)` when the mount point comes back. A photographer who
  swaps cards should not have to re-pick the folder.
- **In-flight stability observations are dropped on unmount.** A file that was
  half-written when the card was pulled must be re-observed from scratch;
  resuming from its old size could import a truncated file if a different card
  mounts at the same path with a same-named file.
- **The handled-paths set survives.** A remount of the same card does not
  re-import what was already taken; the content hash is a second line of
  defence for the same-path-different-card case.

This is a judgement call, not something the plan settles, and it is the part of
this ADR most worth a second opinion.

### 11. Import failures inside a watcher are reported once, then the path is dropped

A permanently unreadable file on a card would otherwise produce a failure every
poll interval until the app quits. The path is marked handled after the first
attempt, so it appears in exactly one report. Cost: a genuinely transient error
needs the folder re-selected to retry. Chosen because an error that repeats
every 2 s is worse than one that needs a manual retry.

### 12. `ProjectMutating` — the asynchronous importers do not own the `Project`

ADR-0002 §10 hands `Project` ownership to the caller and takes it back `inout`.
That is right for a picker callback but impossible for FolderWatcher and a long
MTP download: they run on their own schedule, have no `inout` binding, and the
UI may be mutating its own copy meanwhile. Two writers, last save wins, one of
them loses shots.

So the async importers ask whoever owns it:

```swift
public protocol ProjectMutating: Sendable {
    func withProject<T: Sendable>(
        _ body: @Sendable (inout Project, ProjectStore) throws -> T
    ) async rethrows -> T
}
```

`ProjectSession` is the reference implementation — an actor holding one
`Project` and its store, also usable headless. `App/` will conform its
observable model to the same protocol. `FilesImporter` keeps the plain
`inout Project` signature because its caller genuinely does have the binding.

`FileManager` is not `Sendable`, so each `withProject` body constructs a fresh
`FileManager()` rather than capturing one — which is also Apple's guidance for
using it off the main thread.

### 13. `FolderWatcher` never walks into a `.rpproj`

A user who keeps the project bundle inside the folder they are watching would
otherwise get an infinite copy loop: each file the watcher writes to
`originals/` looks like a new file in the watched tree. The scan skips any
directory with the `rpproj` extension and skips any path under the project's own
bundle. Tested by scanning four more times and asserting the count stays at one.

## Consequences

- Phase 1 item 4 (UI) wires a picker/drop to `FilesImporter`, a
  `PHPickerViewController` to `PhotosImporter`, a device list to
  `MTPCameraImporter`, and a folder picker to `FolderWatcher` — and renders
  `ImportReport`. It must also conform its project model to `ProjectMutating`,
  or use `ProjectSession` directly.
- Phase 3's "auto-apply preset to every new shot" hangs off
  `ImportReport.importedShotIDs`, which is why the report carries ids and not
  just counts.
- `App/` still needs the Info.plist usage string and the two sandbox
  entitlements in §5 before Photos or camera import can be smoke-tested.
- Adding a fifth source means implementing one protocol and calling
  `ShotIngestor`; it does not mean touching `ProjectStore`.

## Amendments — Phase 1 review, 2026-09-04

The decisions above stand as written; these four points were changed after
review. They are recorded here rather than edited into the sections above, so
the reasoning that produced the original text stays readable.

### A1. §10 — the handled set is keyed by `(path, size, mtime)`, not by path

§10 claimed "the content hash is a second line of defence for the
same-path-different-card case". It was not: `guard !handled.contains(path)`
ran *before* the stat, so `ShotIngestor` — where the hash lives — was never
reached. A card reader gives the next card the same mount point when both
volumes carry the same generic label (`/Volumes/NO NAME`), and a camera whose
counter was reset writes `DSC00001.ARW` again; every colliding frame on card B
was dropped with no import and **no report line at all**.

`handled` is now `[path: FileSignature]` where `FileSignature` is
`(byteSize, modifiedAt)`, checked after the stat. A different frame at a reused
path no longer matches and is processed normally; the same frame at the same
path still matches and costs nothing; and where size and mtime coincide the
content hash really does get the last word, at the price of one skip line
instead of a lost photo. Chosen over "reset `handled` on `becameUnavailable`"
because it does not depend on the watcher having *observed* the unmount — a
scan that lands entirely after the swap is covered too — and because it keeps
a transient blip from re-hashing an 800-frame card.

Test: `FolderWatcherTests.differentCardReusingTheMountPoint` (control run with
the old key: 0 of card B's frames imported).

### A2. §11 — only final outcomes are remembered; transient failures are retried

§11 marked a path handled on *any* result. That includes
`.failed(.sourceUnavailable)`, which is what a file vanishing between the
watcher's stat and the ingestor's re-check looks like — a race, not a defect —
and it meant the frame was never imported however long the card stayed in.

`FolderWatcher.isFinal(_:)` now decides: `.imported`, the permanent skips
(`unsupportedFileType`, `duplicateContent`, `notARegularFile`) and the failures
that say something durable about the file or the destination (`unreadable`,
`copyFailed`, `storeRejected`, `sourceError`, `permissionDenied`) are
remembered. `.sourceUnavailable` and `.timedOut` are not, and the file is
re-observed from scratch — so §11's real point, that a corrupt frame must not
produce an error line every 2 s, still holds.

Test: `FolderWatcherTests.transientFailureStaysEligible` and
`finalOutcomeClassification`.

### A3. §12 — `ProjectMutating` / `ProjectSession` moved to `RPCore`

They are project *ownership*, not importing, and they have consumers that have
nothing to do with importing (RPUI today; Phase 3's batch queue and Phase 4's
tether daemon next). Leaving them here forced every one of those to link
PhotoKit and ImageCaptureCore to get a concurrency primitive. The types are
unchanged and `RPImport` still uses them exactly as §12 describes; only the file
moved, to `Packages/RPCore/Sources/RPCore/ProjectSession.swift`. ADR-0004 §1
predicted this move and is amended accordingly.

### A4. `ICCameraSession.contents()` had a lost-wakeup hang

It read `camera.mediaFiles` unlocked, then registered a continuation under the
lock. `deviceDidBecomeReady(withCompleteContentCatalog:)` arriving in that gap
found no continuation, resumed nothing, and the continuation registered a
moment later waited for an event that had already happened — forever, since
`contents()` has no timeout (unlike `cameras(waitingFor:)`).

The catalog signal is now an `EventLatch`: a one-shot latch that *remembers*
the event, so a waiter that arrives late returns immediately, any number of
waiters are resumed, and a device that disappears settles the latch with an
error instead of leaving the import hung. `EventLatch` is plain Foundation and
sits outside the `#if canImport(ImageCaptureCore)` block precisely so the fix
is unit-testable without a camera (`EventLatchTests`); the control shape — check
unlocked, then park — loses 20 of 20 wakeups with a 50 ms window forced between
the two steps.

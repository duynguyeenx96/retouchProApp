# ADR-0001 — Project skeleton: multiplatform target, local packages, test invocation

Status: accepted — 2026-09-04
Scope: Phase 1 item 1 of `docs/PLAN.md`.

## Context

`docs/PLAN.md` §2 fixes the layout: one multiplatform app target at
`RetouchPro.xcodeproj`, app code in `App/`, and six local Swift packages under
`Packages/` (`RPCore`, `RPVision`, `RPEngine`, `RPImport`, `RPUI`, `RPTestKit`).
§5 fixes the verification command:
`xcodebuild test -scheme RetouchPro -destination 'platform=macOS'` plus an
iOS Simulator destination.

## Decisions

### 1. One app target, `SDKROOT = auto`

`SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx"`,
`MACOSX_DEPLOYMENT_TARGET = 15.0`, `IPHONEOS_DEPLOYMENT_TARGET = 18.0`,
`TARGETED_DEVICE_FAMILY = "1,2"`. One target, not one per platform, because the
plan calls for a single codebase and the divergence (tethering, ImageCaptureCore
capabilities) is handled with `#if os(...)` inside packages.

`App/` is attached with a **file-system synchronized group**
(`PBXFileSystemSynchronizedRootGroup`, `objectVersion = 77`), so adding a file to
`App/` never requires editing `project.pbxproj`.

### 2. Six separate packages, not one package with six products

Each package has its own `Package.swift` and declares its dependencies by path
(`.package(path: "../RPCore")`). This makes the dependency direction a *compile
error* if violated, rather than a convention: `RPEngine` physically cannot see
`RPUI` because it does not declare it. It also lets any package be tested on its
own with `swift test` in ~5 s, with no Xcode and no simulator.

Direction (also encoded as data in `RPCore.ModuleGraph` and asserted by tests):

```
RPCore  ←  RPVision
        ←  RPEngine  ←  RPUI
        ←  RPImport
        ←  RPTestKit   (testing support; nothing depends on it)
```

`RPCore` and `RPEngine` must not import UIKit / AppKit / SwiftUI. This is
enforced by `RPTestKit.SourceAudit`, which greps the packages' own `.swift`
sources on disk and reports `file:line` for any violation
(`Packages/RPTestKit/Tests/RPTestKitTests/LayeringAuditTests.swift`).

### 3. A workspace is required to run package tests — `-workspace` is not optional

**Xcode only schedules a local Swift package's test target when the package is a
member of a workspace.** With the packages attached to the project only (as
`XCLocalSwiftPackageReference`), `xcodebuild` silently drops every
`TestableReference` and fails with:

```
xcodebuild: error: Failed to build project RetouchPro with scheme RetouchPro.:
There are no test bundles available to test.
```

Measured on Xcode 26.2 (2026-09-04). Four container spellings were tried in the
scheme and all produced zero `.xctest` bundles:
`container:Packages/RPCore`, `container:Packages/RPCore/Package.swift`,
`container:Packages/RPCore/RPCore.xcodeproj`, `self:Packages/RPCore`.
An explicit `.xctestplan` with `"containerPath": "container:Packages/RPCore"`
was also dropped. Adding the packages to the project's implicit
`RetouchPro.xcodeproj/project.xcworkspace` (relative, `group:` and `absolute:`
forms) did not help either.

Adding `RetouchPro.xcworkspace` at the repo root — containing the project and
the six packages — makes all six test bundles build and run on both
destinations.

Consequence: **the test command must name the workspace.**

```
xcodebuild test -workspace RetouchPro.xcworkspace -scheme RetouchPro -destination 'platform=macOS'
xcodebuild test -workspace RetouchPro.xcworkspace -scheme RetouchPro -destination 'platform=iOS Simulator,name=iPad (A16)'
```

The bare form from PLAN §5 (`xcodebuild test -scheme RetouchPro …`) does **not**
work: when a directory holds both a `.xcodeproj` and a `.xcworkspace`,
`xcodebuild` picks the project (verified with `xcodebuild -list`, which reports
`Information about project "RetouchPro"` even with two workspaces present), and
the project path has no test bundles.

Rejected alternatives:
- *Move `RetouchPro.xcodeproj` into a subdirectory* so the workspace is the only
  container in the root and the bare command works. Rejected: it contradicts the
  layout in PLAN §2 and forces `..`-relative synchronized-group paths.
- *Replace the packages with Xcode framework targets.* Rejected: the plan calls
  for `Packages/`, and SPM targets keep the pure logic testable without Xcode.
- *Put all tests in one app-level test target.* Rejected: tests would no longer
  live next to the code they cover, and `swift test` per package would stop
  being the fast inner loop.

`Scripts/test.sh` wraps both invocations so nobody has to remember the flag.

### 4. Development signing, local only

- macOS: `CODE_SIGN_IDENTITY[sdk=macosx*] = "-"` → "Sign to Run Locally". No
  provisioning profile, no network round trip in CI, App Sandbox still active.
- iOS device: `DEVELOPMENT_TEAM[sdk=iphoneos*] = NTWP6SJ3WF` (read from the
  Apple Development certificate already in the login keychain) with automatic
  signing, for running on the user's real iPad.
- Simulator and macOS builds need no team.
- `App/RetouchPro.entitlements` enables App Sandbox +
  `files.user-selected.read-write`. The sandbox is deliberate: it puts logs at
  `~/Library/Containers/com.duynguyen.RetouchPro/Data/Library/Logs/RetouchPro/`,
  which is what PLAN §5 asks for. Verified by launching the built app once.
- No distribution entitlements, no App Store capabilities (PLAN Context).

### 5. Swift Testing, not XCTest

Packages use `import Testing` / `@Test` (Swift 6.2, Xcode 26.2). It is the Apple
framework of record now, gives parameterised tests for free (useful for the
Phase 2 golden/eval harness) and runs under both `swift test` and `xcodebuild`.

## Consequences

- Open `RetouchPro.xcworkspace`, not the `.xcodeproj`.
- New packages must be added in three places: `Packages/<name>`, a `FileRef` in
  `RetouchPro.xcworkspace/contents.xcworkspacedata`, and — if the app links it —
  an `XCLocalSwiftPackageReference` + product dependency in `project.pbxproj`.
  A new package's tests also need a `TestableReference` in
  `RetouchPro.xcodeproj/xcshareddata/xcschemes/RetouchPro.xcscheme`.
- If Apple fixes project-only package test scheduling, the workspace can be
  deleted and PLAN §5's bare command will work as written.

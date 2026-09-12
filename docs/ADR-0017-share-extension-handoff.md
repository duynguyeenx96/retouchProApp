# ADR-0017 — "Mở với RetouchPro": a Share Extension that hands the photo over through an App Group

Status: accepted — 2026-09-12
Scope: Phase 3B (`docs/HANDOFF-remaining-features-2026-09-10.md` §4.1). iPhone
only. No new algorithm, no render node, no measured number — this is target
structure, entitlements and routing.

## Context

Getting a photo from the Photos app into RetouchPro took four steps: open the
app, open or create a project, tap Nhập, pick the photo. The user asked for one:
pick the photo in Photos, tap **"Mở với RetouchPro"** in the Share Sheet, land
in the editor with the photo on the canvas.

Decisions already settled before this ADR (not re-litigated here):

* **Share Extension, not a Photo Editing Extension.** The goal is to save a
  step, not to edit inside Photos.
* The destination project is **created automatically** — never a picker.
* The auto-created name is the existing `ProjectLibrary.suggestedProjectName()`
  (`"Shoot yyyy-MM-dd"`), the same string the New-project button proposes, so a
  project made this way is indistinguishable from one made by hand.
* Ingest goes through the **existing** `ShotIngestor` / `.rpproj` path — the
  same one the Files import uses. No second ingest mechanism.
* Development signing only. A Share Extension works with a Development profile
  as long as app and extension share a team and an App Group.

## Decision

### 1. Two new targets in `RetouchPro.xcodeproj`

| Target | Product | Platforms | Bundle id |
|---|---|---|---|
| `RetouchProShareExtension` | `.appex`, `com.apple.share-services` | `iphoneos iphonesimulator` | `com.duynguyen.RetouchPro.ShareExtension` |
| `RetouchProUITests` | UI test bundle | `iphoneos iphonesimulator` | `com.duynguyen.RetouchProUITests` |

The app embeds the `.appex` in an **Embed Foundation Extensions** copy phase
(`dstSubfolderSpec = 13`). Both the copy and the target dependency carry
`platformFilters = (ios, )`, which is what keeps `xcodebuild -destination
platform=macOS` working: on a macOS build of the app the extension is neither
built nor copied. There is no macOS Share Extension, so
`App/RetouchPro-macOS.entitlements` is untouched.

`TARGETED_DEVICE_FAMILY = 1` on both new targets (iPhone; iPadOS was removed
from the project's scope on 2026-09-11, PLAN §0.2).

### 2. The App Group is the hand-off channel

`group.com.duynguyen.RetouchPro`, in **both**
`App/RetouchPro.entitlements` (iOS only) and
`ShareExtension/RetouchProShareExtension.entitlements`, and mirrored once in
code as `RPCore.ShareHandoff.appGroupIdentifier`.

The extension copies the picked image into
`<group container>/ShareInbox/<name>` and then opens
`retouchpro://open?v=1&file=<name>`. `NSUserActivity` was *not* used: that is
cross-device continuity, a different mechanism with different requirements, and
it cannot launch the containing app from an extension.

**How the app is actually opened, and why not the documented way.**
`NSExtensionContext.open(_:completionHandler:)` is documented for Today widgets;
from a Share Extension it returns `false` and opens nothing. Measured, not
assumed — on the iOS 26 Simulator the extension logged

```
staged DSC05259.jpg
NSExtensionContext.open refused the URL
```

with the file already in the App Group container. So the primary path is the
responder chain: walk from the extension's view controller to the `UIApplication`
hosting it and call `openURL:options:completionHandler:` on it.
`UIApplication.open` is annotated unavailable to extensions, hence the selector
and an `IMP` cast; the call is guarded by `responds(to:)` and by
`isKind(of: UIApplication.self)`, and falls through to the documented API if the
chain has no application in it. Same Simulator, after the change:

```
asked UIApplication to open the containing app
UIApplication.open reported true
```

This would be an App Store review risk. It is not one here: the app is
Development-signed and never goes to the Store (PLAN §0). And it is not the only
way home — see the launch-time inbox scan in §4.

`CFBundleURLTypes` for `retouchpro` cannot be expressed as an
`INFOPLIST_KEY_`, so the app target gained a hand-written
`Config/RetouchPro-Info.plist` (and the extension a
`Config/RetouchProShareExtension-Info.plist` for its `NSExtension`
dictionary). Both targets keep `GENERATE_INFOPLIST_FILE = YES`; Xcode merges the
generated keys into these files.

Activation rule: `NSExtensionActivationSupportsImageWithMaxCount = 1`. The row
appears for exactly one image and for nothing else — not text, not URLs, not a
multi-photo selection, which would otherwise silently do something other than
what the user asked for.

### 3. The contract lives in RPCore, once

`Packages/RPCore/Sources/RPCore/ShareHandoff.swift` holds the App Group id, the
scheme, the payload version, the inbox directory name, URL building, URL
parsing, file-name sanitising and the "throw the buffer away" step. The
extension target links **RPCore and nothing else** (an extension has a hard
launch budget, and `ShareHandoff` is the entire contract). A constant duplicated
in two targets is exactly the kind of thing that drifts and then fails only on a
device.

**The URL is untrusted.** Any app on the phone can open `retouchpro://`. The
payload is therefore a file *name*, never a path: `isSafeFileName` rejects
separators, `..`, dot-files, over-long names and any extension outside
`ProjectBundle.importableExtensions`, and `resolve` then looks the name up
*inside our own inbox*. The worst a hostile caller can do is name a file that is
not there, which is the "nothing to open" branch.

### 4. Routing, cold start and warm start

```
ShareViewController → ShareHandoff.makeOpenURL → NSExtensionContext.open
  → RetouchProApp.onOpenURL → AppContainer.open(url:)
  → ShareHandoffRouter.handle  (parse + resolve inside the inbox)
  → RPUI.ExternalOpenCoordinator.request(fileURLs:)
  → RetouchProRootView: createProject(named: suggestedProjectName())
                        → EditorModel.open → importFiles (ShotIngestor)
                        → select(shotID:) → EditorView
```

`ExternalOpenCoordinator` is owned by `AppContainer` for the whole process
lifetime, **not** by a view. That is the entire reason the cold start works: the
URL arrives before any view exists, so the request has to sit somewhere until
`RetouchProRootView` is there to take it. The view reacts with
`.onChange(of: opener?.pending?.id, initial: true)`:

* cold start — the request is already pending at the first evaluation, so the
  `initial: true` run picks it up;
* warm start — `onOpenURL` sets it while the view is on screen, so the value
  changes and the same code runs.

Neither branch knows which one happened. `take()` clears the request, so a view
that re-appears cannot create a second project for the same photo.

`.task(id: opener?.pending?.id)` was tried first and is **wrong**: taking the
request clears `pending`, which changes the id, which makes SwiftUI cancel the
very task that is halfway through creating the project. The work is owned by the
hand-off, not by a view update, so it runs in an unstructured `Task`.

The route carries the files to ingest (`Route.pendingImport`) rather than the
view importing before navigating: opening the project and importing into it are
one user action here, and the editor must not flash an empty project first. That
same flag is what makes `EditorView(opensInEditor:)` start on the canvas (1a)
instead of the project's library (2a) — measured the hard way: with the default
the hand-off landed on a grid holding one thumbnail, which is not what "mở thẳng
tới editor" means.

After ingest the inbox copy is deleted. The inbox is a hand-off buffer: the
image is still in the Photos library and now also in `originals/`.

**The second way in: `ShareHandoffRouter.handleInbox`.** Because opening the app
from an extension is a trick and not a promise, every launch also looks in the
inbox and opens whatever is still there. That turns the worst case from "the
photo vanished" into "it is in the editor the next time you open the app". Two
rules keep the two entry points from fighting, both learned from a real run:

* the coordinator refuses a file it has already accepted this launch, so a URL
  and a scan naming the same file produce **one** project;
* the scan waits 1.5 s and then does nothing at all if a URL hand-off already
  claimed this launch — without that, a leftover from an older share replaced
  the photo the user had just shared (observed on the Simulator, fixed).

### 5. Verification

* Unit tests, on macOS and the Simulator, with no Share Sheet and no App Group:
  `ShareHandoffTests` (RPCore — parsing, sanitising, the traversal attempts),
  `ExternalOpenCoordinatorTests` (RPUI — the whole create-project → ingest →
  select → discard sequence the view drives), `ShareHandoffRouterTests`
  (app target — the router with an injected inbox).
* `ShareHandoffSelfTest` (`RP_SHARE_SELFTEST=<file name>`, optional
  `RP_SHARE_SELFTEST_DELAY=<seconds>`) delivers a `retouchpro://open` URL to the
  running app, so both routing cases can be exercised **on the real device**
  where the App Group container actually exists: delay 0 is the cold start (the
  URL arrives as the first screen is being built), a delay is the warm start
  (the app is already up). Same pattern as `FaceSelfTest` / `ExportSelfTest`,
  and for the same reason (docs/ADR-0015): a sandbox-shaped failure is invisible
  on macOS and the Simulator.
* `AppContainer.startupLog` ends with one line saying whether the App Group
  container resolved, so a build that lost the entitlement says so in
  `session.log` instead of failing silently at share time.
* `UITests/ShareExtensionHandoffUITests.swift` drives Photos → Share Sheet →
  RetouchPro for real, once per start-up case. It is deliberately **not** in the
  `RetouchPro` scheme's test action (it is iOS-only and needs a device with
  photos); it has its own `RetouchProUITests` scheme. Both cases pass on the
  iOS 26 Simulator against a real a6300 frame from `Research/data`
  (`DSC05259`), 33 s and 35 s. Note that `xcodebuild test` does **not** always
  reinstall the app under test after a rebuild — install it explicitly
  (`xcrun simctl install`) or the run silently exercises the previous build.

### 6. What is **not** verified yet: the real iPhone

The device build is blocked on signing, not on code:

```
error: Provisioning profile "iOS Team Provisioning Profile: com.duynguyen.RetouchPro"
doesn't match the entitlements file's value for the
com.apple.security.application-groups entitlement.
DVTDeveloperAccountManager: Failed to load credentials for <appleID>:
  Invalid credentials in keychain … missing Xcode-Token
```

The extension's App ID was created with the group
(`…RetouchPro.ShareExtension`'s profile carries
`["group.com.duynguyen.RetouchPro"]`); the **app's** App ID has App Groups
enabled but no group assigned (its profile carries `[]`), and `xcodebuild
-allowProvisioningUpdates` cannot fix that without a signed-in Apple account
session, which the CLI does not have.

Fix, once, in the GUI: open `RetouchPro.xcworkspace` in Xcode → target
**RetouchPro** → Signing & Capabilities → App Groups → tick
`group.com.duynguyen.RetouchPro` (Xcode offers "Try Again" on the profile
error). Then the ordinary device run works:

```
xcodebuild build -workspace RetouchPro.xcworkspace -scheme RetouchPro \
  -destination 'platform=iOS,id=<udid>' -allowProvisioningUpdates
xcrun devicectl device install app --device <udid> <path>/RetouchPro.app
# stage a photo where the extension would have put it, then drive the routing:
xcrun devicectl device copy to --device <udid> \
  --domain-type appGroupDataContainer --domain-identifier group.com.duynguyen.RetouchPro \
  --source Research/data/<photo>.jpg --destination ShareInbox/<photo>.jpg
xcrun devicectl device process launch --console --device <udid> \
  --environment-variables '{"RP_SHARE_SELFTEST":"<photo>.jpg"}' com.duynguyen.RetouchPro
```

## Consequences

* The app now has a public entry point (`retouchpro://`) that any app on the
  device can call. Sanitising in `ShareHandoff` is the only thing standing
  between that and the file system — every change to it deserves the same
  scrutiny as an entitlement change.
* One more signing surface: app and extension must stay on the same team and
  App Group. A mismatch shows up as an empty Share Sheet row or a hand-off that
  logs "App Group UNAVAILABLE".
* Sharing several photos at once is out of scope by the activation rule
  (max 1). The plumbing below it already takes an array, so raising the limit is
  a one-line Info.plist change plus a decision about what the project should be
  called.

import RPUI
import SwiftUI

/// Scene content: `RPUI.RetouchProRootView` — Projects → Editor.
///
/// The view layer lives in `RPUI` (docs/PLAN.md §2); `App/` only builds it and
/// hands it what the container owns. `ProjectsModel` is created once in
/// `AppContainer` so navigating in and out of a project does not rescan the
/// library folder from scratch.
struct RootView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        RetouchProRootView(
            projects: container.projects,
            renderer: container.previewRenderer,
            live: container.live,
            importer: container.importer,
            opener: container.externalOpen
        )
        .task {
            container.startupLog.forEach(AppLog.write)
            // A share the extension staged but could not hand over (it is not
            // guaranteed to be able to open the app — docs/ADR-0017). Safe to
            // run every launch: it waits out `onOpenURL` and then does nothing
            // if a URL hand-off already claimed this launch.
            async let pendingShares: Void = container.openPendingShares()
            // Off unless RP_FACE_SELFTEST is set; see FaceSelfTest for why a
            // real device cannot be checked any other way.
            if let target = FaceSelfTest.target() {
                await FaceSelfTest.run(
                    target: target,
                    renderer: container.previewRenderer,
                    faceProvider: container.faceProvider)
            }
            // The "Sửa da" whole-body mask (docs/ADR-0021 §v2), off unless
            // RP_BODYSKIN_SELFTEST is set. It needs its own hook because its
            // Vision request cannot run on the Simulator at all, so a real
            // device is the only place the intersection actually happens.
            if let target = BodySkinSelfTest.target() {
                await BodySkinSelfTest.run(
                    target: target, renderer: container.previewRenderer, live: container.live)
            }
            // The mask brush (docs/PLAN.md §6.1, docs/ADR-0019), off unless
            // RP_BRUSH_SELFTEST is set. Its own hook for the same reason the two
            // above have one: ADR-0019 requires a ms/frame on an A-series part
            // before the flag goes on, and a package test bundle cannot run on a
            // phone at all.
            if let target = ManualMaskSelfTest.target() {
                await ManualMaskSelfTest.run(
                    target: target, renderer: container.previewRenderer, live: container.live)
            }
            // Same idea for the export path, off unless RP_EXPORT_SELFTEST is
            // set: it runs `ExportController.exportActiveShot` — the Export
            // button's own action — against a shot already in the library, so
            // the sandbox-shaped risks (decode, GPU memory, where the file is
            // written) are checked on the device and not only on the Mac.
            if let target = ExportSelfTest.target() {
                await ExportSelfTest.run(
                    target: target, faceProvider: container.faceProvider, log: AppLog.write)
            }
            // And for the preset library, off unless RP_PRESET_SELFTEST is set:
            // "Nổi bật" reads JSON out of RPCore's resource bundle and "Của
            // tôi" writes into Application Support, and both are the kind of
            // path that resolves on the Mac and can come back empty inside a
            // device container (docs/PLAN.md §Phase 3). It restores whatever it
            // changed — see PresetSelfTest.
            if let target = PresetSelfTest.target() {
                await PresetSelfTest.run(target: target, log: AppLog.write)
            }
            // And for the Share Extension hand-off, off unless
            // RP_SHARE_SELFTEST is set: it delivers a real `retouchpro://open`
            // URL into `AppContainer.open(url:)` — the same entry point
            // `onOpenURL` uses — because a device build is the only place the
            // App Group container exists (docs/ADR-0017 §5).
            if let target = ShareHandoffSelfTest.target() {
                await ShareHandoffSelfTest.run(target: target, log: AppLog.write) { url in
                    container.open(url: url)
                }
            }
            await pendingShares
        }
    }
}

import Foundation
import RPCore

/// Identity of the RPImport package (PLAN Phase 1 item 3).
///
/// Everything here funnels through ``ShotIngestor``, which is the only caller
/// of `ProjectStore.addShot(copyingOriginalAt:into:)` in the package:
///
/// | Type | Source | Testable without hardware |
/// |---|---|---|
/// | ``FilesImporter`` | picker / drag-drop | yes, end to end |
/// | ``PhotosImporter`` | PhotoKit via ``PhotoLibrarySource`` | yes, against a fake library |
/// | ``MTPCameraImporter`` | ImageCaptureCore via ``CameraDeviceSource`` | yes, against a fake session |
/// | ``FolderWatcher`` | a folder or card mount | yes, with an injected clock |
///
/// The two platform-backed implementations — ``PhotoKitLibrarySource`` and
/// ``ImageCaptureCameraSource`` — need a permission prompt and a camera on a
/// cable respectively, and are verified by hand (and by PLAN Phase 0 spike S5),
/// not by these tests. See docs/ADR-0003-import-pipeline.md.
public enum RPImportModule {
    public static let info = ModuleInfo(name: "RPImport", version: "0.2.0", dependsOn: ["RPCore"])
}

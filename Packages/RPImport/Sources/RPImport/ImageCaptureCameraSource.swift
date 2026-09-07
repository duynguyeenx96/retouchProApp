import Foundation
import RPCore

#if canImport(ImageCaptureCore)
    import ImageCaptureCore

    /// The real ``CameraDeviceSource``, on top of ImageCaptureCore.
    ///
    /// ImageCaptureCore is the one camera API that exists on **both** macOS and
    /// iPadOS (PLAN §1.1), which is why MTP import — not tethering — is what
    /// Phase 1 ships. Every API used here is annotated `macos(10.4+), ios(13+)`
    /// (checked against the SDK headers), so there is one code path, not two.
    ///
    /// **Cannot be unit-tested.** It needs a camera on the end of a cable. What
    /// *is* tested is the layer above it: `MTPCameraImporterTests` drives
    /// ``MTPCameraImporter`` against a fake ``CameraSession`` and proves the
    /// wiring into `ProjectStore`. This class gets its real verification from
    /// PLAN Phase 0 spike S5 and a manual smoke test.
    ///
    /// **Host app requirements** (owned by `App/`): on macOS the sandbox needs
    /// `com.apple.security.device.usb`; on iPadOS a connected camera is visible
    /// without an entitlement but only while the app is in the foreground.
    public final class ImageCaptureCameraSource: NSObject, CameraDeviceSource, @unchecked Sendable {
        private let browser = ICDeviceBrowser()
        private let lock = NSLock()
        private var devices: [ICDevice] = []
        private var browsingStarted = false

        public override init() {
            super.init()
            browser.delegate = self
            browser.browsedDeviceTypeMask = ICDeviceTypeMask(
                rawValue: ICDeviceTypeMask.camera.rawValue
                    | ICDeviceLocationTypeMask.local.rawValue
            )!
        }

        deinit {
            browser.stop()
        }

        public func cameras(waitingFor timeout: Duration) async -> [CameraDeviceDescriptor] {
            startBrowsingIfNeeded()
            // `ICDeviceBrowser` never signals "that is all of them", so a
            // deadline is part of the API rather than a hidden detail. Polling
            // (rather than resuming on the first `didAdd`) means a second
            // camera plugged in during the window is still seen.
            let deadline = ContinuousClock.now.advanced(by: timeout)
            var found = snapshot()
            while found.isEmpty && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(200))
                found = snapshot()
            }
            return found.map(Self.describe)
        }

        public func openSession(with device: CameraDeviceDescriptor) async throws
            -> any CameraSession
        {
            startBrowsingIfNeeded()
            guard let icDevice = snapshot().first(where: { Self.identifier(of: $0) == device.id }),
                let camera = icDevice as? ICCameraDevice
            else {
                throw CameraImportError.deviceNotFound(device.id)
            }
            let session = ICCameraSession(camera: camera, descriptor: device)
            try await session.open()
            return session
        }

        private func startBrowsingIfNeeded() {
            lock.lock()
            defer { lock.unlock() }
            guard !browsingStarted else { return }
            browsingStarted = true
            browser.start()
        }

        private func snapshot() -> [ICDevice] {
            lock.lock()
            defer { lock.unlock() }
            return devices
        }

        /// Stable-for-this-session identity of a device.
        ///
        /// `persistentIDString` is macOS-only, so iOS falls back to the UUID
        /// and then the name. A `CameraDeviceDescriptor.id` only has to survive
        /// from "list the cameras" to "open a session", so that is enough.
        static func identifier(of device: ICDevice) -> String {
            if let uuid = device.uuidString { return uuid }
            #if os(macOS)
                if let persistent = device.persistentIDString { return persistent }
            #endif
            return device.name ?? "unknown-device"
        }

        static func describe(_ device: ICDevice) -> CameraDeviceDescriptor {
            CameraDeviceDescriptor(
                id: identifier(of: device),
                name: device.name ?? "Camera",
                manufacturer: nil,
                // A card reader arrives over the mass-storage transport; an
                // a6300 set to "MTP" arrives over USB as a PTP camera. Only
                // affects the label; both import identically.
                isMassStorage: device.transportType
                    == ICDeviceTransport.transportTypeMassStorage.rawValue
            )
        }
    }

    extension ImageCaptureCameraSource: ICDeviceBrowserDelegate {
        public func deviceBrowser(
            _ browser: ICDeviceBrowser,
            didAdd device: ICDevice,
            moreComing: Bool
        ) {
            lock.lock()
            devices.append(device)
            lock.unlock()
        }

        public func deviceBrowser(
            _ browser: ICDeviceBrowser,
            didRemove device: ICDevice,
            moreGoing: Bool
        ) {
            lock.lock()
            devices.removeAll { $0 === device }
            lock.unlock()
        }
    }

    /// One open ImageCaptureCore session.
    ///
    /// An `actor` would read better, but every ImageCaptureCore result arrives
    /// on a delegate callback and the receiver has to be an `NSObject`, so this
    /// is a lock-guarded class with an `async` facade.
    final class ICCameraSession: NSObject, CameraSession, @unchecked Sendable {
        let device: CameraDeviceDescriptor
        private let camera: ICCameraDevice
        private let lock = NSLock()
        /// Settled by `deviceDidBecomeReady(withCompleteContentCatalog:)`, or
        /// with an error when the device goes away. A latch rather than a
        /// stored continuation because the delegate callback can arrive on
        /// ImageCaptureCore's thread *before* ``contents()`` decides to wait;
        /// see ``EventLatch``.
        private let catalogLatch = EventLatch()
        private var downloads: [ObjectIdentifier: CheckedContinuation<URL, any Error>] = [:]
        private var isOpen = false

        init(camera: ICCameraDevice, descriptor: CameraDeviceDescriptor) {
            self.camera = camera
            self.device = descriptor
            super.init()
            camera.delegate = self
        }

        func open() async throws {
            guard !isOpen else { return }
            do {
                // Chronological enumeration so the filmstrip order matches the
                // order the shots were taken, which is what a photographer
                // reviewing a shoot expects.
                try await camera.requestOpenSession(options: [
                    ICSessionOptions.enumerationChronologicalOrder: true
                ])
            } catch {
                throw CameraImportError.sessionFailed(error.localizedDescription)
            }
            isOpen = true
        }

        func close() async {
            guard isOpen else { return }
            isOpen = false
            try? await camera.requestCloseSession(options: nil)
        }

        func contents() async throws -> [CameraItemDescriptor] {
            // `mediaFiles` fills in as the device enumerates;
            // `deviceDidBecomeReady(withCompleteContentCatalog:)` is the signal
            // that it is complete. If files are already there, the catalog
            // arrived before we asked.
            if let files = camera.mediaFiles, !files.isEmpty {
                return files.compactMap(Self.describe)
            }
            // Otherwise wait for the catalog. `catalogLatch` is a latch, not a
            // parked continuation, so a `deviceDidBecomeReady` that fires
            // between the check above and this line returns immediately instead
            // of hanging the import (there is no timeout on this path).
            try await catalogLatch.wait()
            return (camera.mediaFiles ?? []).compactMap(Self.describe)
        }

        func download(_ item: CameraItemDescriptor, to directory: URL) async throws -> URL {
            guard
                let file = camera.mediaFiles?
                    .compactMap({ $0 as? ICCameraFile })
                    .first(where: { Self.identifier(of: $0) == item.id })
            else {
                throw CameraImportError.downloadFailed(
                    item: item.name, message: "no longer on the camera")
            }

            // One directory per download so two files with the same name in
            // different card folders cannot collide before RPCore sees them.
            let destination = directory.appendingPathComponent(
                UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)

            // `deleteAfterSuccessfulDownload: false` is written out rather than
            // omitted, on purpose. The card is frequently the only copy of a
            // shoot until export finishes; nothing in this app erases a camera
            // (PLAN Phase 4: "không xoá gì trên máy"). `requestDeleteFiles` is
            // never called anywhere in RPImport.
            let options: [ICDownloadOption: Any] = [
                .downloadsDirectoryURL: destination,
                .saveAsFilename: item.name,
                .overwrite: true,
                .deleteAfterSuccessfulDownload: false,
            ]

            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                downloads[ObjectIdentifier(file)] = continuation
                lock.unlock()
                camera.requestDownloadFile(
                    file,
                    options: options,
                    downloadDelegate: self,
                    didDownloadSelector: #selector(
                        ICCameraSession.didDownloadFile(_:error:options:contextInfo:)),
                    contextInfo: nil
                )
            }
        }

        /// `ICCameraDeviceDownloadDelegate`'s completion callback, named to
        /// match the selector handed to `requestDownloadFile`.
        @objc(didDownloadFile:error:options:contextInfo:)
        func didDownloadFile(
            _ file: ICCameraFile,
            error: (any Error)?,
            options: [String: Any],
            contextInfo: UnsafeMutableRawPointer?
        ) {
            lock.lock()
            let continuation = downloads.removeValue(forKey: ObjectIdentifier(file))
            lock.unlock()
            guard let continuation else { return }

            if let error {
                continuation.resume(
                    throwing: CameraImportError.downloadFailed(
                        item: file.name ?? "file", message: error.localizedDescription))
                return
            }
            // ImageCaptureCore echoes the options back with `savedFilename`
            // filled in — it may differ from what we asked for if the camera
                // reported a different name.
            guard
                let directory = options[ICDownloadOption.downloadsDirectoryURL.rawValue] as? URL
            else {
                continuation.resume(
                    throwing: CameraImportError.downloadFailed(
                        item: file.name ?? "file",
                        message: "the camera did not report where the file was saved"))
                return
            }
            let name =
                (options[ICDownloadOption.savedFilename.rawValue] as? String)
                ?? file.name ?? "file"
            continuation.resume(returning: directory.appendingPathComponent(name))
        }

        static func identifier(of file: ICCameraFile) -> String {
            let folder = file.parentFolder?.name ?? ""
            let name = file.name ?? "unnamed"
            return folder.isEmpty ? name : "\(folder)/\(name)"
        }

        static func describe(_ item: ICCameraItem) -> CameraItemDescriptor? {
            guard let file = item as? ICCameraFile else { return nil }
            return CameraItemDescriptor(
                id: identifier(of: file),
                name: file.name ?? "unnamed",
                byteSize: Int64(file.fileSize),
                creationDate: file.creationDate,
                uniformTypeIdentifier: file.uti
            )
        }

        /// Fails every outstanding continuation. Called when the device goes
        /// away mid-import, so a pulled cable surfaces as an import failure
        /// instead of a task that never resumes.
        private func failAllPending(with error: any Error) {
            lock.lock()
            let pending = downloads
            downloads = [:]
            lock.unlock()
            // Fails anyone waiting for the catalog *and* anyone who starts
            // waiting afterwards: the session is dead, so a later `contents()`
            // must throw rather than wait for a catalog that will never come.
            catalogLatch.fail(error)
            for (_, continuation) in pending { continuation.resume(throwing: error) }
        }

        fileprivate func deviceWentAway(_ device: ICDevice) {
            isOpen = false
            failAllPending(with: CameraImportError.deviceNotFound(device.name ?? "camera"))
        }

        fileprivate func catalogBecameComplete(_ device: ICCameraDevice) {
            catalogLatch.signal()
        }
    }

    extension ICCameraSession: ICCameraDeviceDelegate {
        func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {}
        func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}

        func didRemove(_ device: ICDevice) {
            deviceWentAway(device)
        }

        func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
            catalogBecameComplete(device)
        }

        func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
        func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
        func cameraDevice(
            _ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?,
            for item: ICCameraItem, error: (any Error)?
        ) {}
        func cameraDevice(
            _ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?,
            for item: ICCameraItem, error: (any Error)?
        ) {}
        func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
        func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
        func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
        func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
        func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    }

    /// Conformance only; the completion arrives through
    /// ``ICCameraSession/didDownloadSelector``, and every member of this
    /// protocol is optional.
    extension ICCameraSession: ICCameraDeviceDownloadDelegate {}
#else

    /// Stand-in on platforms without ImageCaptureCore, so the rest of RPImport
    /// still compiles and reports "unavailable" instead of trapping.
    public struct ImageCaptureCameraSource: CameraDeviceSource {
        public init() {}
        public func cameras(waitingFor timeout: Duration) async -> [CameraDeviceDescriptor] { [] }
        public func openSession(with device: CameraDeviceDescriptor) async throws
            -> any CameraSession
        {
            throw CameraImportError.unavailableOnThisPlatform
        }
    }
#endif

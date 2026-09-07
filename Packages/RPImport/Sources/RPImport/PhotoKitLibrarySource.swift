import Foundation
import RPCore

#if canImport(Photos)
    import Photos
    import UniformTypeIdentifiers

    /// The real ``PhotoLibrarySource``, on top of PhotoKit.
    ///
    /// Kept as thin as it can be: it maps `PHAsset` → ``PhotoAssetDescriptor``
    /// and writes one resource to disk. Everything that decides *what happens to
    /// the file* lives in ``PhotosImporter``, which is testable. This type is only
    /// exercisable with a real library, a usage-description string in the app's
    /// Info.plist and a user tapping "Allow", so there is nothing here worth
    /// unit-testing and nothing here that a unit test would catch.
    ///
    /// **Host app requirements** (owned by `App/`, not by this package):
    /// `NSPhotoLibraryUsageDescription` in Info.plist; on macOS the sandbox needs
    /// `com.apple.security.personal-information.photos-library`.
    public struct PhotoKitLibrarySource: PhotoLibrarySource {
        /// Allow the resource to be fetched from iCloud when it is not on
        /// device. Off would make a partially-offloaded library fail at random.
        public var allowsNetworkAccess: Bool

        public init(allowsNetworkAccess: Bool = true) {
            self.allowsNetworkAccess = allowsNetworkAccess
        }

        public func authorizationStatus() async -> PhotoAuthorization {
            Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        }

        public func requestAuthorization() async -> PhotoAuthorization {
            await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    continuation.resume(returning: Self.map(status))
                }
            }
        }

        public func assets(withLocalIdentifiers identifiers: [String]) async throws
            -> [PhotoAssetDescriptor]
        {
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            var byIdentifier: [String: PhotoAssetDescriptor] = [:]
            fetch.enumerateObjects { asset, _, _ in
                byIdentifier[asset.localIdentifier] = Self.describe(asset)
            }
            // Preserve the caller's order — a picker's selection order is what
            // the user will expect to see in the filmstrip.
            return identifiers.compactMap { byIdentifier[$0] }
        }

        public func exportOriginal(
            _ asset: PhotoAssetDescriptor,
            to directory: URL
        ) async throws -> URL {
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [asset.id], options: nil)
            guard let phAsset = fetch.firstObject else {
                throw PhotoLibraryError.assetNotFound(asset.id)
            }
            guard let resource = Self.preferredResource(for: phAsset) else {
                throw PhotoLibraryError.noExportableResource(asset.id)
            }

            let destination =
                directory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent(resource.originalFilename)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = allowsNetworkAccess

            // `writeData(for:toFile:)` writes the resource **as stored**. It is
            // the only PhotoKit call that does; `requestImageDataAndOrientation`
            // and `PHImageManager` can re-render, which would destroy a RAW.
            // Do not replace it.
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                PHAssetResourceManager.default().writeData(
                    for: resource, toFile: destination, options: options
                ) { error in
                    if let error {
                        continuation.resume(
                            throwing: PhotoLibraryError.exportFailed(
                                "\(asset.originalFileName): \(error.localizedDescription)"))
                    } else {
                        continuation.resume()
                    }
                }
            }
            return destination
        }

        // MARK: - Mapping

        static func map(_ status: PHAuthorizationStatus) -> PhotoAuthorization {
            switch status {
            case .notDetermined: .notDetermined
            case .restricted: .restricted
            case .denied: .denied
            case .authorized: .authorized
            case .limited: .limited
            @unknown default: .denied
            }
        }

        static func describe(_ asset: PHAsset) -> PhotoAssetDescriptor {
            let resources = PHAssetResource.assetResources(for: asset)
            let preferred = preferredResource(from: resources)
            return PhotoAssetDescriptor(
                id: asset.localIdentifier,
                originalFileName: preferred?.originalFilename ?? "\(asset.localIdentifier).jpg",
                creationDate: asset.creationDate,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                hasRAWResource: resources.contains(where: { isRAW($0) }),
                uniformTypeIdentifier: preferred?.uniformTypeIdentifier,
                byteSize: nil
            )
        }

        static func preferredResource(for asset: PHAsset) -> PHAssetResource? {
            preferredResource(from: PHAssetResource.assetResources(for: asset))
        }

        /// Resource selection, in the order that keeps the most information.
        ///
        /// PLAN Phase 1 says "Photos (giữ RAW)". In a RAW+JPEG pair Photos
        /// stores the RAW as `.alternatePhoto` and the JPEG as `.photo`, so
        /// picking `.photo` — the obvious choice — would throw the RAW away.
        /// Hence: any RAW-typed resource first, then the unmodified original,
        /// then whatever is left.
        static func preferredResource(from resources: [PHAssetResource]) -> PHAssetResource? {
            if let raw = resources.first(where: { isRAW($0) }) { return raw }
            if let photo = resources.first(where: { $0.type == .photo }) { return photo }
            if let full = resources.first(where: { $0.type == .fullSizePhoto }) { return full }
            return resources.first
        }

        static func isRAW(_ resource: PHAssetResource) -> Bool {
            if let type = UTType(resource.uniformTypeIdentifier),
                type.conforms(to: .rawImage)
            {
                return true
            }
            // Belt and braces: a resource whose extension is on RPCore's RAW
            // allow-list but whose UTI the system does not know (an ARW copied
            // in from a card on an older OS) is still RAW.
            let ext = (resource.originalFilename as NSString).pathExtension.lowercased()
            return ProjectBundle.isImportableExtension(ext) && Self.rawExtensions.contains(ext)
        }

        static let rawExtensions: Set<String> = [
            "arw", "dng", "cr2", "cr3", "nef", "raf", "orf", "rw2", "srw", "pef",
        ]
    }
#else

    /// Stand-in on platforms with no Photos framework, so the rest of RPImport
    /// still compiles. Every call reports "unavailable" rather than trapping.
    public struct PhotoKitLibrarySource: PhotoLibrarySource {
        public init(allowsNetworkAccess: Bool = true) {}
        public func authorizationStatus() async -> PhotoAuthorization { .restricted }
        public func requestAuthorization() async -> PhotoAuthorization { .restricted }
        public func assets(withLocalIdentifiers identifiers: [String]) async throws
            -> [PhotoAssetDescriptor]
        {
            throw PhotoLibraryError.unavailableOnThisPlatform
        }
        public func exportOriginal(_ asset: PhotoAssetDescriptor, to directory: URL) async throws
            -> URL
        {
            throw PhotoLibraryError.unavailableOnThisPlatform
        }
    }
#endif

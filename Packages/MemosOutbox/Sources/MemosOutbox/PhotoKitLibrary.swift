#if os(iOS)
import Foundation
import Photos
import UniformTypeIdentifiers

/// The photo library the app stages from (MEMNG-952): an item named by its persisted
/// `PHAsset.localIdentifier` is written out through `PHAssetResourceManager` — the original
/// resource, network access allowed for an iCloud original — to the lane's temporary file, which
/// the repository then renames into the capture. The share extension's `loadFileRepresentation`
/// needs the picker's item provider, which no later launch has; this is the same copy-then-rename
/// from the identifier that outlives it.
public struct PhotoKitLibrary: PhotoLibrarySource {
    public init() {}

    public func access(mayPrompt: Bool) async -> PhotoLibraryAccess {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined, mayPrompt {
            // The system shows this once; every later call answers from the person's choice.
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        switch status {
        case .authorized, .limited: return .granted
        default: return .denied
        }
    }

    public func copy(_ assetIdentifier: String, to destination: URL) async throws
        -> PhotoLibraryCopy
    {
        let found = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
        guard let asset = found.firstObject else { throw PhotoLibraryCopyError.unavailable }
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] =
            asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        guard
            let resource = preferred.lazy.compactMap({ type in
                resources.first { $0.type == type }
            }).first ?? resources.first
        else { throw PhotoLibraryCopyError.unavailable }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try Task.checkCancellation()
        try await PHAssetResourceManager.default().writeData(
            for: resource, toFile: destination, options: options)
        try Task.checkCancellation()
        let type = UTType(resource.uniformTypeIdentifier)
        return PhotoLibraryCopy(
            filename: resource.originalFilename,
            mime: type?.preferredMIMEType ?? "application/octet-stream",
            lastModified: asset.creationDate
        )
    }
}

#endif

import Foundation
import MemosShareKit
import UniformTypeIdentifiers

/// Turns what the system handed the extension into things the outbox can take.
///
/// Every media item is loaded as a FILE and copied with `FileManager`. A share extension is given
/// a fraction of an app's memory, so `loadDataRepresentation` — which would hand back a whole
/// video as `Data` — is not an option here at any size; `openInPlace` is asked for so the system
/// may skip its own export copy when it can.
///
/// Main-actor isolated, like the rest of this target: the providers are handed straight from the
/// extension context to the sheet, and the work itself happens on the providers' own threads.
enum SharedItemLoader {
    /// - Returns: what could be read, and how many items could not be. A failure is COUNTED, never
    ///   dropped: silently posting a memo without the photo someone shared is the mistake they
    ///   find out about weeks later.
    static func load(
        _ providers: [NSItemProvider],
        into directory: URL
    ) async -> (items: [SharedItem], failed: Int) {
        var items: [SharedItem] = []
        var failed = 0
        for provider in providers {
            if let item = await load(provider, into: directory) {
                items.append(item)
            } else {
                failed += 1
            }
        }
        return (items, failed)
    }

    /// The order is the order of specificity the activation rule admits: a movie and an image are
    /// files; a web page's address and its title are words. A provider that offers several of
    /// these offers the richest one first.
    private static func load(_ provider: NSItemProvider, into directory: URL) async -> SharedItem? {
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return await file(provider, type: .movie, into: directory)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return await file(provider, type: .image, into: directory)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            return await link(provider)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            return await text(provider)
        }
        return nil
    }

    private static func file(
        _ provider: NSItemProvider,
        type: UTType,
        into directory: URL
    ) async -> SharedItem? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: true) { url, inPlace, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                // The provider's URL is only valid until this closure returns, so the copy happens
                // here — and an in-place original is someone else's file, which has to be opened
                // under its security scope and given back.
                let scoped = inPlace && url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let file = try? SharedFile.imported(url, into: directory) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: .file(file))
            }
        }
    }

    private static func link(_ provider: NSItemProvider) async -> SharedItem? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url.map { SharedItem.link($0) })
            }
        }
    }

    private static func text(_ provider: NSItemProvider) async -> SharedItem? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                continuation.resume(returning: text.map { SharedItem.text($0) })
            }
        }
    }
}

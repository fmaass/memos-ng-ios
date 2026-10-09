import MemosCore
import SwiftUI

/// What a screen that hosts `LibraryGrid` gives the grid, written once for every host
/// (MEMNG-714).
///
/// The grid draws and calls out; it never opens or fetches anything itself, so each screen it
/// stands on owes it the same three things: the viewer a tile's tap opens, the file a tile's menu
/// fetches, and someone to re-sign a lapsed picture. These were `MediaLibraryView`'s private
/// functions until a trip's grid needed them too; both screens now reach them here, so the Library
/// and a trip cannot drift apart in how a tap opens the viewer or how an original leaves the
/// session's download lane. The re-signing stays per screen — only the screen that owns a list
/// can mint another URL for it (`SignedURLRefreshing`) — and comes in as a value.
enum MediaGridHosting {
    /// The viewer a tile's tap opens: over `items` as the grid holds them, at the tapped file.
    static func viewing(_ attachment: MemoAttachment, in items: [LibraryRow])
        -> MediaViewerSelection?
    {
        MediaViewerPresentation.viewer(for: items.map(\.attachment), startingAt: attachment.uid)
    }

    /// A tile menu's fetch: the named rendition of the file through the session's download lane,
    /// offered by `saving`. The credential the original tier needs is the session's, and it stays
    /// there (see `OriginalMedia`). With no session there is nothing to fetch with.
    static func fetch(
        _ attachment: MemoAttachment,
        _ rendition: AttachmentRendition,
        saving: MediaSaveFlow,
        session: SessionStore?
    ) async {
        guard let session else { return }
        await saving.save(attachment) { [session] file in
            try await session.download(file, rendition)
        }
    }
}

extension View {
    /// The full-screen viewer a grid's tap opens, re-signed by `refresher` and grown out of the
    /// tile it matches in `zoom`. `source` is the host's: where the viewer's pages come from, read
    /// for the selection that was opened. `transport` is what the viewer fetches its stills through
    /// — the image layer's own session unless a test is watching it. `action` is the host's one
    /// extra control on a page, nil everywhere but a trip (`MediaViewerHostAction`).
    ///
    /// Declared outside the host's stack and apart from any sheet of its own, for the reason the
    /// timeline's cover is: two presentations on one view is how one of them silently stops
    /// appearing.
    func gridViewer(
        _ viewing: Binding<MediaViewerSelection?>,
        refresher: (any SignedURLRefreshing)?,
        zoom: Namespace.ID,
        transport: any MediaTransport = MediaSession.shared,
        action: MediaViewerHostAction? = nil,
        source: @escaping (MediaViewerSelection) -> MediaViewerSource
    ) -> some View {
        fullScreenCover(item: viewing) { selection in
            MediaViewerView(
                selection: selection, source: source(selection), hostAction: action,
                transport: transport
            )
            .environment(\.signedURLRefresher, refresher)
            .mediaZoomTransition(sourceID: selection.id, in: zoom)
        }
    }
}

import Foundation

extension MemoAttachment {
    /// One pin as the viewer takes it.
    ///
    /// Places adapts rather than pages: the viewer already opens on a fixed list of attachments,
    /// so a marker becomes one of those and nothing about the viewer changes. It lives beside the
    /// model and imports nothing but Foundation, the same split as the library's own row adapter.
    ///
    /// Two fields are decided here rather than carried. `status` is `.ready` because the markers
    /// query answers with ready attachments only: a file still being derived has no coordinate
    /// on it yet. `duration` is nil for the reason the library gives: the payload carries none,
    /// and a zero would read as a clip of no length rather than as an unknown.
    ///
    /// `memoUID` is the MARKER's memo, not the file's uid. It is the whole of what "Show in memo"
    /// asks for, so a mix-up here opens somebody else's memo rather than failing visibly.
    public init(_ marker: PlaceMarker) {
        self.init(
            uid: marker.uid,
            mime: marker.mime,
            status: .ready,
            blurhash: marker.blurhash,
            width: marker.width,
            height: marker.height,
            duration: nil,
            // The marker's own owner flag. Its `takenAt` is a display date and stays off this
            // model: it rides to the viewer as `MediaPage.takenAt`, never as capture metadata.
            mine: marker.mine,
            thumbnailURL: marker.thumbnailURL,
            previewURL: marker.previewURL,
            webURL: marker.webURL,
            posterURL: marker.posterURL,
            downloadURL: marker.downloadURL,
            memoUID: marker.memoUID,
            tags: marker.tags
        )
    }
}

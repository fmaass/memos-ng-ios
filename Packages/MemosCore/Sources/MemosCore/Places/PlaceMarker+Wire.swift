import Foundation
import MemosAPI

extension PlaceMarker {
    /// One row of `GET /api/map/markers`.
    ///
    /// It lives here rather than beside the model for the reason the model states: the Places
    /// decisions are pure functions that must be testable without a client or a wire fixture, so
    /// `PlaceMarker.swift` imports nothing but Foundation. The same split, for the same reason, as
    /// `MemoAttachment`'s library row (`LibraryAttachment.swift`).
    ///
    /// The conversion is TOTAL — every field this model needs is required on the wire, `taken_at`
    /// included, because the server coalesces a missing capture time down to the attachment's own
    /// creation time before it answers. So no marker is dropped here and no date is invented: a row
    /// the server sent is a pin the map draws.
    ///
    /// The four tier URLs arrive as paths and are resolved against the server this answer came
    /// from, exactly as the library resolves its rows'. A string that forms no URL leaves THAT tier
    /// nil rather than dropping the marker: a pin with no thumbnail is still a place somebody was.
    ///
    /// The original is resolved the same way and is required on the wire too, but it is not a
    /// fifth tier: it is served behind authentication, and it is carried because the viewer a pin
    /// opens offers Share and Save only to a photo that has one.
    public init(from generated: Components.Schemas.MapMarker, baseURL: URL) {
        self.init(
            uid: generated.uid,
            memoUID: generated.memoUid,
            mime: generated.mime,
            mine: generated.mine,
            width: generated.width,
            height: generated.height,
            latitude: generated.latitude,
            longitude: generated.longitude,
            takenAt: generated.takenAt,
            thumbnailURL: URL(string: generated.thumbnailUrl, relativeTo: baseURL)?.absoluteURL,
            previewURL: URL(string: generated.previewUrl, relativeTo: baseURL)?.absoluteURL,
            webURL: URL(string: generated.webUrl, relativeTo: baseURL)?.absoluteURL,
            posterURL: URL(string: generated.posterUrl, relativeTo: baseURL)?.absoluteURL,
            downloadURL: URL(string: generated.downloadUrl, relativeTo: baseURL)?.absoluteURL,
            blurhash: generated.blurhash,
            tags: generated.tags ?? []
        )
    }
}

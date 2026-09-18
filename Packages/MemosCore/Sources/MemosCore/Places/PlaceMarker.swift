import Foundation

/// One located attachment, as every Places decision sees it.
///
/// A domain model rather than the generated map type, deliberately: these functions are the whole
/// of the feature's decision-making and they must be testable without a client, a transport or a
/// wire fixture. The store maps the generated type onto this one; nothing else knows it exists.
///
/// `takenAt` is a plain `Date` rather than an optional one because the contract makes it so —
/// `MapMarker.taken_at` is required, non-nullable and `format: date-time` — so a marker that
/// cannot be placed in time cannot reach this type at all. The SPA parses that field as a string
/// at the last moment and therefore carries an "undated" escape hatch through its histogram; here
/// the same case is structurally impossible, which is why no such set is modelled below.
nonisolated public struct PlaceMarker: Sendable, Equatable, Identifiable {
    public var uid: String
    public var memoUID: String
    public var mime: String
    /// Whether the memo this file hangs on belongs to the signed-in person.
    public var mine: Bool
    public var width: Int?
    public var height: Int?
    public var latitude: Double
    public var longitude: Double
    public var takenAt: Date
    /// The four derived tiers the server signs — the same four a memo's attachment carries.
    public var thumbnailURL: URL?
    public var previewURL: URL?
    public var webURL: URL?
    public var posterURL: URL?
    public var blurhash: String?

    public var id: String { uid }

    public init(
        uid: String,
        memoUID: String,
        mime: String,
        mine: Bool,
        width: Int? = nil,
        height: Int? = nil,
        latitude: Double,
        longitude: Double,
        takenAt: Date,
        thumbnailURL: URL? = nil,
        previewURL: URL? = nil,
        webURL: URL? = nil,
        posterURL: URL? = nil,
        blurhash: String? = nil
    ) {
        self.uid = uid
        self.memoUID = memoUID
        self.mime = mime
        self.mine = mine
        self.width = width
        self.height = height
        self.latitude = latitude
        self.longitude = longitude
        self.takenAt = takenAt
        self.thumbnailURL = thumbnailURL
        self.previewURL = previewURL
        self.webURL = webURL
        self.posterURL = posterURL
        self.blurhash = blurhash
    }
}

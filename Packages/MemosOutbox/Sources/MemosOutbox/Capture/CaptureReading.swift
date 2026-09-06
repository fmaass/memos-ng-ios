import Foundation

/// Which tag a capture date came out of. Nothing else is ever read (F2's whitelist).
public enum CaptureSource: String, Sendable, Equatable, Codable {
    /// An image's EXIF `DateTimeOriginal`, with or without an offset beside it.
    case exif
    /// A movie's `com.apple.quicktime.creationdate`, or its movie header.
    case quicktime
}

/// What ONE file said about when it was captured, before any zone is applied to it.
///
/// Two readings are possible and they are not the same fact. An EXACT instant is one the file
/// carried an offset for; a CIVIL time is a wall-clock reading whose zone the file never recorded,
/// and only a client that knows where it is standing can turn it into an instant — which is why it
/// travels as text and is resolved (and marked approximate) at the moment it is compared.
///
/// Absence is the ordinary answer. A file with no date tags, a malformed one, a movie header that
/// is zero or from 1904: all of them read as nothing at all, never as an error. A capture date the
/// app cannot prove is worth less than no capture date.
public struct CaptureReading: Sendable, Equatable, Codable {
    /// The instant the file named outright, floored to the second.
    public var instant: Date?
    /// A wall-clock reading, `YYYY-MM-DDTHH:MM:SS`, that no zone was given for.
    public var civil: String?
    /// Which tag the reading came from, or nil when there was nothing to read.
    public var source: CaptureSource?

    public init(instant: Date? = nil, civil: String? = nil, source: CaptureSource? = nil) {
        self.instant = instant
        self.civil = civil
        self.source = source
    }

    /// The file said nothing.
    public static let empty = CaptureReading()
}

/// Where one attachment's capture read has got to.
///
/// The distinction is what makes "settle before posting" possible at all: a `pending` item has no
/// answer YET, and an item with no date has an answer that happens to be nothing. Treating the
/// first as the second is how a memo gets dated before the photo that should have dated it has
/// been read.
public enum CaptureDecision: Sendable, Equatable {
    case pending
    case settled(CaptureReading)

    public var isPending: Bool { self == .pending }

    /// What was read, or nil while the read is still running.
    public var reading: CaptureReading? {
        if case .settled(let reading) = self { return reading }
        return nil
    }
}

/// Anything the Auto date and the capture order can be computed over.
///
/// A protocol rather than a concrete row so that the composer's tile, the share sheet's item and a
/// test's stub are all ordered by the SAME function — an adapter in between is a place for the two
/// orders to drift.
public protocol CaptureCarrying {
    var capture: CaptureDecision { get }
}

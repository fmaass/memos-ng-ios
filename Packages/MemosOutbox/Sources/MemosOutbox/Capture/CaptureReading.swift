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
///
/// A read that never heard the file out is a different fact, and it says so in `failure`. It
/// still dates nothing — the Auto date and the order treat it exactly as they treat `.empty` —
/// but it is not EQUAL to `.empty`, so a caller can tell "this photo has no date" from "this
/// photo's date was not read", which on a busy phone is the difference between a fact about the
/// file and a fact about the moment it was picked.
public struct CaptureReading: Sendable, Equatable, Codable {
    /// The instant the file named outright, floored to the second.
    public var instant: Date?
    /// A wall-clock reading, `YYYY-MM-DDTHH:MM:SS`, that no zone was given for.
    public var civil: String?
    /// Which tag the reading came from, or nil when there was nothing to read.
    public var source: CaptureSource?
    /// Why the file was not heard out, or nil when it was — including when it said nothing.
    public var failure: CaptureReadFailure?
    /// What the refusing decoder reported at the moment it refused — an ImageIO status, an
    /// AVFoundation error domain and code — and never anything read out of the file.
    public var detail: String?

    public init(
        instant: Date? = nil, civil: String? = nil, source: CaptureSource? = nil,
        failure: CaptureReadFailure? = nil, detail: String? = nil
    ) {
        self.instant = instant
        self.civil = civil
        self.source = source
        self.failure = failure
        self.detail = detail
    }

    /// The file said nothing.
    public static let empty = CaptureReading()
}

/// Why a read answered without having heard the file out.
public enum CaptureReadFailure: String, Sendable, Equatable, Codable {
    /// The read had not finished when its deadline passed. A slow decoder on a loaded device is the
    /// usual cause, which is why this is a failure and never a verdict on the file.
    case deadline
    /// The caller went away before the read answered.
    case cancelled
    /// The system decoder refused the file: AVFoundation threw while loading what was asked of it,
    /// or ImageIO opened no source or no properties for it.
    case undecodable
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
    /// The zone this item's civil reading is resolved in, snapshotted when the item was picked.
    ///
    /// It travels WITH the item because a civil time has no zone of its own and the device's can
    /// change: a phone that crosses a border, or a person who corrects the setting, would otherwise
    /// re-resolve readings that have already been shown — moving the memo's date and reordering the
    /// pictures after the fact. Nil means "whatever zone the caller supplies", which is what a
    /// vector out of the artefact has.
    var captureZone: TimeZone? { get }
}

extension CaptureCarrying {
    public var captureZone: TimeZone? { nil }
}

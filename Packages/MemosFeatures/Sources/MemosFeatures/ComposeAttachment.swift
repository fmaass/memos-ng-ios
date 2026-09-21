import Foundation
import MemosCore
import MemosOutbox

/// Why one picked item could not be read, in the four categories a person can act on.
///
/// The category is what the tile says, and the reason it is a value rather than an error message is
/// that the sentences differ in what they PROMISE. "Needs connection" says the file is fine and the
/// network is not; saying that about a failure nobody classified would be an invitation to go and
/// find a network that will not help. So an unclassified failure says "Couldn't load" and never
/// "needs connection".
nonisolated public enum ComposeLoadFailure: Sendable, Equatable {
    /// The network was not there — the picker's export could not be fetched.
    case transport
    /// The original lives in iCloud and did not come down.
    case iCloudUnavailable
    /// The device would not keep the copy.
    case storage
    /// Anything else. It is not "needs connection", because nobody here knows that.
    case unknown

    /// What the tile says under the thumbnail.
    public var tileLabel: String {
        switch self {
        case .transport, .iCloudUnavailable: "Needs connection"
        case .storage: "No room"
        case .unknown: "Couldn't load"
        }
    }

    /// What a screen reader hears, which never abbreviates the fact.
    public var accessibilityLabel: String {
        switch self {
        case .transport: "Could not be loaded: the server could not be reached"
        case .iCloudUnavailable: "Could not be loaded: the original is in iCloud and did not arrive"
        case .storage: "Could not be loaded: there was no room on this device"
        case .unknown: "Could not be loaded"
        }
    }

    /// The category an error thrown by the picker's export falls into.
    ///
    /// The domains are read down the chain, because the picker wraps what it is given: a
    /// `CloudPhotoLibrary` failure arrives inside a `CocoaError` inside whatever `Transferable`
    /// wrapped it. Nothing here is a guess dressed as a diagnosis — anything unrecognised is
    /// `unknown`.
    public static func category(for error: any Error) -> ComposeLoadFailure {
        var current: NSError? = error as NSError
        for _ in 0..<16 {
            guard let error = current else { break }
            if error.domain == NSURLErrorDomain { return .transport }
            if error.domain.contains("CloudPhotoLibrary") || error.domain.contains("CKError") {
                return .iCloudUnavailable
            }
            if error.domain == NSCocoaErrorDomain {
                switch error.code {
                case NSFileWriteOutOfSpaceError, NSFileWriteNoPermissionError,
                    NSFileWriteVolumeReadOnlyError:
                    return .storage
                case NSUbiquitousFileUnavailableError, NSUbiquitousFileNotUploadedDueToQuotaError,
                    NSUbiquitousFileUbiquityServerNotAvailable:
                    return .iCloudUnavailable
                default: break
                }
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .unknown
    }
}

/// What the picker answered for ONE item.
///
/// A value rather than an optional or a thrown error, because the composer needs the CATEGORY of a
/// failure and an optional carries none — and because it makes the picker seam something a test can
/// drive one category at a time, which is the only way the four tile states are ever exercised.
nonisolated public enum ComposePickerAnswer: Sendable {
    case file(PickedMedia)
    case failed(ComposeLoadFailure)
}

/// One thing about to be posted: its identity, its file, how the read went, and what its own
/// metadata said about when it was captured.
///
/// The identity is minted when the item is PICKED and outlives everything that happens to it — the
/// file arriving, a failure, a retry, a capture read landing late. That is what makes both fences
/// possible: a slow answer is matched against the item it was issued for, and one for an item
/// nobody is holding any more is dropped instead of resurrecting it.
nonisolated public struct ComposeAttachment: Identifiable, Equatable, CaptureCarrying, Sendable {
    /// How the file itself is doing.
    public enum Load: Sendable, Equatable {
        /// The picker is exporting it — which, for an original that lives in iCloud, IS the
        /// download. The picker gives no progress for that, so this covers both.
        case loading
        case ready
        case failed(ComposeLoadFailure)
    }

    public let id: UUID
    /// The copy, once there is one. Nil while loading and after a failure — a failed item is a
    /// placeholder tile, never a silently dropped one.
    public var media: PickedMedia?
    public var load: Load
    /// What the file said about when it was taken. `pending` until the read comes back.
    public var capture: CaptureDecision
    /// What to call it in a sentence. The picker's own filename when there is one, and something
    /// honest before then.
    public var label: String
    /// Where this item comes in PICK order, across everything attached.
    ///
    /// One number for the library and the camera together, because they are one list to the person
    /// holding the phone: a photograph taken before two were picked comes first, and the undated
    /// items — which sort in pick order — would otherwise be grouped by where they came from.
    public var sequence: Int
    /// The zone this item's civil capture time is resolved in, snapshotted when it was picked. See
    /// `CaptureCarrying.captureZone`.
    public var captureZone: TimeZone?
    /// Set when this file was added to an EXISTING memo and the upload did not go through. It is
    /// separate from `load`, which is about the picker: this one is about the server.
    public var uploadFailed: ComposeLoadFailure?

    public init(
        id: UUID = UUID(),
        media: PickedMedia? = nil,
        load: Load = .loading,
        capture: CaptureDecision = .pending,
        label: String = "A file",
        sequence: Int = 0,
        captureZone: TimeZone? = nil,
        uploadFailed: ComposeLoadFailure? = nil
    ) {
        self.id = id
        self.media = media
        self.load = load
        self.capture = capture
        self.label = label
        self.sequence = sequence
        self.captureZone = captureZone
        self.uploadFailed = uploadFailed
    }

    public var isFailed: Bool {
        if case .failed = load { return true }
        return uploadFailed != nil
    }

    public var isLoading: Bool { load == .loading }

    /// Whether this item still owes the composer an answer of any kind.
    public var isUnresolved: Bool { isLoading || isFailed || capture.isPending }

    /// The failure to show on the tile — the picker's, or the upload's.
    public var failure: ComposeLoadFailure? {
        if case .failed(let category) = load { return category }
        return uploadFailed
    }
}

/// One picture the memo already has.
///
/// A struct rather than the bare `MemoAttachment` it wraps: what a later release adds here — a
/// mark that this one is to be removed, the capture instant the server will start sending — is
/// then a field rather than a new type through every call site.
nonisolated struct ComposeExisting: Identifiable, Equatable, Sendable {
    let attachment: MemoAttachment

    var id: String { attachment.uid }
}

/// One thing in the compose row: a picture the memo already has, or a file about to be posted.
///
/// The two never became one shape because they are not one thing. A picked item is a copy on
/// disk this sheet is holding; an existing one is a file on the server with no local copy at all,
/// and the only honest way to draw it is the remote path the rest of the app draws pictures with.
nonisolated enum ComposeRowItem: Identifiable, Equatable, Sendable {
    case existing(ComposeExisting)
    case picked(ComposeAttachment)

    /// Prefixed, because a uid and a picked item's UUID are drawn from different namespaces and
    /// `ForEach` is entitled to assume that two items with one id are one item.
    var id: String {
        switch self {
        case .existing(let existing): "existing-\(existing.id)"
        case .picked(let attachment): "picked-\(attachment.id)"
        }
    }
}

/// What the compose row shows, in order.
///
/// A function rather than a concatenation at the call site: the day old and new pictures share
/// one order — when the existing ones carry a capture instant of their own — there is one place
/// that changes, and it is a place a test can hold today.
nonisolated enum ComposeRow {
    /// Existing pictures first, in the order the server holds them; then what has been picked, in
    /// the order it will be sent (`ComposeImports.ordered`).
    static func items(existing: [ComposeExisting], picked: [ComposeAttachment]) -> [ComposeRowItem]
    {
        existing.map(ComposeRowItem.existing) + picked.map(ComposeRowItem.picked)
    }
}

/// The two decisions the date control makes, as functions rather than as lines inside a view.
///
/// They are the whole of what "Auto" means, and both of them are one-liners that would otherwise
/// live where nothing can ask them a question: whether this sheet has an Auto side at all, and what
/// date the memo ends up carrying.
nonisolated public enum ComposeDate {
    /// The Auto side of the control, or nil where there is none.
    ///
    /// An EDIT has none in 1.4. The memo already has a date, and the files already on it carry no
    /// capture instant this client has ever read — so an Auto offered there would be computed from
    /// whatever was added TODAY and would silently re-date the memo by it. Edit Auto is its own
    /// ticket.
    public static func auto(isEdit: Bool, from attached: AutoMemoDateResult) -> AutoMemoDateResult?
    {
        isEdit ? nil : attached
    }

    /// The date this memo will carry: the one that was chosen, or — on Auto — the earliest capture
    /// instant among what is attached. Nil is "whenever this is", which the outbox stamps with the
    /// moment of writing (`ComposeSubmission.capturedAt(now:)`).
    ///
    /// A chosen date always wins. That is what MANUAL is: once somebody has picked a date, nothing
    /// they attach afterwards may move it, and one tap on Auto in the picker puts it back to nil
    /// and hands the answer to the photographs again.
    public static func resolved(chosen: Date?, auto: AutoMemoDateResult?) -> Date? {
        chosen ?? auto?.instant
    }
}

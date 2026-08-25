import Foundation

/// What one live media event makes of a loaded timeline.
///
/// Pure, and separated from the store for the reason every ported rule in this package is: the
/// decision is asserted directly instead of being inferred from a screen. It is the same transform
/// the SPA applies to its query cache (`frontend/src/composables/useMediaEvents.ts`,
/// `applyMediaEvent`), under the same name, because the two clients must not disagree about what an
/// event means.
///
/// The event carries no URLs, and does not need to: every derived-tier URL is minted from the
/// attachment uid alone (memos-ng `app/services/asset_urls.py:49-56`), so the ones already in hand
/// are the ones a finished attachment is served from. Flipping the status is therefore the whole
/// change — `AttachmentThumbnail.LoadTrigger` keys its fetch on readiness for exactly that reason.
public func applyMediaEvent(_ event: MediaEvent, to memos: [Memo]) -> [Memo] {
    memos.map { memo in
        guard memo.attachments.contains(where: { $0.uid == event.uid }) else { return memo }
        var updated = memo
        updated.attachments = memo.attachments.map { attachment in
            attachment.uid == event.uid ? patched(attachment, with: event) : attachment
        }
        return updated
    }
}

/// One attachment, brought up to what the event says — or left exactly as it was.
///
/// An IN-FLIGHT event never applies to an attachment that is already ready or failed. The stream is
/// a POLL (memos-ng `app/routers/assets.py:727-765`), so a `processing` snapshot taken before a job
/// finished can be delivered after the terminal event; applying it would put a finished photo back
/// under the waiting treatment that nothing will ever take off again, because the job it describes
/// is over and will report nothing further. A terminal event still applies to terminal state — a
/// retried `failed` attachment may legitimately reach `ready`.
///
/// The dimensions move as a PAIR or not at all: one of them beside the other's stale value
/// describes an aspect ratio neither source has, and that ratio is exactly what a tile is laid out
/// from. `MediaEvent.dimensions` is that pair, which is why it is a pair there too.
private func patched(_ attachment: MemoAttachment, with event: MediaEvent) -> MemoAttachment {
    guard attachment.readiness == .waiting || event.status.isTerminal else { return attachment }
    var next = attachment
    next.status = AttachmentStatus(event.status)
    if let dimensions = event.dimensions {
        next.width = dimensions.width
        next.height = dimensions.height
    }
    if let blurhash = event.blurhash { next.blurhash = blurhash }
    return next
}

extension AttachmentStatus {
    /// The live channel's status as the model's own.
    ///
    /// Two enums with the same five cases, mapped by an exhaustive switch rather than through
    /// `rawValue`: a case added on one side then has to be answered for here, which is what a
    /// `rawValue` bridge would silently turn into a `nil`.
    init(_ live: MediaAttachmentStatus) {
        switch live {
        case .uploading: self = .uploading
        case .pending: self = .pending
        case .processing: self = .processing
        case .ready: self = .ready
        case .failed: self = .failed
        }
    }
}

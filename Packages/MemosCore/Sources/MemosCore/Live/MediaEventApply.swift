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
/// address exactly the bytes a finished attachment is served from. Flipping the status is
/// therefore the whole change — `AttachmentThumbnail.LoadTrigger` keys its fetch on readiness for
/// exactly that reason.
///
/// What the URL in hand does NOT carry over is its SIGNATURE, which is minted with the memo and
/// expires. Deciding whether an event may be applied in place at all is therefore a separate
/// question, and it is `mediaEventOutcome`'s — this stays the pure transform both answers use.
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

/// What one live event should DO to the loaded timeline, once the signatures on the URLs already
/// in hand are taken into account.
///
/// Three answers rather than two, because in-place reuse is not always available. The derived-tier
/// URLs on a loaded memo were signed when that memo was READ (`signed_tier_urls`, minted with an
/// `exp` in a one-hour bucket plus a two-hour TTL), so an attachment that sits pending for longer
/// than that and only then goes ready would have its tile flipped onto a URL whose signature has
/// already lapsed: a 403 where a picture should be, until something else refreshes the memo. The
/// server is not wrong to send the event and the transform is not wrong to apply it — what is
/// missing is a URL, and the only place a fresh one comes from is a read.
public enum MediaEventOutcome: Sendable, Equatable {
    /// Nothing a reader could see moves. The common case during a transcode: a percentage climbing
    /// on an attachment this app shows no percentage for.
    case unchanged
    /// The list as the event leaves it, applied where it sits.
    case applied([Memo])
    /// The event stands, but the URLs to serve it from do not: re-read this memo instead.
    case refresh(uid: String)
}

/// Which of the three an event is, at a given moment.
///
/// `now` is a parameter, not a `Date()` taken inside: the whole rule is about a boundary in time,
/// and a rule about time that reads its own clock can only be asserted by waiting for one.
///
/// Only a `ready` event can be past the horizon in a way that matters. A `failed` one paints a
/// glyph and fetches nothing, and the in-flight stages fetch nothing either — the tile keeps its
/// waiting treatment and asks for no URL at all.
public func mediaEventOutcome(
    _ event: MediaEvent,
    for memos: [Memo],
    at now: Date,
    horizon: TimeInterval = SignedMediaURL.horizon
) -> MediaEventOutcome {
    let next = applyMediaEvent(event, to: memos)
    // Also the answer for an attachment nobody has loaded: the transform leaves such a list
    // untouched, and there is no memo to re-read either.
    guard next != memos else { return .unchanged }
    guard event.status == .ready else { return .applied(next) }
    guard
        let memo = memos.first(where: { memo in
            memo.attachments.contains { $0.uid == event.uid }
        }),
        let attachment = memo.attachments.first(where: { $0.uid == event.uid }),
        attachment.isPastURLHorizon(at: now, horizon: horizon)
    else { return .applied(next) }
    return .refresh(uid: memo.uid)
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

import Foundation
import MemosCore
import MemosOutbox

/// The decisions the trip-pass screens make, as values a test can read.
enum TripPassPresentation {
    /// Whether a screen offers a visibility choice.
    ///
    /// While a pass stands, who sees what this phone sends is the trip owner's decision, not this
    /// phone's, so no screen offers one. No guest store (a preview, a test host) is no pass.
    static func showsVisibility(_ guest: GuestSessionStore.State?) -> Bool {
        guard let guest else { return true }
        return !guest.isActive
    }

    /// The entry's words: where a pass stands it opens that pass, otherwise it offers to join one.
    static func entryTitle(for guest: GuestSessionStore.State?) -> String {
        guest?.isActive == true ? "Trip pass" : "Join a trip with a pass"
    }

    static let endedNotice = "This trip pass has ended. Scan a new one to send more."

    /// The line the join screen shows under its controls, or nil when there is nothing to say.
    static func notice(for state: GuestSessionStore.State) -> String? {
        switch state {
        case .refused(let refusal): refusal.message
        case .ended: endedNotice
        case .none, .redeeming, .active: nil
        }
    }

    /// A pasted pass link as a URL. People copy the link out of a chat with or without its scheme,
    /// so a bare `trip.example/p/…` is read as https; whether it IS a pass link is the guest
    /// store's question (`GuestDoor`), asked after this.
    static func passLink(fromPasted text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let spelled = trimmed.contains("://") ? trimmed : "https://" + trimmed
        return URL(string: spelled)
    }

    /// One receipt as a line: how many files, and whether the door has them or the trip's owner
    /// is still looking at them (`held` is the owner's moderation, and the guest sees that it is).
    static func receiptSummary(_ receipt: GuestWire.Receipt) -> String {
        let files = receipt.fileCount == 1 ? "1 file" : "\(receipt.fileCount) files"
        if receipt.status == "held" { return "\(files) · waiting for the trip's owner" }
        return "\(files) · received"
    }
}

import Foundation
import MemosCore

/// What the device-token row says, decided in pure functions the row only reads.
///
/// The arithmetic is here rather than in the view for the reason every other decision on the
/// Settings screen is: the row can show one answer at a time, and the interesting part is the
/// boundaries between them — 59 seconds and 61 seconds must not read the same, and a token with
/// twenty hours left must not read as expiring in zero days.
enum DeviceTokenPresentation {
    static let heading = "This device"

    /// What the row says when there is no row: the read failed, which is not the same as this
    /// device having no token.
    static let unread = "This device's access could not be read."

    static let renameTitle = "Rename"
    static let renewTitle = "Renew"
    static let saveTitle = "Save"
    static let cancelTitle = "Cancel"
    static let nameFieldTitle = "Device name"

    // Spoken labels, which say what the short titles above leave to the surrounding text. A
    // screen reader reaches a button with nothing around it, and "Rename" alone in a Settings
    // screen names nothing.
    static let renameLabel = "Rename this device"
    static let renewLabel = "Renew this device's access"
    static let saveLabel = "Save this device's name"
    static let cancelLabel = "Stop renaming this device"

    /// How long ago, in the largest unit that still says something true.
    ///
    /// A phone whose clock is ahead of the server's would otherwise be told its token was used
    /// "-3 minutes ago"; nothing is gained by naming the skew, so the nearest true thing is said.
    static func elapsed(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 60 else { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return count(minutes, "minute") + " ago" }
        let hours = minutes / 60
        if hours < 24 { return count(hours, "hour") + " ago" }
        return count(hours / 24, "day") + " ago"
    }

    /// Days are as far as this goes deliberately. Months would have to be invented out of a
    /// divisor, and a token last used four hundred days ago is better described by the number.
    static func lastUsedLine(_ lastUsed: Date?, now: Date) -> String {
        guard let lastUsed else { return "Not used yet" }
        return "Last used " + elapsed(lastUsed, now: now)
    }

    /// `nil` means a token that never expires, which is a fact rather than a missing value — the
    /// unbounded kind, which is also the kind that cannot be renewed.
    static func expiryLine(_ expiresAt: Date?, now: Date) -> String {
        guard let expiresAt else { return "Never expires" }
        let seconds = expiresAt.timeIntervalSince(now)
        guard seconds > 0 else { return "Expired" }
        let days = Int(seconds / 86_400)
        guard days > 0 else { return "Expires today" }
        return "Expires in " + count(days, "day")
    }

    private static func count(_ value: Int, _ unit: String) -> String {
        "\(value) \(unit)\(value == 1 ? "" : "s")"
    }
}

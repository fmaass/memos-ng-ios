import Foundation

/// The name a trip guest joins under: what the door stores on the device and credits every picture
/// it sends to.
///
/// The door refuses an empty name and anything over 64 characters (`display_name`, 1 to 64), and
/// it counts the way Python's `len` does — in Unicode code points — so the cap here counts
/// scalars too, and never cuts through a character: an emoji or an accented letter is kept whole
/// or left out whole.
public enum GuestName {
    /// The door's limit, in code points.
    public static let limit = 64
    /// What the door itself falls back to; sent when nothing was typed, now or before.
    public static let lastResort = "Guest"

    /// The name to send: what the person typed, else the name they typed last time, else
    /// `lastResort`. Each is trimmed and capped first, and a blank one counts as absent, so the
    /// answer is never empty.
    ///
    /// The device's own name is deliberately not a candidate: without Apple's
    /// user-assigned-device-name entitlement `UIDevice.name` answers only the model ("iPhone").
    public static func resolve(typed: String?, remembered: String?) -> String {
        cleaned(typed) ?? cleaned(remembered) ?? lastResort
    }

    /// What the Join field starts with: the name typed last time, else nothing, so the field shows
    /// its placeholder rather than a name the person never chose.
    public static func fieldStart(remembered: String?) -> String {
        cleaned(remembered) ?? ""
    }

    /// Trimmed and capped; `nil` when nothing is left.
    public static func cleaned(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // Trimmed on both sides of the cap: a cut can land just after a space.
        let trimmed = capped(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The longest run of whole characters from the start that fits the door's limit.
    public static func capped(_ raw: String) -> String {
        var kept = 0
        var result = ""
        for character in raw {
            let scalars = character.unicodeScalars.count
            guard kept + scalars <= limit else { break }
            kept += scalars
            result.append(character)
        }
        return result
    }
}

/// The joined guest's name field and its one Save in flight.
///
/// The field is LOCKED while a Save is on the wire: nothing typed can land after the name was sent,
/// so the door's answer never overwrites newer typing, and a second Save cannot be issued to join
/// the first under a name the field no longer shows.
public struct GuestNameDraft: Equatable, Sendable {
    public private(set) var text: String
    /// The name a Save sent, while its answer is outstanding.
    public private(set) var pending: String?

    public init(stored: String?) {
        text = stored ?? ""
    }

    public var isEditable: Bool { pending == nil }

    /// Typing, capped to the door's limit as the Join field is. Ignored while a Save is pending.
    public mutating func edit(_ typed: String) {
        guard pending == nil else { return }
        text = GuestName.capped(typed)
    }

    /// The door's stored name changed elsewhere (a redeem, a leave). Ignored while a Save is
    /// pending, whose answer decides the field.
    public mutating func storedChanged(_ stored: String?) {
        guard pending == nil else { return }
        text = stored ?? ""
    }

    /// Whether Save has anything to send against the name the door holds.
    public func canSave(stored: String?) -> Bool {
        pending == nil && GuestName.cleaned(text) != stored
    }

    /// Claims the Save: the text to send, or `nil` when one is already pending or nothing changed.
    public mutating func beginSave(stored: String?) -> String? {
        guard canSave(stored: stored) else { return nil }
        pending = text
        return text
    }

    /// The Save's answer: the stored name replaces the field only if the field still holds what was
    /// sent. Returns the sentence to show, if any.
    public mutating func finish(_ outcome: GuestSessionStore.RenameOutcome) -> String? {
        let sent = pending
        pending = nil
        switch outcome {
        case .renamed(let stored):
            if text == sent { text = stored }
            return nil
        case .refused(let refusal):
            return refusal.message
        case .superseded:
            return nil
        }
    }
}

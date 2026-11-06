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
    /// What the door itself falls back to; reached only when even the device name is blank.
    public static let lastResort = "Guest"

    /// The name to send: what the person typed, else the name they typed last time, else the
    /// device's own name. Each is trimmed and capped first, and a blank one counts as absent, so
    /// the answer is never empty.
    public static func resolve(typed: String?, remembered: String?, deviceName: String) -> String {
        cleaned(typed) ?? cleaned(remembered) ?? cleaned(deviceName) ?? lastResort
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

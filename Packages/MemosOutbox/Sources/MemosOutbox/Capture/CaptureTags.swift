import Foundation

/// The five date tags, as text, turned into readings.
///
/// Kept apart from the frameworks that fetch them so the rules can be held to the artefact's own
/// string vectors — a parser tested only through ImageIO is a parser tested on whatever that
/// machine's files happen to contain.
public enum CaptureTags {
    /// The 1904 epoch QuickTime counts its movie-header seconds from.
    static let quickTimeEpoch = Date(timeIntervalSince1970: -2_082_844_800)
    /// The floor the movie header is trusted from. Below it the value is an unset header rather
    /// than a date — the 1904 zero and the many files that were written with one. It is deliberately
    /// NOT applied to EXIF: a photograph genuinely taken in 1974 keeps its date.
    static let headerFloor = Date(timeIntervalSince1970: 631_152_000)  // 1990-01-01T00:00:00Z

    /// An image's reading from the two tags it is allowed to look at.
    ///
    /// With an offset the pair is an exact instant; without one — or with one that does not parse —
    /// what is left is a civil time the client resolves, which is the honest reading rather than a
    /// guess dressed as an instant.
    public static func imageReading(dateTimeOriginal: String?, offset: String?) -> CaptureReading {
        guard let text = dateTimeOriginal, let civil = exifCivil(text) else { return .empty }
        if let offset, let seconds = offsetSeconds(offset) {
            let instant = civil.pseudoUTC.addingTimeInterval(-TimeInterval(seconds))
            return CaptureReading(
                instant: AutoMemoDate.flooredToSecond(instant), civil: nil, source: .exif)
        }
        return CaptureReading(instant: nil, civil: civil.text, source: .exif)
    }

    /// `YYYY:MM:DD HH:MM:SS`, EXIF's own spelling — the colons in the date become hyphens and the
    /// space becomes a T, which is the shape the artefact writes a civil time in.
    ///
    /// The all-zero date that half the world's cameras write into an empty field is not a date, and
    /// it is refused here rather than downstream: `0000:00:00` reaches a calendar as a real year
    /// zero and comes back as an instant nobody's photograph was taken at.
    static func exifCivil(_ text: String) -> CivilTime? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 19 else { return nil }
        var characters = Array(trimmed)
        guard characters[4] == ":", characters[7] == ":", characters[10] == " " else { return nil }
        characters[4] = "-"
        characters[7] = "-"
        characters[10] = "T"
        guard let civil = CivilTime(String(characters)),
            civil.year > 0, civil.month > 0, civil.day > 0
        else { return nil }
        return civil
    }

    /// `±HH:MM` or `±HHMM`, EXIF's two spellings of an offset. Anything else is not an offset.
    static func offsetSeconds(_ text: String) -> Int? {
        var body = text.trimmingCharacters(in: .whitespaces)
        guard let sign = body.first.map({ $0 == "-" ? -1 : ($0 == "+" ? 1 : 0) }), sign != 0 else {
            return nil
        }
        body.removeFirst()
        if body.count == 5, body[body.index(body.startIndex, offsetBy: 2)] == ":" {
            body.remove(at: body.index(body.startIndex, offsetBy: 2))
        }
        guard body.count == 4, body.allSatisfy(\.isNumber), body.allSatisfy(\.isASCII),
            let hours = Int(body.prefix(2)), let minutes = Int(body.suffix(2)),
            hours <= 23, minutes <= 59
        else { return nil }
        return sign * (hours * 3600 + minutes * 60)
    }

    /// `com.apple.quicktime.creationdate`: ISO 8601 with an offset, sometimes with a fraction on
    /// the seconds, which is floored away.
    public static func quickTimeCreationDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 20 else { return nil }
        // `+0200` and `+02:00` are both written into this tag, and only one of them is RFC 3339;
        // the colon goes in here so the parser below never has to be asked which spelling it takes.
        var normalised = trimmed
        if let last = normalised.last, last != "Z", normalised.count >= 5 {
            let offset = normalised.suffix(5)
            if let sign = offset.first, sign == "+" || sign == "-",
                offset.dropFirst().allSatisfy(\.isNumber)
            {
                normalised.insert(":", at: normalised.index(normalised.endIndex, offsetBy: -2))
            }
        }
        let formatter = ISO8601DateFormatter()
        for options in [
            ISO8601DateFormatter.Options([.withInternetDateTime]),
            ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]),
        ] {
            formatter.formatOptions = options
            if let date = formatter.date(from: normalised) {
                return AutoMemoDate.flooredToSecond(date)
            }
        }
        return nil
    }

    /// The movie header's creation time, in the seconds since 1904 the header itself counts in.
    ///
    /// Rejected when it is zero, before 1990, or in the future by more than a day: those are the
    /// values an unset header takes, and a memo dated 1904 because a camera did not fill a field in
    /// is worse than a memo with no date at all.
    public static func videoHeaderInstant(quickTimeSeconds: Double, now: Date = Date()) -> Date? {
        guard quickTimeSeconds != 0 else { return nil }
        let instant = AutoMemoDate.flooredToSecond(
            quickTimeEpoch.addingTimeInterval(quickTimeSeconds))
        return acceptedHeaderInstant(instant, now: now)
    }

    /// The same rule for a header time a framework has already turned into a date.
    public static func acceptedHeaderInstant(_ instant: Date, now: Date = Date()) -> Date? {
        let floored = AutoMemoDate.flooredToSecond(instant)
        guard floored >= headerFloor, floored <= now.addingTimeInterval(86_400) else { return nil }
        return floored
    }
}

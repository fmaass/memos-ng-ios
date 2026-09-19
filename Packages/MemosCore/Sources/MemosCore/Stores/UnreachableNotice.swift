import Foundation

/// Whether the "can't reach the server" notice belongs on screen right now.
///
/// It is a free function over three values rather than a flag the store keeps in step, because the
/// question has a clock in it and a flag cannot be tested against one. Everything that decides the
/// notice — which verification the session is in, how long it has been in it, and how long the app
/// waits before saying anything — arrives as an argument, so a test holds the clock and the store
/// holds no second opinion: the store's published flag is only ever this answer, taken at a moment
/// the store can name.
public enum UnreachableNotice {
    /// True only for a session that is unverified, has been stamped, and has been that way for at
    /// least `delay`.
    ///
    /// `.verifying` is deliberately not enough: a healthy launch passes through it, and a notice
    /// there would flash on every cold start. A missing stamp is not enough either — an unverified
    /// session nobody has timed is one this app has nothing to say about yet.
    public static func shows(
        _ verification: SessionVerification,
        unverifiedSince: Date?,
        now: Date,
        after delay: Duration
    ) -> Bool {
        guard case .unverified = verification, let since = unverifiedSince else { return false }
        return now.timeIntervalSince(since) >= delay.seconds
    }
}

extension Duration {
    /// The same span as a `TimeInterval`, so a duration can be compared with two dates.
    ///
    /// `Duration` is the app's unit for waiting and `Date` is its unit for when something happened;
    /// the notice's rule needs both in one comparison, and the conversion belongs in one place
    /// rather than at each site that has to reach for `components`.
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

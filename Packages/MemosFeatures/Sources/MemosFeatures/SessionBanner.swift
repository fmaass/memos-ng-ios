import MemosCore

/// Whether the app is saying anything about the credential it is running on, and what.
///
/// A pure function rather than a condition inside a view body, so what the banner shows in each of
/// the three verification states is a thing a test can read back rather than a thing somebody has
/// to run the app to see.
public enum SessionBanner {
    /// The line to show above the tabs, or nil for the two states that show nothing.
    ///
    /// `.verifying` shows nothing on purpose. It is the first check of a launch, a healthy one
    /// passes through it in the time one request takes, and a banner there would flash on every
    /// cold start of a session that is perfectly fine.
    public static func text(for verification: SessionVerification) -> String? {
        guard case .unverified(let reason) = verification else { return nil }
        return reason
    }
}

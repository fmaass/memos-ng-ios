import MemosCore

/// Whether the app is saying anything about the credential it is running on, and what.
///
/// A pure function rather than a condition inside a view body, so what the banner shows in each of
/// the three verification states is a thing a test can read back rather than a thing somebody has
/// to run the app to see.
/// Which single notice the app is showing above the tabs, and the sentence it carries.
///
/// The unreachable notice and the plain unconfirmed line are the same state seen at two distances:
/// the first is the second once it has lasted long enough to be worth a person's attention, and it
/// adds the retry. So they are cases of one value, and exactly one of them can be on screen.
public enum SessionNotice: Equatable, Sendable {
    /// The server has been out of reach long enough to say so, and the app offers a retry.
    case unreachable(String)
    /// The credential is unconfirmed and that is all the app has to say about it yet.
    case unverified(String)
    /// The server speaks an older API major than this build expects. Information only: no retry,
    /// because nothing the person can do from here changes the server's version.
    case olderServer(String)
}

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

    /// The ONE notice above the tabs, or nil when the app has nothing to say.
    ///
    /// One answer rather than two conditions a view body weighs for itself, because both notices
    /// are driven by the same verification state and a screen that asked them separately could
    /// end up stacking two cards saying the same thing.
    public static func notice(
        showingUnreachable: Bool,
        verification: SessionVerification,
        showingOlderServer: Bool = false
    ) -> SessionNotice? {
        // One sentence, one source: the session's own. The flag decides WHICH notice carries it —
        // and with it whether the person is offered a retry — never what it says, because a banner
        // with a sentence of its own would be saying something the session does not.
        if let text = text(for: verification) {
            return showingUnreachable ? .unreachable(text) : .unverified(text)
        }
        // Ranked below both: a server that cannot be reached, or a credential not yet confirmed, is
        // the more urgent thing to say, and the older-server line is still true once they clear.
        // It is the one card a CONFIRMED session can carry, because it is about the server's
        // contract rather than about the credential.
        return showingOlderServer ? .olderServer(olderServerText) : nil
    }

    /// The older-server line. Fixed, because the handshake knows only that the server is older —
    /// not by how much, nor what that will cost.
    public static let olderServerText = "This server is older than the app expects."
}

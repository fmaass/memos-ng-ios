import Foundation
import MemosAPI
import MemosOutbox

/// Whether the server has confirmed the credential this session is running on.
///
/// It is a field beside `SessionState` rather than a fifth case of it, because the app can be
/// signed in and unconfirmed at the same time: a stored credential opens the app before the
/// server answers, and every screen that reads `state.user` is entitled to the same answer it has
/// always had. A fifth case would change what `state.user` means under every one of them.
///
/// `.verifying` deliberately renders nothing. A healthy launch passes through it in the time one
/// request takes, and a banner there would flash on every cold start.
public enum SessionVerification: Sendable, Equatable {
    /// The server answered about this credential, and it is good.
    case verified
    /// A check is in flight and nothing is known yet. No banner.
    case verifying
    /// The check did not confirm the credential — the phone could not reach the server, or the
    /// server answered with something that is not a refusal. The session STANDS: only the server
    /// refusing the credential retires it. The string is the sentence the banner shows.
    case unverified(String)
}

/// The client a request goes out on, and which incarnation of the session that is — read as ONE
/// value.
///
/// Two reads would be two instants. A caller that took the client, suspended, and then asked what
/// generation the session was in could be handed a client belonging to the account BEFORE the
/// suspension and a number belonging to the one after it, and every fence downstream would then
/// agree that a stale request was current. So the pair travels together, taken once at the start
/// of an operation and carried through its retries rather than re-sampled.
public struct SessionHandle {
    public let client: any APIProtocol
    /// The session incarnation this client belongs to. Compared, never interpreted.
    public let generation: Int

    public init(client: any APIProtocol, generation: Int) {
        self.client = client
        self.generation = generation
    }
}

/// The authority to act as this device's signed-in account, as ONE immutable value.
///
/// Every field comes from the session's OWN in-memory state, read in one synchronous step: the
/// user it was established or confirmed with, and the credential its client is presenting. Nothing
/// here is read back out of the keychain or the account licence, and that is the whole of the
/// difference. An incarnation counter can prove that no account switch COMPLETED between two
/// reads; it cannot prove that a subject and a token belong together when the write that was
/// supposed to pair them threw — a sign-in as B whose credential would not store leaves B on
/// screen and A's token in the keychain, and two reads under one unchanged epoch would pair them.
/// Assembled from one source, that state cannot be expressed.
public struct CredentialGrant: Sendable, Equatable {
    /// Whose account this is — the user id the session was established or confirmed with.
    public let subject: String
    public let serverBaseURL: URL
    /// The token the session's client is presenting right now.
    public let token: String
    /// The authority epoch this was granted under (`SessionEpoch`).
    public let epoch: Int

    public init(subject: String, serverBaseURL: URL, token: String, epoch: Int) {
        self.subject = subject
        self.serverBaseURL = serverBaseURL
        self.token = token
        self.epoch = epoch
    }
}

/// The authority epoch, readable from OUTSIDE the main actor.
///
/// `SessionStore` is main-actor isolated and its counter is a property of it, which is the right
/// home for every reader that is already on the main actor. It is the wrong home for a writer that
/// commits from wherever its encoding finished — it would have to hop, and a hop is exactly the
/// gap in which the session it is committing for can end.
///
/// A locked box rather than an actor, and for the reason `PresentedCredential` is one: the answer
/// has to be available synchronously at the instant of the commit, and an actor would put a
/// suspension point between the question and the write it guards.
///
/// It moves whenever EITHER half of the authority changes — the identity this device is signed in
/// as, or the credential it presents. A renewal moves it too, which is what makes an unchanged
/// epoch proof that a grant taken earlier still names a token this device is holding. That is
/// wider than a session incarnation on purpose: it is asked by lanes that carry a token of their
/// own (the outbox), where a stale token is a request the server refuses.
public final class SessionEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    public init() {}

    /// The authority epoch now.
    public var current: Int { lock.withLock { value } }

    /// Whether work granted under `epoch` still speaks for this device's authority.
    public func isCurrent(_ epoch: Int) -> Bool { lock.withLock { epoch == value } }

    /// Moved by `SessionStore`, in the same synchronous step that withdraws or replaces authority.
    func bump() { lock.withLock { value += 1 } }
}

/// The session, as the four reporting stores see it.
///
/// A protocol rather than the store itself so a test can hold the sink still and read back what
/// was reported to it — and so the stores depend on the two things they use rather than on
/// everything a session can do.
@MainActor
public protocol SessionReporting: AnyObject {
    /// The client and the incarnation it belongs to, in one read.
    var activeHandle: SessionHandle? { get }

    /// The incarnation counter in a box a SENDER can read without hopping to the main actor.
    ///
    /// A store's own `sessionStillCurrent` is main-actor isolated, which is the right answer for
    /// everything the store applies. It is the wrong answer for a lane that sends from another
    /// executor — a chunked upload — where the check has to happen on the executor doing the
    /// sending, at the instant it sends (`SendAuthority`).
    nonisolated var sessionIncarnation: SessionEpoch { get }

    /// Whether a refusal still names the credential this device is holding.
    ///
    /// The read-only half of the refusal rule, for the two stores that only SAY something about a
    /// refusal and never end anything (`TagStore`, `HeatmapStore`). It is here rather than on
    /// `SessionStore` because those two hold a `SessionReporting`, and it is SYNCHRONOUS on a
    /// `@MainActor` protocol so a `@MainActor` store asks it with no hop and no await — an await
    /// between the question and the sentence is one more instant for the thing it exists to catch.
    func stillNamesCurrentCredential(_ refusal: CredentialRefusal) -> Bool

    /// A failure that never reached the server, judged against the incarnation that ISSUED the
    /// request rather than the one running now.
    ///
    /// It goes here instead of into a store's `lastError` because "can't reach the server" has
    /// exactly one surface in this app. Four stores reporting it would paint four error cards on
    /// an offline launch, under a banner that already says it once.
    func noteTransportFailure(
        _ failure: ServerReachability.Reason,
        issuedUnder generation: Int
    )

    /// A request that DID reach the server, reported by the incarnation that issued it.
    ///
    /// The sibling of the failure, and deliberately not its mirror image. A failure is evidence
    /// about the server and the session can act on it; a success is evidence about one request at
    /// one instant, and the only thing that confirms a session is a whoami that answered. So this
    /// asks for that check and decides nothing itself — which is also why every store may call it
    /// on every page it applies without any of them being able to confirm a session between them.
    func noteTransportSuccess(issuedUnder generation: Int)
}

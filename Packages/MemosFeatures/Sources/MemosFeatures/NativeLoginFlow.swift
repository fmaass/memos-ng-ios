import Foundation
import MemosCore

/// The native sign-in as a machine: every state it can be in, every thing that can happen to it,
/// and exactly one answer for each pair.
///
/// It exists because the sign-in's failures are invisible. A browser view that never came up, a
/// callback that arrived twice because both return lanes fired, a person who closed the view —
/// from the outside all three are "the button did nothing", and none of them can be driven from a
/// test through a live `SFSafariViewController`. Pulled out here, all of them are a few lines of
/// test.
///
/// Every event names the ATTEMPT it belongs to, and an event naming an attempt that is no longer
/// the live one is dropped. This is the same generation fence the rest of the app uses to stop a
/// dead operation from writing into a live one — `MediaSession.generation`,
/// `MediaEventEnvelope.generation`, `ComposeView.importGeneration`, `SessionStore`'s own
/// `sessionGeneration` — and it is here for the identical reason. A sign-in is a browser view, a
/// timer and a URL that arrives from outside the process, all three of which can outlive the
/// attempt that created them: without the fence, the browser view of a cancelled sign-in closing
/// cancels the one the person has just started, and a watchdog scheduled for one attempt fails
/// another.
///
/// The presenter around it owns the UIKit half and nothing else: it turns taps, browser callbacks
/// and delivered URLs into `Event`s, and does what the returned `Effect` says. It never decides.
struct NativeLoginFlow {
    /// One run at the sign-in. Identity only — it carries nothing, it just is not any other one.
    ///
    /// A monotonic generation rather than a UUID because that is the idiom already in this
    /// codebase for exactly this fence, and because "later than" is readable in a log line.
    struct Attempt: Equatable, Sendable, Hashable {
        let generation: Int
    }

    /// Where the attempt is. The live attempt is part of the state, not beside it, so there is no
    /// way to be presenting and not know which attempt is on screen.
    enum State: Equatable, Sendable {
        /// Nothing is open. The state before the first tap and after a finished attempt.
        case idle
        /// This attempt's browser view has been put on screen; its callback is being waited for.
        case presenting(Attempt)
        /// This attempt's callback was recognised and handed over; the code is being traded.
        case exchanging(Attempt)
        /// Signed in.
        case done
        /// Not signed in, and the screen has been told why.
        case failed

        /// The attempt that owns a browser view right now, if any. Nothing else may be dismissed
        /// and nothing else may be fenced against.
        var liveAttempt: Attempt? {
            switch self {
            case .presenting(let attempt): attempt
            case .idle, .exchanging, .done, .failed: nil
            }
        }
    }

    /// Everything that can happen to a sign-in. Everything except the tap names its attempt: the
    /// tap is the one event that cannot, because it is what MAKES an attempt.
    enum Event: Equatable, Sendable {
        /// Somebody tapped "Sign in".
        case presented
        /// A URL that IS this attempt's callback arrived, on the lane it arrived on. A URL that is
        /// not ours never becomes an event: an unrelated tap may not resolve a waiting sign-in.
        case callback(URL, NativeLoginReturn.Lane, Attempt)
        /// This attempt's browser view went away and no callback had arrived.
        case dismissed(Attempt)
        /// This attempt's browser view was never on screen at all — the presentation watchdog,
        /// which is the failure this rebuild exists for. NOT a limit on how long a person may take.
        case timedOut(Attempt)
        /// The exchange that followed this attempt's callback finished, one way or the other.
        case exchangeFinished(succeeded: Bool, Attempt)
    }

    /// What the presenter must do about it. Everything with a side effect is here, so the machine
    /// itself stays a pure function of state and event.
    enum Effect: Equatable, Sendable {
        /// Nothing at all — the event did not apply, or it named an attempt that is over.
        case nothing
        /// Open a browser view for this attempt, and fence its inbox entry and its watchdog to it.
        case present(Attempt)
        /// Take this attempt's browser view down and hand the URL to the session store.
        case deliver(URL, NativeLoginReturn.Lane, Attempt)
        /// Take this attempt's browser view down and fail it with this, which the screen shows.
        case abandon(NativeLoginError, Attempt)
        /// This attempt is over. Nothing is left to resume — bookkeeping and a log line.
        case settle(Attempt)

        /// Whether this effect requires the attempt's browser view to be off the screen when it
        /// has been carried out.
        ///
        /// It is a property of the EFFECT rather than a rule the presenter remembers, so "no
        /// attempt ever ends with its browser view still up" is a thing a test can walk every
        /// transition and check, instead of a thing the presenter is trusted about.
        var takesTheBrowserDown: Bool {
            switch self {
            case .nothing, .present: false
            case .deliver, .abandon, .settle: true
            }
        }

        /// The attempt this effect is about, if it is about one.
        var attempt: Attempt? {
            switch self {
            case .nothing: nil
            case .present(let attempt): attempt
            case .deliver(_, _, let attempt): attempt
            case .abandon(_, let attempt): attempt
            case .settle(let attempt): attempt
            }
        }
    }

    private(set) var state: State = .idle
    /// The last generation handed out. Only ever goes up, so an attempt id is never reused and a
    /// late signal can never be mistaken for a current one.
    private var lastGeneration = 0

    /// Explicit, so nothing can construct a flow that is already half way through a sign-in.
    init() {}

    /// What a browser view that never appeared is reported as. A sentence rather than a code
    /// because it is rendered verbatim under the button that seemed to do nothing.
    static let neverAppeared = "the sign-in view did not come up"

    mutating func receive(_ event: Event) -> Effect {
        switch (state, event) {
        // A tap while a sign-in is already on screen is IGNORED, and ignored HERE rather than by
        // a guard in the presenter. The browser view in front of the person is the affordance —
        // there is nothing a second tap could add, and the alternatives are both worse: a second
        // live attempt (two browser views, two continuations, one of which can never be resumed)
        // or an error notice painted over a sign-in that is working perfectly well.
        case (.presenting, .presented), (.exchanging, .presented):
            return .nothing

        case (.idle, .presented), (.done, .presented), (.failed, .presented):
            lastGeneration += 1
            let attempt = Attempt(generation: lastGeneration)
            state = .presenting(attempt)
            return .present(attempt)

        // Each of the four below is fenced the same way: the event must name the attempt that is
        // on screen. A signal from an attempt that has ended — its browser view closing as it is
        // torn down, its watchdog firing after it was cancelled, a URL its page emitted late —
        // reaches here after the person has already started another sign-in, and acting on it
        // would cancel or fail THAT one.
        case (.presenting(let live), .callback(let url, let lane, let attempt))
        where attempt == live:
            state = .exchanging(live)
            return .deliver(url, lane, live)

        case (.presenting(let live), .dismissed(let attempt)) where attempt == live:
            state = .failed
            return .abandon(.cancelled, live)

        case (.presenting(let live), .timedOut(let attempt)) where attempt == live:
            state = .failed
            return .abandon(.presentationFailed(Self.neverAppeared), live)

        case (.exchanging(let live), .exchangeFinished(let succeeded, let attempt))
        where attempt == live:
            state = succeeded ? .done : .failed
            return .settle(live)

        // Everything else is a late arrival or a stranger: the second lane's copy of a callback
        // already acted on, the dismissal the app itself performed, a watchdog that fired after
        // the answer came, or any of those belonging to an attempt that is over.
        default:
            return .nothing
        }
    }
}

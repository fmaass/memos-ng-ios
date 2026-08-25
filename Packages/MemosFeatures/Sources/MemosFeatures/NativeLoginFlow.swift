import Foundation
import MemosCore

/// The native sign-in as a machine: every state it can be in, every thing that can happen to it,
/// and exactly one answer for each pair.
///
/// It exists because the sign-in's failures are invisible. A browser view that never came up, a
/// callback that arrived twice because both return lanes fired, a person who swiped the view away
/// after signing in — from the outside all three are "the button did nothing", and none of them
/// can be driven from a test through a live `SFSafariViewController`. Pulled out here, all of them
/// are three lines of test.
///
/// The presenter around it owns the UIKit half and nothing else: it turns taps, delegate callbacks
/// and delivered URLs into `Event`s, and does what the returned `Effect` says. It never decides.
struct NativeLoginFlow {
    /// Where the attempt is.
    enum State: Equatable, Sendable {
        /// Nothing is open. The state before the first tap and after a finished attempt.
        case idle
        /// The browser view has been put on screen and the callback is being waited for.
        case presenting
        /// A callback was recognised and handed over; the handoff code is being traded.
        case exchanging
        /// Signed in.
        case done
        /// Not signed in, and the screen has been told why.
        case failed
    }

    /// Everything that can happen to a sign-in.
    enum Event: Equatable, Sendable {
        /// The browser view was presented — the tap, in other words.
        case presented
        /// A URL that IS this sign-in's callback arrived, on the lane it arrived on. A URL that is
        /// not ours never becomes an event: an unrelated tap may not resolve a waiting sign-in.
        case callback(URL, NativeLoginReturn.Lane)
        /// The browser view went away and no callback had arrived.
        case dismissed
        /// The browser view was never on screen at all — the presentation watchdog, which is the
        /// failure this whole rebuild exists for. NOT a limit on how long a person may take.
        case timedOut
        /// The exchange that follows a callback finished, one way or the other.
        case exchangeFinished(succeeded: Bool)
    }

    /// What the presenter must do about it. Everything with a side effect is here, so the machine
    /// itself stays a pure function of state and event.
    enum Effect: Equatable, Sendable {
        /// Nothing at all — the event did not apply in this state. A double callback, a dismissal
        /// the app itself asked for, an outcome reported twice.
        case nothing
        /// Take the browser view down and hand the URL to the session store.
        case deliver(URL, NativeLoginReturn.Lane)
        /// Take the browser view down and fail the attempt with this, which the sign-in screen
        /// shows. Never `nil`-messaged: silence is the bug.
        case abandon(NativeLoginError)
        /// The attempt is over. Nothing is left to resume — this is bookkeeping and a log line.
        case settle
    }

    private(set) var state: State = .idle

    /// Explicit, so nothing can construct a flow that is already half way through a sign-in.
    init() {}

    /// What a browser view that never appeared is reported as. A sentence rather than a code
    /// because it is rendered verbatim under the button that seemed to do nothing.
    static let neverAppeared = "the sign-in view did not come up"

    mutating func receive(_ event: Event) -> Effect {
        switch (state, event) {
        // From ANY state, including `exchanging`. The machine may never be the reason a tap does
        // nothing: an exchange whose outcome was never reported back would otherwise wedge the
        // sign-in permanently, which is the exact symptom being fixed. Two attempts cannot overlap
        // in practice because the presenter refuses to open a second browser view while it holds
        // one — the guard belongs there, next to the object whose lifetime it is about.
        case (_, .presented):
            state = .presenting
            return .nothing

        case (.presenting, .callback(let url, let lane)):
            state = .exchanging
            return .deliver(url, lane)

        case (.presenting, .dismissed):
            state = .failed
            return .abandon(.cancelled)

        case (.presenting, .timedOut):
            state = .failed
            return .abandon(.presentationFailed(Self.neverAppeared))

        case (.exchanging, .exchangeFinished(let succeeded)):
            state = succeeded ? .done : .failed
            return .settle

        // Everything else is a late arrival: the second lane's copy of a callback already acted
        // on, the dismissal the app itself performed, a watchdog that fired after the answer came.
        default:
            return .nothing
        }
    }
}

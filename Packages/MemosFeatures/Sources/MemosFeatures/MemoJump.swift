import Foundation
import MemosCore

/// A request to open a memo, made from a screen that cannot open one.
///
/// The Library tab can say WHICH memo a photograph belongs to and can do nothing at all with the
/// answer: `MemoDetailView` needs a `TimelineStore`, and the only one in the app belongs to the
/// Timeline tab. Rather than give the library a second store of its own — a second list of the
/// same memos, edited in one place and stale in the other — the request travels: the library asks,
/// the tab bar switches, and the Timeline pushes the memo onto its own stack.
///
/// It is also what the move IS. Photos' "Show in All Photos" takes you out of the album you were
/// looking at and into the library where the picture lives; this takes you out of the grid and
/// into the memo somebody wrote (MEMNG-191).
@MainActor
@Observable
final class MemoJump {
    /// The memo somebody asked for, until whoever can open it has. `nil` at rest.
    private(set) var pending: String?

    init() {}

    func request(_ uid: String) {
        pending = uid
    }

    /// Called by the consumer once the memo is on its way — and by a consumer that could not read
    /// it, because a request nobody can satisfy must not stay pending and re-fire.
    func clear() {
        pending = nil
    }
}

/// Where a jump request goes, decided outside the two view bodies that act on it.
enum MemoJumpRouting {
    /// Which tab the app shows. A pending request means the Timeline, whatever was on screen;
    /// nothing pending changes nothing, so switching tabs by hand is not undone a frame later.
    static func tab(showing current: MainTab, whenJumping uid: String?) -> MainTab {
        uid == nil ? current : .timeline
    }

    /// What the Timeline has to do before it can push a memo onto its stack.
    enum Resolution: Equatable, Sendable {
        /// The list already holds it, and its own copy is the one to show.
        case push
        /// It does not. The memo must be read from the server first.
        case fetchThenPush
    }

    /// Whether the memo is one this screen can already open.
    ///
    /// A memo reached from the library is USUALLY not loaded: the library is ordered by file and
    /// the timeline by memo, so a photograph a few screens into the grid can belong to a memo a
    /// hundred cursor pages down. That case is the normal one here, not the edge — which is why it
    /// gets a read of its own rather than a push onto an empty screen.
    static func resolution(uid: String, loaded: [String]) -> Resolution {
        loaded.contains(uid) ? .push : .fetchThenPush
    }
}

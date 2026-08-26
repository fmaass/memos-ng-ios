import MemosCore
import SwiftUI

/// Whether a section of the search sheet's empty state is still waiting for its first answer.
///
/// The sheet's two empty-state sections both draw from an empty store until the server replies,
/// and an empty store is indistinguishable from an empty ACCOUNT: no tags, no activity. Before
/// MEMNG-175 the sheet drew that indistinguishable state as the answer — the first open showed a
/// row with no chips over a heatmap saying "No memos in the last 12 weeks", and the second open,
/// arriving over a warm connection, showed the household's real one. So the phase is carried
/// explicitly, and a section that has not been answered yet says so.
enum SearchSectionPhase: Equatable {
    /// Nothing has come back yet. The section draws its own shape, greyed, at the size the real
    /// content takes — so what lands lands into the room already kept for it (MEMNG-176).
    case loading
    /// The server has answered, or has said it could not. Whatever is drawn now is the truth.
    case ready

    /// Which of the two a store is in, from the only two facts that separate them.
    ///
    /// A failed read counts as answered: the sheet does not draw a store's error, and a section
    /// that span for ever over a server that already said no would be a worse lie than an empty
    /// one. A CANCELLED read is neither — it records no error and sets no answer — and it is the
    /// case `SearchSectionLoad` exists to ask again for.
    static func phase(hasLoaded: Bool, failed: Bool) -> SearchSectionPhase {
        hasLoaded || failed ? .ready : .loading
    }

    /// Whether the section's contents are controls yet. A placeholder day would open the timeline
    /// at a date chosen by the absence of data, and a placeholder chip would search for a tag
    /// nobody has.
    var acceptsTaps: Bool { self == .ready }
}

/// One read per appearance of a section — and the reason it is not simply `.task`.
///
/// A bare `.task` runs ONCE for a view's identity and is cancelled the moment the view goes away.
/// A sheet's content is built, measured and attached while the sheet is presenting, and a first
/// presentation SwiftUI tears down and re-attaches keeps that identity: the read its `.task`
/// started is cancelled, `.task` does not run again, and nothing else ever asks. The sheet then
/// sits on its placeholders until it is closed and reopened, which is exactly the report
/// (MEMNG-175) — blank the first time, right the second.
///
/// Counting appearances turns the read into `.task(id:)`, which re-runs whenever its id moves. One
/// read per appearance, and a duplicate costs nothing: both stores fence their loads on a
/// monotonic attempt id, so the newest answer is the one that lands.
@MainActor
@Observable
final class SearchSectionLoad {
    /// How many times the section has been on screen. Zero is "not yet", and it is the one value
    /// that owes no read: `.task(id:)` also runs when the view is first built, and a read fired
    /// there would be the build-time read this type exists to stop depending on.
    private(set) var appearances = 0

    func appeared() { appearances += 1 }
}

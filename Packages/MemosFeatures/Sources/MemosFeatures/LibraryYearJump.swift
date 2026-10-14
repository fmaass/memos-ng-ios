import Foundation
import MemosCore

/// A request to show the Library at one year — Months, narrowed to that year's days, exactly what a
/// Years card in the Library does — made from the Collections root's Years row (MEMNG-720).
///
/// It travels the way `LibraryTagJump` does, and for the same reasons: the tab switch is the tab
/// bar's (`MainTabView`), and what the request changes beside the scope — the tag the grid is
/// narrowed to — belongs to the Library's own store, which may not exist until the Library is first
/// shown. So the root asks, the tab bar switches, and the Library applies it.
@MainActor
@Observable
final class LibraryYearJump {
    /// The year somebody asked for (a year bucket's key), until the Library has applied it. `nil`
    /// at rest.
    private(set) var pending: String?

    init() {}

    func request(_ year: String) {
        pending = year
    }

    /// Takes the request, once: the first caller gets the year and every later one nil, so a
    /// request is never applied twice.
    func take() -> String? {
        defer { pending = nil }
        return pending
    }
}

/// Where a year request goes, decided outside the views that act on it.
enum LibraryYearJumpRouting {
    /// Which tab the app shows: the Library while a year is pending, else whatever was on screen.
    static func tab(showing current: MainTab, whenOpening year: String?) -> MainTab {
        year == nil ? current : .library
    }

    /// Shows the pending year in `scope` — Months, narrowed to it, as a Years card's tap does —
    /// taking the request. The year row counts every tag, so a grid narrowed to a tag is widened
    /// back to every tag first: the year opens as the row counted it. Answers whether the grid has
    /// to be read again — true only when a tag was widened.
    static func apply(
        _ jump: LibraryYearJump, to library: MediaLibraryStore, scope: LibraryScopeChoice
    ) -> Bool {
        guard let year = jump.take() else { return false }
        let widened = library.tag != nil
        library.setTag(nil)
        scope.showMonths(of: year)
        return widened
    }
}

/// A request to show the Library at one month — Months, at that month's days, as the All view's
/// date pill does — made from the Collections root's Months row (MEMNG-783).
///
/// It travels exactly as `LibraryYearJump` does, for the same reasons: the root asks, the tab bar
/// switches, and the Library applies it to its own store and scope.
@MainActor
@Observable
final class LibraryMonthJump {
    /// The month somebody asked for (a month bucket's `YYYY-MM` key), until the Library has applied
    /// it. `nil` at rest.
    private(set) var pending: String?

    init() {}

    func request(_ month: String) {
        pending = month
    }

    /// Takes the request, once: the first caller gets the month and every later one nil, so a
    /// request is never applied twice.
    func take() -> String? {
        defer { pending = nil }
        return pending
    }
}

/// Where a month request goes, decided outside the views that act on it.
enum LibraryMonthJumpRouting {
    /// Which tab the app shows: the Library while a month is pending, else whatever was on screen.
    static func tab(showing current: MainTab, whenOpening month: String?) -> MainTab {
        month == nil ? current : .library
    }

    /// Shows the pending month in `scope` — Months, across every year, at that month — taking the
    /// request. The month row counts every tag, so a grid narrowed to a tag is widened back to
    /// every tag first: the month opens as the row counted it. Answers whether the grid has to be
    /// read again — true only when a tag was widened.
    static func apply(
        _ jump: LibraryMonthJump, to library: MediaLibraryStore, scope: LibraryScopeChoice
    ) -> Bool {
        guard let month = jump.take() else { return false }
        let widened = library.tag != nil
        library.setTag(nil)
        scope.showMonth(month)
        return widened
    }
}

/// The Collections root's three ways into the Library. The latest request wins: asking for one
/// withdraws whichever of the other two is still pending, so the Library never applies two, in
/// whichever order its changes arrive.
enum LibraryJumpRequests {
    static func openTag(
        _ tag: String, tags: LibraryTagJump?, years: LibraryYearJump?, months: LibraryMonthJump?
    ) {
        _ = years?.take()
        _ = months?.take()
        tags?.request(tag)
    }

    static func openYear(
        _ year: String, tags: LibraryTagJump?, years: LibraryYearJump?, months: LibraryMonthJump?
    ) {
        _ = tags?.take()
        _ = months?.take()
        years?.request(year)
    }

    static func openMonth(
        _ month: String, tags: LibraryTagJump?, years: LibraryYearJump?, months: LibraryMonthJump?
    ) {
        _ = tags?.take()
        _ = years?.take()
        months?.request(month)
    }
}

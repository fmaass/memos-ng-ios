import Foundation
import MemosCore

/// Where the viewer's pages come from — and, for one of the two, where the NEXT ones come from.
///
/// The viewer used to be handed a snapshot and nothing else, which is right for a memo (its media
/// is all there when it opens and never grows) and wrong for the library (60 rows of a list of
/// 1,314, and swiping to the end of them was where the swiping stopped). A source rather than a
/// list is what lets one viewer serve both: the memo's is a value, the library's is the store the
/// grid behind it is reading, so the two surfaces provably page through the same rows in the same
/// order (MEMNG-189).
enum MediaViewerSource {
    /// A memo's own media. What it shows when it opens is all there will ever be.
    case fixed([MediaPage])
    /// The media library, as the grid holds it: the rows loaded so far, and the way to ask the
    /// store behind them for the next page. The request goes through a closure rather than through
    /// the store because asking the server needs the session, and the session belongs to the screen
    /// that presented this viewer, not to the viewer.
    case library(any MediaLibraryPaging, more: @MainActor () async -> Void)
    /// A memo's media as whoever holds the memo holds it NOW, read on every evaluation: a memo
    /// read again for fresh signatures reaches a viewer already open over it. The pages the
    /// viewer was opened with stand in only while nobody holds the memo.
    case memo(resolve: @MainActor () -> Memo?, fallback: [MediaPage])

    /// The pages this source can show right now.
    ///
    /// For `.library` this reads the store's rows on every evaluation, which is what makes an
    /// appended page appear under a reader already swiping: read inside a SwiftUI body, the read
    /// is an observation.
    var pages: [MediaPage] {
        switch self {
        case .fixed(let pages): pages
        case .library(let pager, _):
            MediaViewerPresentation.pages(for: pager.items)
        case .memo(let resolve, let fallback):
            resolve().map { MediaViewerPresentation.pages(for: $0.attachments) } ?? fallback
        }
    }

    /// How close to the end of what is loaded a reader has to get before the next page is asked
    /// for: HALF A PAGE.
    ///
    /// Much further ahead than the grid's own dozen tiles, and deliberately. A grid shows a whole
    /// row at a time and a reader scrolls it in bursts; a viewer shows exactly one file and a swipe
    /// crosses it in a moment, so by the time the last loaded page is on screen the fetch has to
    /// have been running for a while already. Half a page is the distance at which a fast swiper
    /// never catches the end — and it is measured in the store's OWN page size, so a store built
    /// with a different one moves this with it rather than around it.
    /// The memo the pages hang on, when this source carries it: a memo's own viewer does, the
    /// library and the map do not, and their pages name the memo by uid instead.
    var carriedMemo: Memo? {
        guard case .memo(let resolve, _) = self else { return nil }
        return resolve()
    }

    /// Whether the memo this source carries holds the picture `uid` NOW — never, for a source that
    /// carries none. Now, because the pager keeps a page its source has dropped
    /// (`MediaViewerPager.extended`), and a picture taken off the memo is on no memo (MEMNG-930).
    func carries(_ uid: String) -> Bool {
        carriedMemo?.attachments.contains { $0.uid == uid } ?? false
    }

    static func lookahead(pageSize: Int) -> Int {
        max(1, pageSize / 2)
    }

    /// Whether the server still has rows this source has not read.
    var hasMore: Bool {
        switch self {
        case .fixed, .memo: false
        case .library(let pager, _): pager.hasMore
        }
    }

    /// Whether the reader standing on the page with this id should already have the next page on
    /// its way.
    ///
    /// The page is looked up by UID in the store's OWN rows, and that is the load-bearing detail.
    /// The viewer's pages are a PROJECTION of those rows — documents are dropped, because a PDF is
    /// a black rectangle nobody can leave — so page 40 of the viewer can be row 55 of the store. A
    /// projected offset handed to `shouldLoadMore`, which measures against `items.count`, reads as
    /// further from the end than the reader actually is, by exactly the number of documents behind
    /// them; on a library with many attachments that are not pictures the next page is asked for
    /// too late or never (MEMNG-189, review round 1).
    ///
    /// A fixed source never wants more — there is nothing to want. Everything else is the STORE's
    /// decision, unchanged and undivided: it knows whether the list has an end, whether a request
    /// is already out, and whether there is a cursor to send.
    func wantsMore(atPageWithID id: String) -> Bool {
        guard case .library(let pager, _) = self else { return false }
        guard let raw = pager.items.firstIndex(where: { $0.attachment.uid == id }) else {
            return false
        }
        return pager.shouldLoadMore(
            after: raw,
            lookahead: Self.lookahead(pageSize: pager.pageSize)
        )
    }

    /// How many pages that showed this viewer NOTHING will be read through in one ask.
    ///
    /// A bound rather than "until something appears", because the tail of a library can be any
    /// length of documents and a reader who swiped once must not set a request loop running that
    /// only the end of the list can stop. Eight pages is several hundred rows — far past any real
    /// run of PDFs — and if it is not enough the next swipe asks again.
    static let maximumBlankContinuations = 8

    /// Asks for the next page, and keeps asking while the pages that come back hold nothing this
    /// viewer can show.
    ///
    /// The continuation lives HERE rather than in the view, and that is the fix rather than a
    /// tidying. A page of documents grows the store's rows and leaves the viewer's projection the
    /// same length, so nothing the view observes changes — no `onChange` fires, and the view gets
    /// no second chance to ask. Worse, by then the raw list HAS grown, so the near-end guard is no
    /// longer true and a second ask would be refused anyway. The only place that knows a page
    /// arrived and yielded nothing is the code that awaited it (MEMNG-189, review round 2).
    ///
    /// The near-end guard is deliberately checked ONCE, on entry: after the first page it has
    /// already done its job, and re-testing it is what would end the run early.
    func loadMore(nearingPageWithID id: String) async {
        guard case .library(let pager, let more) = self, wantsMore(atPageWithID: id) else { return }
        for _ in 0..<Self.maximumBlankContinuations {
            let shown = pages.count
            await more()
            // Something to look at arrived, or the server says there is nothing left to ask for.
            if pages.count > shown || !pager.hasMore { return }
        }
    }
}

/// What the viewer shows after its source has changed underneath it.
///
/// A viewer over the library is open across events the grid behind it is free to have: a page
/// arriving, a pull to refresh, a tab or a direction being changed on the screen it was opened
/// from. Only the first of those is something the reader asked this viewer for, and this is the
/// rule that tells them apart — by what the new list IS, rather than by trying to hear about each
/// event.
enum MediaViewerPager {
    /// The pages to show, given the ones already being shown and the ones the source now holds.
    ///
    /// A source that still BEGINS with what is on screen is the same list, longer: adopt it, and
    /// the reader keeps their page (the pager tracks identity, and every id it was tracking is
    /// still there, at the same offset). Anything else is a DIFFERENT list — emptied by a filter
    /// change, reversed by a sort, replaced by a refresh — and the pages open in front of somebody
    /// are not something to pull out from under them. They are kept until the viewer is dismissed,
    /// which is also the only answer that cannot leave the pager holding an index into nothing.
    ///
    /// Kept as pages, not as URLs: a page the source still holds takes the source's copy of it,
    /// whose URLs are the ones the server signed last. Otherwise a memo re-read for fresh
    /// signatures while a sibling was deleted elsewhere would leave the reader's page on the URL
    /// that was refused, and the still keyed on that URL would never load again.
    static func extended(_ shown: [MediaPage], with source: [MediaPage]) -> [MediaPage] {
        if source.count >= shown.count, source.prefix(shown.count).map(\.id) == shown.map(\.id) {
            return source
        }
        let fresh = Dictionary(source.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return shown.map { fresh[$0.id] ?? $0 }
    }

    /// What the viewer shows once some of its pages have been DELETED.
    ///
    /// The composition rather than a second rule, and the composition is the whole point. A memo's
    /// source is `.fixed`: it is the value the cover was presented with, and it never shrinks. The
    /// viewer's page list is recomputed from it on every evaluation, so a page taken out of `shown`
    /// alone comes straight back the next time the body runs — `extended` sees a source that still
    /// begins with what is on screen, only longer, and adopts it. So the deleted ids are stripped
    /// from the SOURCE before `extended` ever compares the two.
    static func visible(
        shown: [MediaPage],
        source: [MediaPage],
        removed: Set<MediaPage.ID>
    ) -> [MediaPage] {
        guard !removed.isEmpty else { return extended(shown, with: source) }
        return extended(shown, with: source.filter { !removed.contains($0.id) })
    }

    /// The pages left after one is deleted, and which one the reader is standing on afterwards.
    ///
    /// The NEXT page, or the previous one when the deleted page was the last — the same answer
    /// Photos gives, and the only one that does not throw the reader back to the start. `nil` means
    /// there is nothing left to look at, and the viewer's answer to that is to close: an empty
    /// pager is a black screen with a close button on it.
    ///
    /// Deleting a page the reader is NOT on leaves them exactly where they are. It cannot happen
    /// from this viewer's own overlay, which only ever acts on the current page, but the rule is
    /// stated rather than assumed because the answer to "which page now" must not depend on which
    /// caller asked.
    static func removing(
        _ id: MediaPage.ID,
        from shown: [MediaPage],
        current: MediaPage.ID
    ) -> (pages: [MediaPage], current: MediaPage.ID?) {
        guard let index = shown.firstIndex(where: { $0.id == id }) else { return (shown, current) }
        var remaining = shown
        remaining.remove(at: index)
        guard !remaining.isEmpty else { return (remaining, nil) }
        guard current == id else { return (remaining, current) }
        // The page that has slid into the gap is the next one; past the end, it is the one before.
        return (remaining, remaining[min(index, remaining.count - 1)].id)
    }

    /// Whether a hold taken by a named page still stands: only while that page is one of the
    /// pages shown AND the page on screen.
    ///
    /// The page on screen, because the filmstrip turns the pager without a swipe (MEMNG-861): a
    /// picture magnified and then left by a tap or a scrub on the strip never reports a release
    /// — it is still zoomed, just not current — so a slot naming it would leave the page the
    /// strip went to unable to swipe or be dismissed. Gone back to, still magnified, it holds
    /// again.
    ///
    /// A page deleted from the viewer's own overlay never reports its release, because its view
    /// is gone by the time there would be anything to report — so a slot naming it would keep
    /// the pager or the interactive dismissal switched off for every page that follows. The id
    /// left behind among the holders (`MediaViewerHolds`) is harmless once the answer is asked
    /// here: ids are unique, and a deleted one is kept out of the rendered list by `removed`.
    static func stands(
        _ holder: MediaPage.ID?, among pages: [MediaPage], current: MediaPage.ID?
    ) -> Bool {
        guard let holder, holder == current else { return false }
        return pages.contains { $0.id == holder }
    }
}

/// Which pages hold the pager and the interactive dismissal: one set of page ids per surface, each
/// id put there and taken out only by its own page's report.
///
/// A set, not a single slot, because a magnified page stays magnified while it is not current
/// (MEMNG-861): zoom one picture, tap a neighbour on the filmstrip, zoom that one too, tap back.
/// A slot the second page overwrote would forget that the first still holds, and the first —
/// still zoomed, so never reporting anything — would come back to a pager that swipes and a
/// presentation that dismisses on a picture being examined.
///
/// The other half is the page's own report on creation (`MediaViewerPage` asks `onChange` with
/// `initial: true`): the lazy pager drops an off-screen page and builds it again, unzoomed, when
/// it is gone back to. That new page reports its release at once, which takes the id the old one
/// left behind out of the set; without it the page would come back holding.
struct MediaViewerHolds: Equatable {
    var pager: Set<MediaPage.ID> = []
    var dismissal: Set<MediaPage.ID> = []

    mutating func report(_ holds: MediaZoom.Holds, by page: MediaPage.ID) {
        if holds.pager { pager.insert(page) } else { pager.remove(page) }
        if holds.dismissal { dismissal.insert(page) } else { dismissal.remove(page) }
    }

    func holdsPager(among pages: [MediaPage], current: MediaPage.ID?) -> Bool {
        Self.stands(pager, among: pages, current: current)
    }

    func holdsDismissal(among pages: [MediaPage], current: MediaPage.ID?) -> Bool {
        Self.stands(dismissal, among: pages, current: current)
    }

    private static func stands(
        _ holders: Set<MediaPage.ID>, among pages: [MediaPage], current: MediaPage.ID?
    ) -> Bool {
        guard let current, holders.contains(current) else { return false }
        return MediaViewerPager.stands(current, among: pages, current: current)
    }
}

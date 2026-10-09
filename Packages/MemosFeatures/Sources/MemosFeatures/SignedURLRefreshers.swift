import MemosCore
import SwiftUI

/// The session a re-signing read is issued under, read at the moment it is issued.
///
/// Closures rather than the `SessionStore` itself, so a refresher can be driven by a test with a
/// handle of its own; the screens build it from their store.
struct IssuingSession {
    let handle: @MainActor () -> SessionHandle?
    let baseURL: @MainActor () -> URL?

    init(
        handle: @escaping @MainActor () -> SessionHandle?,
        baseURL: @escaping @MainActor () -> URL?
    ) {
        self.handle = handle
        self.baseURL = baseURL
    }

    init(_ session: SessionStore?) {
        self.init(handle: { session?.activeHandle }, baseURL: { session?.serverBaseURL })
    }
}

/// A memo the detail screen read for itself because its timeline does not hold it.
///
/// `fetchMemo` hands the memo back and leaves the list alone, so the copy it returns has nowhere
/// to live but here; the screen, and a viewer open over it, read it from here so a re-read with
/// fresh signatures reaches both.
@MainActor
@Observable
final class DetachedMemo {
    let uid: String
    private(set) var fetched: Memo?
    /// The read on the wire, and the session generation it was issued under.
    @ObservationIgnored private var reading: (generation: Int, claim: Int, task: Task<Void, Never>)?
    /// Bumped by every read that starts; only the latest one's answer is installed.
    @ObservationIgnored private var claims = 0

    init(uid: String) {
        self.uid = uid
    }

    /// Reads the memo again and keeps the answer.
    ///
    /// Two pictures of one memo lapse together, and each asks. An asker arriving while a read
    /// under the same session is out JOINS it — one read on the wire, claimed before anything is
    /// awaited — because `fetchMemo`, unlike `refreshMemo`, has no join of its own, and two
    /// overlapping reads could land in either order. A read under another session is a new claim,
    /// and an answer that is not the latest claim's is not installed.
    func reread(
        through timeline: TimelineStore,
        using handle: SessionHandle,
        baseURL: URL,
        current: @escaping @MainActor () -> SessionHandle?
    ) async {
        // Refused before it can join, claim or send: a read issued under a session that has
        // ended would take the claim from the running session's read, whose answer would then
        // not be installed, and its own would fail the session fence — leaving nothing to install.
        guard current()?.generation == handle.generation else { return }
        if let reading, reading.generation == handle.generation {
            await reading.task.value
            return
        }
        claims += 1
        let claim = claims
        let task = Task { [self] in
            let memo = await timeline.fetchMemo(uid: uid, using: handle, baseURL: baseURL)
            if reading?.claim == claim { reading = nil }
            guard let memo, claim == claims else { return }
            install(memo, issuedUnder: handle, current: current())
        }
        reading = (handle.generation, claim, task)
        await task.value
    }

    /// Taken only for this memo and only under the session that issued the read: an answer that
    /// outlived its session describes an account nobody is signed in as.
    @discardableResult
    func install(_ memo: Memo, issuedUnder handle: SessionHandle, current: SessionHandle?) -> Bool {
        guard memo.uid == uid, current?.generation == handle.generation else { return false }
        fetched = memo
        return true
    }
}

/// A memo's pictures, re-signed by reading the memo again: through the timeline when it holds the
/// memo, and into the detail screen's own copy when it does not.
@MainActor
final class MemoURLRefresher: SignedURLRefreshing {
    let timeline: TimelineStore
    let session: IssuingSession
    let detached: DetachedMemo?

    init(timeline: TimelineStore, session: IssuingSession, detached: DetachedMemo? = nil) {
        self.timeline = timeline
        self.session = session
        self.detached = detached
    }

    /// A detail screen's own copy when it has one, the timeline otherwise.
    var owner: AnyObject { detached ?? timeline }

    /// Everything the read is started from — the session, and which store holds the picture — is
    /// read inside the task, in the same turn that enters the store, and never carried into it
    /// from the ask: an ask that waited for its task across a sign-in would otherwise start a read
    /// under a session that has ended.
    func signatureExpired(uid: String) {
        Task { [self] in await start(uid) }
    }

    private func start(_ uid: String) async {
        guard let handle = session.handle(), let baseURL = session.baseURL() else { return }
        if let memo = timeline.memos.first(where: { $0.attachments.contains { $0.uid == uid } }) {
            _ = await timeline.refreshMemo(uid: memo.uid, using: handle, baseURL: baseURL)
            return
        }
        guard let detached else { return }
        await detached.reread(
            through: timeline,
            using: handle,
            baseURL: baseURL,
            current: session.handle
        )
    }
}

/// The library grid's and its viewer's pictures, re-signed by walking the pages the library holds.
///
/// Only the rows: a bucket's cover is the bucket store's, and is re-signed by `BucketURLRefresher`
/// on the subtree that draws the covers. A cover can be the same attachment as a row, so which
/// store answers is decided by who DREW the picture, never by which store happens to hold its uid.
@MainActor
final class LibraryURLRefresher: SignedURLRefreshing {
    let library: MediaLibraryStore
    let session: IssuingSession

    init(library: MediaLibraryStore, session: IssuingSession) {
        self.library = library
        self.session = session
    }

    var owner: AnyObject { library }

    /// The session is read in the turn that enters the store, for `MemoURLRefresher`'s reason.
    func signatureExpired(uid: String) {
        Task { [library, session] in
            guard let handle = session.handle(), let baseURL = session.baseURL() else { return }
            await library.reissue(uids: [uid], using: handle, baseURL: baseURL)
        }
    }
}

/// The Years and Months covers, re-signed by reading the buckets on screen again.
@MainActor
final class BucketURLRefresher: SignedURLRefreshing {
    let buckets: LibraryBucketStore
    let session: IssuingSession

    init(buckets: LibraryBucketStore, session: IssuingSession) {
        self.buckets = buckets
        self.session = session
    }

    var owner: AnyObject { buckets }

    /// The request the refused cover was drawn from is taken at the ask; the store refuses the
    /// read if that is no longer the list on screen or another read is already on its way.
    func signatureExpired(uid: String) {
        guard let drawnFrom = buckets.loadedRequest else { return }
        Task { [buckets, session] in
            guard let handle = session.handle(), let baseURL = session.baseURL() else { return }
            await buckets.rereadCovers(
                of: drawnFrom,
                holding: uid,
                using: handle,
                baseURL: baseURL
            )
        }
    }
}

extension MediaViewerSource {
    /// A memo's viewer, reading the memo as its owner holds it now.
    static func memo(
        uid: String,
        in timeline: TimelineStore?,
        detached: DetachedMemo? = nil,
        fallback: [MediaPage]
    ) -> MediaViewerSource {
        .memo(
            resolve: {
                timeline?.memos.first { $0.uid == uid } ?? detached?.fetched
            },
            fallback: fallback
        )
    }
}

/// A trip's pictures, re-signed by reading the trip again (MEMNG-714).
///
/// The membership is one drained list with no page to walk back to, so the way to fresh
/// signatures is the drain itself: it reads every page again and applies the whole list at once,
/// joining a drain of the same trip already on the wire. The trip is looked up when the ask
/// arrives, so a trip deleted meanwhile is not read.
@MainActor
final class TripURLRefresher: SignedURLRefreshing {
    let trips: TripMembershipStore
    let collections: CollectionStore
    let id: UUID
    let session: IssuingSession

    init(
        trips: TripMembershipStore, collections: CollectionStore, id: UUID, session: IssuingSession
    ) {
        self.trips = trips
        self.collections = collections
        self.id = id
        self.session = session
    }

    var owner: AnyObject { trips }

    /// The session is read in the turn that enters the store, for `MemoURLRefresher`'s reason.
    func signatureExpired(uid: String) {
        Task { [trips, collections, id, session] in
            guard let record = collections.records.first(where: { $0.id == id }),
                let handle = session.handle(), let baseURL = session.baseURL()
            else { return }
            await trips.drain(record, using: handle, baseURL: baseURL)
        }
    }
}

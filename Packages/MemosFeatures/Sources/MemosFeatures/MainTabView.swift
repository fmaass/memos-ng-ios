import MemosCore
import MemosOutbox
import SwiftUI

/// What the app shows while somebody is signed in.
///
/// A tab bar rather than a screen with a button to somewhere else: the library is a place people
/// go back to, and a destination reached by pushing off the timeline is one that loses its scroll
/// position every time. Each tab keeps its own navigation stack, which is what makes going back
/// and forth between them cost nothing.
struct MainTabView: View {
    @Environment(SessionStore.self) private var session
    @State private var selection: MainTab
    /// A memo asked for from a tab that cannot open one.
    ///
    /// It lives HERE because the move it describes is a move between tabs: the Library says which
    /// memo a photograph belongs to, the Timeline is the only tab that can show a memo, and the
    /// tab bar is the only thing that can put the app on the other one. Both ends read it out of
    /// the environment (MEMNG-191).
    @State private var jump = MemoJump()
    /// A tag asked for from the Collections root, which the Library narrows its grid to.
    @State private var tagJump = LibraryTagJump()
    /// A year asked for from the Collections root, which the Library shows in Months (MEMNG-720).
    @State private var yearJump = LibraryYearJump()
    /// A month asked for from the Collections root, which the Library shows in Months (MEMNG-783).
    @State private var monthJump = LibraryMonthJump()
    /// The session's collections and their memberships: one of each for as long as this view
    /// shows a session, built once its identity can be read, moved to a new identity beside the
    /// timeline (`TimelineView`), and read by every tab through the environment.
    @State private var trips: TripStore?
    @State private var members: TripMemberStore?
    /// Select mode's memo actions (MEMNG-788), built beside the trip stores it re-reads.
    @State private var actions: MemoActionStore?
    /// The session's favorites (MEMNG-867) and the picture-tag counts they mark stale: one of
    /// each, built beside the trip stores, read by the viewer's heart and by the Favorites card
    /// through the environment. Every store holding copies of pictures follows `favorites`.
    @State private var favorites: FavoriteStore?
    @State private var pictureTags: PictureTagStore?
    /// What Add to trip asks whether an edit of a picture's memo is still owed from this phone.
    @Environment(Outbox.self) private var outbox: Outbox?

    /// Opens on the Timeline (plan page 3929 decision 11), third of the four since Collections
    /// came in beside the Library (MEMNG-709). A test that is about another tab's screen under the
    /// real bar opens there instead.
    init(opening tab: MainTab = .timeline) {
        _selection = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Above the tabs rather than inside one, because it is true of the whole app: the
            // library is as stale as the timeline when the server cannot be reached. Persistent
            // and not dismissable — it is not a notification of an event, it is the state the
            // session is in, and it goes away when the session leaves that state.
            notice
            tabs
        }
        .task { makeTripStores() }
        // The ledger and the counts belong to the account that wrote them.
        .onSessionIdentityChange(session.snapshotIdentity) { _ in
            favorites?.sessionIdentityChanged()
            pictureTags?.sessionIdentityChanged()
        }
        // The trip list at once, not when the Collections root first appears: the composer's
        // offer of today's trip reads it (MEMNG-781).
        .readsTrips(trips, under: session.snapshotIdentity) { [session] in
            guard let handle = session.activeHandle, let baseURL = session.serverBaseURL
            else { return nil }
            return CollectionsAccess(handle: handle, baseURL: baseURL)
        }
    }

    /// Builds the trip and member stores, once, under the identity signed in now. Both report to
    /// the session and hand a refusal to its funnel (`SessionStore.handle`).
    private func makeTripStores() {
        guard trips == nil else { return }
        let store = TripStore(
            identity: session.snapshotIdentity,
            onUnauthorized: { [session] refusal in await session.handle(refusal) }
        )
        store.reports(to: session)
        let memberStore = TripMemberStore(
            trips: store,
            onUnauthorized: { [session] refusal in await session.handle(refusal) }
        )
        memberStore.reports(to: session)
        let actionStore = MemoActionStore(
            trips: store,
            onUnauthorized: { [session] refusal in await session.handle(refusal) },
            outboxCheck: MemoActionStore.outboxCheck(outbox)
        )
        actionStore.reports(to: session)
        trips = store
        members = memberStore
        actions = actionStore
        makeFavoriteStores(following: memberStore)
    }

    /// Builds the favorites and picture-tag stores, once. The member store built beside them
    /// follows the favorites here; the timeline and the library follow from their own screens,
    /// which build their stores (`followFavorites`).
    private func makeFavoriteStores(following memberStore: TripMemberStore) {
        guard favorites == nil else { return }
        let favoriteStore = FavoriteStore(
            onUnauthorized: { [session] refusal in await session.handle(refusal) })
        favoriteStore.reports(to: session)
        let tagStore = PictureTagStore(
            onUnauthorized: { [session] refusal in await session.handle(refusal) })
        tagStore.reports(to: session)
        tagStore.follow(favoriteStore)
        memberStore.follow(favoriteStore)
        favorites = favoriteStore
        pictureTags = tagStore
    }

    /// The one card the session is entitled to, and never two: which of them is on screen is
    /// decided by `SessionBanner.notice`, so the weighing is a function with its own cases rather
    /// than two conditions sitting next to each other in a view body.
    @ViewBuilder
    private var notice: some View {
        switch SessionBanner.notice(
            showingUnreachable: session.showsUnreachableNotice,
            verification: session.verification,
            showingOlderServer: session.showsOlderServerNotice
        ) {
        case .unreachable(let text):
            UnreachableBanner(text: text, retry: { await session.retryNow() })
                .padding(.horizontal, DesignTokens.Space.regular)
                .padding(.top, DesignTokens.Space.regular)
        case .unverified(let text):
            NoticeCard(text: text, tone: .warning)
                .padding(.horizontal, DesignTokens.Space.regular)
                .padding(.top, DesignTokens.Space.regular)
        case .olderServer(let text):
            // A plain line, not a card: it informs, asks nothing of the person and offers no retry.
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignTokens.Space.regular)
                .padding(.top, DesignTokens.Space.regular)
        case nil:
            EmptyView()
        }
    }

    private var tabs: some View {
        // The bar IS `MainTab.allCases`: its content and its order are the enum's, so a case added
        // without a screen is a compile error rather than a tab nobody can reach, and a test that
        // reads the enum reads what a person touches. The tabs that hold it are `MainTabs`.
        MainTabs(selection: $selection) { tab in
            screen(for: tab)
        }
        .environment(jump)
        .environment(tagJump)
        .environment(yearJump)
        .environment(monthJump)
        .environment(trips)
        .environment(members)
        .environment(actions)
        .environment(favorites)
        .environment(pictureTags)
        // The tab switch, and only the tab switch. Whoever asked has already said which memo; the
        // Timeline is what reads that and pushes it, because it owns both the list and the stack.
        .onChange(of: jump.pending) { _, pending in
            selection = MemoJumpRouting.tab(showing: selection, whenJumping: pending)
        }
        // The same for a tag asked for from Collections: the Library applies it.
        .onChange(of: tagJump.pending) { _, pending in
            selection = LibraryTagJumpRouting.tab(showing: selection, whenOpening: pending)
        }
        // And for a year asked for from Collections: the Library shows it.
        .onChange(of: yearJump.pending) { _, pending in
            selection = LibraryYearJumpRouting.tab(showing: selection, whenOpening: pending)
        }
        // And for a month: the Library shows its days.
        .onChange(of: monthJump.pending) { _, pending in
            selection = LibraryMonthJumpRouting.tab(showing: selection, whenOpening: pending)
        }
    }

    @ViewBuilder
    private func screen(for tab: MainTab) -> some View {
        switch tab {
        case .timeline: TimelineView()
        case .library: MediaLibraryView()
        case .collections: CollectionsRootView()
        case .places: PlacesView()
        }
    }
}

/// The navigation bar the Timeline and Places roots stand under (MEMNG-756): inline, with no
/// title, so neither spends a band of the screen on its name — the main bar's selected item
/// already says which tab this is. One modifier both roots apply, so the bar a test reads over a
/// hosted root is the one this says.
struct TabRootChrome: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationBarTitleDisplayMode(.inline)
    }
}

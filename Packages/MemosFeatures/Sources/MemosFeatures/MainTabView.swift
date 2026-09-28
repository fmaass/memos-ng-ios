import MemosCore
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

    /// Opens on the Timeline, the middle tab (plan page 3929 decision 11). A test that is about
    /// another tab's screen under the real dock opens there instead.
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
        // reads the enum reads what a person touches. The dock that draws it is `DockedTabs`.
        DockedTabs(selection: $selection) { tab in
            screen(for: tab)
        }
        .environment(jump)
        // The tab switch, and only the tab switch. Whoever asked has already said which memo; the
        // Timeline is what reads that and pushes it, because it owns both the list and the stack.
        .onChange(of: jump.pending) { _, pending in
            selection = MemoJumpRouting.tab(showing: selection, whenJumping: pending)
        }
    }

    @ViewBuilder
    private func screen(for tab: MainTab) -> some View {
        switch tab {
        case .timeline: TimelineView()
        case .library: MediaLibraryView()
        case .places: PlacesView()
        }
    }
}

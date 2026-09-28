import MemosCore
import SwiftUI

/// The signed-in app's surfaces, as a value rather than as literals inside a `TabView`.
///
/// It exists so what the app's main navigation OFFERS is assertable: a tab whose title or glyph is
/// written inline in a view body is a thing no test can read back, and this is the one list that
/// says how many ways into the app there are.
public enum MainTab: String, CaseIterable, Identifiable, Sendable {
    // Declaration order IS the bar's order, left to right: Library, Timeline in the middle, Places —
    // the same pill the web dock draws (plan page 3929 decision 11), so the two clients read alike.
    // Which tab the app opens on is not this order's business; `MainTabView.selection` says it.
    case library
    case timeline
    case places

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .timeline: "Timeline"
        case .library: "Library"
        case .places: "Places"
        }
    }

    /// SF Symbols, so the bar looks like every other tab bar on the phone.
    public var symbol: String {
        switch self {
        case .timeline: "list.bullet"
        case .library: "photo.on.rectangle.angled"
        case .places: "map"
        }
    }
}

/// What the app shows while somebody is signed in.
///
/// A tab bar rather than a screen with a button to somewhere else: the library is a place people
/// go back to, and a destination reached by pushing off the timeline is one that loses its scroll
/// position every time. Each tab keeps its own navigation stack, which is what makes going back
/// and forth between them cost nothing.
struct MainTabView: View {
    @Environment(SessionStore.self) private var session
    @State private var selection: MainTab = .timeline
    /// A memo asked for from a tab that cannot open one.
    ///
    /// It lives HERE because the move it describes is a move between tabs: the Library says which
    /// memo a photograph belongs to, the Timeline is the only tab that can show a memo, and the
    /// tab bar is the only thing that can put the app on the other one. Both ends read it out of
    /// the environment (MEMNG-191).
    @State private var jump = MemoJump()

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
        // reads the enum reads what a person touches.
        TabView(selection: $selection) {
            ForEach(MainTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.symbol, value: tab) {
                    screen(for: tab)
                }
            }
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

import SwiftUI

/// The signed-in app's surfaces, as a value rather than as two literals inside a `TabView`.
///
/// It exists so what the app's main navigation OFFERS is assertable: a tab whose title or glyph is
/// written inline in a view body is a thing no test can read back, and this is the one list that
/// says how many ways into the app there are.
public enum MainTab: String, CaseIterable, Identifiable, Sendable {
    case timeline
    case library

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .timeline: "Timeline"
        case .library: "Library"
        }
    }

    /// SF Symbols, so the bar looks like every other tab bar on the phone.
    public var symbol: String {
        switch self {
        case .timeline: "list.bullet"
        case .library: "photo.on.rectangle.angled"
        }
    }
}

/// What the app shows while somebody is signed in.
///
/// A tab bar rather than a screen with a button to somewhere else: the library is a place people
/// go back to, and a destination reached by pushing off the timeline is one that loses its scroll
/// position every time. Both tabs keep their own navigation stack, which is what makes going back
/// and forth between them cost nothing.
struct MainTabView: View {
    @State private var selection: MainTab = .timeline
    /// A memo asked for from a tab that cannot open one.
    ///
    /// It lives HERE because the move it describes is a move between tabs: the Library says which
    /// memo a photograph belongs to, the Timeline is the only tab that can show a memo, and the
    /// tab bar is the only thing that can put the app on the other one. Both ends read it out of
    /// the environment (MEMNG-191).
    @State private var jump = MemoJump()

    var body: some View {
        TabView(selection: $selection) {
            Tab(
                MainTab.timeline.title,
                systemImage: MainTab.timeline.symbol,
                value: MainTab.timeline
            ) {
                TimelineView()
            }
            Tab(
                MainTab.library.title,
                systemImage: MainTab.library.symbol,
                value: MainTab.library
            ) {
                MediaLibraryView()
            }
        }
        .environment(jump)
        // The tab switch, and only the tab switch. Whoever asked has already said which memo; the
        // Timeline is what reads that and pushes it, because it owns both the list and the stack.
        .onChange(of: jump.pending) { _, pending in
            selection = MemoJumpRouting.tab(showing: selection, whenJumping: pending)
        }
    }
}

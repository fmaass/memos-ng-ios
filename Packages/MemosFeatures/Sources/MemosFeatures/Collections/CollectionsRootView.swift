import MemosCore
import SwiftUI

/// The Collections tab's root, a placeholder for now (MEMNG-709).
///
/// It holds the tab's place in the bar and nothing more: no store, no read, no content. The `+`
/// is drawn where making a collection will live and is disabled until there is something it can
/// do. The stack is the tab's own, as every tab's is, so what grows here later keeps its own
/// navigation and scroll position.
struct CollectionsRootView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(Self.emptyTitle, systemImage: MainTab.collections.symbol)
                // The whole screen, so the chrome around the root is laid out against the
                // screen and not against the empty state's own size (MEMNG-605).
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tabRootTitle(MainTab.collections.title)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button(Self.newCollection, systemImage: "plus") {}
                            .disabled(true)
                    }
                }
                // The app's main bar's room, inside the stack (MEMNG-690).
                .leadingFootBar(on: .collections)
        }
    }

    /// What the empty root says.
    static let emptyTitle = "No collections yet"
    /// The `+` button's name, read by VoiceOver.
    static let newCollection = "New Collection"
}

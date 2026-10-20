import MemosCore
import SwiftUI

extension View {
    /// Has `store` follow the session's favorites (`FavoriteStore`, from the environment) once
    /// both exist, and once per pair: a store built before the favorites arrive, or the other way
    /// round, still follows, and a screen that re-renders does not subscribe twice.
    func followsFavorites<Store: AnyObject>(
        _ store: Store?, follow: @escaping (Store, FavoriteStore) -> Void
    ) -> some View {
        modifier(FollowsFavorites(store: store, follow: follow))
    }
}

private struct FollowsFavorites<Store: AnyObject>: ViewModifier {
    @Environment(FavoriteStore.self) private var favorites: FavoriteStore?
    let store: Store?
    let follow: (Store, FavoriteStore) -> Void
    @State private var followed: Pair?

    struct Pair: Equatable {
        let store: ObjectIdentifier
        let favorites: ObjectIdentifier
    }

    func body(content: Content) -> some View {
        content.onChange(of: pair, initial: true) { _, now in
            guard let now, now != followed, let store, let favorites else { return }
            followed = now
            follow(store, favorites)
        }
    }

    private var pair: Pair? {
        guard let store, let favorites else { return nil }
        return Pair(store: ObjectIdentifier(store), favorites: ObjectIdentifier(favorites))
    }
}

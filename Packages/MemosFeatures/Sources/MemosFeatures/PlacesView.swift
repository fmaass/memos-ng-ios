import MemosCore
import SwiftUI

/// The map of where the photographs were taken.
///
/// The store is built here and dropped with the signed-in hierarchy, exactly as the library's is:
/// the markers belong to whoever is signed in, and a screen that outlives a sign-out holding them
/// is the leak `RootView`'s identity on the hierarchy exists to prevent.
///
/// Nothing on this screen classifies a refusal or compares a generation of its own. The read is
/// `PlacesStore.load(using:baseURL:)` and the four states are `PlacesStore.status` — asked through
/// `PlacesPresentation`, so which state the reader is shown is a thing a test states rather than
/// something only a rendered view knows.
struct PlacesView: View {
    @Environment(SessionStore.self) private var session
    @State private var places: PlacesStore?

    var body: some View {
        Group {
            if let places {
                content(places)
            } else {
                // Before the store exists there is nothing to say about the library yet.
                ProgressView()
            }
        }
        .tint(DesignTokens.accent)
        .task {
            if places == nil {
                places = PlacesStore(
                    onUnauthorized: { [session] refusal in
                        await session.handle(refusal)
                    }
                )
            }
            // A failure that never reached the server belongs to the session's one banner, not to
            // an error card over this map (`SessionReporting`).
            places?.reports(to: session)
            await load()
        }
    }

    @ViewBuilder
    private func content(_ places: PlacesStore) -> some View {
        let state = PlacesPresentation.state(of: places)
        switch state {
        case .pending:
            // Not the empty state: a screen that has not settled once knows nothing about the
            // library yet, and saying "no places" while the answer is in flight is a claim that
            // has not been earned.
            ProgressView()
        case .ready:
            PlacesMapView(
                pins: PlacesPresentation.pins(for: places.markers),
                region: PlacesPresentation.fitRegion(for: places.markers)
            )
            .ignoresSafeArea(edges: .top)
        case .empty, .error:
            notice(
                PlacesPresentation.notice(for: state, error: places.lastError),
                retry: state == .error
            )
        }
    }

    @ViewBuilder
    private func notice(_ notice: PlacesNotice?, retry: Bool) -> some View {
        if let notice {
            ContentUnavailableView {
                Label(notice.title, systemImage: notice.symbol)
            } description: {
                Text(notice.message)
            } actions: {
                if retry {
                    Button("Try Again") {
                        Task { await load() }
                    }
                }
            }
        }
    }

    private func load() async {
        guard let places, let handle = session.activeHandle,
            let baseURL = session.serverBaseURL
        else { return }
        await places.load(using: handle, baseURL: baseURL)
    }
}

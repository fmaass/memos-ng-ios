import MapKit
import MemosCore
import SwiftUI

/// The map of where the photographs were taken.
///
/// The screen is one line here because everything it holds lives in the view below, keyed on the
/// subject signed in. A revalidation can come back as somebody ELSE while the signed-in hierarchy
/// stands (`SessionStore.establish`), and nothing in that hierarchy is keyed on who it is — so
/// this key is what drops the first person's store, markers, sheet and viewer in one go,
/// including whatever state the screen grows later. The next subject's view then loads on its own
/// first appearance, and a read still in flight for the previous one lands in a store nothing
/// shows and is refused against the handle it presented.
struct PlacesView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        // A stack of its own, as every tab root has one, under a bar with no title (MEMNG-756):
        // the main bar's selected item already names the tab. The map still runs under the bars,
        // edge to edge.
        NavigationStack {
            PlacesScreen()
                .id(session.state.user?.subject)
                .modifier(TabRootChrome())
                // The app's main bar's room, inside the stack (MEMNG-690).
                .leadingFootBar(on: .places)
        }
    }

    /// What the screen's full-size root is found by in a test (MEMNG-605).
    static let rootIdentifier = "places-root"
}

/// The screen itself, for as long as one person is signed in.
///
/// Nothing on this screen classifies a refusal or compares a generation of its own. The read is
/// `PlacesStore.load(using:baseURL:)` and the four states are `PlacesStore.status` — asked through
/// `PlacesPresentation`, so which state the reader is shown is a thing a test states rather than
/// something only a rendered view knows.
private struct PlacesScreen: View {
    @Environment(SessionStore.self) private var session
    @State private var places: PlacesStore?
    /// The map's delegate, held by the screen because Zoom-in is an action ON the map taken from a
    /// sheet the map does not present.
    @State private var map = PlacesMapCoordinator()
    /// The sheet and the two viewers a tap on the map opens (`PlacesPresenting`, shared with a
    /// trip's Map since MEMNG-719).
    @State private var presenting = PlacesPresenting()
    /// A picture's place asked for from the viewer's Info sheet (MEMNG-869). Optional: a host
    /// without one has nothing to focus on.
    @Environment(PlacesFocus.self) private var focus: PlacesFocus?

    var body: some View {
        Group {
            if let places {
                content(places)
            } else {
                // Before the store exists there is nothing to say about the library yet.
                ProgressView()
            }
        }
        // The whole screen from the first layout, in every state: a spinner sized to itself is a
        // root the chrome around it was laid out against, which is how the bar came to stand in
        // the middle of the screen until the map arrived (MEMNG-605). The spinner, the notices
        // and the map are all drawn inside this one frame.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The frame made readable: a container element reports the union of what it holds, which
        // while loading is the spinner alone, so the size is carried by a leaf behind everything
        // that takes the frame's whole size and no touch.
        .background {
            Color.clear
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel(MainTab.places.title)
                .accessibilityIdentifier(PlacesView.rootIdentifier)
        }
        // Outside the view that presents the sheet, for the reason the library's cover is outside
        // its navigation stack: two presentations declared on one view is how one of them silently
        // stops appearing.
        .placesViewer($presenting.viewing, delete: deletePicture)
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
            applyFocus()
        }
        .onChange(of: focus?.pending) { _, _ in applyFocus() }
        // A request that came while the first read was still out is answered when it settles,
        // whichever load that turns out to be (MEMNG-906).
        .onChange(of: places.map { PlacesPresentation.state(of: $0) }) { _, _ in applyFocus() }
        .alert(
            PlacesFocus.Decline.title, isPresented: declineShown, presenting: focus?.declined
        ) { _ in
            Button("OK", role: .cancel) { focus?.dismissDecline() }
        } message: { decline in
            Text(decline.message)
        }
        .reloadsOnRecovery(session.reachabilityRecoveries) { await load() }
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
            wholeMap(places)
        case .empty, .error:
            PlacesNoticeView(
                notice: PlacesPresentation.notice(for: state, error: places.lastError),
                retry: state == .error ? retry : nil
            )
        }
    }

    /// The map, and nothing beside it.
    ///
    /// The screen opens on the whole map, and photographs appear only where the reader asks for
    /// them: a crowded pin or a cluster presents its sheet, a pin of one photograph opens the
    /// viewer. A grid that was always on screen took nearly half of it to repeat what the pins
    /// already say. The map runs under the status bar and the tab bar so that it is the screen
    /// rather than a panel between two bars — a thing to look at on a device, not one anything
    /// here depends on.
    private func wholeMap(_ places: PlacesStore) -> some View {
        // The map and its sheet are `PlacesMapStage`, shared with a trip's Map (MEMNG-719).
        PlacesMapStage(
            markers: places.markers, control: map, presenting: $presenting,
            delete: deletePicture, gone: places.deleted)
    }

    /// The viewer's bin: the picture leaves the server and, with it, this map
    /// (`PlacesStore.delete`).
    private func deletePicture(_ uid: String) async -> Bool {
        guard let places, let handle = session.activeHandle else { return false }
        return await places.delete(uid, using: handle)
    }

    /// Try Again on the error card.
    private var retry: @MainActor () async -> Void {
        { await load() }
    }

    private var declineShown: Binding<Bool> {
        Binding(
            get: { focus?.declined != nil },
            set: { shown in if !shown { focus?.dismissDecline() } })
    }

    /// Answers a pending focus (`PlacesFocus.answer(given:)`) and hands a taken one to the map once
    /// the markers have been read, so the picture's own pin can be the centre; the map holds it
    /// until it has had its opening view.
    private func applyFocus() {
        guard let places,
            case .focus(let request)? = focus?.answer(given: PlacesPresentation.state(of: places))
        else { return }
        let center = PlacesFocusRouting.center(for: request, in: places.markers)
        map.focus(
            on: MKCoordinateRegion(
                center: center, latitudinalMeters: PlacesFocusRouting.span,
                longitudinalMeters: PlacesFocusRouting.span))
    }

    private func load() async {
        guard let places, let handle = session.activeHandle,
            let baseURL = session.serverBaseURL
        else { return }
        await places.load(using: handle, baseURL: baseURL)
    }
}

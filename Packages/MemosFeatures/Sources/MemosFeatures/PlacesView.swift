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
        // A stack of its own for the one thing it carries: the tab root's large title, which a
        // root stands under on every tab now that the bar is the system's (MEMNG-666). The map
        // still runs under the bars, edge to edge.
        NavigationStack {
            PlacesScreen()
                .id(session.state.user?.subject)
                .tabRootTitle(MainTab.places.title)
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
    /// The photographs a tap on a crowded pin or a cluster listed.
    @State private var sheet: PlaceSheet?
    /// The viewer opened from the map with no sheet up, by a pin that holds one photograph.
    @State private var viewing: MediaViewerSelection?
    /// The viewer opened while the sheet is up — by a photograph inside it, or by a pin tapped on
    /// the map behind it — presented by the sheet itself. A second state rather than the one
    /// above because both covers would be live at once while the sheet is up, and a photograph
    /// tapped in the sheet must not need the sheet dismissed first: dismissing and presenting in
    /// one turn is how the second presentation gets dropped.
    @State private var viewingFromSheet: MediaViewerSelection?

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
        .fullScreenCover(item: $viewing) { selection in
            // The photographs of that moment, paged as a value: this screen's list is what the
            // reader was looking at, not a window onto a store that keeps loading.
            MediaViewerView(selection: selection, source: .fixed(selection.pages))
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
                .sheet(item: $sheet) { sheet in
                    sheetContents(sheet)
                        .presentationDetents([.medium, .large])
                        // At half height the sheet is a drawer under the map, not a dialog over
                        // it: the map stays live, so the reader can pan, or tap another place and
                        // have its photographs replace these. Pulled to full height it covers the
                        // map and is modal again.
                        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                }
        case .empty, .error:
            notice(
                PlacesPresentation.notice(for: state, error: places.lastError),
                retry: state == .error
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
        PlacesMapView(
            pins: PlacesPresentation.pins(for: places.markers),
            region: PlacesPresentation.fitRegion(for: places.markers),
            markers: places.markers,
            onTap: { open($0) },
            control: map
        )
        .ignoresSafeArea()
    }

    /// One tappable square per photograph, in the order the list is already in.
    @ViewBuilder
    private func tiles(
        _ markers: [PlaceMarker],
        opening viewer: Binding<MediaViewerSelection?>
    ) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 96), spacing: DesignTokens.Space.hair)],
            spacing: DesignTokens.Space.hair
        ) {
            ForEach(markers, id: \.uid) { marker in
                // `AttachmentThumbnail` is the one image path: it evicts a lapsed signature before
                // its cache read and re-checks the media generation inside its task, which is why
                // nothing here paints a marker's URL by hand.
                AttachmentThumbnail(
                    attachment: MemoAttachment(marker),
                    tier: .thumb,
                    slot: MemoPresentation.gridSlot
                )
                .contentShape(.rect)
                .onTapGesture {
                    viewer.wrappedValue = PlacesPresentation.open(marker.uid, in: markers)
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Photo")
                .accessibilityHint("Opens full screen")
            }
        }
        .padding(.horizontal, DesignTokens.Space.hair)
    }

    /// What a crowded pin or a cluster listed, and the one action that can still separate it.
    @ViewBuilder
    private func sheetContents(_ listed: PlaceSheet) -> some View {
        NavigationStack {
            ScrollView {
                tiles(listed.markers, opening: $viewingFromSheet)
            }
            // The sheet opens for two photographs or more — one photograph is the viewer, not a
            // list — so the plural is not a case that has to be chosen.
            .navigationTitle("\(listed.markers.count) Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { sheet = nil }
                }
                if listed.canZoomIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Zoom In") {
                            map.zoomIn(to: listed.members)
                            sheet = nil
                        }
                    }
                }
            }
        }
        // On the sheet itself: a photograph tapped in the list opens over it, rather than the
        // sheet dismissing and something else presenting a turn later.
        .fullScreenCover(item: $viewingFromSheet) { selection in
            MediaViewerView(selection: selection, source: .fixed(selection.pages))
        }
    }

    /// Where a tap on the map goes. The rule is `PlacesPresentation`'s; this is the presentation
    /// its answer asks for.
    private func open(_ action: PlaceTapAction) {
        switch action {
        case .viewer(let selection):
            // The map stays live under a half-height sheet, so a pin of one photograph can be
            // tapped while the sheet is up. Whatever is on top is what presents: a cover asked of
            // the screen underneath a live sheet is the presentation that gets dropped.
            if sheet == nil {
                viewing = selection
            } else {
                viewingFromSheet = selection
            }
        case .sheet(let listed):
            sheet = listed
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

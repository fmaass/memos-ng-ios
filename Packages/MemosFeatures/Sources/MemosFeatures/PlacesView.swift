import MemosCore
import SwiftUI

/// The map of where the photographs were taken.
///
/// The screen is one line here because everything it holds lives in the view below, keyed on the
/// subject signed in. A revalidation can come back as somebody ELSE while the signed-in hierarchy
/// stands (`SessionStore.establish`), and nothing in that hierarchy is keyed on who it is — so
/// this key is what drops the first person's store, markers, grid, sheet and viewer in one go,
/// including whatever state the screen grows later. The next subject's view then loads on its own
/// first appearance, and a read still in flight for the previous one lands in a store nothing
/// shows and is refused against the handle it presented.
struct PlacesView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        PlacesScreen()
            .id(session.state.user?.subject)
    }
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
    /// What the map last settled on, and nil until it has settled once.
    @State private var visible: PlaceBBox?
    /// The photographs a tap on a crowded pin or a cluster listed.
    @State private var sheet: PlaceSheet?
    /// The viewer opened from the map or from the grid under it.
    @State private var viewing: MediaViewerSelection?
    /// The viewer opened from INSIDE the sheet, presented by the sheet itself. A second state
    /// rather than the one above because both covers would be live at once while the sheet is up,
    /// and a photograph tapped in the sheet must not need the sheet dismissed first: dismissing
    /// and presenting in one turn is how the second presentation gets dropped.
    @State private var viewingFromSheet: MediaViewerSelection?

    /// How much of the screen the map keeps, the grid taking the rest. Chosen for parity with the
    /// web's phone layout; a number to look at on a device rather than one anything depends on.
    private static let mapShare: CGFloat = 0.55

    var body: some View {
        Group {
            if let places {
                content(places)
            } else {
                // Before the store exists there is nothing to say about the library yet.
                ProgressView()
            }
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
            mapWithGrid(places)
                .sheet(item: $sheet) { sheet in
                    sheetContents(sheet)
                        .presentationDetents([.medium, .large])
                }
        case .empty, .error:
            notice(
                PlacesPresentation.notice(for: state, error: places.lastError),
                retry: state == .error
            )
        }
    }

    /// The map over the photographs it is currently showing.
    ///
    /// The grid is rebuilt from what the map REPORTS once it has stopped moving, never from the
    /// pins it happens to be drawing: a list that reshuffled under the finger during a pan is the
    /// one thing this layout must not do.
    @ViewBuilder
    private func mapWithGrid(_ places: PlacesStore) -> some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                PlacesMapView(
                    pins: PlacesPresentation.pins(for: places.markers),
                    region: PlacesPresentation.fitRegion(for: places.markers),
                    markers: places.markers,
                    onRegionChange: { visible = $0 },
                    onTap: { open($0) },
                    control: map
                )
                .frame(height: geometry.size.height * Self.mapShare)
                .ignoresSafeArea(edges: .top)
                grid(PlacesPresentation.visibleGrid(places.markers, in: visible))
            }
        }
    }

    /// The photographs of the part of the map on screen.
    @ViewBuilder
    private func grid(_ markers: [PlaceMarker]) -> some View {
        if markers.isEmpty {
            // Not the screen's empty state: the library has photographs with a place, this piece
            // of the map has none. Saying so here leaves the map where the reader put it.
            Text("No photos in this part of the map.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                tiles(markers, opening: $viewing)
            }
        }
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
            viewing = selection
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

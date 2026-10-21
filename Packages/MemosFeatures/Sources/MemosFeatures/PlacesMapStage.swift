import MemosCore
import SwiftUI

/// What a screen showing photographs on the map has open over it: the sheet a crowded pin or a
/// cluster listed, and the viewer a pin of one photograph — or a photograph in that sheet — opened.
///
/// These were `PlacesView`'s own three states until a trip's Map needed the same map (MEMNG-719);
/// both screens now hold one of these, so the Places tab and a trip cannot drift apart in what a
/// tap opens or where it is presented.
struct PlacesPresenting {
    /// The photographs a tap on a crowded pin or a cluster listed.
    var sheet: PlaceSheet?
    /// The viewer opened from the map with no sheet up, by a pin that holds one photograph.
    var viewing: MediaViewerSelection?
    /// The viewer opened while the sheet is up — by a photograph inside it, or by a pin tapped on
    /// the map behind it — presented by the sheet itself. A second state rather than the one
    /// above because both covers would be live at once while the sheet is up, and a photograph
    /// tapped in the sheet must not need the sheet dismissed first: dismissing and presenting in
    /// one turn is how the second presentation gets dropped.
    var viewingFromSheet: MediaViewerSelection?

    /// Where a tap on the map goes. The rule is `PlacesPresentation`'s; this is the presentation
    /// its answer asks for.
    mutating func open(_ action: PlaceTapAction) {
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

    /// Closes whatever shows a photograph outside `kept` — nil keeps nothing — and leaves the rest.
    ///
    /// For a map whose photographs can leave it while something is open over it: a trip's, where
    /// a picture excluded or a trip deleted takes its markers away (MEMNG-719). A viewer pages
    /// over exactly the pages it was opened with (`.fixed`), and a sheet lists exactly its
    /// markers, so a presentation still holding a photograph that left is closed rather than
    /// left showing it. The viewer a sheet presents goes with the sheet.
    mutating func keep(only kept: Set<String>?) {
        let kept = kept ?? []
        func fits(_ selection: MediaViewerSelection?) -> Bool {
            selection.map { Set($0.pages.map(\.id)).isSubset(of: kept) } ?? true
        }
        if !fits(viewing) { viewing = nil }
        if let sheet, !Set(sheet.markers.map(\.uid)).isSubset(of: kept) {
            self.sheet = nil
            viewingFromSheet = nil
        }
        if !fits(viewingFromSheet) { viewingFromSheet = nil }
    }
}

/// The map of `markers`, and the sheet a tap on it lists: what the Places tab shows once it is
/// ready, and what a trip's Map shows over the trip's own markers (MEMNG-719).
///
/// A tap is resolved against `markers` and nothing else (`PlacesPresentation.tap`), so the sheet
/// and the viewer opened from this map list only what it was handed. The viewer a pin opens with
/// no sheet up is NOT presented here: the host declares it outside this view
/// (`placesViewer(_:)`), because two presentations declared on one view is how one of them
/// silently stops appearing.
struct PlacesMapStage: View {
    let markers: [PlaceMarker]
    /// A test's window onto this stage; nil in the app.
    @Environment(\.placesStageProbe) private var probe
    /// The map's delegate, held by the host because Zoom-in is an action ON the map taken from a
    /// sheet the map does not present.
    let control: PlacesMapCoordinator
    @Binding var presenting: PlacesPresenting
    /// What the viewer over the sheet offers beside its own actions: a trip's "Use as Cover" on a
    /// trip's Map, nothing on the Places tab's (MEMNG-720).
    var viewerAction: MediaViewerHostAction? = nil
    /// The host's bin for the viewer over the sheet, shown on each page that is mine.
    var delete: (@MainActor (String) async -> Bool)? = nil
    /// The pictures deleted since the sheet was listed: its tiles leave with them.
    var gone: Set<String> = []

    var body: some View {
        // The map runs under the status bar and the tab bar so that it is the screen rather than
        // a panel between two bars — a thing to look at on a device, not one anything here
        // depends on.
        PlacesMapView(
            pins: PlacesPresentation.pins(for: markers),
            region: PlacesPresentation.fitRegion(for: markers),
            markers: markers,
            onTap: { presenting.open($0) },
            control: control
        )
        .ignoresSafeArea()
        // What the map was handed, exactly as `PlacesMapView` gets it, and the tap path its pins
        // call: read by a test, because an `MKMapView`'s annotations are not in the
        // accessibility tree a hosted test can walk.
        .onChange(of: markers.map(\.uid), initial: true) { _, uids in probe?.staged = uids }
        .onAppear { probe?.tap = { presenting.open($0) } }
        .sheet(item: $presenting.sheet) { sheet in
            PlaceSheetContents(
                listed: sheet, control: control, presenting: $presenting,
                viewerAction: viewerAction, delete: delete, gone: gone
            )
            .presentationDetents([.medium, .large])
            // At half height the sheet is a drawer under the map, not a dialog over it: the map
            // stays live, so the reader can pan, or tap another place and have its photographs
            // replace these. Pulled to full height it covers the map and is modal again.
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
    }
}

/// What a crowded pin or a cluster listed, and the one action that can still separate it.
struct PlaceSheetContents: View {
    let listed: PlaceSheet
    let control: PlacesMapCoordinator
    @Binding var presenting: PlacesPresenting
    var viewerAction: MediaViewerHostAction? = nil
    var delete: (@MainActor (String) async -> Bool)? = nil
    var gone: Set<String> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                tiles
            }
            // The sheet opens for two photographs or more — one photograph is the viewer, not a
            // list — so the plural is not a case that has to be chosen.
            .navigationTitle("\(markers.count) Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { presenting.sheet = nil }
                }
                if listed.canZoomIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Zoom In") {
                            control.zoomIn(to: listed.members)
                            presenting.sheet = nil
                        }
                    }
                }
            }
        }
        // On the sheet itself: a photograph tapped in the list opens over it, rather than the
        // sheet dismissing and something else presenting a turn later.
        .fullScreenCover(item: $presenting.viewingFromSheet) { selection in
            MediaViewerView(
                selection: selection, source: .fixed(selection.pages), delete: delete,
                hostAction: viewerAction)
        }
    }

    /// The listed photographs less the ones deleted since: a tile of a file the server no longer
    /// has is a tile that opens nothing.
    private var markers: [PlaceMarker] {
        gone.isEmpty ? listed.markers : listed.markers.filter { !gone.contains($0.uid) }
    }

    /// One tappable square per photograph, in the order the list is already in.
    private var tiles: some View {
        let markers = markers
        return LazyVGrid(
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
                    presenting.viewingFromSheet = PlacesPresentation.open(marker.uid, in: markers)
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Photo")
                .accessibilityHint("Opens full screen")
            }
        }
        .padding(.horizontal, DesignTokens.Space.hair)
    }
}

/// What a map screen says instead of its map: a `PlacesNotice` drawn, with Try Again when `retry`
/// is given — the Places tab's card, shared with a trip's Map (MEMNG-719).
struct PlacesNoticeView: View {
    let notice: PlacesNotice?
    var retry: (@MainActor () async -> Void)?

    var body: some View {
        if let notice {
            ContentUnavailableView {
                Label(notice.title, systemImage: notice.symbol)
            } description: {
                Text(notice.message)
            } actions: {
                if let retry {
                    Button("Try Again") {
                        Task { await retry() }
                    }
                }
            }
        }
    }
}

extension View {
    /// The viewer a pin of one photograph opens with no sheet up, declared by the host outside
    /// the view that presents the sheet (`PlacesMapStage`).
    ///
    /// The photographs of that moment, paged as a value: the list is what the reader was looking
    /// at, not a window onto a store that keeps loading. `action` is a trip Map's "Use as Cover",
    /// nil on the Places tab (MEMNG-720).
    func placesViewer(
        _ viewing: Binding<MediaViewerSelection?>, action: MediaViewerHostAction? = nil,
        delete: (@MainActor (String) async -> Bool)? = nil
    ) -> some View {
        fullScreenCover(item: viewing) { selection in
            MediaViewerView(
                selection: selection, source: .fixed(selection.pages), delete: delete,
                hostAction: action)
        }
    }
}

/// What a map screen hands its map and what it has open over it, for a test to read: the uids
/// `PlacesMapStage` was last given, the stage's own tap path, and the host's presentations. Nil in
/// the app; a test puts one in the environment (`placesStageProbe`).
@MainActor
final class PlacesStageProbe {
    /// The uids of the markers the stage last handed `PlacesMapView`, in its order.
    var staged: [String] = []
    /// What a pin's tap calls: `PlacesPresenting.open` on the host's state.
    var tap: ((PlaceTapAction) -> Void)?
    /// The host's presentations as they are now.
    var presenting: (() -> PlacesPresenting)?
}

extension EnvironmentValues {
    @Entry var placesStageProbe: PlacesStageProbe?
}

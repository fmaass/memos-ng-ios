import MemosCore
import SwiftUI

/// Every decision a trip's Map makes that is not drawing (MEMNG-719).
///
/// `GET /api/map/markers` takes no parameters, so the map is given every located photo the account
/// can see and keeps the trip's: a marker stays exactly when its `uid` — the attachment's — is one
/// of the trip's member uids. Those uids are the COMPLETE drained membership
/// (`TripMembershipStore.members(for:)`, the drained list minus the record's exclusions), and only
/// once the drain has settled: a drain applies its list once, at its end, and while one is on the
/// wire there is no membership to filter by, so the map waits rather than draw a partial trip or
/// say it has no places. A drain stopped at the cap filters by the pictures it did read — the
/// first `memberCap` — as the grid shows them.
nonisolated enum TripMapPresentation {
    /// What a trip's map says when no member of the trip knows where it was taken.
    static let emptyTitle = "No places in this trip"
    /// The map's name, read by VoiceOver.
    static let mapLabel = "Trip map"
    /// What the map is found by in a test.
    static let mapIdentifier = "trip-map"

    /// The uids the map may show: the trip's drained members, or nil while the drain has not
    /// settled — not read yet, or a read on the wire.
    @MainActor
    static func memberUids(of record: CollectionRecord, in trips: TripMembershipStore)
        -> Set<String>?
    {
        switch trips.state(for: record) {
        case .complete, .truncated: Set(trips.members(for: record).map(\.id))
        case .draining, .notLoaded: nil
        }
    }

    /// The trip's markers: those of `markers` whose uid is a member, in the order they came. None
    /// while the members are not known.
    static func markers(_ markers: [PlaceMarker], of members: Set<String>?) -> [PlaceMarker] {
        guard let members else { return [] }
        return markers.filter { members.contains($0.uid) }
    }

    /// What a presentation open over the map may still show: the uids of the markers drawn, or
    /// nil while the membership is not known — which keeps nothing open (`PlacesPresenting.keep`).
    static func kept(_ shown: [PlaceMarker], members: Set<String>?) -> Set<String>? {
        members.map { _ in Set(shown.map(\.uid)) }
    }

    /// Which of the four states the trip's map is in.
    ///
    /// The membership is asked first: a drain on the wire, or none yet, is pending — never empty —
    /// and one that failed before any reading of the trip is an error. With the members known, the
    /// markers' own state decides, except that a read answered with markers of which none is the
    /// trip's is the empty map: no member of this trip knows where it was taken.
    static func state(
        places: PlacesStatus, membership: TripMembershipState, membershipError: String?,
        shown: Int
    ) -> PlacesStatus {
        switch membership {
        case .draining: return .pending
        case .notLoaded: return membershipError == nil ? .pending : .error
        case .complete, .truncated: break
        }
        switch places {
        case .pending: return .pending
        case .error: return .error
        case .empty, .ready: return shown > 0 ? .ready : .empty
        }
    }

    /// What to say instead of the trip's map, or nil when a map (or a spinner) is what is shown.
    static func notice(for status: PlacesStatus, error: String?) -> PlacesNotice? {
        switch status {
        case .ready, .pending:
            nil
        case .empty:
            PlacesNotice(
                title: emptyTitle,
                symbol: "mappin.slash",
                message: "No photo of this trip knows where it was taken."
            )
        case .error:
            PlacesNotice(
                title: "The trip's map could not be loaded",
                symbol: "exclamationmark.triangle",
                message: error ?? "The last attempt did not finish."
            )
        }
    }

    /// The markers' store a trip's Map reads through, made to report to the session.
    ///
    /// Reporting is what fences it. `PlacesStore` judges every answer against the session that
    /// ISSUED its request only once it has a session to ask (`sessionStillCurrent`); so the store
    /// is put to use already reporting, and an answer that outlives its session — somebody else
    /// signed in meanwhile — is not put on this trip's map.
    @MainActor
    static func reporting(_ store: PlacesStore, to session: (any SessionReporting)?)
        -> PlacesStore
    {
        if let session { store.reports(to: session) }
        return store
    }
}

/// A trip's Map: the hero with its chips, and under it the trip's markers on the Places map — the
/// map, its sheet and its viewers being `PlacesMapStage`, the Places tab's own (MEMNG-719).
///
/// **One `PlacesStore` per Map, owned here.** The Places tab's store is that screen's private
/// state, keyed on the subject, and sharing it would mean hoisting it out of a screen this change
/// must not alter. Built when the Map is chosen and loaded then, so choosing Map reads the markers; dropped
/// with the Map, and keyed on the subject by `TripView`, so a change of account starts over with a
/// store of its own. An answer still in flight for the previous account lands in a store nothing
/// shows, and is refused anyway against the handle that presented it (`TripMapPresentation.reporting`).
///
/// **The membership is read live.** A picture excluded, or the trip deleted, takes its markers
/// off the map on the next body, and closes any sheet or viewer still holding one of them
/// (`PlacesPresenting.keep`): a deleted trip's membership is unknown again, so everything open
/// closes and the map waits while the screen leaves the stack.
struct TripMapScreen<Hero: View>: View {
    /// The trip as the screen draws it — the live record, or the snapshot on its way out.
    let record: CollectionRecord
    let trips: TripMembershipStore
    let access: () -> CollectionsAccess?
    /// Reads the trip's membership again, for Try Again after a drain that failed.
    let redrain: () async -> Void
    @ViewBuilder let hero: () -> Hero

    /// Optional: a test hosts the screen without a session.
    @Environment(SessionStore.self) private var session: SessionStore?
    @State private var places: PlacesStore?
    @State private var map = PlacesMapCoordinator()
    @State private var presenting = PlacesPresenting()
    /// A test's window onto what is open over the map; nil in the app.
    @Environment(\.placesStageProbe) private var probe

    var body: some View {
        let members = TripMapPresentation.memberUids(of: record, in: trips)
        let markers = TripMapPresentation.markers(places?.markers ?? [], of: members)
        let membership = trips.state(for: record)
        let status = TripMapPresentation.state(
            places: places?.status ?? .pending, membership: membership,
            membershipError: trips.lastError, shown: markers.count)
        VStack(spacing: 0) {
            hero()
            content(status, markers: markers, membership: membership)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .placesViewer($presenting.viewing)
        .onAppear { probe?.presenting = { presenting } }
        .onChange(of: TripMapPresentation.kept(markers, members: members)) { _, kept in
            presenting.keep(only: kept)
        }
        .task {
            if places == nil {
                let store = PlacesStore(onUnauthorized: { [session] refusal in
                    await session?.handle(refusal) ?? .superseded
                })
                places = TripMapPresentation.reporting(store, to: session)
            }
            await load()
        }
        .reloadsOnRecovery(session?.reachabilityRecoveries ?? 0) { await load() }
    }

    @ViewBuilder
    private func content(
        _ status: PlacesStatus, markers: [PlaceMarker], membership: TripMembershipState
    ) -> some View {
        switch status {
        case .pending:
            // Not the empty state: a trip whose membership or markers are still on their way has
            // not earned "no places".
            ProgressView()
        case .ready:
            PlacesMapStage(markers: markers, control: map, presenting: $presenting)
                .background {
                    Color.clear
                        .allowsHitTesting(false)
                        .accessibilityElement()
                        .accessibilityLabel(TripMapPresentation.mapLabel)
                        .accessibilityIdentifier(TripMapPresentation.mapIdentifier)
                }
        case .empty, .error:
            PlacesNoticeView(
                notice: notice(status, membership: membership), retry: retryAction(status))
        }
    }

    /// What the card says: the membership's failure when the trip could not be read, else the
    /// markers'.
    private func notice(_ status: PlacesStatus, membership: TripMembershipState)
        -> PlacesNotice?
    {
        let error = membership == .notLoaded ? trips.lastError : places?.lastError
        return TripMapPresentation.notice(for: status, error: error)
    }

    /// Try Again, offered on the error card only.
    private func retryAction(_ status: PlacesStatus) -> (@MainActor () async -> Void)? {
        guard status == .error else { return nil }
        return { await retry() }
    }

    private func load() async {
        guard let places, let access = access() else { return }
        await places.load(using: access.handle, baseURL: access.baseURL)
    }

    /// Try Again: the membership when it could not be read, and the markers.
    private func retry() async {
        if trips.state(for: record) == .notLoaded { await redrain() }
        await load()
    }
}

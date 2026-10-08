import MemosCore
import SwiftUI

/// The Collections tab's root (MEMNG-709, MEMNG-713), as the tab hosts it: the session's stores
/// handed to `CollectionsScreen`.
///
/// The collection and membership stores are the session's, built once by `MainTabView` and moved
/// to a new identity beside the timeline (`TimelineView`); this view only reads them. The tag
/// list is its own, as the Library's is. With no stores in the environment — a harness that hosts
/// the tabs without a session's — it draws the empty root with nothing it can do.
struct CollectionsRootView: View {
    @Environment(SessionStore.self) private var session: SessionStore?
    @Environment(CollectionStore.self) private var collections: CollectionStore?
    @Environment(TripMembershipStore.self) private var trips: TripMembershipStore?
    @Environment(LibraryTagJump.self) private var tagJump: LibraryTagJump?
    /// The Tags row's names and counts, every kind of file counted.
    @State private var tags: LibraryTagStore?

    var body: some View {
        NavigationStack {
            content
                // The app's main bar's room, inside the stack (MEMNG-690).
                .leadingFootBar(on: .collections)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let session, let collections, let trips, let tags {
            CollectionsScreen(
                collections: collections,
                trips: trips,
                tags: tags,
                subject: session.state.user?.subject,
                access: {
                    guard let handle = session.activeHandle, let baseURL = session.serverBaseURL
                    else { return nil }
                    return CollectionsAccess(handle: handle, baseURL: baseURL)
                },
                openTag: { tag in tagJump?.request(tag) }
            )
            .onChange(of: session.state.user?.subject) { tags.sessionIdentityChanged() }
        } else {
            CollectionsScreen.placeholder
                .task {
                    guard tags == nil, let session else { return }
                    let store = LibraryTagStore(
                        onUnauthorized: { [session] refusal in await session.handle(refusal) }
                    )
                    store.reports(to: session)
                    tags = store
                }
        }
    }
}

/// The Collections root: the trips as a row of cards, the tags as a row of chips, and `+` for a
/// new trip.
///
/// Everything it reads arrives as a value — the stores, and the session's means of reading as a
/// closure — so a test hosts it over a scripted transport without a session.
///
/// **Cards.** In `order`, each with its cover, title, span and count. The span and count are the
/// record's `lastSummary`, so a card renders before anything is read; the cover is the member that
/// summary names, once the membership has been drained here. Every trip on screen is drained when
/// the root appears and whenever the list of trips changes — `TripMembershipStore` joins a drain
/// already in flight, and writes a summary that changed back to the record.
struct CollectionsScreen: View {
    let collections: CollectionStore
    let trips: TripMembershipStore
    let tags: LibraryTagStore
    /// Whose root this is; a change reads it all again.
    let subject: String?
    /// The session's handle and server when a read is issued, or nil when there is none.
    let access: () -> CollectionsAccess?
    /// A tag chip was tapped: the Library opens narrowed to it.
    let openTag: (String) -> Void
    var now: () -> Date = { Date() }

    @State private var newTrip: NewTripFlow?
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    /// What the empty root says.
    static let emptyTitle = "No trips yet"
    /// What it says under that.
    static let emptyDetail = "Tap + to make a trip from one of your tags."
    /// The `+` button's name, read by VoiceOver.
    static let newTripButton = "New Trip"
    /// The trips' heading.
    static let tripsHeader = "Trips"
    /// The tags' heading.
    static let tagsHeader = "Tags"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Space.section) {
                if collections.records.isEmpty {
                    Self.emptyState
                } else {
                    tripsRow
                }
                if !tags.tags.isEmpty {
                    tagsRow
                }
            }
            .padding(.vertical, DesignTokens.Space.roomy)
        }
        // The whole screen, so the chrome around the root is laid out against the screen and not
        // against the content's own size (MEMNG-605).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tabRootTitle(MainTab.collections.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(Self.newTripButton, systemImage: "plus") { newTrip = NewTripFlow() }
            }
        }
        .sheet(item: $newTrip) { flow in
            NewTripSheet(
                flow: flow, collections: collections, trips: trips, access: access, now: now)
        }
        .task(id: subject) { await loadTags() }
        .task(id: DrainKey(subject: subject, ids: collections.records.map(\.id))) {
            await drainTrips()
        }
    }

    /// The root before the session's stores exist: the empty state and a `+` that cannot act.
    static var placeholder: some View {
        ScrollView { emptyState.padding(.vertical, DesignTokens.Space.roomy) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tabRootTitle(MainTab.collections.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(newTripButton, systemImage: "plus") {}
                        .disabled(true)
                }
            }
    }

    private static var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: MainTab.collections.symbol)
        } description: {
            Text(emptyDetail)
        }
    }

    private var tripsRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            Text(Self.tripsHeader)
                .font(.title2.bold())
                .padding(.horizontal, DesignTokens.Space.roomy)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: DesignTokens.Space.regular) {
                    ForEach(collections.records) { record in
                        TripCard(
                            record: record,
                            cover: CollectionsPresentation.cover(
                                of: record, members: trips.members(for: record)),
                            detail: CollectionsPresentation.cardDetail(
                                record.lastSummary, locale: locale, timeZone: timeZone)
                        )
                    }
                }
                .padding(.horizontal, DesignTokens.Space.roomy)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var tagsRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            Text(Self.tagsHeader)
                .font(.title2.bold())
                .padding(.horizontal, DesignTokens.Space.roomy)
            ScrollView(.horizontal) {
                LazyHStack(spacing: DesignTokens.Space.snug) {
                    ForEach(tags.tags) { tag in
                        TagChip(tag: tag) { openTag(tag.name) }
                    }
                }
                .padding(.horizontal, DesignTokens.Space.roomy)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func loadTags() async {
        guard let access = access() else { return }
        await tags.load(for: .all, using: access.handle)
    }

    /// Every trip's membership, one after another, in the order the cards stand.
    private func drainTrips() async {
        for record in collections.records {
            if Task.isCancelled { return }
            guard let access = access() else { return }
            await trips.drain(record, using: access.handle, baseURL: access.baseURL)
        }
    }

    private struct DrainKey: Equatable {
        let subject: String?
        let ids: [UUID]
    }
}

/// One trip: its cover, then its title, then its span and count.
struct TripCard: View {
    let record: CollectionRecord
    let cover: MemoAttachment?
    let detail: String?

    static let width: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.hair) {
            coverImage
                .frame(width: Self.width, height: Self.width)
                .clipShape(.rect(cornerRadius: DesignTokens.Radius.tile))
                .padding(.bottom, DesignTokens.Space.tight)
            Text(record.title)
                .font(.headline)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(record.title)
        .accessibilityValue(detail ?? "")
    }

    @ViewBuilder
    private var coverImage: some View {
        if let cover {
            AttachmentThumbnail(
                attachment: cover,
                tier: .thumb,
                slot: AttachmentSlot(aspectRatio: 1, contentMode: .fill)
            )
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "suitcase")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One tag: its name and how many files carry it. A tap opens the Library narrowed to it.
struct TagChip: View {
    let tag: LibraryTag
    let open: () -> Void

    /// What a chip says for `name`.
    static func label(_ name: String) -> String { "#\(name)" }

    var body: some View {
        Button(action: open) {
            HStack(spacing: DesignTokens.Space.tight) {
                Text(Self.label(tag.name))
                    .font(.subheadline.weight(.medium))
                Text("\(tag.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DesignTokens.Space.regular)
            .padding(.vertical, DesignTokens.Space.snug)
            .background(.quaternary, in: .capsule)
        }
        .buttonStyle(.plain)
        // As drawn, "#" included — which is also what tells it apart from the same tag's row on
        // the New trip sheet over it.
        .accessibilityLabel(Self.label(tag.name))
        .accessibilityValue(bucketCountLabel(tag.count))
    }
}

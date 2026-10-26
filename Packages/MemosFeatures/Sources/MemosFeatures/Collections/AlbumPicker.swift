import MemosCore
import SwiftUI

/// Add to Album (MEMNG-805): the album picker the select bar and the viewer open, and the one
/// sentence an add ends in. The bar's Add to Album replaced Show Selected (the owner, 2026-10-14).
///
/// Values of their inputs, as `AddToCollection` is, so a test reads the list and the sentence
/// without hosting the sheet.
enum AlbumPicker {
    /// The select bar's button, the viewer's menu row and the sheet's title.
    static let title = "Add to Album"
    /// The row at the top of the sheet, the Albums row's own card's words.
    static let newAlbum = NewAlbumCard.title
    /// The section of albums.
    static let albumsHeader = "Albums"

    /// The albums the sheet lists: the listed albums only — no trip, which is its tag and span —
    /// newest first, the uid breaking a tie so the order never moves between two drawings.
    static func albums(_ listed: [Trip]) -> [Trip] {
        listed.filter { $0.kind == .album }.sorted { left, right in
            left.createdAt == right.createdAt
                ? left.uid > right.uid : left.createdAt > right.createdAt
        }
    }

    /// New Album's flow: the new-collection sheet's Album path, already chosen, so it opens on the
    /// album's title (MEMNG-803) rather than asking Trip or Album.
    static func newAlbumFlow() -> NewTripFlow { NewTripFlow(kind: .album) }

    /// An album row's count line.
    static func countText(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    /// The one sentence an add ends in, summed over its chunks: "3 added, 1 already there", with
    /// what was answered but not added and what was never answered after it.
    static func sentence(_ outcome: AlbumAddOutcome) -> String {
        var parts = ["\(outcome.added.count) added"]
        if !outcome.alreadyMember.isEmpty {
            parts.append("\(outcome.alreadyMember.count) already there")
        }
        if !outcome.notAdded.isEmpty { parts.append("\(outcome.notAdded.count) not added") }
        if outcome.unanswered > 0 { parts.append("\(outcome.unanswered) failed") }
        return parts.joined(separator: ", ")
    }

    /// What an add that answered nothing says, or nil for one that lost its session.
    static func failureSentence(_ failure: TripStore.Failure) -> String? {
        switch failure {
        case .superseded: nil
        case .busy: "Another change to this album is still being saved."
        default: failure.errorDescription ?? "The pictures could not be added."
        }
    }
}

/// One Add to Album on a screen: which pictures the picker is up for, the add itself and the
/// sentence it ends in. The sentence goes to the screen's select banner when it has one (the
/// select bar), or is held here for the screen to show (the viewer).
@MainActor
@Observable
final class AlbumAddFlow {
    /// The pictures one opening of the picker offers, frozen when it opened.
    struct Picking: Identifiable {
        let id = UUID()
        let uids: [String]
    }

    /// The picker is up, for these pictures.
    var picking: Picking?
    /// The last add's sentence, when the screen has no banner to put it in.
    var message: String?
    /// Moved by `abandon`: an add that set out before has no screen left to speak to.
    private var run = 0
    private let banner: SelectBanner?

    init(banner: SelectBanner? = nil) {
        self.banner = banner
    }

    /// Opens the picker for `uids`; nothing opens for none.
    func open(_ uids: [String]) {
        guard !uids.isEmpty else { return }
        picking = Picking(uids: uids)
    }

    /// The picker's choice: the pictures go to `album` (`TripStore.addMembers`, which serialises
    /// the album's writes), and the outcome is said in one sentence.
    func add(
        _ uids: [String], to album: Trip, trips: TripStore, access: CollectionsAccess?
    ) async {
        guard let access, !uids.isEmpty else { return }
        let mine = run
        let text: String?
        do {
            let outcome = try await trips.addMembers(
                uids, to: album, using: access.handle, baseURL: access.baseURL)
            text = AlbumPicker.sentence(outcome)
        } catch let failure as TripStore.Failure {
            text = AlbumPicker.failureSentence(failure)
        } catch {
            text = nil
        }
        guard run == mine, let text else { return }
        if let banner {
            banner.publish(text, from: .action)
        } else {
            message = text
        }
    }

    /// The screen ended — select mode closed, the viewer went: the picker closes and an add still
    /// out finishes without a sentence.
    func abandon() {
        run += 1
        picking = nil
        message = nil
    }
}

/// The album picker: "New Album" at the top, then the albums newest first with cover and count.
/// A row hands its album to `choose` and closes the sheet; New Album runs the Album path of the
/// new-collection sheet and then hands the album it made to `choose`.
struct AlbumPickerSheet: View {
    let trips: TripStore
    /// Nil where the screen has no member store: no covers drawn, and no New Album offered.
    let members: TripMemberStore?
    let access: () -> CollectionsAccess?
    let choose: (Trip) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The new-collection sheet, up on Album.
    @State private var newAlbum: NewTripFlow?
    /// The flow that sheet ran, read once it is down.
    @State private var lastFlow: NewTripFlow?

    /// A row's cover side.
    static let coverSide: CGFloat = 44

    var body: some View {
        NavigationStack {
            List {
                if members != nil {
                    Section {
                        Button(AlbumPicker.newAlbum, systemImage: "plus") {
                            let flow = AlbumPicker.newAlbumFlow()
                            lastFlow = flow
                            newAlbum = flow
                        }
                    }
                }
                let albums = AlbumPicker.albums(trips.trips)
                if !albums.isEmpty {
                    Section(AlbumPicker.albumsHeader) {
                        ForEach(albums) { album in
                            Button {
                                choose(album)
                                dismiss()
                            } label: {
                                row(album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(AlbumPicker.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(item: $newAlbum, onDismiss: madeAlbum) { flow in
            if let members {
                NewTripSheet(flow: flow, trips: trips, members: members, access: access)
            }
        }
    }

    /// Back from the new-collection sheet: the album it made, if it made one, takes the pictures.
    private func madeAlbum() {
        guard let made = lastFlow?.created else { return }
        lastFlow = nil
        choose(made)
        dismiss()
    }

    private func row(_ album: Trip) -> some View {
        HStack(spacing: DesignTokens.Space.snug) {
            cover(album)
                .frame(width: Self.coverSide, height: Self.coverSide)
                .clipShape(.rect(cornerRadius: DesignTokens.Radius.card / 2))
            VStack(alignment: .leading) {
                Text(album.title).font(.body).lineLimit(1)
                Text(AlbumPicker.countText(album.memberCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func cover(_ album: Trip) -> some View {
        if let cover = CollectionsPresentation.cover(
            of: album, summary: members?.summary(for: album))
        {
            AttachmentThumbnail(
                attachment: cover, tier: .thumb,
                slot: AttachmentSlot(aspectRatio: 1, contentMode: .fill))
        } else {
            Rectangle().fill(.quaternary)
        }
    }
}

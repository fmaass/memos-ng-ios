import MemosCore
import SwiftUI

/// Select mode's Add on the Library (MEMNG-855): one row in the actions menu, in the slot the Add
/// to trip submenu held, that opens the Add to collection sheet. The sheet lists the collections
/// the chosen pictures can go to, one section per kind, and a row sends them to its collection in
/// one inclusion, as the submenu's trip rows did.
///
/// Trips alone for now: an album's member route is live on the server only from memos-ng v2.6.0,
/// and this app vendors v2.5.0, so the album section joins as a second `Kind` with WPN-29.
///
/// Functions of their inputs, as `MediaLibraryView.selectRows` is, so a test reads the rows and
/// what a row sends without hosting the sheet.
enum AddToCollection {
    /// The actions menu's row.
    static let addRowTitle = "Add"
    /// The sheet's title.
    static let sheetTitle = "Add to collection"
    /// The trips' section.
    static let tripsHeader = "Trips"

    /// A kind of collection the sheet lists, one section each, in this order.
    enum Kind: Hashable {
        case trips
    }

    /// Where a row sends the chosen pictures.
    enum Target: Equatable {
        case trip(Trip)
    }

    /// One collection the sheet offers.
    struct Row: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        /// Drawn but taking no press, under the same rules as the Add row itself.
        let disabled: Bool
        let target: Target
    }

    /// One kind's section of the sheet.
    struct SheetSection: Identifiable {
        let kind: Kind
        let header: String
        let rows: [Row]
        var id: Kind { kind }
    }

    /// The actions menu's Add row: drawn disabled while none of the chosen pictures is on a memo
    /// of mine (`memos` empty), the actions are not `free`, or no trip is `tagged` — the rules the
    /// Add to trip submenu was drawn under (MEMNG-788).
    static func addRow(
        memos: [String], free: Bool, tagged: [Trip], open: @escaping () -> Void
    ) -> SelectAction {
        SelectAction(
            id: "add", title: addRowTitle, systemImage: "plus",
            disabled: !free || memos.isEmpty || tagged.isEmpty, action: open)
    }

    /// The sheet's sections: the `tagged` trips under Trips, each disabled under the Add row's own
    /// rules, and no section for a kind with nothing to offer.
    static func sections(memos: [String], free: Bool, tagged: [Trip]) -> [SheetSection] {
        let off = !free || memos.isEmpty
        let trips = tagged.map { trip in
            Row(
                id: "add-to-\(trip.uid)", title: trip.title, systemImage: "suitcase",
                disabled: off, target: .trip(trip))
        }
        guard !trips.isEmpty else { return [] }
        return [SheetSection(kind: .trips, header: tripsHeader, rows: trips)]
    }

    /// What a row sends: the chosen pictures to its trip in ONE inclusion request
    /// (`MemoActionStore.add`), which keeps the caller's pictures on a memo and nothing else.
    static func send(
        _ target: Target, chosen: [MemoActionPicture], actions: MemoActionStore,
        using handle: SessionHandle, baseURL: URL
    ) async -> MemoActionResult {
        switch target {
        case .trip(let trip):
            return await actions.add(
                attachments: chosen, toTrip: trip, using: handle, baseURL: baseURL)
        }
    }
}

/// The Add to collection sheet: a section per kind of collection, a row per collection. A row
/// hands its target to `choose` and closes the sheet; the screen's banner reports the outcome.
struct AddToCollectionSheet: View {
    let sections: [AddToCollection.SheetSection]
    let choose: (AddToCollection.Target) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections) { section in
                    Section(section.header) {
                        ForEach(section.rows) { row in
                            Button(row.title, systemImage: row.systemImage) {
                                choose(row.target)
                                dismiss()
                            }
                            .disabled(row.disabled)
                        }
                    }
                }
            }
            .navigationTitle(AddToCollection.sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

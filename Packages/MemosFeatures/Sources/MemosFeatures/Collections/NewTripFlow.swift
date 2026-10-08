import Foundation
import MemosCore
import Observation

/// One opening of the New trip sheet: the tag chosen, the title being written, and how Create
/// ended.
///
/// **Create is read back, never trusted.** `CollectionStore.create` hands back a record whether or
/// not it reached the file — with nobody signed in, or a write that failed, the record exists
/// nowhere else. So the flow looks for it in `records`, the list the file says, and only a record
/// found there closes the sheet; anything else keeps the sheet open with `failure` said under it.
///
/// **One trip per sheet, refused after.** A second Create after one that succeeded is refused, not
/// sent: the store runs two calls one after the other and would file two trips. A Create that
/// failed may be pressed again — nothing of it exists to duplicate.
@MainActor
@Observable
final class NewTripFlow: Identifiable {
    /// The tag the trip is made of, or nil before one is chosen.
    private(set) var chosenTag: String?
    /// The title field, prefilled from the chosen tag.
    var title = ""
    /// Why the last Create did not file a trip, or nil.
    private(set) var failure: String?
    /// The trip this sheet filed, once it has.
    private(set) var created: CollectionRecord?

    /// What the sheet says when the record is not in the store after Create.
    static let notSaved = "The trip could not be saved on this device. Try again."

    /// The suggestion the title field was last filled with, so a title somebody typed survives
    /// choosing another tag and one they left alone follows it.
    @ObservationIgnored private var suggestedTitle = ""

    nonisolated let id = UUID()

    init() {}

    /// Chooses `tag`, and fills the title from it unless somebody has written their own.
    func choose(_ tag: String) {
        chosenTag = tag
        failure = nil
        if title.isEmpty || title == suggestedTitle {
            suggestedTitle = TripTitle.suggest(tag)
            title = suggestedTitle
        }
    }

    /// The title as it will be filed: trimmed.
    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether Create has anything to file.
    var canCreate: Bool { chosenTag != nil && !trimmedTitle.isEmpty && created == nil }

    /// Files the trip in `store` and answers it, or nil when nothing was filed — refused, or not
    /// found in the store afterwards (`failure` then says so).
    @discardableResult
    func create(in store: CollectionStore) -> CollectionRecord? {
        guard created == nil, let tag = chosenTag, !trimmedTitle.isEmpty else { return nil }
        let record = store.create(title: trimmedTitle, tags: [tag])
        guard let filed = store.records.first(where: { $0.id == record.id }) else {
            failure = Self.notSaved
            return nil
        }
        failure = nil
        created = filed
        return filed
    }
}

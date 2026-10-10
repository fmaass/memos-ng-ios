import MemosCore
import SwiftUI

/// A trip's window in time as a sheet edits it: two instants and the zone they are read in.
///
/// **To the minute.** The pickers choose a day and a minute, so what is written is the start's
/// minute from its first second and the end's minute to its last: "until 14:00" keeps a picture
/// taken at 14:00:30 and drops one taken at 14:01. A span set by its days alone therefore runs from
/// 00:00:00 of the first to 23:59:59 of the last (`TripSpan.days`), and the wheels then move either
/// end within its day.
///
/// **An end before the start is refused.** `span` is nil then: the sheet says why and Save is off,
/// and nothing is written.
struct TripSpanDraft: Equatable {
    var start: Date
    var end: Date
    var zone: TimeZone

    init(start: Date, end: Date, zone: TimeZone) {
        self.start = start
        self.end = end
        self.zone = zone
    }

    init(_ span: TripSpan) {
        self.init(start: span.start, end: span.end, zone: span.timeZone)
    }

    /// The whole days from `first`'s to `last`'s in `zone`, or nil when `last` is earlier.
    static func days(from first: Date, to last: Date, in zone: TimeZone) -> TripSpanDraft? {
        TripSpan.days(from: first, to: last, in: zone).map(TripSpanDraft.init)
    }

    /// What Save writes, or nil when the end lies before the start.
    var span: TripSpan? {
        let first = minute(of: start)
        let last = minute(of: end).addingTimeInterval(59)
        guard last >= first else { return nil }
        return TripSpan(start: first, end: last, zone: zone.identifier)
    }

    /// Another zone, the same wall clock: 14:00 chosen in Berlin is 14:00 in Lisbon once the
    /// zone is Lisbon, never 13:00.
    mutating func move(to zone: TimeZone) {
        start = Self.rezone(start, from: self.zone, to: zone)
        end = Self.rezone(end, from: self.zone, to: zone)
        self.zone = zone
    }

    /// Writes the span to the trip, and answers whether the record now holds it.
    @discardableResult
    func save(to collections: CollectionStore, id: UUID) -> Bool {
        guard let span else { return false }
        collections.setSpan(id: id, span)
        return collections.records.first { $0.id == id }?.span == span
    }

    private func minute(of date: Date) -> Date {
        calendar(zone).dateInterval(of: .minute, for: date)?.start ?? date
    }

    private static func rezone(_ date: Date, from: TimeZone, to: TimeZone) -> Date {
        let wall = calendar(from).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return calendar(to).date(from: wall) ?? date
    }
}

private func calendar(_ zone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
}

/// The From, To and Time Zone rows of a span, shown in its own zone — on the Trip Dates sheet and
/// on the New trip sheet alike.
struct TripSpanFields: View {
    @Binding var draft: TripSpanDraft

    static let fromLabel = "From"
    static let toLabel = "To"
    static let zoneLabel = "Time Zone"
    /// What stands under the rows while the end lies before the start.
    static let backward = "The end is before the start."

    var body: some View {
        Group {
            DatePicker(
                Self.fromLabel, selection: $draft.start,
                displayedComponents: [.date, .hourAndMinute])
            DatePicker(
                Self.toLabel, selection: $draft.end, displayedComponents: [.date, .hourAndMinute])
            Picker(Self.zoneLabel, selection: zone) {
                ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.navigationLink)
            if draft.span == nil {
                Text(Self.backward)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .environment(\.timeZone, draft.zone)
    }

    private var zone: Binding<String> {
        Binding(
            get: { draft.zone.identifier },
            set: { identifier in
                guard let zone = TimeZone(identifier: identifier) else { return }
                draft.move(to: zone)
            }
        )
    }
}

/// Trip Dates, from the trip's Manage menu (MEMNG-737): the trip's span, edited and saved, or
/// taken away from a trip that keeps its tag.
///
/// A trip without a span opens on the days its pictures span (`lastSummary`), else on the day it
/// is opened, in the device's zone.
struct TripSpanSheet: View {
    let record: CollectionRecord
    let collections: CollectionStore
    @State private var draft: TripSpanDraft
    @Environment(\.dismiss) private var dismiss
    /// Why the last Save or Remove Dates did not reach the trip, or nil.
    @State private var failure: String?

    static let title = "Trip Dates"
    static let save = "Save"
    static let removeDates = "Remove Dates"
    /// What the sheet says when a write did not reach the device: the New trip sheet's sentence.
    static let notSaved = NewTripFlow.notSaved

    init(record: CollectionRecord, collections: CollectionStore, now: Date = Date()) {
        self.record = record
        self.collections = collections
        _draft = State(initialValue: Self.opening(record, now: now, zone: .current))
    }

    /// What the sheet opens on.
    static func opening(_ record: CollectionRecord, now: Date, zone: TimeZone) -> TripSpanDraft {
        if let span = record.span { return TripSpanDraft(span) }
        let first = record.lastSummary?.firstTaken ?? now
        let last = record.lastSummary?.lastTaken ?? first
        return TripSpanDraft.days(from: first, to: max(first, last), in: zone)
            ?? TripSpanDraft(start: now, end: now, zone: zone)
    }

    /// Takes the span off the trip, and answers whether the record, read back, holds none.
    static func removeDates(of id: UUID, in collections: CollectionStore) -> Bool {
        collections.setSpan(id: id, nil)
        return collections.records.first { $0.id == id }?.span == nil
    }

    /// Closes the sheet on a write the trip holds; keeps it, saying so, on one it does not.
    private func finish(_ saved: Bool) {
        if saved {
            dismiss()
        } else {
            failure = Self.notSaved
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { TripSpanFields(draft: $draft) }
                if let failure {
                    Section { Text(failure).foregroundStyle(.red) }
                }
                // Without its tag a trip with no span would have no rule left at all.
                if record.span != nil, !record.tags.isEmpty {
                    Section {
                        Button(Self.removeDates, role: .destructive) {
                            finish(Self.removeDates(of: record.id, in: collections))
                        }
                    }
                }
            }
            .navigationTitle(Self.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Self.save) {
                        finish(draft.save(to: collections, id: record.id))
                    }
                    .disabled(draft.span == nil)
                }
            }
        }
    }
}

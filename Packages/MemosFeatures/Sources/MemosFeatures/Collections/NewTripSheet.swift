import MemosCore
import SwiftUI

/// The signed-in session's means of reading, as one value: the handle a read is issued under and
/// the server its relative URLs resolve against.
struct CollectionsAccess {
    let handle: SessionHandle
    let baseURL: URL
}

/// Making a trip from a tag: every tag with its picture count and span, the tags that look like a
/// trip under `Suggested`, a title prefilled from the chosen tag, its dates prefilled from the
/// tag's pictures (`NewTripFlow.prefill`) and editable as on Trip Dates, and Create.
///
/// The counts and spans are `TripMemberStore`'s sheet reads — one count read for every tag,
/// then a span read per tag, in the server's order — and each row fills in as its answer arrives.
/// A tag already read under this session is not read again.
struct NewTripSheet: View {
    @Bindable var flow: NewTripFlow
    let trips: TripStore
    let members: TripMemberStore
    /// The session's handle and server when a read is issued, or nil when there is none.
    let access: () -> CollectionsAccess?
    /// The clock `Suggested` is judged against.
    var now: () -> Date = { Date() }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    /// The title field's name, read by VoiceOver.
    static let titleField = "Trip title"
    /// The section of tags that look like a trip.
    static let suggestedHeader = "Suggested"
    /// The section of every tag.
    static let allTagsHeader = "All tags"
    /// The confirming button.
    static let create = "Create"
    /// What stands in its place while Create is out, read by VoiceOver.
    static let creating = "Creating"
    /// The section of the trip's span.
    static let datesHeader = "Dates"
    static let addDates = "Add Dates"
    static let removeDates = "No Dates"
    /// What the Dates section says while the chosen tag's dates are read.
    static let readingDates = "Reading the tag's dates…"
    /// What the sheet says while no tag has a picture.
    static let noTags = "No tag has a photo yet. Tag a memo's photos to make a trip of them."
    /// The identifier a suggested row carries, so a test can tell it from the same tag's row in
    /// the full list.
    static func suggestedRowID(_ tag: String) -> String { "new-trip-suggested-\(tag)" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(Self.titleField, text: $flow.title)
                        .accessibilityLabel(Self.titleField)
                    if let failure = flow.failure {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Section(Self.datesHeader) {
                    if let span = flow.span {
                        TripSpanFields(
                            draft: Binding(get: { flow.span ?? span }, set: { flow.span = $0 }))
                        if flow.chosenTag != nil {
                            Button(Self.removeDates) { flow.removeDates() }
                        }
                    } else if flow.awaitingDates {
                        HStack {
                            Text(Self.readingDates).foregroundStyle(.secondary)
                            Spacer()
                            ProgressView()
                        }
                        Button(Self.removeDates) { flow.removeDates() }
                    } else {
                        Button(Self.addDates) { flow.addDates(now: now(), zone: timeZone) }
                    }
                }
                if let error = members.lastError {
                    Section { NoticeCard(text: error, tone: .error) }
                }
                let tags = members.tagCounts.filter { $0.count > 0 }
                let suggested = CollectionsPresentation.suggested(
                    tags, spans: members.spans, now: now())
                if !suggested.isEmpty {
                    Section(Self.suggestedHeader) {
                        ForEach(suggested) { tag in
                            row(tag).accessibilityIdentifier(Self.suggestedRowID(tag.name))
                        }
                    }
                }
                Section(Self.allTagsHeader) {
                    if tags.isEmpty, members.tagCountsLoaded {
                        Text(Self.noTags).foregroundStyle(.secondary)
                    }
                    ForEach(tags) { tag in row(tag) }
                }
            }
            .navigationTitle("New Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if flow.isCreating {
                        ProgressView().accessibilityLabel(Self.creating)
                    } else {
                        Button(Self.create) {
                            let access = access()
                            Task {
                                if await flow.create(in: trips, using: access) != nil
                                    || flow.abandoned
                                {
                                    dismiss()
                                }
                            }
                        }
                        .disabled(!flow.canCreate)
                    }
                }
            }
        }
        .task { await load() }
        // Somebody else's session now: the sheet closes, and nothing is sent for them.
        .onChange(of: trips.identity) {
            flow.abandon()
            dismiss()
        }
        // The chosen tag's dates are read at once, ahead of the other tags'.
        .task(id: flow.chosenTag) { await readChosenDates() }
        // A tag chosen before its span arrived takes the span once it does.
        .onChange(of: flow.chosenTag.flatMap { members.spans[$0] }) { _, span in
            guard let tag = flow.chosenTag else { return }
            flow.prefill(span, of: tag, zone: timeZone)
        }
    }

    private func row(_ tag: LibraryTag) -> some View {
        Button {
            flow.choose(tag.name, span: members.spans[tag.name], zone: timeZone)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: DesignTokens.Space.hair) {
                    Text(tag.name)
                        .foregroundStyle(.primary)
                    Text(detail(tag))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if flow.chosenTag == tag.name {
                    Image(systemName: "checkmark")
                        .foregroundStyle(DesignTokens.accent)
                }
            }
        }
        .accessibilityLabel(tag.name)
        .accessibilityValue(detail(tag))
        .accessibilityAddTraits(flow.chosenTag == tag.name ? .isSelected : [])
    }

    private func detail(_ tag: LibraryTag) -> String {
        CollectionsPresentation.tagDetail(
            count: tag.count, span: members.spans[tag.name], locale: locale, timeZone: timeZone)
    }

    /// The chosen tag's dates: read, or joined when the sweep is already reading them, so this
    /// returns only once that read has ended. Then they are prefilled and Create stops waiting —
    /// whatever the read's outcome, and only for this tag.
    private func readChosenDates() async {
        guard let tag = flow.chosenTag else { return }
        if members.spans[tag] == nil, let access = access() {
            await members.loadSpan(ofTag: tag, using: access.handle, baseURL: access.baseURL)
        }
        flow.prefill(members.spans[tag], of: tag, zone: timeZone)
        flow.endDatesRead(of: tag)
    }

    /// The counts, then the span of every tag not yet read under this session, one at a time.
    private func load() async {
        guard let access = access() else { return }
        await members.loadTagCounts(using: access.handle)
        for tag in members.tagCounts where tag.count > 0 && members.spans[tag.name] == nil {
            if Task.isCancelled { return }
            guard let current = self.access(), current.handle.generation == access.handle.generation
            else { return }
            await members.loadSpan(ofTag: tag.name, using: current.handle, baseURL: current.baseURL)
        }
    }
}

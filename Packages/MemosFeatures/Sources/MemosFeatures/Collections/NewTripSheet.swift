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
///
/// A tag a listed trip is made of is not offered (decision H, as on the root): it is that trip's.
/// While the list of trips is unread or failed nothing is left out, and a chosen tag that becomes
/// a trip's while the sheet is up is no longer chosen (`NewTripFlow.drop`).
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
    /// What the sheet says while every tag with a picture is already a trip's.
    static let everyTagIsATrip =
        "Every tag with a photo is already a trip. Tag a memo's photos to make another."
    /// The first step's two choices, and what each says under its name.
    static let tripChoice = "Trip"
    static let tripChoiceDetail = "The photos of a tag or of a span of days"
    static let albumChoice = "Album"
    static let albumChoiceDetail = "No dates: the photos you add to it one by one"
    /// The Album path's title field, read by VoiceOver.
    static let albumTitleField = "Album title"
    /// The identifier a suggested row carries, so a test can tell it from the same tag's row in
    /// the full list.
    static func suggestedRowID(_ tag: String) -> String { "new-trip-suggested-\(tag)" }

    var body: some View {
        NavigationStack {
            Group {
                switch flow.kind {
                case nil: question
                case .album?: albumForm
                case .trip?: tripForm
                }
            }
            .navigationTitle(Self.navigationTitle(flow.kind))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if flow.kind != nil {
                    ToolbarItem(placement: .confirmationAction) { confirm }
                }
            }
        }
        // An album offers no tag: nothing is read for one.
        .task(id: flow.kind != .album) {
            if flow.kind != .album { await load() }
        }
        // Somebody else's session now: the sheet closes, and nothing is sent for them.
        .onChange(of: trips.identity) {
            flow.abandon()
            dismiss()
        }
        // A tag that became a trip's is no longer a choice.
        .onChange(of: tripTags, initial: true) { _, excluded in flow.drop(excluded) }
        // The chosen tag's dates are read at once, ahead of the other tags'.
        .task(id: flow.chosenTag) { await readChosenDates() }
        // A tag chosen before its span arrived takes the span once it does.
        .onChange(of: flow.chosenTag.flatMap { members.spans[$0] }) { _, span in
            guard let tag = flow.chosenTag else { return }
            flow.prefill(span, of: tag, zone: timeZone)
        }
    }

    /// The bar's title over each step.
    static func navigationTitle(_ kind: Trip.Kind?) -> String {
        switch kind {
        case nil: "New Collection"
        case .trip?: "New Trip"
        case .album?: "New Album"
        }
    }

    /// The first step: Trip or Album, as two large choices.
    private var question: some View {
        VStack(spacing: DesignTokens.Space.regular) {
            choice(.trip, title: Self.tripChoice, detail: Self.tripChoiceDetail, symbol: "suitcase")
            choice(
                .album, title: Self.albumChoice, detail: Self.albumChoiceDetail,
                symbol: "rectangle.stack")
            Spacer()
        }
        .padding(DesignTokens.Space.roomy)
    }

    private func choice(
        _ kind: Trip.Kind, title: String, detail: String, symbol: String
    ) -> some View {
        Button {
            flow.choose(kind: kind)
        } label: {
            HStack(spacing: DesignTokens.Space.regular) {
                Image(systemName: symbol)
                    .font(.title)
                    .foregroundStyle(DesignTokens.accent)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: DesignTokens.Space.hair) {
                    Text(title).font(.title3.bold()).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(DesignTokens.Space.roomy)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .background(.quaternary, in: .rect(cornerRadius: DesignTokens.Radius.card))
        }
        .buttonStyle(.plain)
        // On the Button itself, so the element VoiceOver activates is the one that runs it.
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }

    /// The Album path: a title and Create — no tag, no dates.
    private var albumForm: some View {
        Form {
            Section {
                TextField(Self.albumTitleField, text: $flow.title)
                    .accessibilityLabel(Self.albumTitleField)
                if let failure = flow.failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// The Trip path, as it was before the question.
    private var tripForm: some View {
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
            let pictured = members.tagCounts.filter { $0.count > 0 }
            let tags = CollectionsPresentation.tags(pictured, excluding: tripTags)
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
                    Text(pictured.isEmpty ? Self.noTags : Self.everyTagIsATrip)
                        .foregroundStyle(.secondary)
                }
                ForEach(tags) { tag in row(tag) }
            }
        }
    }

    @ViewBuilder
    private var confirm: some View {
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

    /// The tags the listed trips are made of, left out of every list on the sheet.
    private var tripTags: Set<String> {
        CollectionsPresentation.tripTags(trips.trips, listFailed: trips.lastError != nil)
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

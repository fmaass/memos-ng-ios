import MemosCore
import SwiftUI

/// The signed-in session's means of reading, as one value: the handle a read is issued under and
/// the server its relative URLs resolve against.
struct CollectionsAccess {
    let handle: SessionHandle
    let baseURL: URL
}

/// Making a trip from a tag: every tag with its picture count and span, the tags that look like a
/// trip under `Suggested`, a title prefilled from the chosen tag, and Create.
///
/// The counts and spans are `TripMembershipStore`'s sheet reads — one count read for every tag,
/// then a span read per tag, in the server's order — and each row fills in as its answer arrives.
/// A tag already read under this session is not read again.
struct NewTripSheet: View {
    @Bindable var flow: NewTripFlow
    let collections: CollectionStore
    let trips: TripMembershipStore
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
                if let error = trips.lastError {
                    Section { NoticeCard(text: error, tone: .error) }
                }
                let tags = trips.tagCounts.filter { $0.count > 0 }
                let suggested = CollectionsPresentation.suggested(
                    tags, spans: trips.spans, now: now())
                if !suggested.isEmpty {
                    Section(Self.suggestedHeader) {
                        ForEach(suggested) { tag in
                            row(tag).accessibilityIdentifier(Self.suggestedRowID(tag.name))
                        }
                    }
                }
                Section(Self.allTagsHeader) {
                    if tags.isEmpty, trips.tagCountsLoaded {
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
                    Button(Self.create) {
                        if flow.create(in: collections) != nil { dismiss() }
                    }
                    .disabled(!flow.canCreate)
                }
            }
        }
        .task { await load() }
    }

    private func row(_ tag: LibraryTag) -> some View {
        Button {
            flow.choose(tag.name)
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
            count: tag.count, span: trips.spans[tag.name], locale: locale, timeZone: timeZone)
    }

    /// The counts, then the span of every tag not yet read under this session, one at a time.
    private func load() async {
        guard let access = access() else { return }
        await trips.loadTagCounts(using: access.handle)
        for tag in trips.tagCounts where tag.count > 0 && trips.spans[tag.name] == nil {
            if Task.isCancelled { return }
            guard let current = self.access(), current.handle.generation == access.handle.generation
            else { return }
            await trips.loadSpan(ofTag: tag.name, using: current.handle, baseURL: current.baseURL)
        }
    }
}

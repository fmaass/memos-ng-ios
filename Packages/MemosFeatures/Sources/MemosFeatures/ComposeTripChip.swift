import Foundation
import MemosCore
import SwiftUI

/// The trip a new memo is offered while one is pinned: the title the chip shows and the tag the
/// memo is given.
///
/// A VALUE handed into the sheet by whoever presents it, decided once from the store when the
/// sheet is built. The sheet reads neither a clock nor the store: the pin is read at the instant
/// the capture is opened, and a test builds the offer it wants instead of a store and a date.
public struct ComposePinnedTrip: Equatable, Sendable {
    public var title: String
    public var tag: String

    public init(title: String, tag: String) {
        self.title = title
        self.tag = tag
    }

    /// The record's offer — its title and its FIRST tag — or nil for a record with no tag, which
    /// has nothing to add to a memo.
    public init?(record: CollectionRecord) {
        guard let tag = record.tags.first, !tag.isEmpty else { return nil }
        self.init(title: record.title, tag: tag)
    }

    /// What a new memo opened at `now` is offered: the trip pinned at that instant
    /// (`CollectionStore.activePin(now:)`, which treats a pin ending exactly at `now` as over), or
    /// nothing — with no store, no pin, an expired pin or a pinned record without a tag alike.
    public static func offered(by store: CollectionStore?, now: Date) -> ComposePinnedTrip? {
        store?.activePin(now: now).flatMap(ComposePinnedTrip.init(record:))
    }
}

/// The chip one compose sheet shows, and what it does to the words that are posted.
///
/// Only a NEW memo gets one: the pin is for captures, and an edit is never offered it whatever it
/// was handed. The ✕ is this sheet's alone — it is state of the sheet, so a new sheet with the
/// same pin starts with the chip back, and the pin itself is never written.
///
/// The tag is added to the SUBMISSION, never to the editor: the words on screen stay what was
/// typed, and a post that failed and is tried again builds its content afresh from them — the
/// line cannot be added twice, and `appendingPinnedTag` leaves a text already carrying the tag
/// (a restored capture, or a writer who typed it) exactly as it is.
struct ComposeTripChip: Equatable {
    private let trip: ComposePinnedTrip?
    private(set) var isDismissed = false

    init(mode: ComposeView.Mode, offered: ComposePinnedTrip?) {
        if case .create = mode {
            trip = offered
        } else {
            trip = nil
        }
    }

    /// The trip the chip shows, or nil when there is no chip.
    var shown: ComposePinnedTrip? { isDismissed ? nil : trip }

    /// The ✕: no chip and no tag for the rest of this sheet.
    mutating func dismiss() { isDismissed = true }

    /// The content a Post sends for `text`, the editor's words as they stand.
    func submittedContent(_ text: String) -> String {
        guard let shown else { return text }
        return appendingPinnedTag(shown.tag, to: text)
    }
}

/// The visibility one compose sheet posts with, and whether the pin or the person put it there.
///
/// A trip post is for the two of us and never for the digest, so a NEW memo opened while a trip
/// is offered starts on "Just us" (protected) instead of the account default. The account default
/// itself stays what it is: most posts are not trip posts. That start is the pin's SUGGESTION and
/// it is kept apart from a CHOICE — the chip's ✕ takes an untouched suggestion back to the account
/// default along with the tag, but once the person has set the pill, to anything, "Default"
/// included, it is theirs and nothing the chip does overrides it.
///
/// Only a fresh capture is preselected. An edit states no visibility at all — who sees a memo is
/// changed on purpose, never as a side effect of a pin — and a restored capture keeps the one it
/// was stopped with, which was decided when it was first written.
struct ComposeVisibilityPick: Equatable {
    /// What the post states, or nil for the account default.
    private(set) var selection: MemoVisibility?
    /// Whether `selection` is still the pin's suggestion rather than the person's choice.
    private(set) var isSuggested = false

    init(mode: ComposeView.Mode, offered: ComposePinnedTrip?) {
        switch mode {
        case .create(.some(let restored)):
            selection = restored.visibility
        case .create(.none):
            if offered != nil {
                selection = .protected
                isSuggested = true
            }
        case .edit:
            selection = nil
        }
    }

    /// What the pill shows and writes. Every write is the person choosing.
    var chosen: MemoVisibility? {
        get { selection }
        set {
            selection = newValue
            isSuggested = false
        }
    }

    /// The chip's ✕: a suggestion nobody touched goes back to the account default; a choice stays.
    mutating func tripRemoved() {
        guard isSuggested else { return }
        selection = nil
        isSuggested = false
    }
}

/// The chip itself: the pinned trip's title and the ✕ that leaves its tag off this memo.
struct ComposeTripChipView: View {
    let trip: ComposePinnedTrip
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Space.tight) {
            Image(systemName: "pin.fill")
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(trip.title)
                .lineLimit(1)
                .accessibilityLabel("Pinned trip, \(trip.title)")
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove trip tag")
        }
        .font(.subheadline)
        .foregroundStyle(DesignTokens.accent)
        .padding(.horizontal, DesignTokens.Space.regular)
        .padding(.vertical, DesignTokens.Space.tight)
        .background(DesignTokens.accent.opacity(0.12), in: Capsule())
    }
}

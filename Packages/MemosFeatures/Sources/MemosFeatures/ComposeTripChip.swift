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

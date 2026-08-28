import Foundation
import MemosCore
import SwiftUI
import Testing

@testable import MemosFeatures

/// The archive, as somebody meets it: a control on the memo's own screen, and a memo that says it
/// is archived wherever it turns up.
///
/// The projection and the screen are both held here on purpose. A rule that says "offer Restore on
/// an archived memo" proves nothing if no screen asks it, and this affordance did not exist at all
/// until now — so "it is really on the screen" is the part worth keeping.
@MainActor
@Suite("Archive affordance")
struct ArchiveAffordanceTests {
    private let archivedAt = Date(timeIntervalSince1970: 1_756_000_000)

    private func detail(_ memo: Memo) -> some View {
        MemoDetailView(uid: memo.uid, initial: memo, timeline: TimelineStore())
    }

    @Test("an active memo of mine offers to archive it")
    func activeMemoOffersArchive() {
        let action = MemoDetailPresentation.archiveAction(for: MemoFixture.memo(uid: "m1"))

        #expect(action?.archived == true)
        #expect(action?.title == "Archive memo")
    }

    @Test("an archived memo of mine offers to restore it")
    func archivedMemoOffersRestore() {
        let action = MemoDetailPresentation.archiveAction(
            for: MemoFixture.memo(uid: "m1", archivedAt: archivedAt)
        )

        // The direction is derived from the memo, so no screen can offer to archive something
        // that is already archived — which is a request the server would answer by doing nothing.
        #expect(action?.archived == false)
        #expect(action?.title == "Restore memo")
    }

    @Test("someone else's memo offers no archive at all")
    func notMineOffersNothing() {
        #expect(MemoDetailPresentation.archiveAction(for: MemoFixture.memo(mine: false)) == nil)
        #expect(
            MemoDetailPresentation.archiveAction(
                for: MemoFixture.memo(mine: false, archivedAt: archivedAt)
            ) == nil
        )
    }

    @Test("my own memo's screen really shows the Archive button")
    func ownMemoShowsArchive() {
        let memo = MemoFixture.memo(uid: "m1", content: "the boiler man comes Thursday")
        let labels = ScreenProbe.labels(of: detail(memo))

        // The positive control: without it, the absence of "Archive memo" would only prove that
        // the probe saw nothing whatsoever.
        #expect(
            labels.contains { $0.contains("the boiler man") },
            "the probe found nothing of the memo itself: \(labels)"
        )
        #expect(labels.contains("Archive memo"), "no archive affordance on the screen: \(labels)")
        #expect(!labels.contains("Restore memo"))
    }

    @Test("an archived memo's screen offers Restore and says it is archived")
    func archivedMemoScreenSaysSo() {
        let memo = MemoFixture.memo(
            uid: "m2", content: "the boiler man comes Thursday", archivedAt: archivedAt
        )
        let labels = ScreenProbe.labels(of: detail(memo))

        #expect(labels.contains { $0.contains("the boiler man") })
        #expect(labels.contains("Restore memo"), "no restore affordance on the screen: \(labels)")
        #expect(labels.contains("Archived"), "the screen does not say the memo is archived")
    }

    @Test("someone else's memo's screen shows no archive control")
    func otherMemoShowsNoArchive() {
        let memo = MemoFixture.memo(
            uid: "m3", content: "the boiler man comes Thursday", mine: false
        )
        let labels = ScreenProbe.labels(of: detail(memo))

        #expect(labels.contains { $0.contains("the boiler man") })
        #expect(!labels.contains("Archive memo"))
        #expect(!labels.contains("Restore memo"))
    }

    @Test("the card of an archived memo says so, and an active one does not")
    func theCardSaysArchived() {
        let archived = ScreenProbe.labels(
            of: MemoCard(memo: MemoFixture.memo(uid: "m4", archivedAt: archivedAt))
        )
        let active = ScreenProbe.labels(of: MemoCard(memo: MemoFixture.memo(uid: "m5")))

        // A card combines its children into one element, so the word arrives inside the combined
        // label rather than as one of its own.
        #expect(
            archived.contains { $0.contains("Archived") },
            "an archived memo's card gives no sign of it: \(archived)"
        )
        #expect(!active.contains { $0.contains("Archived") })
    }
}

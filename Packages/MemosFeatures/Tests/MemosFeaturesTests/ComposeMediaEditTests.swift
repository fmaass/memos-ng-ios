import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// A save the test can read back — the same shape `MemoEditWiringTests` uses, kept local so the
/// two suites cannot come to disagree about what a recorder is.
@MainActor
private final class MediaSubmissionRecorder {
    private(set) var last: ComposeSubmission?

    func save(_ mode: ComposeView.Mode, _ submission: ComposeSubmission) async -> ComposeOutcome {
        last = submission
        return .saved
    }
}

/// Attaching a photograph to a memo that already exists.
///
/// Until now an edit could change the words and the date and nothing else: the sheet showed only
/// the date row, so a memo posted without its picture could never be given one from the app. The
/// picker is on the edit sheet now, and what it picks rides the submission to a foreground upload
/// (`TimelineStore.edit(attaching:)`) rather than the outbox, which owns new captures.
@MainActor
@Suite("Attaching media on an edit")
struct ComposeMediaEditTests {
    private let created = Date(timeIntervalSince1970: 1_750_000_000)

    private func mode() -> ComposeView.Mode {
        .edit(uid: "m1", content: "the boiler man", createdAt: created)
    }

    private func picked(_ name: String) -> PickedMedia {
        PickedMedia(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            filename: name,
            mime: "image/jpeg"
        )
    }

    @Test("an edit sheet really offers the photo picker and the date")
    func theEditSheetOffersThePicker() {
        let labels = ScreenProbe.labels(of: ComposeView(mode: mode()) { _ in .saved })

        // The positive control: without it, a missing picker below would only prove the probe saw
        // nothing whatsoever.
        #expect(
            labels.contains { $0.contains("Save") },
            "the probe found nothing of the sheet at all: \(labels)"
        )
        #expect(
            labels.contains("Add photos or videos"),
            "an edit still cannot attach anything: \(labels)"
        )
        #expect(labels.contains("Memo date"), "the date row left the edit sheet: \(labels)")
    }

    @Test("an edit sheet still says nothing about who can see the memo")
    func theEditSheetOffersNoVisibility() {
        let editing = ScreenProbe.labels(of: ComposeView(mode: mode()) { _ in .saved })
        let creating = ScreenProbe.labels(of: ComposeView(mode: .create) { _ in .saved })

        // Who can see a memo is its own deliberate action on the memo, not something that changes
        // as a side effect of fixing a typo.
        #expect(
            !editing.contains { $0.hasPrefix("Visibility:") },
            "an edit sheet offered to change the visibility: \(editing)"
        )
        // The control: a NEW memo does choose one, so the absence above is a decision rather than
        // a control the probe cannot see.
        #expect(
            creating.contains { $0.hasPrefix("Visibility:") },
            "the probe cannot see the visibility control at all: \(creating)"
        )
    }

    @Test("the files picked in the sheet reach the save whole")
    func theFilesReachTheSave() async {
        let flow = MemoEditFlow()
        let recorder = MediaSubmissionRecorder()
        flow.begin(mode())

        let closed = await flow.submit(
            ComposeSubmission(
                content: "the boiler man, and here he is",
                visibility: nil,
                attachments: [picked("a.jpg"), picked("b.jpg")]
            ),
            save: recorder.save
        )

        #expect(closed.isSaved)
        // Dropped here, the upload would never happen and the memo would save its new text with
        // the photograph silently missing — the one half-edit nobody can see has gone wrong.
        #expect(recorder.last?.attachments.map(\.filename) == ["a.jpg", "b.jpg"])
    }

    @Test("what the save sends up is the picked file, in the shape an upload takes")
    func stagedSourcesCarryTheFile() {
        let staged = picked("holiday.jpg").stagedSource

        #expect(staged.filename == "holiday.jpg")
        #expect(staged.mime == "image/jpeg")
        #expect(staged.url.lastPathComponent == "holiday.jpg")
    }
}

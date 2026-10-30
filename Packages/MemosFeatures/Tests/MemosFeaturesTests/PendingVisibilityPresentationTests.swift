import Foundation
import MemosCore
import MemosOutbox
import Testing

@testable import MemosFeatures

/// The visibility menu on a pending card and in the Transfers sheet (MEMNG-971): what it shows,
/// when it is offered, and what a pick sends.
@Suite("A pending memo's visibility menu")
@MainActor
struct PendingVisibilityPresentationTests {
    private func job(_ change: (inout UploadJob) -> Void = { _ in }) -> UploadJob {
        var job = UploadJob(
            content: "x", visibility: "PRIVATE", capturedAt: Date(), files: [],
            binding: AccountBinding(
                serverBaseURL: URL(filePath: "/server"), ownerSubject: "fabian"))
        change(&job)
        return job
    }

    private func edit(_ visibility: String?) -> PendingEdit {
        PendingEdit(content: "x", visibility: visibility, capturedAt: Date(), fileIDs: [])
    }

    @Test("offered until a change of the capture is on the wire")
    func offeredUntilAChangeIsOnTheWire() {
        #expect(PendingVisibility.isEditable(job()))
        #expect(PendingVisibility.isEditable(job { $0.state = .creating }))
        let frozen = job { $0.editUnansweredSince = Date() }
        #expect(!PendingVisibility.isEditable(frozen))
        let offer = PendingMemoActions.offers(for: frozen).first { $0.action == .visibility }
        #expect(offer?.disabledReason == PendingMemoActions.visibilityOnTheWire)
    }

    @Test("the menu shows what the manifest now means, the owed edit first")
    func showsWhatTheManifestMeans() {
        #expect(PendingVisibility.current(of: job()) == .private)
        #expect(PendingVisibility.current(of: job { $0.visibility = nil }) == nil)
        #expect(PendingVisibility.current(of: job { $0.pendingEdit = edit("PUBLIC") }) == .public)
        #expect(PendingVisibility.current(of: job { $0.pendingEdit = edit(nil) }) == .private)
    }

    @Test("a narrowing is sent at once; a widening asks first and sends nothing until its yes")
    func aNarrowingGoesAndAWideningAsks() throws {
        var widening = WideningAsk()
        let shared = job { $0.visibility = "PUBLIC" }
        let narrowed = PendingVisibility.pick(.protected, on: shared, asking: &widening)
        #expect(narrowed?.to == .protected)
        #expect(widening.pending == nil)

        let unchanged = PendingVisibility.pick(.private, on: job(), asking: &widening)
        #expect(unchanged == nil)
        #expect(widening.pending == nil, "the audience it already has asked a question")

        // The owed edit is where the capture stands: PUBLIC there makes PRIVATE a narrowing.
        let owed = job { $0.pendingEdit = edit("PUBLIC") }
        let fromOwed = PendingVisibility.pick(.private, on: owed, asking: &widening)
        #expect(fromOwed?.to == .private)

        let widened = PendingVisibility.pick(.public, on: job(), asking: &widening)
        #expect(widened == nil)
        let pending = try #require(widening.pending)
        #expect(pending.question.to == .public)
        let answered = widening.answer(pending, confirmed: true)
        let yes = try #require(answered)
        #expect(yes.change.to == .public && yes.change.confirmed)
    }
}

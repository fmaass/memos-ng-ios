import Foundation
import MemosAPI
import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// The sheet the timeline builds, hosted, with the flow it is built from driven underneath it.
///
/// It is the production call site written once more — `TimelineView`'s `.sheet` closure reads the
/// flow inside a view body, which is what makes a sentence written after the sheet is up arrive on
/// it. A test that called the factory and kept the result would be holding a picture taken before
/// anything failed: `MemoEditFlow` is `@Observable`, and a read outside a body observes nothing.
@MainActor
private struct SheetHost: View {
    let flow: MemoEditFlow
    let mode: ComposeView.Mode
    let delete: @MainActor (String) async -> Bool

    var body: some View {
        TimelineView.editSheet(
            mode: mode,
            isAsking: flow.deleteStage == .asking,
            failure: flow.lastError,
            send: { event in flow.sendDelete(event, delete: delete) }
        ) { _ in .saved }
    }
}

/// What the timeline's open edit sheet says when the server refuses.
///
/// The timeline's own notices are rows of its list (`TimelineView`'s `NoticeCard`s), and a sheet is
/// drawn over the list — so a refusal said there is said behind a screen nobody can see past. The
/// delete's answer has no way back into `ComposeView` either: `ComposeDelete.send` returns nothing.
/// The sentence the flow already holds is therefore the only thing the sheet can say, and these
/// hold that it really says it.
///
/// Both of them assert on what the HOSTED CONTENT reads as, never on `lastError`'s value — the
/// value is `MemoEditFlow`'s own suite's subject. And both prove the FACTORY's presentation: what
/// they do not prove is `.sheet` presentation itself, which never happens under a test, nor the
/// timeline's production save wiring, which does not go through `MemoEditFlow` at all.
@MainActor
@Suite("The timeline's sheet says what was refused")
struct TimelineSheetRefusalTests {
    private let created = Date(timeIntervalSince1970: 1_750_000_000)
    /// The delete, by the operation the contract names it — the request the refusal is scripted
    /// against, and not "whatever else this composition sends".
    private static let deleteMemo = "delete_memo_api_memos__uid__delete"

    /// The sheet's width on a phone, and the room the medium detent it opens at leaves inside it —
    /// half of a 393 x 852 screen, which is the viewport the notice has to share with the editor.
    private static let sheetWidth: CGFloat = 393
    private static let mediumDetent: CGFloat = 426

    private func editing(_ uid: String) -> ComposeView.Mode {
        .edit(
            uid: uid, content: "the boiler man comes Thursday", createdAt: created,
            attachments: []
        )
    }

    /// The real store, over the app's own generated client, over a transport that says no.
    ///
    /// Nothing between the sheet and the wire is a stand-in: the store builds the request, the
    /// middleware attaches the token, the generated client reads the status back. A substituted
    /// store would answer `false` without any of that ever having been asked.
    private func refusingTimeline() -> (store: TimelineStore, handle: SessionHandle) {
        let transport = ScriptedWireTransport()
        transport.refuse(Self.deleteMemo)
        let client = APIClientFactory.make(
            configuration: ServerConfiguration(
                baseURL: URL(string: "https://memos.example.invalid")!
            ),
            token: { "memos_pat_sheet_refusal" },
            transport: transport
        )
        return (TimelineStore(), SessionHandle(client: client, generation: 1))
    }

    @Test("a delete the server refused is said on the sheet that is still open")
    func aRefusedDeleteIsSaidOnTheSheet() async {
        let (timeline, handle) = refusingTimeline()
        let flow = MemoEditFlow()
        let mode = editing("m1")
        flow.begin(mode)
        let host = SheetHost(flow: flow, mode: mode) { uid in
            await timeline.delete(uid: uid, using: handle)
        }

        await PressProbe.withScreen(host, height: 852) { screen in
            // The positive control: if the probe cannot find the sheet's own destructive row, its
            // silence about a sentence would prove nothing at all.
            #expect(
                screen.element(labelled: "Delete memo") != nil,
                "the probe found nothing of the sheet at all"
            )
            #expect(
                !screen.says(MemoEditFlow.deleteFailureMessage),
                "the sheet said a delete had failed before one had been asked for"
            )

            // Both events in one turn, as the alert delivers them: the question is never drawn,
            // and the request goes out on the transition the second one makes.
            flow.sendDelete(.tapped, delete: host.delete)
            flow.sendDelete(.confirmed, delete: host.delete)
            await screen.settle(turns: 400, until: { flow.lastError != nil })

            #expect(
                screen.says(MemoEditFlow.deleteFailureMessage),
                "the refused delete left the open sheet saying nothing"
            )
        }
    }

    /// The same presentation, reached by the other writer of `lastError`.
    ///
    /// Save is deliberately never pressed. `ComposeView` keeps a failure sentence of its own and
    /// draws it, so a control that pressed Save would pass with no notice in the factory at all —
    /// it would be reading the compose view's message and calling it this one's. The failure here
    /// is obtained from `MemoEditFlow.submit` directly, and the only thing the screen is then asked
    /// is whether the sheet the timeline builds shows it.
    ///
    /// It is also what a delete-shaped fix fails: this sentence was written by the save path.
    @Test("a save the flow refused is said on the sheet the timeline builds")
    func aRefusedSaveIsSaidOnTheSheet() async {
        let flow = MemoEditFlow()
        let mode = editing("m2")
        flow.begin(mode)
        let recorder = SubmissionRecorder(result: false)
        await flow.submit(
            ComposeSubmission(content: "after", visibility: nil), save: recorder.save
        )
        let sentence = ComposeFailurePresentation.sentence(for: .rejection)
        let host = SheetHost(flow: flow, mode: mode) { _ in true }

        await PressProbe.withScreen(host, height: 852) { screen in
            #expect(
                screen.element(labelled: "Delete memo") != nil,
                "the probe found nothing of the sheet at all"
            )
            await screen.settle(turns: 40, until: { screen.says(sentence) })

            #expect(
                screen.says(sentence),
                "the sheet the timeline builds showed nothing of a save the server refused"
            )
            #expect(
                recorder.count == 1,
                "the control pressed Save on the sheet and read ComposeView's own message"
            )
        }
    }

    /// What the notice costs the sheet at the largest text size somebody can choose.
    ///
    /// The sentence is the point, so it is never shortened to fit — which makes what it TAKES a
    /// number worth having rather than a thing to tune. Measured the way the fitting suite measures
    /// a card: what the notice wants at `.accessibility5` against what it wants at `.large`, and
    /// against the detent it has to share. The floor held here is the honest one — the notice alone
    /// may not fill the sheet — and the measurement itself is printed rather than judged in here,
    /// for the reason the toolbar suite prints its bar.
    @Test("the notice's cost at the largest text size is measured, not assumed")
    func theNoticeCostsWhatItCosts() {
        let notice = NoticeCard(text: MemoEditFlow.deleteFailureMessage, tone: .error)
            .padding(.horizontal, DesignTokens.Space.roomy)
            .padding(.top, DesignTokens.Space.regular)
        let largest = LayoutProbe.size(notice, width: Self.sheetWidth, typeSize: .accessibility5)
        let ordinary = LayoutProbe.size(notice, width: Self.sheetWidth, typeSize: .large)
        print(
            "MEMOSNG_SHEET_NOTICE_BEGIN\nwidth=\(Self.sheetWidth) detent=\(Self.mediumDetent) "
                + "largest=\(largest.height) ordinary=\(ordinary.height)\n"
                + "MEMOSNG_SHEET_NOTICE_END"
        )

        #expect(largest.height > ordinary.height, "the notice ignored the text size")
        #expect(
            largest.height < Self.mediumDetent,
            "the notice wants \(largest.height)pt of a \(Self.mediumDetent)pt sheet"
        )
    }
}

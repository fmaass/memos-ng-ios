import Foundation
import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// How the compose sheet opens its photo picker.
///
/// The defect this holds shut: the sheet raises the keyboard as it opens, and the picker used to be
/// asked for with that keyboard still standing — so it presented while the keyboard resigned
/// underneath it and the sheet settled back to its own height, and the picker was re-laid out once
/// on its way in. The picker's own presentation cannot be driven from here (a modal presentation
/// never completes under `xcodebuild test`), so the ORDER is held on the value that decides it -
/// two phases bridged by the keyboard's own did-hide, because two writes in one update land in
/// one frame - and the count of pickers is held on the real screen.
@MainActor
@Suite("Compose picker presentation")
struct ComposePickerPresentationTests {
    @Test("the sheet opens wanting the keyboard, and nothing else")
    func openingRaisesTheKeyboardOnly() {
        var stage = ComposeStage()
        #expect(!stage.wantsKeyboard)
        #expect(!stage.pickingPhotos)

        stage.opened()

        #expect(stage.wantsKeyboard)
        #expect(!stage.pickingPhotos, "the sheet opened with the photo picker already up")
    }

    @Test("asking for the picker waits for the keyboard to finish leaving")
    func pickingPhotosWaitsForTheKeyboard() {
        var stage = ComposeStage()
        stage.opened()
        stage.keyboardShown()

        stage.pickPhotos()

        #expect(
            !stage.wantsKeyboard,
            "the keyboard was not asked down when the picker was asked for"
        )
        // The regression pin. One update carrying both writes presents the picker in the very
        // frame the keyboard begins to leave — which is the flicker itself, and exactly what a
        // final-values assertion cannot see (review round 2).
        #expect(
            !stage.pickingPhotos,
            "the picker presented in the same frame the keyboard began to leave"
        )

        stage.keyboardHidden()

        #expect(stage.pickingPhotos, "the keyboard finished leaving and no picker followed")
    }

    @Test("a picker asked for with no keyboard up presents at once")
    func pickingPhotosWithoutAKeyboardIsImmediate() {
        var stage = ComposeStage()

        stage.pickPhotos()

        #expect(stage.pickingPhotos, "with nothing to put down, the picker still waited")
        stage.keyboardHidden()
        #expect(stage.pickingPhotos, "a stray did-hide dismissed a presented picker")
    }

    @Test("a keyboard already leaving still holds the picker back")
    func aDismissingKeyboardStillHoldsThePicker() {
        var stage = ComposeStage()
        stage.opened()
        stage.keyboardShown()
        // Focus went somewhere else first — the keyboard is on its way down but not gone. The
        // intent is stale; the PRESENCE is what matters (review round 3).
        stage.editorFocusChanged(to: false)

        stage.pickPhotos()

        #expect(
            !stage.pickingPhotos,
            "the picker presented into the tail of a dismissal it did not start"
        )
        stage.keyboardHidden()
        #expect(stage.pickingPhotos)
    }

    @Test("taking the editor back while the picker waits abandons the presentation")
    func refocusingWhileWaitingAbandonsThePicker() {
        var stage = ComposeStage()
        stage.opened()
        stage.keyboardShown()
        stage.pickPhotos()

        stage.editorFocusChanged(to: true)
        stage.keyboardHidden()

        #expect(
            !stage.pickingPhotos,
            "the picker presented behind the keyboard the person just asked back"
        )
        #expect(stage.wantsKeyboard)
    }

    /// The second open is its own case. Focus moves without the stage being asked — a tap back into
    /// the editor after the first pick — and a stage that did not hear about it would think the
    /// keyboard already down, lower nothing, and present over a standing keyboard again.
    @Test("a picker opened again still puts the keyboard down")
    func pickingPhotosLowersTheKeyboardOnEveryOpen() {
        var stage = ComposeStage()
        stage.opened()
        stage.keyboardShown()
        stage.pickPhotos()
        stage.keyboardHidden()
        stage.photosPickerClosed()
        #expect(!stage.pickingPhotos)

        // Somebody tapped back into the editor, so the keyboard is up again — the refocus is
        // the intent, and the keyboard's own will-show is the presence that follows it.
        stage.editorFocusChanged(to: true)
        stage.keyboardShown()
        #expect(stage.wantsKeyboard)

        stage.pickPhotos()

        #expect(!stage.wantsKeyboard, "the second open left the keyboard standing")
        #expect(!stage.pickingPhotos, "the second open presented over a keyboard still leaving")
        stage.keyboardHidden()
        #expect(stage.pickingPhotos)
    }

    @Test("a closed picker does not bring the keyboard back up over the thumbnails")
    func closingThePickerLeavesTheKeyboardDown() {
        var stage = ComposeStage()
        stage.opened()
        stage.keyboardShown()
        stage.pickPhotos()
        stage.keyboardHidden()

        stage.photosPickerClosed()

        #expect(!stage.pickingPhotos)
        #expect(!stage.wantsKeyboard)
    }

    /// The camera is the pill's other choice, and it gets the identical hand-off: a full-screen
    /// camera arriving while the sheet under it is still following the keyboard down is the same
    /// defect as a picker doing it, and one answer to that question is enough.
    @Test("the camera waits for the keyboard exactly as the picker does")
    func theCameraWaitsForTheKeyboardToo() {
        var stage = ComposeStage()
        stage.opened()
        stage.keyboardShown()

        stage.openCamera()

        #expect(!stage.wantsKeyboard)
        #expect(!stage.capturing, "the camera arrived in the frame the keyboard began to leave")
        stage.keyboardHidden()
        #expect(stage.capturing)
        // And it is the camera that is up, not both things at once.
        #expect(!stage.pickingPhotos, "opening the camera opened the photo picker as well")
        stage.cameraClosed()
        #expect(!stage.capturing)
        #expect(!stage.wantsKeyboard, "the camera closing brought the keyboard back over the row")
    }

    /// The two presentations are told apart by the value, not by whichever dismissal happens to
    /// arrive: a `fullScreenCover` and a `photosPicker` both write `false` through their binding
    /// when they close, and a phase that could not say which one had closed would let either
    /// dismissal take the other down.
    @Test("a dismissal closes the presentation it belongs to, and not the other one")
    func eachDismissalClosesItsOwnPresentation() {
        var stage = ComposeStage()

        stage.pickPhotos()
        #expect(stage.pickingPhotos)
        stage.cameraClosed()
        #expect(stage.pickingPhotos, "a camera dismissal closed the photo picker")
        stage.photosPickerClosed()
        #expect(!stage.pickingPhotos)

        stage.openCamera()
        #expect(stage.capturing)
        stage.photosPickerClosed()
        #expect(stage.capturing, "a picker dismissal closed the camera")
        stage.cameraClosed()
        #expect(!stage.capturing)
    }

    /// The other half, on the real screen: the pill that opens the picker is still there, still
    /// says what it does, and there is no more of it than there is of the pill beside it.
    ///
    /// The counts are compared with each other rather than against one. The probe reaches parts of
    /// the tree by two routes and lists what it finds once per route, so an absolute count says
    /// more about the traversal than about the screen; the three pills are siblings in one row, so
    /// whatever that factor is, it is the same for all of them.
    @Test("the photos pill is on the sheet, and there is one of it")
    func onePhotosPillOnTheSheet() {
        let labels = ScreenProbe.labels(of: ComposeView(mode: .create) { _ in .saved })

        // The positive control: if the probe cannot see the row's other pill, everything said
        // about this one would be said about a screen the probe never saw.
        let dates = labels.filter { $0 == "Memo date" }.count
        #expect(dates > 0, "the probe found no meta row on the screen: \(labels)")

        let pickers = labels.filter { $0 == "Add photos or videos" }.count
        #expect(pickers == dates, "photos pills: \(pickers), date pills: \(dates) — \(labels)")
    }

    @Test("the picker's menu keeps its declared order, library above camera")
    func photoChoicesKeepTheirDeclaredOrder() {
        // The popup cannot be opened under `xcodebuild test`, so what is held is the value the
        // menu is given. The system default is priority order, which turns an upward-opening
        // menu upside down — see `ComposeMetaRow.photoChoicesOrder` for the screen this bit.
        #expect(ComposeMetaRow.photoChoicesOrder == .fixed)
    }
    /// What a picker answer means while a save is carrying the list it would replace.
    ///
    /// The refusal has to empty the binding — the same photographs chosen again must stay a
    /// change — and that emptying comes back as an answer of its own, on whatever update follows.
    /// A save that FAILS releases its flag with the sheet still open, so that echo can arrive with
    /// nothing running and be read as somebody deselecting everything, which would take the
    /// retained pictures off a row the save never touched.
    @Test("a selection landing while a save runs is refused, and the binding emptied with it")
    func aSelectionDuringASaveIsRefused() {
        var stage = ComposeStage()

        let answer = stage.selectionLanded(count: 2, submitting: true)

        #expect(answer == .refuseAndReset)
    }

    @Test("the emptying's own answer is swallowed while the save is still running")
    func theEchoIsSwallowedDuringTheSave() {
        var stage = ComposeStage()
        _ = stage.selectionLanded(count: 2, submitting: true)

        let answer = stage.selectionLanded(count: 0, submitting: true)

        #expect(answer == .swallowReset)
    }

    /// The case the save's ending makes: released on a failure with the sheet still open, or on a
    /// success a moment before it closes, the flag says nothing about where this answer came from.
    @Test("the emptying's own answer is swallowed after the save has ended")
    func theEchoIsSwallowedAfterTheSaveEnds() {
        var stage = ComposeStage()
        _ = stage.selectionLanded(count: 2, submitting: true)

        let answer = stage.selectionLanded(count: 0, submitting: false)

        #expect(answer == .swallowReset)
    }

    @Test("an empty answer with no emptying outstanding is somebody deselecting everything")
    func aGenuineEmptyAnswerIsASelection() {
        var stage = ComposeStage()

        let answer = stage.selectionLanded(count: 0, submitting: false)

        #expect(answer == .load)
    }

    @Test("an answer after the emptying has been accounted for is an ordinary selection")
    func aSelectionAfterTheEchoIsASelection() {
        var stage = ComposeStage()
        _ = stage.selectionLanded(count: 2, submitting: true)
        _ = stage.selectionLanded(count: 0, submitting: false)

        let answer = stage.selectionLanded(count: 3, submitting: false)

        #expect(answer == .load)
    }

    /// A real selection can also land BEFORE the emptying's answer does, and it is still a
    /// selection — and it accounts for the emptying, so the one that follows is swallowed once.
    @Test("a real selection landing before the emptying's answer is still a selection")
    func aSelectionBeforeTheEchoIsASelection() {
        var stage = ComposeStage()
        _ = stage.selectionLanded(count: 2, submitting: true)

        let answer = stage.selectionLanded(count: 3, submitting: false)

        #expect(answer == .load)
    }

    /// Nothing in the binding and a save running: there is nothing to take and nothing to give
    /// back, so the answer is left alone rather than emptied a second time.
    @Test("an empty answer during a save is refused without an emptying of its own")
    func anEmptyAnswerDuringASaveIsSwallowed() {
        var stage = ComposeStage()

        let answer = stage.selectionLanded(count: 0, submitting: true)

        #expect(answer == .swallowReset)
    }

}

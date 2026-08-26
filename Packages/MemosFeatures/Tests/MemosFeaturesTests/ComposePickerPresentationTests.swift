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

    /// The other half, on the real screen: the pill that opens the picker is still there, still
    /// says what it does, and there is no more of it than there is of the pill beside it.
    ///
    /// The counts are compared with each other rather than against one. The probe reaches parts of
    /// the tree by two routes and lists what it finds once per route, so an absolute count says
    /// more about the traversal than about the screen; the three pills are siblings in one row, so
    /// whatever that factor is, it is the same for all of them.
    @Test("the photos pill is on the sheet, and there is one of it")
    func onePhotosPillOnTheSheet() {
        let labels = ScreenProbe.labels(of: ComposeView(mode: .create) { _ in true })

        // The positive control: if the probe cannot see the row's other pill, everything said
        // about this one would be said about a screen the probe never saw.
        let dates = labels.filter { $0 == "Memo date" }.count
        #expect(dates > 0, "the probe found no meta row on the screen: \(labels)")

        let pickers = labels.filter { $0 == "Add photos or videos" }.count
        #expect(pickers == dates, "photos pills: \(pickers), date pills: \(dates) — \(labels)")
    }
}

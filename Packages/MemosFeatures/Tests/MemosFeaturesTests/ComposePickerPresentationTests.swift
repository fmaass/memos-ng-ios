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
/// never completes under `xcodebuild test`), so the ORDER is held on the value that decides it and
/// the count of pickers is held on the real screen.
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

    @Test("asking for the picker puts the keyboard down first")
    func pickingPhotosLowersTheKeyboard() {
        var stage = ComposeStage()
        stage.opened()

        stage.pickPhotos()

        #expect(
            !stage.wantsKeyboard,
            "the keyboard is still up when the picker is asked for: it resigns mid-presentation"
        )
        #expect(stage.pickingPhotos)
    }

    /// The second open is its own case. Focus moves without the stage being asked — a tap back into
    /// the editor after the first pick — and a stage that did not hear about it would think the
    /// keyboard already down, lower nothing, and present over a standing keyboard again.
    @Test("a picker opened again still puts the keyboard down")
    func pickingPhotosLowersTheKeyboardOnEveryOpen() {
        var stage = ComposeStage()
        stage.opened()
        stage.pickPhotos()
        stage.photosPickerClosed()
        #expect(!stage.pickingPhotos)

        // Somebody tapped back into the editor, so the keyboard is up again.
        stage.editorFocusChanged(to: true)
        #expect(stage.wantsKeyboard)

        stage.pickPhotos()

        #expect(!stage.wantsKeyboard, "the second open left the keyboard standing")
        #expect(stage.pickingPhotos)
    }

    @Test("a closed picker does not bring the keyboard back up over the thumbnails")
    func closingThePickerLeavesTheKeyboardDown() {
        var stage = ComposeStage()
        stage.opened()
        stage.pickPhotos()

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

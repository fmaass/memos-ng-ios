/// What the compose sheet has up: its keyboard, and whichever way of attaching media it is showing.
///
/// They are one value because they are not independent. The sheet raises the keyboard as it opens,
/// and a picker asked for while it stands used to present WHILE the keyboard resigned — the
/// detented sheet's height follows the keyboard, so its geometry changed under the arriving
/// picker, which was re-laid out once on the way in. That single re-layout was the reported
/// flicker (MEMNG-181).
///
/// Writing "keyboard down" and "picker up" in one update does not fix that: SwiftUI applies both
/// in the same frame and promises no order between the resignation and the presentation (review
/// round 2). So the hand-off is TWO PHASES bridged by the keyboard's own settling: asking for the
/// picker lowers the keyboard and WAITS, and only the keyboard-did-hide notification — delivered
/// when the resignation has actually finished — raises the picker. A picker asked for with no
/// keyboard up skips the wait entirely. The phases live here, on a value, where a test can hold
/// the order itself rather than two writes a frame happens to apply together.
struct ComposeStage: Equatable {
    /// Where the picker's presentation is in its keyboard hand-off.
    enum PickerPhase: Equatable {
        /// No picker asked for.
        case idle
        /// The pill was tapped with the keyboard up: it is going down, and the picker waits for
        /// the did-hide that says it has gone.
        case waitingForKeyboard
        /// The picker is up (or arriving over a sheet whose geometry is done moving).
        case presenting
    }

    /// Where media is being attached from.
    enum Source: Equatable {
        case photos
        case camera
    }

    /// Whether the sheet wants the editor focused — the INTENT, which is not the same thing as
    /// the keyboard being on screen: focus can be lost while the keyboard is still animating
    /// away, and a picker gated on intent alone would present into exactly that window (review
    /// round 3). Presence is `keyboardVisible`, and only presence gates the presentation.
    private(set) var wantsKeyboard = false
    /// Whether the keyboard is on screen — true from its will-show, false from its did-hide, the
    /// two signals the keyboard itself sends. This is what the picker waits on.
    private(set) var keyboardVisible = false
    /// The picker's phase. Read through `pickingPhotos` by the presentation binding.
    private(set) var phase: PickerPhase = .idle
    /// Which source the phase above belongs to. They cannot both be up — one sheet, one
    /// presentation — and they share the whole hand-off, because the camera arrives over the same
    /// sheet whose height is still following the keyboard down.
    private(set) var presented: Source = .photos

    /// Whether the photo picker should be on screen.
    var pickingPhotos: Bool { phase == .presenting && presented == .photos }

    /// Whether the in-app camera should be on screen.
    var capturing: Bool { phase == .presenting && presented == .camera }

    /// The sheet has appeared. The keyboard comes with it: writing is what this screen is for.
    mutating func opened() { wantsKeyboard = true }

    /// The photos pill was tapped. With the keyboard ON SCREEN — whether or not anything still
    /// wants it — this only STARTS the hand-off: the picker presents when the keyboard has
    /// finished leaving, not in the same frame it begins to, and not into the tail of a dismissal
    /// some other interaction already started.
    mutating func pickPhotos() {
        present(.photos)
    }

    /// The camera was chosen from the same pill. It gets the identical hand-off: a full-screen
    /// camera arriving while the sheet under it is still settling is the same defect as a picker
    /// doing it, and there is no reason for two answers to one question.
    mutating func openCamera() {
        present(.camera)
    }

    private mutating func present(_ source: Source) {
        presented = source
        wantsKeyboard = false
        phase = keyboardVisible ? .waitingForKeyboard : .presenting
    }

    /// The keyboard has begun arriving. From this instant a picker must wait for it to leave.
    mutating func keyboardShown() {
        keyboardVisible = true
    }

    /// The keyboard has finished hiding — the sheet's geometry is done following it, and a picker
    /// that was waiting can present over a surface that is no longer moving.
    mutating func keyboardHidden() {
        keyboardVisible = false
        if phase == .waitingForKeyboard { phase = .presenting }
    }

    /// The picker closed. The keyboard is not asked back: what has just arrived on the sheet is a
    /// row of thumbnails, and a keyboard springing up over them is the sheet arguing with itself.
    mutating func photosPickerClosed() {
        if phase == .presenting, presented == .photos { phase = .idle }
    }

    /// The camera closed — because a capture was taken and attached, or because somebody left.
    /// Neither brings the keyboard back, for the reason the picker does not.
    mutating func cameraClosed() {
        if phase == .presenting, presented == .camera { phase = .idle }
    }

    /// Focus moved without this value being asked — somebody tapped into the editor, or dragged
    /// the keyboard away. Kept in step so the NEXT `pickPhotos` still has something to put down —
    /// and a tap INTO the editor while a picker was waiting on the keyboard is that person
    /// changing their mind: the presentation is abandoned, not queued behind the keyboard they
    /// just asked back.
    mutating func editorFocusChanged(to focused: Bool) {
        wantsKeyboard = focused
        if focused, phase == .waitingForKeyboard { phase = .idle }
    }
}

/// What the compose sheet has up: its keyboard, and its photo picker.
///
/// They are one value because they are not independent. The sheet raises the keyboard as it opens
/// and nothing put it back down, so the picker was asked for with the keyboard still standing — and
/// it then resigned DURING the presentation. The sheet it resigns out of is a detented one whose
/// height and selected detent both follow the keyboard, so its geometry and its state change while
/// the picker is still arriving on top of it, and the picker is re-laid out once on the way in.
/// That single re-layout is the reported flicker.
///
/// So putting the keyboard down and asking for the picker are ONE move, in that order, in one place
/// a test can read back — rather than two writes a view body happens to make in the right order
/// this week. It is the discipline `MemoEditFlow` is built on, for the same reason: an ordering
/// that lives only inside a `body` is an ordering no test can hold, and a modal presentation never
/// completes under `xcodebuild test`, so driving the real picker is not the alternative.
struct ComposeStage: Equatable {
    /// Whether the sheet wants the editor focused — which is to say, whether it wants the keyboard.
    private(set) var wantsKeyboard = false
    /// Whether the photo picker is up.
    private(set) var pickingPhotos = false

    /// The sheet has appeared. The keyboard comes with it: writing is what this screen is for.
    mutating func opened() { wantsKeyboard = true }

    /// The photos pill was tapped. The keyboard goes down FIRST — see the type comment for what
    /// happens when it does not.
    mutating func pickPhotos() {
        wantsKeyboard = false
        pickingPhotos = true
    }

    /// The picker closed. The keyboard is not asked back: what has just arrived on the sheet is a
    /// row of thumbnails, and a keyboard springing up over them is the sheet arguing with itself.
    mutating func photosPickerClosed() { pickingPhotos = false }

    /// Focus moved without this value being asked — somebody tapped into the editor, or dragged the
    /// keyboard away. Kept in step so the NEXT `pickPhotos` still has something to put down: a
    /// stage that believes the keyboard is already gone lowers nothing, and the picker opens over a
    /// standing keyboard exactly as it did before.
    mutating func editorFocusChanged(to focused: Bool) { wantsKeyboard = focused }
}

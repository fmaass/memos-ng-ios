import MemosShareKit
import Testing

@Suite("The share sheet's visibility words")
struct ShareVisibilityTests {
    /// The picker reads these, and they have to be the app's own words for the same three levels:
    /// a memo shared as "Just us" from Photos must not come back labelled something else in a card.
    @Test("the picker names each level the way the app does")
    func pickerWords() {
        #expect(ShareVisibility.private.label == "Private")
        #expect(ShareVisibility.protected.label == "Just us")
        #expect(ShareVisibility.public.label == "Public")
        // The wire value is untouched: only the word a person reads changed.
        #expect(ShareVisibility.protected.rawValue == "PROTECTED")
        #expect(Set(ShareVisibility.allCases.map(\.label)).count == ShareVisibility.allCases.count)
    }
}

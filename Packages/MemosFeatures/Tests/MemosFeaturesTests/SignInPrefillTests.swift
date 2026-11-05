import Testing

@testable import MemosFeatures

/// The sign-in field follows the session's suggestion until a person types into it (MEMNG-1127):
/// the launch restore can resolve while the screen is already showing, and a field only filled on
/// appearance would keep the server it showed first.
@Suite("The sign-in field follows the suggestion until edited")
struct SignInPrefillTests {
    typealias Vector = (current: String, suggestion: String, edited: Bool, shown: String)

    private static let vectors: [Vector] = [
        ("", "memos.example.com", false, "memos.example.com"),
        ("a.example.com", "b.example.com", false, "b.example.com"),
        ("a.example.com", "", false, ""),
        ("typed.example.com", "b.example.com", true, "typed.example.com"),
        ("", "b.example.com", true, ""),
    ]

    @Test("an untouched field takes the suggestion, an edited one keeps what was typed")
    func fieldRule() {
        for vector in Self.vectors {
            let shown = SignInPrefill.field(
                vector.current, suggestion: vector.suggestion, edited: vector.edited
            )
            #expect(shown == vector.shown, "\(vector)")
        }
    }
}

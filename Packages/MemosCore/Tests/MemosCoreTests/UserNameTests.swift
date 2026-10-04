import MemosCore
import Testing

/// The name the app calls the signed-in account by. Each step of the fall-through is held with
/// literal values: a display name that is absent OR blank gives way to the address, and an
/// address that is absent OR blank gives way to the subject. Blank means empty or nothing but
/// whitespace, because `??` alone takes `""` as a name and the screen then reads "signed in as ,".
@Suite("User.name")
struct UserNameTests {
    private let address = "fabian@example.invalid"

    private func user(displayName: String?, email: String?) -> User {
        User(
            subject: "sub-7f3a",
            displayName: displayName,
            email: email,
            role: "user",
            authKind: "token"
        )
    }

    @Test("a display name is the name")
    func displayNameWins() {
        #expect(user(displayName: "Fabian", email: address).name == "Fabian")
    }

    @Test("an absent display name gives way to the address")
    func absentDisplayNameFallsToEmail() {
        #expect(user(displayName: nil, email: address).name == address)
    }

    @Test("an empty display name gives way to the address")
    func emptyDisplayNameFallsToEmail() {
        #expect(user(displayName: "", email: address).name == address)
    }

    @Test("a display name of only whitespace gives way to the address")
    func whitespaceDisplayNameFallsToEmail() {
        #expect(user(displayName: "  ", email: address).name == address)
        #expect(user(displayName: "\t\n", email: address).name == address)
    }

    @Test("an absent address gives way to the subject")
    func absentEmailFallsToSubject() {
        #expect(user(displayName: nil, email: nil).name == "sub-7f3a")
        #expect(user(displayName: "", email: nil).name == "sub-7f3a")
    }

    @Test("a blank address gives way to the subject")
    func blankEmailFallsToSubject() {
        #expect(user(displayName: nil, email: "").name == "sub-7f3a")
        #expect(user(displayName: "  ", email: " ").name == "sub-7f3a")
    }

    /// The control: a name that merely has whitespace around it is a name, and it is handed over as
    /// it came — the change is about blank values, not about rewriting the ones that are not.
    @Test("a name with whitespace around it is still the name, untouched")
    func paddedNameIsKeptAsItCame() {
        #expect(user(displayName: " Fabian ", email: address).name == " Fabian ")
        let padded = " fabian@example.invalid"
        #expect(user(displayName: nil, email: padded).name == padded)
    }
}

import MemosCore
import Testing

@testable import MemosFeatures

/// What the account menu holds, and — the part that matters — in what order.
///
/// MEMNG-119: the overflow menu's only row was a destructive "Sign out", and a menu opens with its
/// first row directly under the anchor that opened it, so a second tap on the anchor — the reflex
/// when a tap seems not to have registered — revoked a live credential. The heading is what stands
/// in that position now. These hold it there, which is the part a screenshot of a menu could never
/// show.
@MainActor
@Suite("The account menu")
struct AccountMenuTests {
    @Test("the menu is a heading, Settings, and Sign out — in that order")
    func rowsAndOrder() {
        #expect(
            AccountMenu.rows(name: "Fabian") == [
                .heading("Signed in as Fabian"), .settings, .signOut,
            ]
        )
    }

    /// The invariant, stated as itself rather than as a consequence of the list above: whatever
    /// the account is called, the row a second tap on the anchor lands on cannot take anything
    /// away. One case per category of name, because the heading is the thing under test and
    /// `accountHeading` answers differently for a missing one.
    @Test("the first row is never the destructive one, whoever is signed in")
    func theAnchorRowIsNeverDestructive() throws {
        for name in ["Fabian", "laura", "", "   ", nil] {
            let rows = AccountMenu.rows(name: name)
            let first = try #require(rows.first)
            #expect(!first.isDestructive)
            guard case .heading = first else {
                Issue.record("the first row was \(first), not a heading")
                continue
            }
        }
    }

    @Test("exactly one row is destructive, and it is the last")
    func oneDestructiveRowAtTheEnd() {
        let rows = AccountMenu.rows(name: "Fabian")
        #expect(rows.filter(\.isDestructive) == [.signOut])
        #expect(rows.last == .signOut)
    }

    /// Appearance is a setting and lives with the settings. A menu offering a second way to change
    /// one of them would be two answers to the same question, and the two would drift.
    @Test("the menu offers no appearance row")
    func noAppearanceRow() {
        let rows = AccountMenu.rows(name: "Fabian")
        #expect(rows.count == 3)
        // Stated as the whole set rather than as an absence, so a row added without a decision
        // fails here rather than quietly appearing.
        #expect(Set(rows) == Set([.heading("Signed in as Fabian"), .settings, .signOut]))
    }

    /// The heading is not invented here — it is the same sentence the Settings screen's Account
    /// section shows, so the two cannot come to disagree about who is signed in.
    @Test("the heading is the account heading, not a second wording of it")
    func headingComesFromSignOutFlow() {
        for name in ["Fabian", nil] {
            #expect(
                AccountMenu.rows(name: name).first
                    == .heading(SignOutFlow.accountHeading(name: name))
            )
        }
    }
}

/// Which sections the Settings screen has, held as a list so "these five and no others" is an
/// assertion rather than a reading of a view body.
@MainActor
@Suite("The Settings screen's sections")
struct SettingsScreenTests {
    @Test("five sections, in the order they are read")
    func sectionsAndOrder() {
        #expect(SettingsScreen.sections == [.account, .defaults, .appearance, .storage, .about])
    }

    @Test("each section has the title the screen prints")
    func titles() {
        #expect(
            SettingsScreen.sections.map(\.title) == [
                "Account", "Defaults", "Appearance", "Storage", "About",
            ]
        )
    }

    /// Tokens and notifications are coming and are deliberately absent. A section rendered as a
    /// disabled row or a "coming soon" line is a promise the app has not kept, and it costs a
    /// reader a tap to find that out — so this fails the moment one is stubbed in.
    @Test("nothing is stubbed in ahead of working")
    func noStubbedSections() {
        let titles = SettingsScreen.sections.map { $0.title.lowercased() }
        for absent in ["tokens", "notifications", "coming soon"] {
            #expect(!titles.contains { $0.contains(absent) })
        }
        // Positive control: the grep above can find a section that IS there.
        #expect(titles.contains { $0.contains("storage") })
    }
}

/// What the ROOT view applies, which is not quite the same question as what was chosen.
@MainActor
@Suite("Applying the appearance")
struct AppearanceApplicationTests {
    /// A host with no settings store follows the device rather than guessing — and so does the
    /// "System" choice. The two deliberately produce the same answer, because neither is an
    /// opinion about the screen.
    @Test("every input the root view can have resolves to a scheme, or to the device")
    func rootAlwaysHasAnAnswer() {
        #expect(AppSettings.colorScheme(for: nil) == nil)
        #expect(AppSettings.colorScheme(for: .system) == nil)
        #expect(AppSettings.colorScheme(for: .light) == .light)
        #expect(AppSettings.colorScheme(for: .dark) == .dark)
    }
}

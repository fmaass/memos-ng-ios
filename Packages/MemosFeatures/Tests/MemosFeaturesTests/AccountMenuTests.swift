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
///
/// MEMNG-185: the destructive row has left this menu altogether — signing out is one unprominent
/// row at the very bottom of the Settings screen (`SettingsScreenTests`). The heading-first
/// assertions stay, because what stands under the anchor is still a decision; what the menu can no
/// longer do is now stated outright rather than implied by the list.
@MainActor
@Suite("The account menu")
struct AccountMenuTests {
    @Test("the menu is a heading and Settings — in that order")
    func rowsAndOrder() {
        #expect(
            AccountMenu.rows(name: "Fabian") == [.heading("Signed in as Fabian"), .settings]
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

    /// The stronger form of the same promise, and the point of MEMNG-185: there is no row here
    /// that a mis-aimed tap could regret, whoever is signed in. `Row.isDestructive` switches over
    /// every case, so a row added later has to answer this question rather than inherit an answer.
    @Test("no row in the menu can take anything away")
    func nothingInTheMenuIsDestructive() {
        for name in ["Fabian", "laura", "", "   ", nil] {
            let rows = AccountMenu.rows(name: name)
            #expect(rows.filter(\.isDestructive).isEmpty)
            // Positive control: the menu really was built, so the emptiness above is about
            // destructiveness rather than about there being no rows to look at.
            #expect(rows.count == 2)
        }
    }

    /// Appearance is a setting and lives with the settings. A menu offering a second way to change
    /// one of them would be two answers to the same question, and the two would drift.
    @Test("the menu offers no appearance row")
    func noAppearanceRow() {
        let rows = AccountMenu.rows(name: "Fabian")
        #expect(rows.count == 2)
        // Stated as the whole set rather than as an absence, so a row added without a decision
        // fails here rather than quietly appearing.
        #expect(Set(rows) == Set([.heading("Signed in as Fabian"), .settings]))
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

/// Which sections the Settings screen has, held as a list so "these seven and no others" is an
/// assertion rather than a reading of a view body.
@MainActor
@Suite("The Settings screen's sections")
struct SettingsScreenTests {
    @Test("seven sections, in the order they are read")
    func sectionsAndOrder() {
        #expect(
            SettingsScreen.sections == [
                .account, .defaults, .uploads, .appearance, .storage, .about, .signOut,
            ]
        )
    }

    @Test("each section has the title the screen prints")
    func titles() {
        #expect(
            SettingsScreen.sections.map(\.title) == [
                "Account", "Defaults", "Uploads", "Appearance", "Storage", "About", nil,
            ]
        )
    }

    /// MEMNG-185. Signing out is a rare, deliberate act and it now reads as one: last on the
    /// screen rather than first, and under no heading — the row already says the word, and a
    /// heading over it would say it twice. `nil` is what the screen reads to draw nothing
    /// (`SettingsView`), so that is the thing worth pinning; whether a header view appears is
    /// otherwise a property of a body no test in this bundle can construct.
    @Test("the sign-out section is last, and carries no heading")
    func signOutSectionIsLastAndUnheaded() {
        #expect(SettingsScreen.sections.last == .signOut)
        #expect(SettingsScreen.Section.signOut.title == nil)
        // Positive control: every other section does print one, so the `nil` above is this
        // section's decision rather than a screen that lost its headings.
        #expect(SettingsScreen.sections.dropLast().allSatisfy { $0.title != nil })
    }

    /// Tokens and notifications are coming and are deliberately absent. A section rendered as a
    /// disabled row or a "coming soon" line is a promise the app has not kept, and it costs a
    /// reader a tap to find that out — so this fails the moment one is stubbed in.
    @Test("nothing is stubbed in ahead of working")
    func noStubbedSections() {
        let titles = SettingsScreen.sections.compactMap { $0.title?.lowercased() }
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

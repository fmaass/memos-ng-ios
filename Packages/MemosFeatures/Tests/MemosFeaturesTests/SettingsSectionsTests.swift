import MemosCore
import Testing

@testable import MemosFeatures

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

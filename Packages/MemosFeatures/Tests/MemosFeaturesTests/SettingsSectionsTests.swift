import MemosCore
import Testing

@testable import MemosFeatures

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

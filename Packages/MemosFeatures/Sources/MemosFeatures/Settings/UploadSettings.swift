import Foundation
import MemosOutbox
import Observation

/// The upload preference, as a screen can hold it.
///
/// Modelled on `AppSettings` and deliberately NOT one of its properties: appearance is about this
/// screen in this hand and lives in the app's own defaults, while this one is read by the drain —
/// which runs in a process that may have no screen at all — out of the app group's suite. So the
/// value itself belongs to `UploadPreferences` below, and this is the observable mirror SwiftUI
/// needs: the same object the outbox is listening to, never a second store over the same key.
@MainActor
@Observable
public final class UploadSettings {
    /// The row, and the sentence under it. Held here rather than in the view body because both are
    /// promises about behaviour — the second one names Low Data Mode, which the toggle does not
    /// override — and a promise the screen makes is worth a test.
    public static let title = "Upload over mobile data"
    public static let footer =
        "Captures are sent only on your home network unless this is on."
        + " Low Data Mode always waits."

    private let preferences: UploadPreferences

    public private(set) var allowsMobileData: Bool

    public init(preferences: UploadPreferences) {
        self.preferences = preferences
        self.allowsMobileData = preferences.allowsMobileData
    }

    /// Chooses, writes it down, and lets the outbox act on it — in that order and in one place, so
    /// there is no path that changes the switch without also changing what the next drain reads.
    /// The awaited half is what makes a capture already waiting for the home network go NOW.
    public func select(_ value: Bool) async {
        allowsMobileData = value
        await preferences.set(value)
    }
}

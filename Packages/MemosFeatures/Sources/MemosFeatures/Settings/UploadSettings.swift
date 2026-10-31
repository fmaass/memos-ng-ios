import Foundation
import MemosOutbox
import Observation

/// The upload preference, as a screen can hold it.
///
/// Modelled on `AppSettings` and deliberately NOT one of its properties: appearance is about this
/// screen in this hand and only this app reads it, while this one is read by the drain — which
/// runs in a process that may have no screen at all — at the moment of use. So the value itself
/// belongs to `UploadPreferences` below, and this is the observable mirror SwiftUI needs: the same
/// object the outbox is listening to, never a second store over the same key.
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

    /// The key the Settings app writes — into the app group's suite, the one `UploadPreferences`
    /// reads, because the pane names that group at its root. One suite, so nothing here mirrors:
    /// a choice made in the Settings app is already where the outbox and the share extension look.
    public static let key = UploadPreferences.allowsMobileDataKey

    /// The pane's second Uploads row: which videos go over mobile data once mobile data is on.
    /// The choice is the Settings app's to write and the drain's to read at the moment of use
    /// (`UploadPreferences.mobileVideoPolicy`), so nothing here mirrors it; the row's words are
    /// held here so the pane is tested against them.
    public static let videoKey = UploadPreferences.mobileVideoPolicyKey
    public static let videoTitle = "Send videos over mobile data"

    /// What the pane calls each choice, in the order it lists them.
    public static func videoLabel(_ policy: MobileVideoPolicy) -> String {
        switch policy {
        case .always: "Always"
        case .underLimit: "Only under 200 MB"
        case .never: "Never"
        }
    }

    private let preferences: UploadPreferences

    public private(set) var allowsMobileData: Bool

    public init(preferences: UploadPreferences) {
        self.preferences = preferences
        self.allowsMobileData = preferences.allowsMobileData
    }

    /// Chooses, writes it down, and lets the outbox act on it — in that order and in one place, so
    /// there is no path that changes the switch without also changing what the next drain reads.
    /// The returned drain is what makes a capture already waiting for the home network go NOW.
    ///
    /// Synchronous, so the suite is written and the queue told by the time it RETURNS: a write left
    /// to the far side of a hop could be lost to a process ended in between, with the switch
    /// showing one thing and the suite the drain reads saying the other. Only the drain is left to
    /// run; a caller that needs it done awaits it.
    @discardableResult
    public func select(_ value: Bool) -> Task<Void, Never> {
        apply(value)
        let preferences = self.preferences
        return Task { await preferences.drainAfterApply() }
    }

    /// The activation path's write: the same suite, told synchronously, no drain — the
    /// foreground's own drain follows it (`SettingsBundleSync.activate`).
    public func apply(_ value: Bool) {
        allowsMobileData = value
        preferences.apply(value)
    }

    /// Reads the suite again — the Settings app writes it while this process is away — and when
    /// the switch shows another value, applies the stored one, so the screen and the queue's
    /// verdict follow it. An unchanged value writes and tells nothing.
    public func reload() {
        let stored = preferences.allowsMobileData
        if stored != allowsMobileData { apply(stored) }
    }
}

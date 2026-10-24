import Foundation
import MemosCore
import SwiftUI
import Testing

@testable import MemosFeatures

/// How long ago and how long left, said in words — the arithmetic behind the two lines under the
/// device's name.
///
/// Pure and tested by category rather than driven through the row, because the row can only ever
/// show one answer at a time and the interesting part is the boundaries between them: a token used
/// 59 seconds ago and one used 61 seconds ago must not read the same, and one that expires in
/// twenty hours must not read as expiring in zero days.
@Suite("Saying when a device token was used and when it runs out")
struct DeviceTokenPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ago(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(-seconds)
    }

    @Test("every span has its own words, and the units change where they should")
    func elapsedByCategory() {
        #expect(DeviceTokenPresentation.elapsed(ago(0), now: now) == "just now")
        #expect(DeviceTokenPresentation.elapsed(ago(59), now: now) == "just now")
        #expect(DeviceTokenPresentation.elapsed(ago(60), now: now) == "1 minute ago")
        #expect(DeviceTokenPresentation.elapsed(ago(120), now: now) == "2 minutes ago")
        #expect(DeviceTokenPresentation.elapsed(ago(3599), now: now) == "59 minutes ago")
        #expect(DeviceTokenPresentation.elapsed(ago(3600), now: now) == "1 hour ago")
        #expect(DeviceTokenPresentation.elapsed(ago(7200), now: now) == "2 hours ago")
        #expect(DeviceTokenPresentation.elapsed(ago(86_399), now: now) == "23 hours ago")
        #expect(DeviceTokenPresentation.elapsed(ago(86_400), now: now) == "1 day ago")
        #expect(DeviceTokenPresentation.elapsed(ago(400 * 86_400), now: now) == "400 days ago")
    }

    /// A phone whose clock is ahead of the server's would otherwise be told its token was used
    /// in "-3 minutes ago". Nothing is gained by naming the skew, so the nearest true thing is
    /// said instead.
    @Test("a timestamp in the future reads as just now rather than as negative time")
    func elapsedSurvivesClockSkew() {
        let ahead = now.addingTimeInterval(600)
        #expect(DeviceTokenPresentation.elapsed(ahead, now: now) == "just now")
    }

    @Test("a token that has never been used says so instead of guessing")
    func lastUsedLines() {
        #expect(DeviceTokenPresentation.lastUsedLine(nil, now: now) == "Not used yet")
        #expect(
            DeviceTokenPresentation.lastUsedLine(ago(120), now: now) == "Last used 2 minutes ago"
        )
    }

    @Test("an expiry is counted in whole days, and an absent one is not invented")
    func expiryLines() {
        #expect(DeviceTokenPresentation.expiryLine(nil, now: now) == "Never expires")
        #expect(
            DeviceTokenPresentation.expiryLine(now.addingTimeInterval(-1), now: now) == "Expired"
        )
        #expect(
            DeviceTokenPresentation.expiryLine(now.addingTimeInterval(3600), now: now)
                == "Expires today"
        )
        #expect(
            DeviceTokenPresentation.expiryLine(now.addingTimeInterval(86_400), now: now)
                == "Expires in 1 day"
        )
        #expect(
            DeviceTokenPresentation.expiryLine(now.addingTimeInterval(365 * 86_400), now: now)
                == "Expires in 365 days"
        )
    }
}

/// The row itself: what it puts on the screen, and what pressing it does.
///
/// Drawn rather than reasoned about, for the reason `SignOutSectionTests` exists. The row's host
/// today is `AccountSheet`, and that sheet is hosted in this bundle (`AccountSheetRenderTests`),
/// but only over a `SessionStore` signed in through a scripted server, where the token's states
/// are whatever that server answers. On its own the row takes every state as a value, so each
/// one is put on a screen here and pressed.
@MainActor
@Suite("The device-token row in Settings")
struct DeviceTokenSectionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Somewhere a `@Sendable`-free binding can put what the row wrote, and the test can read it
    /// back afterwards.
    @MainActor
    private final class Draft {
        var value: String?
    }

    private func row(
        token: DeviceToken?,
        notice: String? = nil,
        isBusy: Bool = false,
        draft: Draft? = nil,
        rename: @escaping (String) -> Void = { _ in },
        renew: @escaping () -> Void = {}
    ) -> DeviceTokenSection {
        let held = draft ?? Draft()
        return DeviceTokenSection(
            token: token,
            notice: notice,
            now: now,
            isBusy: isBusy,
            draft: Binding(get: { held.value }, set: { held.value = $0 }),
            rename: rename,
            renew: renew
        )
    }

    private func token(
        name: String = "Fabian's iPhone",
        lastUsed: TimeInterval? = 120,
        expiresIn: TimeInterval? = 365 * 86_400
    ) -> DeviceToken {
        DeviceToken(
            name: name,
            createdAt: now.addingTimeInterval(-30 * 86_400),
            lastUsed: lastUsed.map { now.addingTimeInterval(-$0) },
            expiresAt: expiresIn.map { now.addingTimeInterval($0) }
        )
    }

    /// Whether the row SAYS something, wherever SwiftUI decided to put it. A substring rather than
    /// an equality, because a stack of `Text`s is sometimes handed to VoiceOver as one merged
    /// element and sometimes as several, and which of those happened is not what is being asserted
    /// here — that the words reached the screen is.
    private func says(_ words: String, _ labels: [String]) -> Bool {
        labels.contains { $0.contains(words) }
    }

    @Test("the row names the device, when it runs out and when it last spoke")
    func drawsTheRow() {
        let labels = ScreenProbe.labels(of: row(token: token()))

        #expect(says("This device", labels))
        #expect(says("Fabian's iPhone", labels))
        #expect(says("Expires in 365 days", labels))
        #expect(says("Last used 2 minutes ago", labels))
    }

    /// The probe's own control: it can answer no. Without this the four checks above would be
    /// worth nothing, because a probe that collected the whole world would satisfy them too.
    @Test("the row does not draw a name it was never given")
    func drawsNothingItWasNotGiven() {
        let labels = ScreenProbe.labels(of: row(token: token()))

        #expect(!says("Kitchen phone", labels))
    }

    /// The household's own token predates the bounded ones and has no expiry at all. Printing a
    /// date there — or nothing — would both be lies; it says the true thing.
    @Test("a token with no expiry says so rather than showing a date")
    func drawsAnUnboundedTokenHonestly() {
        let labels = ScreenProbe.labels(of: row(token: token(lastUsed: nil, expiresIn: nil)))

        #expect(says("Never expires", labels))
        #expect(says("Not used yet", labels))
        #expect(!says("Expires in", labels))
    }

    @Test("a row with nothing to show says the read failed rather than drawing an empty device")
    func drawsAnUnreadRow() {
        let labels = ScreenProbe.labels(of: row(token: nil))

        #expect(says(DeviceTokenPresentation.unread, labels))
        #expect(!says("Fabian's iPhone", labels))
    }

    @Test("a notice from the session is put on the row")
    func drawsItsNotice() {
        let labels = ScreenProbe.labels(of: row(token: token(), notice: "That did not work."))

        #expect(says("That did not work.", labels))
    }

    // MARK: - the affordances

    @Test("the rename affordance is on the screen, under the label VoiceOver reads")
    func renameIsLabelled() {
        let found = PressProbe.withElement(
            labelled: DeviceTokenPresentation.renameLabel,
            in: row(token: token())
        ) { $0 != nil }

        #expect(found, "no rename control on the device-token row")
    }

    /// The probe's control, the same one `SignOutSectionTests` keeps: it says no to a label the
    /// row does not carry.
    @Test("the probe answers no to a label the row does not have")
    func theProbeCanAnswerNo() {
        let found = PressProbe.withElement(
            labelled: "Forget this device",
            in: row(token: token())
        ) { $0 != nil }

        #expect(!found)
    }

    @Test("pressing rename opens the field on the device's current name")
    func pressingRenameOpensTheField() {
        let draft = Draft()

        let pressed = PressProbe.withElement(
            labelled: DeviceTokenPresentation.renameLabel,
            in: row(token: token(), draft: draft)
        ) { $0?.accessibilityActivate() ?? false }

        #expect(pressed, "the rename control did not accept an activation")
        #expect(draft.value == "Fabian's iPhone")
    }

    @Test("with the field open the row offers to save, and saving hands over what was typed")
    func savingSendsTheDraft() {
        let draft = Draft()
        draft.value = "Kitchen phone"
        let sent = Draft()

        let pressed = PressProbe.withElement(
            labelled: DeviceTokenPresentation.saveLabel,
            in: row(token: token(), draft: draft, rename: { sent.value = $0 })
        ) { $0?.accessibilityActivate() ?? false }

        #expect(pressed, "the save control did not accept an activation")
        #expect(sent.value == "Kitchen phone")
        #expect(draft.value == nil, "saving closes the field")
    }

    @Test("cancelling closes the field and sends nothing")
    func cancellingSendsNothing() {
        let draft = Draft()
        draft.value = "Kitchen phone"
        let sent = Draft()

        PressProbe.withElement(
            labelled: DeviceTokenPresentation.cancelLabel,
            in: row(token: token(), draft: draft, rename: { sent.value = $0 })
        ) { $0?.accessibilityActivate() }

        #expect(draft.value == nil)
        #expect(sent.value == nil)
    }

    @Test("the renew affordance is on the screen and asks the session when pressed")
    func renewIsWired() {
        let asked = Draft()

        let pressed = PressProbe.withElement(
            labelled: DeviceTokenPresentation.renewLabel,
            in: row(token: token(), renew: { asked.value = "asked" })
        ) { $0?.accessibilityActivate() ?? false }

        #expect(pressed, "the renew control did not accept an activation")
        #expect(asked.value == "asked")
    }

    /// While a rename or a renewal is in flight the row must not accept a second one — the renewal
    /// destroys the presenting token, and two of them in flight is one successor orphaned.
    @Test("nothing is sent while a call is already in flight")
    func busyRefusesASecondPress() {
        let asked = Draft()

        let onScreen = PressProbe.withElement(
            labelled: DeviceTokenPresentation.renewLabel,
            in: row(token: token(), isBusy: true, renew: { asked.value = "asked" })
        ) { element -> Bool in
            let present = element != nil
            element?.accessibilityActivate()
            return present
        }

        // The control stays where it was — it is unusable, not gone, so the row does not reflow
        // under the reader's finger — and pressing it sends nothing.
        #expect(onScreen, "the renew control left the screen instead of going quiet")
        #expect(asked.value == nil)
    }
}

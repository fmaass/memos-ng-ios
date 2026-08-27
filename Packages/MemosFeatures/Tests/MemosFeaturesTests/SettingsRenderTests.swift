import Foundation
import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// Drawing a piece of the Settings screen on a real device, and proving it drew something.
///
/// This repo's habit is that a screenshot is what a test CANNOT check, so the assertion here is
/// the one a picture could not make: that the view renders at all, and that the result is not a
/// blank rectangle. The image itself is emitted for whoever wants to look.
///
/// One SECTION of the Settings screen is rendered here — the Uploads one, which is the only
/// control on that screen that decides whether bytes leave the phone. It needs no session, so it
/// can be drawn; and unless it is drawn, nothing in this bundle can tell whether the screen has a
/// switch on it at all.
///
/// The SETTINGS SCREEN itself is deliberately not rendered here, and the reason is structural
/// rather than incidental: `SettingsView` reads `SessionStore` from the environment, and
/// constructing one inlines `APIClientFactory.make` from the API layer — which this bundle does
/// not link, because Features reaches the API through Core and never directly. Making the screen's
/// session optional to get around that would be defensive code written for a test, and adding the
/// API layer to this bundle would be the dependency rule bent for a screenshot. What the screen is
/// made of is held instead by `SettingsScreenTests` (which sections, in what order, and that none
/// is stubbed), by `SignOutSectionTests` (the one row that ends the session), and by the suites
/// over every function it draws from.
@MainActor
@Suite("The Settings screen draws")
struct SettingsRenderTests {
    /// Hosted in a real window and drawn from the hierarchy rather than through `ImageRenderer`:
    /// the rows are UIKit-backed once SwiftUI lays them out, and `ImageRenderer` sees only the
    /// SwiftUI content — which comes back as an empty background, exactly the blank rectangle
    /// `isNotBlank` exists to refuse.
    private func render(_ view: some View, size: CGSize) -> UIImage? {
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // Scale pinned rather than taken from the device: the gate picks whichever simulator the
        // build host has newest, and a capture whose pixel size depended on that would be a
        // different picture every time the runtime moved. 2x is legible and a quarter the bytes
        // of the 3x a Pro device would otherwise hand back.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format)
        let image = renderer.image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        return image
    }

    /// More than one colour in the frame. A render that failed politely hands back a single flat
    /// rectangle, which is exactly what a bare "it rendered" check would otherwise accept.
    private func isNotBlank(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage,
            let data = cgImage.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else { return false }
        let count = CFDataGetLength(data)
        guard count > 4 else { return false }
        let first = (bytes[0], bytes[1], bytes[2])
        // A prime stride, so the sampling cannot fall into step with the row width and read the
        // same column of an otherwise varied image over and over.
        for offset in stride(from: 0, to: count - 3, by: 401 * 4)
        where (bytes[offset], bytes[offset + 1], bytes[offset + 2]) != first {
            return true
        }
        return false
    }

    private func uploadsCard(isOn: Bool) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.regular) {
            UploadsSection(allowsMobileData: .constant(isOn))
        }
        .padding(DesignTokens.Space.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.card))
        .padding(DesignTokens.Space.roomy)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.systemGroupedBackground))
    }

    /// That the screen HAS this section is held by `SettingsScreenTests`, and what the store does
    /// when it changes by `UploadSettingsTests`. Between them sat the thing neither could see:
    /// whether the section draws a switch, and whether that switch is drawn from the setting
    /// rather than from nothing. Two renders that differ is the assertion — delete the `Toggle`,
    /// or pin its `isOn:` to a constant, and the two pictures become the same picture. The
    /// write direction is the binding in `SettingsView`, which the compiler requires and
    /// `UploadSettingsTests` follows to the store.
    @Test("the Uploads section draws a switch, and draws it from the setting")
    func uploadsSectionDrawsItsSwitch() throws {
        let size = CGSize(width: 393, height: 200)
        let off = try #require(render(uploadsCard(isOn: false), size: size))
        let on = try #require(render(uploadsCard(isOn: true), size: size))

        #expect(isNotBlank(off))
        #expect(isNotBlank(on))
        #expect(off.pngData() != on.pngData(), "the switch is drawn from the value it carries")
    }
}

/// A session that records what was asked of it and nothing more.
///
/// The narrow protocol (`SignOutRevoking`) exists so this can stand in for a `SessionStore`, which
/// this bundle cannot construct.
@MainActor
private final class SignOutSpy: SignOutRevoking {
    private(set) var revokes = 0
    private(set) var discards = 0
    var outcome = SignOutOutcome.revoked

    func signOut() async -> SignOutOutcome {
        revokes += 1
        return outcome
    }

    func signOutWithoutRevoking() async { discards += 1 }

    /// Returns once a revoke has actually been asked for, and gives up rather than hanging if one
    /// never is. A fence on the thing under test rather than a wait of a chosen length: the test
    /// cannot pass by having slept long enough, and it does not slow down when the machine is
    /// fast.
    func revokeAsked() async {
        for _ in 0..<200 where revokes == 0 { await Task.yield() }
    }
}

/// The row at the bottom of the Settings screen, which since MEMNG-185 is the app's ONLY way to
/// sign out.
///
/// Held here rather than by an assertion about `SettingsScreen.sections`, because a section that is
/// listed and a row that works are different claims: `SettingsView` cannot be hosted in this bundle
/// (it reads a `SessionStore`), so before `SignOutSection` was a view of its own, emptying the row
/// or cutting the line inside it left every test in the suite green while the app had no way out
/// of the account at all.
@MainActor
@Suite("The sign-out row on the Settings screen")
struct SignOutSectionTests {
    private func row(_ conversation: SignOutConversation, _ session: SignOutSpy) -> SignOutSection {
        SignOutSection(conversation: conversation, session: session)
    }

    @Test("the row puts a Sign out button on the screen")
    func theRowDraws() {
        let drawn = PressProbe.withElement(
            labelled: "Sign out",
            in: row(SignOutConversation(), SignOutSpy())
        ) { $0 != nil }

        #expect(drawn, "no Sign out button on the screen")
    }

    /// The probe's own control. Without this, "it found Sign out" would be worth nothing — a probe
    /// that answered yes to anything would say the same.
    @Test("the probe answers no to a label the row does not have")
    func theProbeCanAnswerNo() {
        let drawn = PressProbe.withElement(
            labelled: "Sign in",
            in: row(SignOutConversation(), SignOutSpy())
        ) { $0 != nil }

        #expect(!drawn)
    }

    /// The wiring, pressed rather than inspected: the button the screen ships, activated the way a
    /// screen reader activates it, moving the shared conversation the alerts are attached to.
    @Test("pressing the row asks the shared conversation, and asking revokes nothing")
    func pressingTheRowAsks() {
        let conversation = SignOutConversation()
        let session = SignOutSpy()
        #expect(conversation.stage == .idle)

        let pressed = PressProbe.withElement(labelled: "Sign out", in: row(conversation, session)) {
            $0?.accessibilityActivate() ?? false
        }

        #expect(pressed, "the Sign out button did not accept an activation")
        #expect(conversation.stage == .asking)
        // The whole point of the machine: the question is a question, and nothing has been sent.
        #expect(session.revokes == 0)
    }

    /// And the answer to that question does reach the server — asked through the conversation the
    /// row itself started, so this is the row's own path rather than a machine driven from
    /// nowhere.
    @Test("answering yes to the row's question revokes exactly once")
    func answeringYesRevokes() async {
        let conversation = SignOutConversation()
        let session = SignOutSpy()
        PressProbe.withElement(labelled: "Sign out", in: row(conversation, session)) {
            $0?.accessibilityActivate()
        }

        conversation.send(.confirmed, to: session)
        await session.revokeAsked()

        #expect(session.revokes == 1)
        #expect(session.discards == 0)
    }
}

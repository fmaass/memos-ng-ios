import Foundation
import MemosCore
import SwiftUI
import Testing

@testable import MemosFeatures

/// What the token-management screen says in each of the states it can be in.
///
/// Drawn rather than reasoned about, for the reason `DeviceTokenSectionTests` exists: the view
/// that owns the store cannot be hosted in this bundle, so a screen written inline in that body
/// would be a surface no test could see. Every state here is handed to the screen as a value,
/// which is also the only way three of them can be reached at all — a server without these routes
/// and a management session that has just run out are not things a rendered screen can arrange.
@MainActor
@Suite("The token-management screen")
struct ManageTokensScreenTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Somewhere a binding can put what the screen wrote, readable afterwards.
    @MainActor
    private final class Held<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private func screen(
        state: ManageTokensState,
        minted: MintedToken? = nil,
        secretLost: Bool = false,
        notice: String? = nil,
        isBusy: Bool = false,
        draft: Held<String>? = nil,
        signOn: @escaping () -> Void = {},
        create: @escaping (String) -> Void = { _ in },
        revoke: @escaping (Int) -> Void = { _ in },
        copySecret: @escaping (String) -> Void = { _ in },
        dismissSecret: @escaping () -> Void = {}
    ) -> ManageTokensScreen {
        let held = draft ?? Held("")
        return ManageTokensScreen(
            state: state,
            minted: minted,
            secretLost: secretLost,
            notice: notice,
            isBusy: isBusy,
            now: now,
            draft: Binding(get: { held.value }, set: { held.value = $0 }),
            signOn: signOn,
            create: create,
            revoke: revoke,
            copySecret: copySecret,
            dismissSecret: dismissSecret
        )
    }

    private func token(
        id: Int,
        name: String,
        expiresIn: TimeInterval? = 365 * 86_400,
        lastUsed: TimeInterval? = 120
    ) -> ManagedToken {
        ManagedToken(
            id: id,
            name: name,
            createdAt: now.addingTimeInterval(-30 * 86_400),
            lastUsed: lastUsed.map { now.addingTimeInterval(-$0) },
            expiresAt: expiresIn.map { now.addingTimeInterval($0) }
        )
    }

    /// Whether the screen SAYS something, wherever SwiftUI decided to put it. A substring rather
    /// than an equality, because a stack of `Text`s is sometimes handed to VoiceOver merged and
    /// sometimes not, and which of those happened is not what is being asserted.
    private func says(_ words: String, _ labels: [String]) -> Bool {
        labels.contains { $0.contains(words) }
    }

    // MARK: - the states that are not a list

    @Test("a screen that has not signed on says what a sign-on buys and offers one")
    func offersTheRoundTrip() {
        let labels = ScreenProbe.labels(of: screen(state: .locked(.never)))

        #expect(says("needs a fresh sign-in", labels))
        #expect(says(ManageTokensPresentation.signOnLabel, labels))
    }

    /// The probe's own control: it can answer no. Without it every check here would be satisfied
    /// by a probe that collected the whole world.
    @Test("the screen does not say things it was never given")
    func saysNothingItWasNotGiven() {
        let labels = ScreenProbe.labels(of: screen(state: .locked(.never)))

        #expect(!says("Kitchen phone", labels))
    }

    /// A management session is minutes long by design, so its end is an ordinary sentence and the
    /// way out of it is the same round trip — never an error somebody has to interpret.
    @Test("an ended session says so and offers the round trip again")
    func expiryLandsInTheReauthState() {
        let labels = ScreenProbe.labels(of: screen(state: .locked(.expired)))

        #expect(says("management session has ended", labels))
        #expect(says(ManageTokensPresentation.signOnLabel, labels))
    }

    /// The process-loss face of the same state: the app was put away and the grant went with it,
    /// which is what "in memory only" means rather than something that went wrong.
    @Test("a session dropped by the app going away says that, and not that something failed")
    func processLossReadsAsWhatItIs() {
        let labels = ScreenProbe.labels(of: screen(state: .locked(.discarded)))

        #expect(says("app was put away", labels))
        #expect(says(ManageTokensPresentation.signOnLabel, labels))
    }

    /// The build can ship before the deploy that carries these routes. When it does, this screen
    /// says so — it does not crash, and it does not sit on a spinner nobody can end.
    @Test("a server without token management says so, and offers no sign-on to nowhere")
    func degradesHonestly() {
        let labels = ScreenProbe.labels(of: screen(state: .unsupported))

        #expect(says("does not offer token management", labels))
        #expect(!says(ManageTokensPresentation.signOnLabel, labels))
        #expect(!says(ManageTokensPresentation.createLabel, labels))
    }

    @Test("a sign-on in progress says so instead of showing an empty list")
    func authenticatingSaysSo() {
        let labels = ScreenProbe.labels(of: screen(state: .authenticating))

        #expect(says(ManageTokensPresentation.signingOn, labels))
        #expect(!says(ManageTokensPresentation.signOnLabel, labels))
    }

    @Test("an account with no tokens says so rather than showing an empty card")
    func emptyListSaysSo() {
        let labels = ScreenProbe.labels(of: screen(state: .listed([])))

        #expect(says(ManageTokensPresentation.empty, labels))
    }

    // MARK: - the list

    @Test("the list names every token, when it runs out and when it last spoke")
    func drawsTheList() {
        let labels = ScreenProbe.labels(
            of: screen(
                state: .listed([
                    token(id: 1, name: "Kitchen phone"),
                    token(id: 7, name: "Laptop", expiresIn: nil, lastUsed: nil),
                ])
            )
        )

        #expect(says("Kitchen phone", labels))
        #expect(says("Laptop", labels))
        #expect(says("Expires in 365 days", labels))
        #expect(says("Never expires", labels))
        #expect(says("Not used yet", labels))
    }

    /// A screen reader reaching a column of identical "Revoke" buttons cannot tell which token it
    /// is about to destroy, so every one of them is named.
    @Test("each row's revoke control is named after its own token")
    func revokeControlsAreNamed() {
        let list = screen(
            state: .listed([token(id: 1, name: "Kitchen phone"), token(id: 7, name: "Laptop")])
        )

        #expect(
            PressProbe.withElement(labelled: "Revoke Kitchen phone", in: list) { $0 != nil }
        )
        #expect(PressProbe.withElement(labelled: "Revoke Laptop", in: list) { $0 != nil })
        #expect(!PressProbe.withElement(labelled: "Revoke Garage phone", in: list) { $0 != nil })
    }

    /// The whole reason this screen exists: the grant is the authority here, so a token belonging
    /// to another device can be taken away from the phone that is still holding it.
    @Test("pressing a sibling's revoke asks for that token and no other")
    func revokingASiblingSendsItsId() {
        let asked = Held<Int?>(nil)

        let pressed = PressProbe.withElement(
            labelled: "Revoke Laptop",
            in: screen(
                state: .listed([token(id: 1, name: "Kitchen phone"), token(id: 7, name: "Laptop")]),
                revoke: { asked.value = $0 }
            )
        ) { $0?.accessibilityActivate() ?? false }

        #expect(pressed, "the revoke control did not accept an activation")
        #expect(asked.value == 7)
    }

    @Test("creating hands over the name that was typed")
    func creatingSendsTheDraft() {
        let draft = Held("Laptop")
        let sent = Held<String?>(nil)

        let pressed = PressProbe.withElement(
            labelled: ManageTokensPresentation.createLabel,
            in: screen(state: .listed([]), draft: draft, create: { sent.value = $0 })
        ) { $0?.accessibilityActivate() ?? false }

        #expect(pressed, "the create control did not accept an activation")
        #expect(sent.value == "Laptop")
    }

    /// While a call is in flight the controls go quiet rather than leaving the screen, so the list
    /// does not reflow under the reader's finger — and pressing one sends nothing.
    @Test("nothing is sent while a call is already in flight")
    func busyRefusesASecondPress() {
        let asked = Held<Int?>(nil)

        let onScreen = PressProbe.withElement(
            labelled: "Revoke Laptop",
            in: screen(
                state: .listed([token(id: 7, name: "Laptop")]),
                isBusy: true,
                revoke: { asked.value = $0 }
            )
        ) { element -> Bool in
            let present = element != nil
            element?.accessibilityActivate()
            return present
        }

        #expect(onScreen, "the revoke control left the screen instead of going quiet")
        #expect(asked.value == nil)
    }

    // MARK: - the one look at a new token

    @Test("a created token shows its text, says it is the only look, and offers to copy it")
    func showsTheSecretOnce() {
        let minted = MintedToken(
            token: token(id: 9, name: "Laptop", expiresIn: nil, lastUsed: nil),
            secret: "memos_pat_brand_new"
        )
        let labels = ScreenProbe.labels(of: screen(state: .listed([]), minted: minted))

        #expect(says("memos_pat_brand_new", labels))
        #expect(says("only time this token is shown", labels))
        #expect(says(ManageTokensPresentation.copyLabel, labels))
    }

    @Test("copying hands over the token text itself")
    func copyingSendsTheSecret() {
        let copied = Held<String?>(nil)
        let minted = MintedToken(
            token: token(id: 9, name: "Laptop"),
            secret: "memos_pat_brand_new"
        )

        let pressed = PressProbe.withElement(
            labelled: ManageTokensPresentation.copyLabel,
            in: screen(state: .listed([]), minted: minted, copySecret: { copied.value = $0 })
        ) { $0?.accessibilityActivate() ?? false }

        #expect(pressed, "the copy control did not accept an activation")
        #expect(copied.value == "memos_pat_brand_new")
    }

    /// A text that went away without being read is said out loud: the token still works and can
    /// still be revoked, and only its text is unrecoverable. Showing one panel fewer would leave
    /// somebody believing they had copied something they had not.
    @Test("a plaintext lost to the app going away says so, and says the token is still there")
    func aLostSecretIsAnnounced() {
        let labels = ScreenProbe.labels(
            of: screen(state: .locked(.discarded), secretLost: true)
        )

        #expect(says("shown once and only once", labels))
        #expect(says("sign in again to find it in the list", labels))
    }

    @Test("a notice from the store is put on the screen")
    func drawsItsNotice() {
        let labels = ScreenProbe.labels(
            of: screen(state: .listed([]), notice: "That token was already gone.")
        )

        #expect(says("That token was already gone.", labels))
    }

    // MARK: - the row that opens it

    @Test("the Settings row is on the screen under the label VoiceOver reads")
    func theSettingsRowIsLabelled() {
        #expect(
            PressProbe.withElement(
                labelled: ManageTokensPresentation.rowLabel,
                in: ManageTokensRow(open: {})
            ) { $0 != nil }
        )
    }

    /// The row says what the tap costs. A row that opened the household sign-on without warning
    /// would be a surprise, and this screen cannot be reached any other way.
    @Test("the row says a fresh sign-in is what it costs")
    func theRowNamesItsPrice() {
        let labels = ScreenProbe.labels(of: ManageTokensRow(open: {}))

        #expect(says("fresh sign-in", labels))
    }

    @Test("pressing the row opens token management")
    func pressingTheRowOpensIt() {
        let opened = Held(false)

        let pressed = PressProbe.withElement(
            labelled: ManageTokensPresentation.rowLabel,
            in: ManageTokensRow(open: { opened.value = true })
        ) { $0?.accessibilityActivate() ?? false }

        #expect(pressed, "the row did not accept an activation")
        #expect(opened.value)
    }
}

/// The sentences themselves, held to the distinctions they exist to make.
@Suite("What token management says about itself")
struct ManageTokensPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Four states, four sentences. They are not interchangeable: "the app was put away" and
    /// "that session ended" answer different questions, and a screen that said the same thing for
    /// both would be telling somebody the wrong story about their own phone.
    @Test("every reason for asking to sign on has its own words")
    func eachLockHasItsOwnLine() {
        let lines = [
            ManageTokensPresentation.lockLine(.never),
            ManageTokensPresentation.lockLine(.expired),
            ManageTokensPresentation.lockLine(.discarded),
            ManageTokensPresentation.lockLine(.refused(.cancelled)),
        ]

        #expect(Set(lines).count == 4)
        #expect(lines.allSatisfy { !$0.isEmpty })
    }

    /// The one refusal with nothing to say is a sign-on already on screen. It falls back to the
    /// opening line rather than to an empty label under the button.
    @Test("a silent refusal still leaves a sentence on the screen")
    func aSilentRefusalStillSaysSomething() {
        #expect(
            ManageTokensPresentation.lockLine(.refused(.alreadySigningIn))
                == ManageTokensPresentation.lockLine(.never)
        )
    }

    @Test("a refusal that has something to say says it")
    func aRefusalCarriesItsReason() {
        let line = ManageTokensPresentation.lockLine(.refused(.malformedCallback))

        #expect(line == NativeLoginError.malformedCallback.message)
    }

    /// The same arithmetic the device row uses, because it is the same question about the same
    /// kind of row.
    @Test("a token's detail line names its expiry and when it last spoke")
    func detailLine() {
        let token = ManagedToken(
            id: 1,
            name: "Laptop",
            createdAt: now.addingTimeInterval(-86_400),
            lastUsed: now.addingTimeInterval(-120),
            expiresAt: nil
        )

        #expect(
            ManageTokensPresentation.detail(token, now: now)
                == "Never expires · Last used 2 minutes ago"
        )
    }
}

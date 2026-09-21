import Foundation
import MemosCore
import SwiftUI
import Testing

@testable import MemosFeatures

/// What the token-management screen says in each of the states it can be in.
///
/// Drawn rather than reasoned about, for the reason `DeviceTokenSectionTests` exists: the view
/// that owns the store puts it through the whole token flow — a management sign-on in a browser
/// sheet, and a grant — and a screen written inline in that body could only be reached by running
/// it. Every state here is handed to the screen as a value,
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
        appAccountName: String = "fabian@example.invalid",
        minted: MintedToken? = nil,
        secretLost: Bool = false,
        notice: String? = nil,
        isBusy: Bool = false,
        draft: Held<String>? = nil,
        pending: Held<ManagedToken?>? = nil,
        signOn: @escaping () -> Void = {},
        reread: @escaping () -> Void = {},
        create: @escaping (String) -> Void = { _ in },
        revoke: @escaping (Int) -> Void = { _ in },
        copySecret: @escaping () -> Void = {},
        dismissSecret: @escaping () -> Void = {}
    ) -> ManageTokensScreen {
        let held = draft ?? Held("")
        let asked = pending ?? Held(nil)
        return ManageTokensScreen(
            state: state,
            appAccountName: appAccountName,
            minted: minted,
            secretLost: secretLost,
            notice: notice,
            isBusy: isBusy,
            now: now,
            draft: Binding(get: { held.value }, set: { held.value = $0 }),
            pendingRevoke: Binding(get: { asked.value }, set: { asked.value = $0 }),
            signOn: signOn,
            reread: reread,
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

        #expect(says("goes through the browser's sign-in", labels))
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

    /// A read that did not arrive is not a session that ended, and the difference is the whole
    /// sentence: one is mended by pressing something here, the other by buying another sign-on.
    @Test("a session whose list did not arrive says the session is still good")
    func anUnlistedSessionSaysItIsStillLive() {
        let labels = ScreenProbe.labels(of: screen(state: .unlisted))

        #expect(says("could not be read", labels))
        #expect(says(ManageTokensPresentation.rereadLabel, labels))
        #expect(!says(ManageTokensPresentation.signingOn, labels))
    }

    /// The affordance itself: without something to press, a first read that failed is a screen with
    /// a live grant on it and no way to spend it.
    @Test("pressing the read-again control asks for the list once")
    func rereadingAsksForTheListOnce() {
        let asked = Held(0)

        let pressed = PressProbe.withElement(
            labelled: ManageTokensPresentation.rereadLabel,
            in: screen(state: .unlisted, reread: { asked.value += 1 })
        ) { $0?.accessibilityActivate() ?? false }

        #expect(pressed, "the read-again control did not accept an activation")
        #expect(asked.value == 1)
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

    /// The screen's one statement of what it cannot check, where it is still a warning rather than
    /// an explanation: it names the account the APP is signed in as, says the list may not be that
    /// account's, and is read before anything here can mint or destroy a token. Order is asserted
    /// and not only presence, because the same sentence under the list would be an account
    /// somebody learns about after revoking somebody else's token.
    @Test("the unverified account is stated before Create and before every Revoke")
    func theAccountStatementComesBeforeAnythingThatChangesTokens() throws {
        let listed = ScreenProbe.labels(
            of: screen(
                state: .listed([token(id: 1, name: "Kitchen phone"), token(id: 7, name: "Laptop")]),
                appAccountName: "fabian@example.invalid"
            ),
            size: CGSize(width: 393, height: 1400)
        )

        #expect(says("signed in as fabian@example.invalid", listed))
        let statement = try #require(
            listed.firstIndex { $0.contains("cannot verify that these are the same account") },
            "the listed screen never said the two accounts are unverified"
        )
        let create = try #require(
            listed.firstIndex { $0.contains(ManageTokensPresentation.createLabel) },
            "the listed screen had no create control for the statement to be ahead of"
        )
        // Every occurrence, not the first: a control is reached through more than one branch of
        // the tree the probe walks, and it is the LAST of them the statement has to precede.
        let revokes = listed.indices.filter {
            listed[$0] == ManageTokensPresentation.revokeLabel(for: "Kitchen phone")
                || listed[$0] == ManageTokensPresentation.revokeLabel(for: "Laptop")
        }

        #expect(
            listed.contains(ManageTokensPresentation.revokeLabel(for: "Kitchen phone")),
            "the first token's revoke control was not on the screen"
        )
        #expect(
            listed.contains(ManageTokensPresentation.revokeLabel(for: "Laptop")),
            "the second token's revoke control was not on the screen"
        )
        #expect(statement < create, "the statement was read after the create control")
        #expect(revokes.allSatisfy { statement < $0 }, "a revoke control was read before it")

        // Before the sign-on there is no list, and the opening line already carries the statement.
        // Saying it twice would read as two different rules about two different things.
        let locked = ScreenProbe.labels(of: screen(state: .locked(.never)))

        #expect(says("cannot verify that it is the same account as its own", locked))
        #expect(!says("close this screen before creating or revoking tokens", locked))
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
    /// to another device can be taken away from the phone that is still holding it. The press
    /// takes nothing away by itself — it names the token the question is about, and the question's
    /// own answer is what sends anything.
    @Test("pressing a sibling's revoke asks about that token and sends nothing yet")
    func revokingASiblingSendsItsId() {
        let asked = Held<Int?>(nil)
        let pending = Held<ManagedToken?>(nil)

        let pressed = PressProbe.withElement(
            labelled: "Revoke Laptop",
            in: screen(
                state: .listed([token(id: 1, name: "Kitchen phone"), token(id: 7, name: "Laptop")]),
                pending: pending,
                revoke: { asked.value = $0 }
            )
        ) { $0?.accessibilityActivate() ?? false }

        #expect(pressed, "the revoke control did not accept an activation")
        #expect(asked.value == nil, "the press took the token away without asking first")
        #expect(pending.value?.id == 7)
    }

    /// The busy guard is visible only through the pending binding. The case above watches the
    /// revoke callback, and a press on this screen never calls that back at all — it raises a
    /// question — so that case reads the same whether the control is quiet or not. This one reads
    /// what a press would have written.
    @Test("a revoke pressed while a call is in flight asks about nothing")
    func busyPressSetsNoPendingToken() {
        let asked = Held<Int?>(nil)
        let pending = Held<ManagedToken?>(nil)

        let onScreen = PressProbe.withElement(
            labelled: "Revoke Laptop",
            in: screen(
                state: .listed([token(id: 7, name: "Laptop")]),
                isBusy: true,
                pending: pending,
                revoke: { asked.value = $0 }
            )
        ) { element -> Bool in
            let present = element != nil
            element?.accessibilityActivate()
            return present
        }

        #expect(onScreen, "the revoke control left the screen instead of going quiet")
        #expect(pending.value == nil, "a busy press raised the question anyway")
        #expect(asked.value == nil)
    }

    /// A management session that ended, or an app that was put away, takes the list with it —
    /// and the question was about a row of that list.
    @Test("a question does not outlive the list it was raised from")
    func aPendingRevokeGoesWithItsList() {
        let pending = Held<ManagedToken?>(token(id: 7, name: "Laptop"))

        RedrawProbe.host(
            screen(state: .listed([token(id: 7, name: "Laptop")]), pending: pending),
            then: screen(state: .locked(.discarded), pending: pending)
        )

        #expect(pending.value == nil)
    }

    /// A list that came back without the token is the same thing said differently: the row the
    /// question named is not on the screen any more.
    @Test("a question about a token the list no longer names is withdrawn")
    func aPendingRevokeGoesWhenItsRowDoes() {
        let pending = Held<ManagedToken?>(token(id: 7, name: "Laptop"))

        RedrawProbe.host(
            screen(state: .listed([token(id: 7, name: "Laptop")]), pending: pending),
            then: screen(state: .listed([token(id: 1, name: "Kitchen phone")]), pending: pending)
        )

        #expect(pending.value == nil)
    }

    /// The question's own two answers, rendered on their own. A presented dialog is drawn by the
    /// system outside the hosted tree, so these are pressed where a test can watch them.
    @Test("confirming asks for the token the question was raised about")
    func confirmingRevokesThatToken() {
        let asked = Held<[Int]>([])
        let buttons = RevokeConfirmationButtons(
            token: token(id: 7, name: "Laptop"),
            confirm: { asked.value.append($0) },
            cancel: {}
        )

        let pressed = PressProbe.withElement(
            labelled: ManageTokensPresentation.revokeTitle,
            in: buttons
        ) { $0?.accessibilityActivate() ?? false }

        #expect(pressed, "the confirming control did not accept an activation")
        #expect(asked.value == [7])
    }

    @Test("cancelling the question asks for nothing")
    func cancellingRevokesNothing() {
        let asked = Held<[Int]>([])
        let cancelled = Held(0)
        let buttons = RevokeConfirmationButtons(
            token: token(id: 7, name: "Laptop"),
            confirm: { asked.value.append($0) },
            cancel: { cancelled.value += 1 }
        )

        let pressed = PressProbe.withElement(
            labelled: ManageTokensPresentation.cancelTitle,
            in: buttons
        ) { $0?.accessibilityActivate() ?? false }

        #expect(pressed, "the cancelling control did not accept an activation")
        #expect(asked.value.isEmpty)
        #expect(cancelled.value == 1)
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

    /// The store refuses a create while a plaintext is still up — minting over it would take a live
    /// token's only copy away from somebody who has not read it yet. The control says the same
    /// thing, because a press whose one possible outcome is a sentence explaining itself is not an
    /// offer.
    @Test("nothing is created while a token's text is still on screen")
    func creatingIsRefusedWhileASecretShows() {
        let draft = Held("Laptop")
        let sent = Held<String?>(nil)
        let minted = MintedToken(
            token: token(id: 9, name: "Laptop"),
            secret: "memos_pat_brand_new"
        )

        let onScreen = PressProbe.withElement(
            labelled: ManageTokensPresentation.createLabel,
            in: screen(
                state: .listed([]),
                minted: minted,
                draft: draft,
                create: { sent.value = $0 }
            ),
            // The plaintext panel sits above the card Create is in, and a list only builds the
            // rows it has room for.
            height: 1200
        ) { element -> Bool in
            let present = element != nil
            element?.accessibilityActivate()
            return present
        }

        #expect(onScreen, "the create control left the screen instead of going quiet")
        #expect(sent.value == nil)
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

    /// The control hands over no text: what is copied is read where the copying happens, so all the
    /// screen owes is exactly one ask per press.
    @Test("copying asks once, and hands over no text of its own")
    func copyingAsksForTheSecret() {
        let asked = Held(0)
        let minted = MintedToken(
            token: token(id: 9, name: "Laptop"),
            secret: "memos_pat_brand_new"
        )

        let pressed = PressProbe.withElement(
            labelled: ManageTokensPresentation.copyLabel,
            in: screen(state: .listed([]), minted: minted, copySecret: { asked.value += 1 })
        ) { $0?.accessibilityActivate() ?? false }

        #expect(pressed, "the copy control did not accept an activation")
        #expect(asked.value == 1)
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

    /// The row says what the tap costs and where the answer comes from. A row that opened the
    /// household sign-on without warning would be a surprise, and this screen cannot be reached
    /// any other way; a row that promised this account's tokens would be promising something the
    /// browser decides.
    @Test("the row says which sign-in it costs and whose tokens that gets")
    func theRowNamesItsPriceAndItsAccount() {
        let labels = ScreenProbe.labels(of: ManageTokensRow(open: {}))

        #expect(says("browser's sign-in", labels))
        #expect(says("manages the account signed in there", labels))
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

    /// Five states, five sentences. They are not interchangeable: "the app was put away", "that
    /// session ended" and "that sign-in never came back" answer different questions, and a screen
    /// that said the same thing for them would be telling somebody the wrong story about their own
    /// phone.
    @Test("every reason for asking to sign on has its own words")
    func eachLockHasItsOwnLine() {
        let lines = [
            ManageTokensPresentation.lockLine(.never),
            ManageTokensPresentation.lockLine(.expired),
            ManageTokensPresentation.lockLine(.discarded),
            ManageTokensPresentation.lockLine(.unanswered),
            ManageTokensPresentation.lockLine(.refused(.cancelled)),
        ]

        #expect(Set(lines).count == 5)
        #expect(lines.allSatisfy { !$0.isEmpty })
    }

    /// A sign-on that produced no answer has to end in words rather than in a spinner nobody can
    /// stop: nothing was bought, so the sentence says what ran out and offers the way back.
    @Test("a sign-on that never came back is said in words, and says nothing was lost")
    func anUnansweredSignOnSaysWhatHappened() {
        let line = ManageTokensPresentation.lockLine(.unanswered)

        #expect(line.contains("did not come back"))
        #expect(line != ManageTokensPresentation.lockLine(.never))
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

    /// Each of the three reasons on its own, so that one of them holding is not mistaken for all
    /// three — the plaintext one above all, which is the store's own refusal said in the only place
    /// the screen can say it before the tap.
    @Test("create is offered only with a name typed, nothing in flight and no plaintext up")
    func createIsOfferedOnlyWhenItWouldBeAccepted() {
        #expect(
            !ManageTokensPresentation.createIsDisabled(
                isBusy: false, secretShowing: false, draft: "Laptop"
            )
        )
        #expect(
            ManageTokensPresentation.createIsDisabled(
                isBusy: false, secretShowing: true, draft: "Laptop"
            )
        )
        #expect(
            ManageTokensPresentation.createIsDisabled(
                isBusy: true, secretShowing: false, draft: "Laptop"
            )
        )
        #expect(
            ManageTokensPresentation.createIsDisabled(
                isBusy: false, secretShowing: false, draft: "   "
            )
        )
    }
}

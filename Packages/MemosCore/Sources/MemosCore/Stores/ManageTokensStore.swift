import Foundation
import MemosAPI

/// Why the management screen is asking for a sign-on rather than showing a list.
///
/// Four reasons, and they are told apart because they read differently to the person in front of
/// the phone: one of them is the ordinary opening state, one is a deadline that passed, one is the
/// app having been put away, and one is a round trip that went wrong and has something to say.
public enum ManageTokensLock: Sendable, Equatable {
    /// Nothing has been asked for yet — the screen as it opens.
    case never
    /// The grant ran out, or the server refused it. A management session is minutes long by
    /// design, so this is the ordinary end of one rather than a failure.
    case expired
    /// The screen went away or the app was backgrounded, and the grant went with it. Not a
    /// failure either: it is what "in memory only" means, said out loud.
    case discarded
    /// The round trip did not produce a grant, carrying what went wrong.
    case refused(NativeLoginError)
}

/// Where the management screen is.
///
/// `unsupported` is a state of its own rather than a failure notice because it is not one: a server
/// that does not offer these routes yet is a deployment that has not caught up with this build, and
/// the honest thing to say is that it does not offer this yet. It exists so that shipping the app
/// before the backend deploy can never strand this screen on a spinner or an error nobody can act
/// on.
public enum ManageTokensState: Sendable, Equatable {
    case locked(ManageTokensLock)
    /// The sign-on is on screen, or its code is being traded for a grant.
    case authenticating
    /// A live grant, and the account's tokens as the server last listed them.
    case listed([ManagedToken])
    /// A live grant and no list: the read that should have brought one did not arrive. What went
    /// wrong is in `notice`, and the way out is another read rather than another sign-on — the
    /// minutes this session was bought for are still running.
    case unlisted
    /// This server has no token management for a native client at all.
    case unsupported
}

/// The account's tokens, for as long as one management session lasts.
///
/// It is NOT part of `SessionStore` and does not touch it, which is the design rather than a
/// separation of concerns. The session holds the device's personal access token; this holds a
/// step-up grant bought with a fresh household sign-on; and the two credentials must never meet.
/// A device token mints and revokes nothing but itself (ADR-0015), so the capability to manage the
/// account's tokens is bought with an authentication and expires in minutes — and the only client
/// that reaches `/api/pats` is the one built here, from the grant alone, which has no way to see
/// the session's token at all.
///
/// The grant lives in this object and nowhere else: not in the Keychain, not in `UserDefaults`,
/// not in a file. It dies with the screen, with the app going to the background, with its own
/// deadline and with the process. Every path back to a list therefore goes through another
/// sign-on, and that is the whole point of the design rather than a limitation of it.
///
/// A 401 here NEVER ends the app's session. It is a refusal of the grant, which says nothing
/// whatever about the device token the rest of the app is holding; treating it as a sign-out would
/// log somebody out of their timeline because a management session of ten minutes ran out.
@MainActor
@Observable
public final class ManageTokensStore {
    public private(set) var state: ManageTokensState = .locked(.never)
    /// The token created in THIS management session, with the one look anybody gets at its
    /// plaintext. `nil` once it has been dismissed or lost.
    ///
    /// Fenced on the identity the secret was minted under, and judged HERE, as the screen reads:
    /// the session withdraws its handle synchronously and this sheet is torn down afterwards, so
    /// between those two instants a panel showing somebody's full-access token — with its Copy
    /// action live — belongs to an account nobody is signed in to. Everything the screen can see of
    /// a plaintext comes through this one read, so there is one answer to it.
    public var minted: MintedToken? { appIdentityHolds ? heldMinted : nil }
    /// The only copy of the plaintext there will ever be. Held for as long as the panel showing it
    /// can be read, and dropped from memory at the next touch of the store under an identity that
    /// has gone — at the latest by the screen's own teardown.
    private var heldMinted: MintedToken?
    /// A plaintext that went away without being dismissed — the app was backgrounded, the grant
    /// ran out, the screen was left. The token still exists and can still be revoked from the
    /// list; its text cannot come back, and the screen says so rather than quietly showing one
    /// fewer panel.
    ///
    /// Judged HERE too, for the same reason the plaintext is: a notice raised while the identity
    /// still held was true at the instant it was written, and nothing comes along afterwards to
    /// take it back — so a sheet still up when the sign-out lands would tell whoever signs in next
    /// that a token was minted on an account they are not holding.
    public var mintedSecretLost: Bool { appIdentityHolds && heldSecretLost }
    /// Whether a loss was announced at all. Who it is announced to is the read above.
    private var heldSecretLost = false
    /// A call is on the wire. The controls go quiet rather than disappearing.
    public private(set) var isBusy = false
    /// What went wrong with the last list, create or revoke, when it was not the grant ending.
    /// `nil` when there is nothing to say.
    public private(set) var notice: String?

    private let configuration: ServerConfiguration
    /// The one copy of the grant on this device, and the same object the client's middleware reads.
    private let grant: ManagementGrant
    /// Built ONCE, from the grant alone. It is also what buys the grant, made before there is one
    /// to present — the mint request is anonymous by construction.
    private let client: any APIProtocol
    /// Injected so a test can decide that a deadline has passed without waiting for it.
    private let now: @Sendable () -> Date
    /// Which management session this is. Bumped by every sign-on, every discard and every lapse,
    /// because each of them changes whose grant the answers still in the air belong to. A reply
    /// can outlive the question here as easily as anywhere else in the app.
    private var generation = 0
    /// The operation in flight, if there is one. `nil` means the store is free to start another.
    private var runningWork: Int?
    /// Only ever goes up, so one piece of work can never be mistaken for a later one — which is
    /// what lets an abandoned operation tell that the gate it is about to hand back is no longer
    /// the one it took.
    private var workSequence = 0

    /// The app session this management session is a step-up on, and the incarnation it was bought
    /// under.
    ///
    /// A grant speaks for one signed-in identity and means nothing once that identity is gone. The
    /// screen's own teardown cannot stand in for the question: the session withdraws its client and
    /// its incarnation synchronously, and the sheet goes away afterwards.
    private let session: (any SessionReporting)?
    private let boughtUnder: Int?

    public init(
        configuration: ServerConfiguration,
        session: (any SessionReporting)? = nil,
        makeClient: (ServerConfiguration, ManagementGrant, GrantSendLicence) -> any APIProtocol = {
            APIClientFactory.make(configuration: $0, grant: $1, licence: $2)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let grant = ManagementGrant()
        // Read off the main actor, at the instant a request leaves: a check made here, where the
        // work was started, cannot speak for the moment the transport sends.
        let licence: GrantSendLicence
        if let incarnation = session?.sessionIncarnation {
            let granted = incarnation.current
            licence = GrantSendLicence { incarnation.isCurrent(granted) }
        } else {
            licence = GrantSendLicence { true }
        }
        self.configuration = configuration
        self.session = session
        self.boughtUnder = session?.activeHandle?.generation
        self.grant = grant
        self.client = makeClient(configuration, grant, licence)
        self.now = now
    }

    /// Built from the base URL the session is signed in to.
    ///
    /// It exists because the layer above cannot name a `ServerConfiguration`: that type belongs to
    /// the API layer, and the screens layer reaches the API through this one and never directly
    /// (the dependency rule, checked by the gate). A URL is a thing both layers can say.
    public convenience init(serverBaseURL: URL, session: any SessionReporting) {
        self.init(configuration: ServerConfiguration(baseURL: serverBaseURL), session: session)
    }

    // MARK: - buying a management session

    /// The step-up: the same browser sign-on the app signs in with, asking for a grant instead of
    /// a device token, and then the account's tokens under it.
    ///
    /// The verifier is destroyed on every path out of here, success or failure, exactly as the
    /// sign-in destroys its own: it is the half of the pair that makes an intercepted code
    /// useless, and it has no purpose after the mint.
    @discardableResult
    public func authenticate(
        deviceName: String,
        presenter: any NativeLoginPresenter,
        pkce: PKCE = PKCE()
    ) async -> Bool {
        defer { pkce.zeroize() }
        // A second tap while the browser view is up opens nothing: the view in front of the person
        // is the affordance, and a second round trip would leave one of them unresolvable.
        if case .authenticating = state { return false }

        guard
            let authorizeURL = NativeLogin.authorizeURL(
                configuration: configuration,
                codeChallenge: pkce.challenge,
                device: deviceName,
                purpose: .manage
            ),
            let callbackHost = NativeLogin.callbackHost(for: configuration)
        else {
            dropGrant()
            state = .locked(.refused(.unusableRequest))
            return false
        }

        // The grant being replaced does not outlive the tap that replaced it.
        dropGrant()
        generation += 1
        // Any operation still in the air belongs to the session just ended. Its gate is handed
        // back here rather than when it lands, or the read this sign-on finishes with would be
        // refused by a dead operation and the screen would sit on its spinner.
        runningWork = nil
        let mine = generation
        state = .authenticating
        notice = nil
        do {
            let callbackURL = try await presenter.authenticate(
                authorizeURL: authorizeURL,
                callbackHost: callbackHost,
                callbackPath: NativeLogin.callbackPath
            )
            // The one reading of a callback URL in this app, shared with the sign-in lane: a
            // second copy of it here would be a second answer to "did this come back with a code".
            let code = try SessionStore.code(from: callbackURL)
            guard let verifier = pkce.verifier else { throw NativeLoginError.unusableRequest }
            // The browser is gone for as long as the person is in it, and what it comes back to
            // may no longer be the app it left. Asked before the exchange and not only after it:
            // a handoff code spent here would buy a management session for an identity that has
            // already been withdrawn, and the grant it bought would outlive the sign-out.
            guard isCurrent(mine) else { return false }
            let held = try await Self.mintGrant(client, code: code, verifier: verifier)
            guard isCurrent(mine) else { return false }
            grant.hold(held.grant, until: held.expiresAt)
            MemosLog.session.info("POST /api/auth/native/manage-grant -> 200")
            await refresh()
            return true
        } catch is RouteMissing {
            guard isCurrent(mine) else { return false }
            state = .unsupported
            return false
        } catch let error as NativeLoginError {
            guard isCurrent(mine) else { return false }
            state = .locked(.refused(error))
            return false
        } catch {
            guard isCurrent(mine) else { return false }
            // Named by what the failure WAS, never by its own description: this request's body is
            // the handoff code and the PKCE verifier, and the error text carries the request.
            state = .locked(.refused(.transport(NativeLoginTransportFailure.classify(error))))
            return false
        }
    }

    // MARK: - the tokens themselves

    /// Re-reads the account's tokens. The one place a list on screen comes from.
    public func refresh() async {
        guard let work = beginWork() else { return }
        await reload(work)
        endWork(work)
    }

    /// The list read every path shares, under work its caller already holds.
    ///
    /// Apart from `refresh()` because a create's read-back must not have to take the gate its own
    /// create is still holding — and because only a caller that still owns its work may write the
    /// screen with what comes back.
    private func reload(_ work: Work) async {
        do {
            let rows = try await Self.list(client)
            guard isCurrent(work) else { return }
            state = .listed(rows)
            notice = nil
        } catch {
            guard isCurrent(work) else { return }
            report(error)
            // A read that failed with nothing yet on screen has to land somewhere it can be asked
            // again from. Left as it was, the sign-on this list belongs to is still "in progress":
            // the screen draws a spinner with nothing to press, and the round trip that would mend
            // it is refused for being already under way. A failure with a list already on screen
            // keeps that list — it is still the last thing the server said.
            if case .authenticating = state { state = .unlisted }
        }
    }

    /// Mints a token and shows its plaintext once, then re-reads the list.
    ///
    /// Nothing is added optimistically. What the screen lists afterwards is the server's answer to
    /// "what does this account have", not this call congratulating itself — and the read-back is
    /// also what proves the new token is really there for the person now holding its only copy.
    @discardableResult
    public func create(name: String, expiresInDays: Int? = nil) async -> Bool {
        // A plaintext still on screen has not been read yet, and there will never be another copy
        // of it. Minting over it would take a live token's only secret away from somebody who has
        // not written it down, and leave that token on the account with nothing but its name to
        // identify it by. So a create waits for the panel to be put away — decided HERE, because
        // a control that merely looked disabled would be a hint rather than a rule.
        guard minted == nil else {
            notice = Self.secretStillShowing
            return false
        }
        // Checked here rather than by the field alone, so the one rule is the one the request is
        // built from. It is `/api/pats`' own bound, which is the same one a device token is
        // renamed under.
        guard let sanitized = DeviceTokenName.sanitized(name) else {
            notice = Self.nameRefused
            return false
        }
        guard let work = beginWork() else { return false }
        do {
            let created = try await Self.create(
                client, name: sanitized, expiresInDays: expiresInDays
            )
            guard isCurrent(work) else {
                // The token was MINTED. This management session ended while the answer was in the
                // air and the plaintext went with it — so dropping the answer quietly would leave
                // a full-access token on the account that nobody knows was ever created. It IS
                // recoverable: sign on again, find it in the list, revoke it. Only if the app says
                // it happened.
                MemosLog.session.error(
                    "a token was created for a management session that had already ended"
                )
                // Only while the app identity that bought this session is still signed in. Past
                // that, the notice has nobody to reach: the screen it would appear on belongs to
                // whoever signs in next, and telling them about a token on an account they are not
                // holding is not a recovery, it is a leak of the last person's account activity.
                if appIdentityHolds { heldSecretLost = true }
                endWork(work)
                return false
            }
            heldMinted = created
            heldSecretLost = false
            notice = nil
        } catch {
            guard isCurrent(work) else {
                endWork(work)
                return false
            }
            report(error)
            endWork(work)
            return false
        }
        // The read-back runs under the SAME piece of work as the mint, so a second tap while it is
        // out is refused as well: one intention is one create, not a create and then a window.
        await reload(work)
        endWork(work)
        return true
    }

    /// Revokes any of the account's tokens — a sibling included, which is the whole reason this
    /// screen exists. The authority is the GRANT, not a bearer: ADR-0015's rule is about what a
    /// device token may do, and a fresh authentication may do more.
    @discardableResult
    public func revoke(_ id: Int) async -> Bool {
        guard let work = beginWork() else { return false }
        do {
            try await Self.revoke(client, id: id)
            guard isCurrent(work) else {
                endWork(work)
                return false
            }
            notice = nil
        } catch {
            guard isCurrent(work) else {
                endWork(work)
                return false
            }
            // A 404 from `/api/pats/{id}` is a token that is already gone or was never this
            // account's — NOT a missing route, which is why this branch is here and not in
            // `report`. The list is re-read either way, so the screen ends up showing what is
            // really there rather than the row somebody just pressed.
            if StoreFailure.reportable(error) == .notFound {
                await reload(work)
                if isCurrent(work) { notice = Self.alreadyGone }
                endWork(work)
                return false
            }
            report(error)
            endWork(work)
            return false
        }
        await reload(work)
        endWork(work)
        return true
    }

    /// The screen went away, or the app did. In memory only means exactly this.
    ///
    /// A screen that never bought anything is left alone: moving it to "that session ended" would
    /// be the app announcing the end of something that never began.
    public func forget() {
        // The held plaintext, not what the screen could still see of it: a session that bought a
        // token ended here whether or not the identity it was bought under is still around.
        let hadSomething = grant.current != nil || heldMinted != nil
        generation += 1
        // The operation in flight belonged to the session this ends. Its gate is handed back HERE
        // rather than when it lands: a screen coming back from the background could otherwise
        // never ask for anything again, because the work holding the gate is one nothing will
        // resume. Its own answer is fenced off by the generation above.
        runningWork = nil
        dropGrant()
        isBusy = false
        notice = nil
        if hadSomething {
            state = .locked(.discarded)
        } else if case .authenticating = state {
            // A round trip that was still open when the app went away. Nothing was bought, and the
            // spinner must not outlive the screen that was showing it.
            state = .locked(.never)
        }
    }

    /// The plaintext has been read and put away on purpose. Not a loss, so nothing says it was.
    public func dismissMinted() {
        heldMinted = nil
        heldSecretLost = false
    }

    // MARK: - the rules the calls above share

    static let nameRefused = "A token needs a name, and no more than 255 characters of one."
    static let alreadyGone = "That token was already gone. The list below is what is there now."
    /// Why a create is refused while a plaintext is still on screen. Not a scolding: the token
    /// above is the only copy there will ever be of that secret, and minting over it would take it
    /// away from somebody who has not read it yet.
    static let secretStillShowing =
        "Copy the new token above and press Done before creating another - its text cannot be "
        + "shown again."

    /// One piece of work: which operation it is, and which management session it belongs to.
    private struct Work {
        let id: Int
        let generation: Int
    }

    /// The gate every `/api/pats` call passes: ONE operation at a time, with a live grant behind
    /// it.
    ///
    /// One at a time is decided here rather than by a disabled control, and on this screen that
    /// distinction is not academic. A disabled button is a hint — a redraw, an accessibility
    /// activation, a restored scene can each put a second tap past it — and a second tap that
    /// reaches the server mints a SECOND full-access token whose plaintext nobody will ever see.
    /// A refusal costs a tap; the alternative cannot be undone by the person who caused it.
    ///
    /// The grant is checked before the request rather than after the 401, because the app already
    /// knows the answer — asking anyway would spend a round trip to be told something it holds.
    /// The identity it was bought under is checked for the same reason: a live grant that speaks
    /// for an account nobody is signed in to any more is not authority to send anything.
    private func beginWork() -> Work? {
        guard runningWork == nil else { return nil }
        guard isCurrent(generation), grant.isLive(at: now()) else {
            lapse()
            return nil
        }
        workSequence += 1
        runningWork = workSequence
        isBusy = true
        return Work(id: workSequence, generation: generation)
    }

    /// Whether the app identity this management session was bought under is still the app's
    /// identity.
    ///
    /// Asked here and nowhere else, so there is one answer to it. A store with no session named to
    /// it has nothing to be wrong about; a session that has withdrawn its handle has no identity to
    /// match, and that is a no.
    private var appIdentityHolds: Bool {
        guard let session else { return true }
        guard let boughtUnder, let current = session.activeHandle?.generation else { return false }
        return current == boughtUnder
    }

    /// Whether a management session generation still speaks for what is on screen — which means
    /// both that this screen's own session has not been replaced AND that the identity it is a
    /// step-up on is still signed in. Neither half alone is the question: the app withdraws its
    /// incarnation synchronously and tears this screen down afterwards, so a generation that still
    /// matches says nothing about whether anybody is left to read what it would write.
    private func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation && appIdentityHolds
    }

    /// Whether this work still speaks for the session on screen. False means its answer is about a
    /// management session that has ended, and nothing it learned may be written anywhere.
    private func isCurrent(_ work: Work) -> Bool { isCurrent(work.generation) }

    /// Hands the gate back — but only if this work still holds it. `forget()` and `lapse()` both
    /// release the gate as they happen, so by the time an abandoned operation lands the gate may
    /// belong to another one, and taking it from THAT would let a third start alongside it.
    private func endWork(_ work: Work) {
        guard runningWork == work.id else { return }
        runningWork = nil
        isBusy = false
    }

    /// The management session is over. The screen goes back to offering the round trip, which is
    /// the only thing that can fix it — not to an error somebody has to interpret.
    private func lapse() {
        dropGrant()
        // Advanced here as well as in `forget()`, and that is the point of it: anything still in
        // the air belonged to the session this ends, and a reply landing afterwards would
        // otherwise be free to put `.listed` back on a screen whose grant is already gone.
        generation += 1
        runningWork = nil
        isBusy = false
        state = .locked(.expired)
    }

    private func dropGrant() {
        grant.forget()
        if heldMinted != nil {
            heldMinted = nil
            // The notice is scoped to the identity that bought the session, exactly as the create
            // path's is: a secret the screen stopped showing because that identity went was not
            // lost to anybody left to read this screen, and telling whoever signs in next that a
            // token was minted is a sentence about the last person's account.
            if appIdentityHolds { heldSecretLost = true }
        }
    }

    private func report(_ error: any Error) {
        if error is RouteMissing {
            state = .unsupported
            return
        }
        // A cancellation is this app's own doing and is never reported back to the person who
        // caused it (`StoreFailure`).
        guard let failure = StoreFailure.reportable(error) else { return }
        guard failure != .unauthorized else {
            // The grant was refused. It says nothing about the device token the rest of the app is
            // holding, so it ends this screen's session and nothing else.
            lapse()
            return
        }
        notice = failure.errorDescription
    }

    /// A route this server does not have. Distinguished from every other 404 because it means the
    /// deployment has not caught up with this build, which is a sentence rather than an error.
    private struct RouteMissing: Error {}

    // MARK: - the wire

    static func mintGrant(
        _ client: any APIProtocol,
        code: String,
        verifier: String
    ) async throws -> (grant: String, expiresAt: Date) {
        let response = try await client.nativeManageGrantApiAuthNativeManageGrantPost(
            .init(body: .json(.init(code: code, codeVerifier: verifier)))
        )
        switch response {
        case .ok(let ok):
            let payload = try ok.body.json
            return (payload.grant, payload.expiresAt)
        case .unprocessableContent:
            throw NativeLoginError.api(.server(status: 422))
        case .undocumented(let statusCode, let payload):
            // A server that predates this route answers 404, and that is the ONE signal that
            // separates "this deployment has not caught up" from "the code was refused".
            if statusCode == 404 { throw RouteMissing() }
            // Every refusal is a 400 with one of the same four stable detail codes the sign-in
            // exchange answers with — the two lanes share `_redeem_handoff_code`.
            if statusCode == 400, let body = payload.body,
                let data = try? await Data(collecting: body, upTo: 4096),
                let failure = NativeExchangeFailure.fromDetailBody(data)
            {
                throw NativeLoginError.exchangeRejected(failure)
            }
            throw NativeLoginError.api(.fromStatus(statusCode))
        }
    }

    static func list(_ client: any APIProtocol) async throws -> [ManagedToken] {
        switch try await client.listPatsApiPatsGet(.init()) {
        case .ok(let ok):
            return try ok.body.json.map(ManagedToken.init)
        case .undocumented(let statusCode, _):
            if statusCode == 404 { throw RouteMissing() }
            throw APIError.fromStatus(statusCode)
        }
    }

    static func create(
        _ client: any APIProtocol,
        name: String,
        expiresInDays: Int?
    ) async throws -> MintedToken {
        let response = try await client.createPatApiPatsPost(
            .init(body: .json(.init(expiresInDays: expiresInDays, name: name)))
        )
        switch response {
        case .created(let created):
            let payload = try created.body.json
            return MintedToken(token: ManagedToken(payload), secret: payload.token)
        case .unprocessableContent:
            throw APIError.server(status: 422)
        case .undocumented(let statusCode, _):
            if statusCode == 404 { throw RouteMissing() }
            throw APIError.fromStatus(statusCode)
        }
    }

    static func revoke(_ client: any APIProtocol, id: Int) async throws {
        switch try await client.revokePatApiPatsPatIdDelete(.init(path: .init(patId: id))) {
        case .noContent:
            return
        case .unprocessableContent:
            throw APIError.server(status: 422)
        case .undocumented(let statusCode, _):
            // Deliberately no `RouteMissing` here: this path's 404 is the server saying that token
            // is not there, which is a thing the screen reports and re-reads rather than a server
            // without token management.
            throw APIError.fromStatus(statusCode)
        }
    }
}

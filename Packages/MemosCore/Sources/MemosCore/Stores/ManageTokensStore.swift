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
    public private(set) var minted: MintedToken?
    /// A plaintext that went away without being dismissed — the app was backgrounded, the grant
    /// ran out, the screen was left. The token still exists and can still be revoked from the
    /// list; its text cannot come back, and the screen says so rather than quietly showing one
    /// fewer panel.
    public private(set) var mintedSecretLost = false
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
    /// Which management session this is. Bumped by every sign-on and by every discard, because
    /// both change whose grant the answers still in the air belong to. A reply can outlive the
    /// question here as easily as anywhere else in the app.
    private var generation = 0

    public init(
        configuration: ServerConfiguration,
        makeClient: (ServerConfiguration, ManagementGrant) -> any APIProtocol = {
            APIClientFactory.make(configuration: $0, grant: $1)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let grant = ManagementGrant()
        self.configuration = configuration
        self.grant = grant
        self.client = makeClient(configuration, grant)
        self.now = now
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
            let held = try await Self.mintGrant(client, code: code, verifier: verifier)
            guard mine == generation else { return false }
            grant.hold(held.grant, until: held.expiresAt)
            MemosLog.session.info("POST /api/auth/native/manage-grant -> 200")
            await refresh()
            return true
        } catch is RouteMissing {
            guard mine == generation else { return false }
            state = .unsupported
            return false
        } catch let error as NativeLoginError {
            guard mine == generation else { return false }
            state = .locked(.refused(error))
            return false
        } catch {
            guard mine == generation else { return false }
            // Named by what the failure WAS, never by its own description: this request's body is
            // the handoff code and the PKCE verifier, and the error text carries the request.
            state = .locked(.refused(.transport(NativeLoginTransportFailure.classify(error))))
            return false
        }
    }

    // MARK: - the tokens themselves

    /// Re-reads the account's tokens. The one place a list on screen comes from.
    public func refresh() async {
        guard let mine = beginWork() else { return }
        defer { endWork(mine) }
        do {
            let rows = try await Self.list(client)
            guard mine == generation else { return }
            state = .listed(rows)
            notice = nil
        } catch {
            guard mine == generation else { return }
            report(error)
        }
    }

    /// Mints a token and shows its plaintext once, then re-reads the list.
    ///
    /// Nothing is added optimistically. What the screen lists afterwards is the server's answer to
    /// "what does this account have", not this call congratulating itself — and the read-back is
    /// also what proves the new token is really there for the person now holding its only copy.
    @discardableResult
    public func create(name: String, expiresInDays: Int? = nil) async -> Bool {
        // Checked here rather than by the field alone, so the one rule is the one the request is
        // built from. It is `/api/pats`' own bound, which is the same one a device token is
        // renamed under.
        guard let sanitized = DeviceTokenName.sanitized(name) else {
            notice = Self.nameRefused
            return false
        }
        guard let mine = beginWork() else { return false }
        do {
            let created = try await Self.create(
                client, name: sanitized, expiresInDays: expiresInDays
            )
            guard mine == generation else {
                endWork(mine)
                return false
            }
            minted = created
            mintedSecretLost = false
            notice = nil
        } catch {
            endWork(mine)
            guard mine == generation else { return false }
            report(error)
            return false
        }
        endWork(mine)
        await refresh()
        return true
    }

    /// Revokes any of the account's tokens — a sibling included, which is the whole reason this
    /// screen exists. The authority is the GRANT, not a bearer: ADR-0015's rule is about what a
    /// device token may do, and a fresh authentication may do more.
    @discardableResult
    public func revoke(_ id: Int) async -> Bool {
        guard let mine = beginWork() else { return false }
        do {
            try await Self.revoke(client, id: id)
            guard mine == generation else {
                endWork(mine)
                return false
            }
            notice = nil
        } catch {
            endWork(mine)
            guard mine == generation else { return false }
            // A 404 from `/api/pats/{id}` is a token that is already gone or was never this
            // account's — NOT a missing route, which is why this branch is here and not in
            // `report`. The list is re-read either way, so the screen ends up showing what is
            // really there rather than the row somebody just pressed.
            if StoreFailure.reportable(error) == .notFound {
                await refresh()
                guard mine == generation else { return false }
                notice = Self.alreadyGone
                return false
            }
            report(error)
            return false
        }
        endWork(mine)
        await refresh()
        return true
    }

    /// The screen went away, or the app did. In memory only means exactly this.
    ///
    /// A screen that never bought anything is left alone: moving it to "that session ended" would
    /// be the app announcing the end of something that never began.
    public func forget() {
        let hadSomething = grant.current != nil || minted != nil
        generation += 1
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
        minted = nil
        mintedSecretLost = false
    }

    // MARK: - the rules the calls above share

    static let nameRefused = "A token needs a name, and no more than 255 characters of one."
    static let alreadyGone = "That token was already gone. The list below is what is there now."

    /// The gate every `/api/pats` call passes: there has to be a live grant, and the deadline that
    /// decides is the server's own.
    ///
    /// Checked before the request rather than after the 401, because the app already knows the
    /// answer — asking anyway would spend a round trip to be told something it was holding.
    private func beginWork() -> Int? {
        guard grant.isLive(at: now()) else {
            lapse()
            return nil
        }
        isBusy = true
        return generation
    }

    private func endWork(_ mine: Int) {
        guard mine == generation else { return }
        isBusy = false
    }

    /// The management session is over. The screen goes back to offering the round trip, which is
    /// the only thing that can fix it — not to an error somebody has to interpret.
    private func lapse() {
        dropGrant()
        isBusy = false
        state = .locked(.expired)
    }

    private func dropGrant() {
        grant.forget()
        if minted != nil {
            minted = nil
            mintedSecretLost = true
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

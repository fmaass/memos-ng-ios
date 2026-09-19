import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

// The transport is handed the contract's own operationId, not the generated Swift method name.
private let mintOperation = "native_manage_grant_api_auth_native_manage_grant_post"
private let listOperation = "list_pats_api_pats_get"
private let createOperation = "create_pat_api_pats_post"
private let revokeOperation = "revoke_pat_api_pats__pat_id__delete"
private let whoamiOperation = "whoami_api_auth_user_get"

/// The clock every test here reads. A fixed instant rather than the real one, so a grant's
/// deadline is a decision the test makes instead of a race it hopes to win.
private let managementNow = Date(timeIntervalSince1970: 1_800_000_000)

/// The same encoding the client's own transcoder writes, so a date sent into these bodies comes
/// back out of the decoder as the date that went in.
private func iso(_ date: Date) -> String {
    date.formatted(.iso8601.dateTimeSeparator(.standard).timeSeparator(.colon))
}

/// A mint response whose deadline is ten minutes past the fixed clock above — a live grant.
///
/// At file scope rather than on the suite because every transport handler here is `@Sendable` and
/// runs off the main actor: a body read off the main-actor-isolated suite would not compile.
private let liveGrant = Stub.manageGrant(
    "mg_live",
    expiresAt: iso(managementNow.addingTimeInterval(600))
)

/// One request as the transport saw it — and above all what credential it presented.
///
/// The header is the whole point of most of this suite. A management screen that talked to
/// `/api/pats` with the device's bearer token would look identical from the outside: the same
/// rows, the same creates, the same revokes. What must be true is that the token never leaves the
/// session's own client, and the only place that can be checked is the request itself.
private struct Seen: Sendable {
    let operation: String
    let method: String
    let path: String
    let authorization: String?
}

/// A list route that answers differently each time it is asked, so that a read-back is a read-back
/// rather than the same body served twice.
private final class Pages: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String]

    init(_ bodies: [String]) { self.bodies = bodies }

    func next() -> String {
        lock.withLock {
            guard let first = bodies.first else { return "[]" }
            if bodies.count > 1 { bodies.removeFirst() }
            return first
        }
    }
}

/// The account's tokens, managed under a step-up grant.
///
/// Every test drives the REAL generated client over a scripted transport (`Stub.client(grant:)`),
/// so the request each call builds, the middleware that attaches the grant and the decoding are
/// all exercised. Substituting `APIProtocol` here would assert only that the test agrees with
/// itself.
@MainActor
@Suite("Managing the account's tokens under a step-up grant")
struct ManageTokensStoreTests {
    private func makeStore(
        seen: LockedValue<[Seen]>,
        session: (any SessionReporting)? = nil,
        now: @escaping @Sendable () -> Date = { managementNow },
        handler: @escaping @Sendable (String) async throws -> HTTPResponseLike
    ) -> ManageTokensStore {
        ManageTokensStore(
            configuration: ServerConfiguration(baseURL: Stub.baseURL),
            session: session,
            makeClient: { _, grant, licence in
                Stub.client(grant: grant, licence: licence) { request, _, operation in
                    seen.set(
                        seen.get()
                            + [
                                Seen(
                                    operation: operation,
                                    method: request.method.rawValue,
                                    path: request.path ?? "",
                                    authorization: request.headerFields[.authorization]
                                )
                            ]
                    )
                    return try await handler(operation).parts
                }
            },
            now: now
        )
    }

    private func stubPresenter(code: String = "handoff-code") -> StubPresenter {
        StubPresenter(behaviour: .callback("memosng://auth-callback?code=\(code)"))
    }

    @discardableResult
    private func signOn(
        _ store: ManageTokensStore,
        presenter: StubPresenter? = nil
    ) async -> Bool {
        await store.authenticate(
            deviceName: "Fabian's iPhone",
            presenter: presenter ?? stubPresenter()
        )
    }

    private func rows(_ state: ManageTokensState) -> [ManagedToken]? {
        guard case .listed(let rows) = state else { return nil }
        return rows
    }

    // MARK: - what a management request carries

    @Test("the round trip asks for a management grant, not for a device token")
    func theRoundTripNamesItsPurpose() async throws {
        let seen = LockedValue<[Seen]>([])
        let presenter = stubPresenter()
        let store = makeStore(seen: seen) { operation in
            operation == mintOperation ? .json(liveGrant) : .json("[]")
        }

        await signOn(store, presenter: presenter)

        let url = try #require(presenter.seenAuthorizeURL.get())
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = try #require(components?.queryItems)
        #expect(query.contains(URLQueryItem(name: "purpose", value: "manage")))
        #expect(query.contains(URLQueryItem(name: "client", value: "ios")))
    }

    /// The mint is anonymous by construction, exactly as the sign-in exchange is: the code and the
    /// verifier ARE the authority, and the client has nothing to present at that moment anyway.
    @Test("the request that buys the grant presents no credential of its own")
    func theMintIsAnonymous() async throws {
        let seen = LockedValue<[Seen]>([])
        let store = makeStore(seen: seen) { operation in
            operation == mintOperation ? .json(liveGrant) : .json("[]")
        }

        await signOn(store)

        let mint = try #require(seen.get().first { $0.operation == mintOperation })
        #expect(mint.authorization == nil)
    }

    @Test("every management route is authorised by the grant, under its own scheme")
    func theGrantAuthorisesAllThreeRoutes() async throws {
        let seen = LockedValue<[Seen]>([])
        let store = makeStore(seen: seen) { operation in
            switch operation {
            case mintOperation: .json(liveGrant)
            case listOperation: .json("[\(Stub.pat(id: 1, name: "Kitchen phone"))]")
            case createOperation:
                .created(Stub.patCreated(id: 2, name: "Laptop", token: "memos_pat_new"))
            case revokeOperation: .status(.noContent)
            default: .status(.internalServerError)
            }
        }

        await signOn(store)
        await store.create(name: "Laptop")
        await store.revoke(1)

        let management = seen.get().filter {
            [listOperation, createOperation, revokeOperation].contains($0.operation)
        }
        #expect(management.count >= 3, "all three management routes should have been called")
        #expect(management.allSatisfy { $0.authorization == "Grant mg_live" })
        // The control, and the reason the line above means anything: a middleware writing
        // `Bearer mg_live` would satisfy "there is an Authorization header" just as well.
        #expect(management.allSatisfy { $0.authorization?.hasPrefix("Bearer") == false })
        #expect(Set(management.map(\.operation)).count == 3)
    }

    /// The rule this whole design exists for (ADR-0015): the capability to manage this account's
    /// tokens is bought with an authentication, and a device token carries none of it — so a
    /// device token must never appear on one of these requests.
    ///
    /// The bearer client is driven over the SAME transport first, as the positive control: it
    /// proves the recorder sees Authorization headers at all and that this token really does
    /// travel when a bearer client is the one asking.
    @Test("the device's own token is never sent on a management route")
    func theDevicePatNeverReachesManagement() async throws {
        let seen = LockedValue<[Seen]>([])
        let devicePAT = "memos_pat_device"
        let handler: @Sendable (String) async throws -> HTTPResponseLike = { operation in
            switch operation {
            case whoamiOperation: .json(Stub.user)
            case mintOperation: .json(liveGrant)
            case listOperation: .json("[\(Stub.pat(id: 1, name: "Kitchen phone"))]")
            case createOperation:
                .created(Stub.patCreated(id: 2, name: "Laptop", token: "memos_pat_new"))
            case revokeOperation: .status(.noContent)
            default: .status(.internalServerError)
            }
        }
        let record: @Sendable (HTTPRequest, String) -> Void = { request, operation in
            seen.set(
                seen.get()
                    + [
                        Seen(
                            operation: operation,
                            method: request.method.rawValue,
                            path: request.path ?? "",
                            authorization: request.headerFields[.authorization]
                        )
                    ]
            )
        }
        let session = Stub.client(token: PresentedCredential(devicePAT)) { request, _, operation in
            record(request, operation)
            return try await handler(operation).parts
        }
        let store = ManageTokensStore(
            configuration: ServerConfiguration(baseURL: Stub.baseURL),
            makeClient: { _, grant, licence in
                Stub.client(grant: grant, licence: licence) { request, _, operation in
                    record(request, operation)
                    return try await handler(operation).parts
                }
            },
            now: { managementNow }
        )

        _ = try await session.whoamiApiAuthUserGet(.init())
        await signOn(store)
        await store.create(name: "Laptop")
        await store.revoke(1)

        let control = try #require(seen.get().first { $0.operation == whoamiOperation })
        #expect(control.authorization == "Bearer \(devicePAT)")
        let management = seen.get().filter {
            [mintOperation, listOperation, createOperation, revokeOperation].contains($0.operation)
        }
        #expect(management.count >= 4)
        #expect(management.allSatisfy { $0.authorization?.contains(devicePAT) != true })
    }

    // MARK: - the list, and what a create shows once

    @Test("a management session opens on the account's tokens, read from the server")
    func signingOnListsTheAccountsTokens() async throws {
        let seen = LockedValue<[Seen]>([])
        let store = makeStore(seen: seen) { operation in
            switch operation {
            case mintOperation: .json(liveGrant)
            case listOperation:
                .json(
                    """
                    [\(Stub.pat(id: 1, name: "Kitchen phone")),\
                    \(Stub.pat(id: 7, name: "Laptop", expiresAt: nil))]
                    """
                )
            default: .status(.internalServerError)
            }
        }

        let signedOn = await signOn(store)

        #expect(signedOn)
        let listed = try #require(rows(store.state))
        #expect(listed.map(\.id) == [1, 7])
        #expect(listed.map(\.name) == ["Kitchen phone", "Laptop"])
        #expect(listed[1].expiresAt == nil)
        #expect(store.notice == nil)
    }

    @Test("a created token shows its text once, and the list is re-read from the server")
    func createShowsThePlaintextOnceAndReadsBack() async throws {
        let seen = LockedValue<[Seen]>([])
        let pages = Pages([
            "[\(Stub.pat(id: 1, name: "Kitchen phone"))]",
            """
            [\(Stub.pat(id: 1, name: "Kitchen phone")),\
            \(Stub.pat(id: 2, name: "Laptop", lastUsed: nil, expiresAt: nil))]
            """,
        ])
        let store = makeStore(seen: seen) { operation in
            switch operation {
            case mintOperation: .json(liveGrant)
            case listOperation: .json(pages.next())
            case createOperation:
                .created(Stub.patCreated(id: 2, name: "Laptop", token: "memos_pat_brand_new"))
            default: .status(.internalServerError)
            }
        }

        await signOn(store)
        let created = await store.create(name: "Laptop")

        #expect(created)
        let minted = try #require(store.minted)
        #expect(minted.secret == "memos_pat_brand_new")
        #expect(minted.token.id == 2)
        #expect(minted.token.name == "Laptop")
        // The read-back is what the screen lists — the server's answer to "what does this account
        // have", not this call adding a row it hoped for.
        let listed = try #require(rows(store.state))
        #expect(listed.map(\.id) == [1, 2])
        #expect(seen.get().filter { $0.operation == listOperation }.count == 2)
    }

    /// A `ManagedToken` has nowhere to put a secret and a list response carries none, so the only
    /// place the plaintext can be is the one panel that shows it — and putting that panel away is
    /// the end of it.
    @Test("the plaintext is gone once it has been put away, and the list never carried it")
    func thePlaintextIsShownOnlyOnce() async throws {
        let seen = LockedValue<[Seen]>([])
        let store = makeStore(seen: seen) { operation in
            switch operation {
            case mintOperation: .json(liveGrant)
            case listOperation: .json("[\(Stub.pat(id: 2, name: "Laptop"))]")
            case createOperation:
                .created(Stub.patCreated(id: 2, name: "Laptop", token: "memos_pat_brand_new"))
            default: .status(.internalServerError)
            }
        }

        await signOn(store)
        await store.create(name: "Laptop")
        store.dismissMinted()
        await store.refresh()

        #expect(store.minted == nil)
        // Dismissing is a deliberate act, so nothing complains that something was lost.
        #expect(!store.mintedSecretLost)
        #expect(rows(store.state)?.map(\.id) == [2])
    }

    @Test("a name the server would refuse is never sent")
    func aRefusedNameIsNeverSent() async throws {
        let seen = LockedValue<[Seen]>([])
        let store = makeStore(seen: seen) { operation in
            operation == mintOperation ? .json(liveGrant) : .json("[]")
        }

        await signOn(store)
        let created = await store.create(name: "   ")

        #expect(!created)
        #expect(store.notice == ManageTokensStore.nameRefused)
        #expect(seen.get().allSatisfy { $0.operation != createOperation })
    }

    // MARK: - revoking

    /// The reason this screen exists. A device token may revoke nothing but itself; a fresh
    /// authentication may revoke any of them, which is how a lost phone's token is taken away
    /// from the phone that is still in somebody's hand.
    @Test("any of the account's tokens can be revoked, and the list reads back without it")
    func revokesASibling() async throws {
        let seen = LockedValue<[Seen]>([])
        let pages = Pages([
            """
            [\(Stub.pat(id: 1, name: "Kitchen phone")),\
            \(Stub.pat(id: 7, name: "Lost phone"))]
            """,
            "[\(Stub.pat(id: 1, name: "Kitchen phone"))]",
        ])
        let store = makeStore(seen: seen) { operation in
            switch operation {
            case mintOperation: .json(liveGrant)
            case listOperation: .json(pages.next())
            case revokeOperation: .status(.noContent)
            default: .status(.internalServerError)
            }
        }

        await signOn(store)
        let revoked = await store.revoke(7)

        #expect(revoked)
        let call = try #require(seen.get().first { $0.operation == revokeOperation })
        #expect(call.method == "DELETE")
        #expect(call.path == "/api/pats/7")
        #expect(rows(store.state)?.map(\.id) == [1])
    }

    /// A 404 from `/api/pats/{id}` is a token that is already gone — NOT a server without token
    /// management. Reading it as the latter would tell somebody their server cannot do this,
    /// having just watched it do it.
    @Test("revoking a token that is already gone says so and re-reads, rather than giving up")
    func revokingAVanishedTokenRereads() async throws {
        let seen = LockedValue<[Seen]>([])
        let pages = Pages([
            "[\(Stub.pat(id: 1, name: "Kitchen phone")),\(Stub.pat(id: 7, name: "Lost phone"))]",
            "[\(Stub.pat(id: 1, name: "Kitchen phone"))]",
        ])
        let store = makeStore(seen: seen) { operation in
            switch operation {
            case mintOperation: .json(liveGrant)
            case listOperation: .json(pages.next())
            case revokeOperation: .status(.notFound)
            default: .status(.internalServerError)
            }
        }

        await signOn(store)
        let revoked = await store.revoke(7)

        #expect(!revoked)
        #expect(store.notice == ManageTokensStore.alreadyGone)
        #expect(rows(store.state)?.map(\.id) == [1])
        #expect(store.state != .unsupported)
    }

    // MARK: - when the grant ends

    /// A management session is minutes long by design, so its end is ordinary rather than an
    /// error: the screen offers the round trip again, which is the only thing that can fix it.
    @Test("a refused grant lands the screen in the honest re-authenticate state")
    func aRefusedGrantAsksAgain() async throws {
        let seen = LockedValue<[Seen]>([])
        let refuse = LockedValue(false)
        let store = makeStore(seen: seen) { operation in
            switch operation {
            case mintOperation: .json(liveGrant)
            case listOperation:
                refuse.get() ? .status(.unauthorized) : .json("[\(Stub.pat(id: 1, name: "a"))]")
            default: .status(.internalServerError)
            }
        }

        await signOn(store)
        refuse.set(true)
        await store.refresh()

        #expect(store.state == .locked(.expired))
        #expect(!store.isBusy)
        // The grant is gone with it: a credential the server has refused is not one to keep
        // presenting.
        await store.refresh()
        #expect(seen.get().filter { $0.operation == listOperation }.count == 2)
    }

    /// The deadline the server sent is what decides, and the app already knows it. Asking anyway
    /// would spend a round trip to be told something it was holding.
    @Test("a grant whose deadline has passed is not asked about at all")
    func aLapsedDeadlineIsNotAskedAbout() async throws {
        let seen = LockedValue<[Seen]>([])
        let clock = LockedValue(managementNow)
        let store = makeStore(seen: seen, now: { clock.get() }) { operation in
            switch operation {
            case mintOperation: .json(liveGrant)
            case listOperation: .json("[\(Stub.pat(id: 1, name: "a"))]")
            default: .status(.internalServerError)
            }
        }

        await signOn(store)
        let before = seen.get().filter { $0.operation == listOperation }.count
        clock.set(managementNow.addingTimeInterval(601))
        await store.refresh()

        #expect(before == 1)
        #expect(seen.get().filter { $0.operation == listOperation }.count == 1)
        #expect(store.state == .locked(.expired))
    }

    // MARK: - the app going away mid-flow

    /// In memory only means exactly this: the grant does not survive the screen or the app going
    /// away, and the way back is another sign-on. The plaintext does not survive either, which is
    /// why the store remembers that one was lost rather than quietly showing one panel fewer.
    @Test("backgrounding drops the grant and says the new token's text is gone")
    func processLossDropsEverything() async throws {
        let seen = LockedValue<[Seen]>([])
        let store = makeStore(seen: seen) { operation in
            switch operation {
            case mintOperation: .json(liveGrant)
            case listOperation: .json("[\(Stub.pat(id: 2, name: "Laptop"))]")
            case createOperation:
                .created(Stub.patCreated(id: 2, name: "Laptop", token: "memos_pat_brand_new"))
            default: .status(.internalServerError)
            }
        }

        await signOn(store)
        await store.create(name: "Laptop")
        let before = seen.get().count
        store.forget()

        #expect(store.state == .locked(.discarded))
        #expect(store.minted == nil)
        #expect(store.mintedSecretLost)
        #expect(!store.isBusy)
        // Nothing is presented afterwards, because there is nothing left to present.
        await store.refresh()
        #expect(seen.get().count == before)
    }

    /// The recoverable half of the same story: the token itself was committed on the server before
    /// the loss, so another sign-on finds it in the list and it can be revoked from there. Only
    /// its plaintext is unrecoverable.
    @Test("a token created before the loss is found again after signing on, and can be revoked")
    func aCreateBeforeTheLossIsRecoverable() async throws {
        let seen = LockedValue<[Seen]>([])
        // Before the create, after it, after signing on again, and after the revoke.
        let pages = Pages([
            "[]",
            "[\(Stub.pat(id: 2, name: "Laptop"))]",
            "[\(Stub.pat(id: 2, name: "Laptop"))]",
            "[]",
        ])
        let store = makeStore(seen: seen) { operation in
            switch operation {
            case mintOperation: .json(liveGrant)
            case listOperation: .json(pages.next())
            case createOperation:
                .created(Stub.patCreated(id: 2, name: "Laptop", token: "memos_pat_brand_new"))
            case revokeOperation: .status(.noContent)
            default: .status(.internalServerError)
            }
        }

        await signOn(store)
        await store.create(name: "Laptop")
        store.forget()
        await signOn(store)

        #expect(rows(store.state)?.map(\.id) == [2])
        // Signing on again buys a new grant; it does not buy back the plaintext.
        #expect(store.minted == nil)
        let revoked = await store.revoke(2)
        #expect(revoked)
        #expect(rows(store.state)?.isEmpty == true)
    }

    /// A screen that bought nothing has lost nothing. Announcing the end of a management session
    /// that never began would be the app inventing an event.
    @Test("leaving a screen that never signed on says nothing ended")
    func forgettingNothingAnnouncesNothing() async {
        let seen = LockedValue<[Seen]>([])
        let store = makeStore(seen: seen) { _ in .status(.internalServerError) }

        store.forget()

        #expect(store.state == .locked(.never))
        #expect(!store.mintedSecretLost)
    }

    // MARK: - a server that does not offer this yet

    /// The iOS build and the backend deploy do not land together, and this screen must never be
    /// what discovers that: no crash, no spinner that never ends, and a sentence somebody can
    /// actually read.
    @Test("a server without the management route says so rather than failing")
    func aServerWithoutTheMintRouteSaysSo() async {
        let seen = LockedValue<[Seen]>([])
        let store = makeStore(seen: seen) { operation in
            operation == mintOperation ? .status(.notFound) : .status(.internalServerError)
        }

        let signedOn = await signOn(store)

        #expect(!signedOn)
        #expect(store.state == .unsupported)
        #expect(!store.isBusy)
    }

    @Test("a server that mints a grant but has no token list says so too")
    func aServerWithoutThePatsRouteSaysSo() async {
        let seen = LockedValue<[Seen]>([])
        let store = makeStore(seen: seen) { operation in
            operation == mintOperation ? .json(liveGrant) : .status(.notFound)
        }

        await signOn(store)

        #expect(store.state == .unsupported)
        #expect(!store.isBusy)
    }

    // MARK: - a round trip that went wrong

    @Test("a refused handoff code is reported as what it was, and asks for another sign-on")
    func aRefusedCodeIsReported() async {
        let seen = LockedValue<[Seen]>([])
        let store = makeStore(seen: seen) { operation in
            operation == mintOperation
                ? .detail("code_expired", status: .badRequest) : .status(.internalServerError)
        }

        let signedOn = await signOn(store)

        #expect(!signedOn)
        #expect(store.state == .locked(.refused(.exchangeRejected(.codeExpired))))
    }

    @Test("a sign-on the person closed leaves the screen offering it again")
    func aCancelledSignOnAsksAgain() async {
        let seen = LockedValue<[Seen]>([])
        let store = makeStore(seen: seen) { _ in .status(.internalServerError) }

        let signedOn = await store.authenticate(
            deviceName: "Fabian's iPhone",
            presenter: StubPresenter(behaviour: .failure(.cancelled))
        )

        #expect(!signedOn)
        #expect(store.state == .locked(.refused(.cancelled)))
        #expect(seen.get().isEmpty)
    }

    /// A second tap while the browser view is up opens nothing: the view in front of the person is
    /// the affordance, and a second round trip would leave one of them with no way to resolve.
    ///
    /// Driven from INSIDE the presenter, which is the one moment the store is provably in the
    /// middle of a sign-on — no timing, no second task.
    @Test("a second sign-on while one is on screen opens nothing")
    func aSecondSignOnWhileOneIsOpenIsIgnored() async throws {
        let seen = LockedValue<[Seen]>([])
        let store = makeStore(seen: seen) { operation in
            operation == mintOperation ? .json(liveGrant) : .json("[]")
        }
        let reentrant = ReentrantPresenter(callback: "memosng://auth-callback?code=abc")
        reentrant.reenter = { [weak store] in
            guard let store else { return true }
            return await store.authenticate(
                deviceName: "Fabian's iPhone",
                presenter: StubPresenter(behaviour: .callback("memosng://auth-callback?code=two"))
            )
        }

        let signedOn = await store.authenticate(
            deviceName: "Fabian's iPhone",
            presenter: reentrant
        )

        #expect(signedOn)
        #expect(reentrant.secondResult == false, "the second sign-on should have opened nothing")
        #expect(seen.get().filter { $0.operation == mintOperation }.count == 1)
    }
}

/// A presenter that calls back INTO the store while its own sign-on is still open — the only
/// deterministic way to ask what a second tap does while the browser view is up.
@MainActor
private final class ReentrantPresenter: NativeLoginPresenter {
    private let callback: String
    var reenter: (() async -> Bool)?
    private(set) var secondResult: Bool?

    init(callback: String) { self.callback = callback }

    func authenticate(
        authorizeURL: URL,
        callbackHost: String,
        callbackPath: String
    ) async throws -> URL {
        secondResult = await reenter?()
        guard let url = URL(string: callback) else { throw NativeLoginError.malformedCallback }
        return url
    }
}

/// Holds one response open on the wire, so a second call can be made while the first is still in
/// the air.
///
/// It is the only way to ask what two overlapping taps do. A test that calls twice in sequence
/// asks a different question entirely — the interesting one is what happens while the first
/// request is still out there, which is exactly the window a double tap lands in.
private actor RequestGate {
    /// EVERY held request, not the latest one. A gate that kept a single continuation turned the
    /// exact bug these tests are about into a hang: with two requests in the air the second
    /// overwrote the first's continuation, the first was never resumed, and the suite stopped
    /// instead of failing. A test that hangs when the behaviour breaks reports nothing.
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrival: CheckedContinuation<Void, Never>?
    private var arrivals = 0
    private var released = false

    /// Called from inside the transport: says the request is on the wire, then waits to be let go.
    ///
    /// Only the FIRST arrival is held, and that is what keeps these tests honest in both worlds.
    /// A test asks "what does a second call do while the first is in the air", so it has to make
    /// that second call and read its answer before it can let the first go — and if the second
    /// were held too, a store that failed to serialise would block the test rather than fail it.
    /// Holding one and waving the rest through means a store that serialises is proved by a
    /// refusal, and one that does not is proved by the extra request in the log. Neither hangs.
    func hold() async {
        arrivals += 1
        arrival?.resume()
        arrival = nil
        guard !released, arrivals == 1 else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// The test waits here until a request has actually reached the transport, rather than
    /// guessing with a yield.
    func waitForArrival() async {
        guard arrivals == 0 else { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func release() {
        released = true
        let held = waiting
        waiting.removeAll()
        for continuation in held { continuation.resume() }
    }

    /// How many requests reached this gate at all.
    var count: Int { arrivals }
}

/// What happens when two of these run at once, and what happens to work that lands after the
/// session it belonged to is over.
///
/// The store is where one-at-a-time is decided, not the screen. A disabled button is a hint: a
/// redraw, an accessibility activation or a restored scene can all put a second tap past it, and
/// on THIS screen a second tap that reaches the server mints a second full-access token whose
/// plaintext nobody ever sees.
extension ManageTokensStoreTests {
    @Test("two taps on Create mint one token, not two")
    func createIsSerialised() async throws {
        let seen = LockedValue<[Seen]>([])
        let gate = RequestGate()
        let store = makeStore(seen: seen) { operation in
            if operation == createOperation {
                await gate.hold()
                return .created(
                    Stub.patCreated(id: 2, name: "Laptop", token: "memos_pat_brand_new")
                )
            }
            switch operation {
            case mintOperation: return .json(liveGrant)
            case listOperation: return .json("[]")
            default: return .status(.internalServerError)
            }
        }
        await signOn(store)

        async let first = store.create(name: "Laptop")
        await gate.waitForArrival()
        let second = await store.create(name: "Laptop")
        await gate.release()
        let firstFinished = await first

        #expect(firstFinished)
        #expect(!second, "the second tap should have been refused rather than sent")
        #expect(seen.get().filter { $0.operation == createOperation }.count == 1)
        #expect(store.minted?.secret == "memos_pat_brand_new")
    }

    @Test("two overlapping reads put one request on the wire, not two")
    func readsAreSerialised() async throws {
        let seen = LockedValue<[Seen]>([])
        let gate = RequestGate()
        let armed = LockedValue(false)
        let store = makeStore(seen: seen) { operation in
            if operation == listOperation, armed.get() { await gate.hold() }
            switch operation {
            case mintOperation: return .json(liveGrant)
            case listOperation: return .json("[\(Stub.pat(id: 1, name: "Kitchen phone"))]")
            default: return .status(.internalServerError)
            }
        }
        await signOn(store)
        armed.set(true)

        async let reading: Void = store.refresh()
        await gate.waitForArrival()
        await store.refresh()
        await gate.release()
        await reading

        // One for the sign-on's own read, one for the read that was held. The second refresh is
        // refused rather than queued behind it.
        #expect(seen.get().filter { $0.operation == listOperation }.count == 2)
        #expect(rows(store.state)?.map(\.id) == [1])
    }

    /// Work that was in the air when the app was put away belongs to a session that is over. It
    /// may not write the screen, and it must not leave the store holding a gate nothing will ever
    /// release — a screen that can never ask for anything again is the same bug as a stuck spinner.
    @Test("a read that lands after the app was put away cannot bring the session back")
    func aStaleReadCannotResurrectTheSession() async throws {
        let seen = LockedValue<[Seen]>([])
        let gate = RequestGate()
        let armed = LockedValue(false)
        let store = makeStore(seen: seen) { operation in
            if operation == listOperation, armed.get() { await gate.hold() }
            switch operation {
            case mintOperation: return .json(liveGrant)
            case listOperation: return .json("[\(Stub.pat(id: 1, name: "Kitchen phone"))]")
            default: return .status(.internalServerError)
            }
        }
        await signOn(store)
        armed.set(true)

        async let reading: Void = store.refresh()
        await gate.waitForArrival()
        store.forget()
        await gate.release()
        await reading

        #expect(store.state == .locked(.discarded))
        #expect(!store.isBusy)
        let signedOnAgain = await signOn(store)
        #expect(signedOnAgain, "the store was left unable to start anything")
        #expect(rows(store.state)?.map(\.id) == [1])
    }

    /// The token was MINTED. The screen that asked for it is gone and its plaintext with it, so
    /// dropping the response silently leaves a full-access token on the account that nobody knows
    /// exists. It is recoverable — sign on again, find it in the list, revoke it — but only if the
    /// app says it happened.
    @Test("a token created for a session that has ended is reported, never silently dropped")
    func aStaleCreateReportsTheLoss() async throws {
        let seen = LockedValue<[Seen]>([])
        let gate = RequestGate()
        let store = makeStore(seen: seen) { operation in
            if operation == createOperation {
                await gate.hold()
                return .created(
                    Stub.patCreated(id: 2, name: "Laptop", token: "memos_pat_brand_new")
                )
            }
            switch operation {
            case mintOperation: return .json(liveGrant)
            case listOperation: return .json("[]")
            default: return .status(.internalServerError)
            }
        }
        await signOn(store)

        async let creating = store.create(name: "Laptop")
        await gate.waitForArrival()
        store.forget()
        await gate.release()
        let created = await creating

        #expect(!created)
        #expect(store.state == .locked(.discarded))
        #expect(store.minted == nil, "there is no session left to show it on")
        #expect(store.mintedSecretLost, "a minted token was dropped without saying so")
    }

    /// A plaintext still on screen has not been read yet. Minting over it replaces the only copy
    /// of a live token's secret with another one, and the first token goes on existing with
    /// full access and no way to identify it beyond its name.
    @Test("a second create cannot mint over a plaintext nobody has read yet")
    func aSecondCreateCannotOrphanTheFirst() async throws {
        let seen = LockedValue<[Seen]>([])
        let secrets = Pages([
            Stub.patCreated(id: 2, name: "Laptop", token: "memos_pat_first"),
            Stub.patCreated(id: 3, name: "Desktop", token: "memos_pat_second"),
        ])
        let store = makeStore(seen: seen) { operation in
            switch operation {
            case mintOperation: return .json(liveGrant)
            case listOperation: return .json("[]")
            case createOperation: return .created(secrets.next())
            default: return .status(.internalServerError)
            }
        }
        await signOn(store)

        let first = await store.create(name: "Laptop")
        let second = await store.create(name: "Desktop")

        #expect(first)
        #expect(!second, "a create over an unread plaintext must be refused")
        #expect(store.minted?.secret == "memos_pat_first")
        #expect(store.notice == ManageTokensStore.secretStillShowing)
        #expect(seen.get().filter { $0.operation == createOperation }.count == 1)

        // Once it HAS been read and put away, another one is perfectly fine.
        store.dismissMinted()
        let third = await store.create(name: "Desktop")

        #expect(third)
        #expect(store.minted?.secret == "memos_pat_second")
    }
}

/// Holds a request on its way OUT, in front of the grant middleware.
///
/// The gate inside the transport holds an ANSWER, which is a different instant: by then the request
/// has already been authorised and sent. The only way to ask what happens to a request that was
/// started while the identity was there and leaves after it went is to hold it before it goes.
private struct HoldingOnTheWayOut: ClientMiddleware {
    typealias Answer = (HTTPResponse, HTTPBody?)
    /// `@concurrent` for the reason `RenewingOnRefusal` carries it: under this target's MainActor
    /// default isolation the conformance fails without it.
    typealias Next = @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> Answer

    let operation: String
    let armed: LockedValue<Bool>
    let gate: RequestGate

    nonisolated func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: Next
    ) async throws -> Answer {
        if operationID == operation, armed.get() { await gate.hold() }
        return try await next(request, body, baseURL)
    }
}

/// A step-up belongs to the identity that bought it, and that identity can be withdrawn while the
/// management screen is still up: the session drops its client and moves its incarnation
/// synchronously, and the sheet is torn down afterwards.
///
/// Every test here drives a REAL `SessionStore`, because the question is what the app's identity
/// says about itself. A stand-in would answer with whatever it was told to answer.
extension ManageTokensStoreTests {
    private func signedInSession() async -> SessionStore {
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token) { _, _, _ in Stub.json(Stub.user) }
            },
            sleeper: { _ in throw CancellationError() }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        return session
    }

    @Test("a list that lands after the app identity went does not reach the screen")
    func aHeldListCannotInstallForAnIdentityThatWent() async throws {
        let seen = LockedValue<[Seen]>([])
        let gate = RequestGate()
        let armed = LockedValue(false)
        let pages = Pages([
            "[\(Stub.pat(id: 1, name: "Kitchen phone"))]",
            "[\(Stub.pat(id: 1, name: "Kitchen phone")),\(Stub.pat(id: 2, name: "Laptop"))]",
        ])
        let session = await signedInSession()
        let store = makeStore(seen: seen, session: session) { operation in
            if operation == listOperation, armed.get() { await gate.hold() }
            switch operation {
            case mintOperation: return .json(liveGrant)
            case listOperation: return .json(pages.next())
            default: return .status(.internalServerError)
            }
        }
        await signOn(store)
        armed.set(true)

        async let reading: Void = store.refresh()
        await gate.waitForArrival()
        await session.signOutWithoutRevoking()
        #expect(session.activeHandle == nil, "the identity was still there to be judged against")
        await gate.release()
        await reading

        #expect(rows(store.state)?.map(\.id) == [1], "a list from a gone identity was installed")
    }

    /// The plaintext of a minted token is shown once, on the screen that asked for it. After the
    /// identity went there is no such screen, and the notice about the loss belongs to it too —
    /// surfacing it later would be a sentence about somebody else's account.
    @Test("a token minted after the app identity went is neither shown nor announced")
    func aHeldCreateCannotShowForAnIdentityThatWent() async throws {
        let seen = LockedValue<[Seen]>([])
        let gate = RequestGate()
        let session = await signedInSession()
        let store = makeStore(seen: seen, session: session) { operation in
            if operation == createOperation {
                await gate.hold()
                return .created(
                    Stub.patCreated(id: 2, name: "Laptop", token: "memos_pat_brand_new")
                )
            }
            switch operation {
            case mintOperation: return .json(liveGrant)
            case listOperation: return .json("[]")
            default: return .status(.internalServerError)
            }
        }
        await signOn(store)

        async let creating = store.create(name: "Laptop")
        await gate.waitForArrival()
        await session.signOutWithoutRevoking()
        #expect(session.activeHandle == nil, "the identity was still there to be judged against")
        await gate.release()
        let created = await creating

        #expect(!created)
        #expect(store.minted == nil, "a plaintext was shown for an identity that is gone")
        #expect(!store.mintedSecretLost, "the loss was announced to an identity that is gone")
    }

    /// A failure answers through a different continuation than a success, and every one of them
    /// writes the screen. A mint that failed for an identity that has gone must write none of them.
    @Test("a mint the server refused after the app identity went says nothing")
    func aHeldMintRefusalCannotSpeakForAnIdentityThatWent() async throws {
        let seen = LockedValue<[Seen]>([])
        let gate = RequestGate()
        let session = await signedInSession()
        let store = makeStore(seen: seen, session: session) { operation in
            guard operation == mintOperation else { return .status(.internalServerError) }
            await gate.hold()
            return .status(.notFound)
        }

        async let signingOn = signOn(store)
        await gate.waitForArrival()
        await session.signOutWithoutRevoking()
        await gate.release()
        let signedOn = await signingOn

        #expect(!signedOn)
        #expect(store.state != .unsupported, "a refusal was written for an identity that is gone")
    }

    @Test("a handoff code the server rejected after the app identity went says nothing either")
    func aHeldMintRejectionCannotSpeakForAnIdentityThatWent() async throws {
        let seen = LockedValue<[Seen]>([])
        let gate = RequestGate()
        let session = await signedInSession()
        let store = makeStore(seen: seen, session: session) { operation in
            guard operation == mintOperation else { return .status(.internalServerError) }
            await gate.hold()
            return .detail("code_expired", status: .badRequest)
        }

        async let signingOn = signOn(store)
        await gate.waitForArrival()
        await session.signOutWithoutRevoking()
        await gate.release()
        let signedOn = await signingOn

        #expect(!signedOn)
        #expect(
            store.state != .locked(.refused(.exchangeRejected(.codeExpired))),
            "a refusal was written for an identity that is gone"
        )
    }

    /// The browser is out of the app's hands: a callback can come back at any moment, including
    /// after the person signed out from another screen. The handoff code it carries buys a grant on
    /// an account nobody is signed in to any more, so it is not exchanged at all.
    @Test("a browser callback that returns after the app identity went exchanges nothing")
    func aCallbackAfterTheIdentityWentIsNotExchanged() async throws {
        let seen = LockedValue<[Seen]>([])
        let session = await signedInSession()
        let store = makeStore(seen: seen, session: session) { operation in
            operation == mintOperation ? .json(liveGrant) : .json("[]")
        }
        let reentrant = ReentrantPresenter(callback: "memosng://auth-callback?code=abc")
        reentrant.reenter = {
            await session.signOutWithoutRevoking()
            return true
        }

        let signedOn = await store.authenticate(
            deviceName: "Fabian's iPhone",
            presenter: reentrant
        )

        #expect(!signedOn)
        #expect(session.activeHandle == nil, "the identity was still there to be judged against")
        #expect(seen.get().isEmpty, "a handoff code was exchanged for an identity that is gone")
    }

    /// The last instant, and the one no check on the main actor can cover: the request was started
    /// while the identity was there and leaves after it went.
    @Test("a request already on its way out is not sent once the app identity goes")
    func aRequestOnItsWayOutIsNotSentAfterTheIdentityGoes() async throws {
        let seen = LockedValue<[Seen]>([])
        let gate = RequestGate()
        let armed = LockedValue(false)
        let session = await signedInSession()
        let store = ManageTokensStore(
            configuration: ServerConfiguration(baseURL: Stub.baseURL),
            session: session,
            makeClient: { _, grant, licence in
                Stub.client(
                    grant: grant,
                    licence: licence,
                    ahead: HoldingOnTheWayOut(operation: listOperation, armed: armed, gate: gate)
                ) { request, _, operation in
                    seen.set(
                        seen.get()
                            + [
                                Seen(
                                    operation: operation,
                                    method: request.method.rawValue,
                                    path: request.path ?? "",
                                    authorization: request.headerFields[.authorization]
                                )
                            ]
                    )
                    switch operation {
                    case mintOperation: return Stub.json(liveGrant)
                    case listOperation:
                        return Stub.json("[\(Stub.pat(id: 1, name: "Kitchen phone"))]")
                    default: return Stub.empty(.internalServerError)
                    }
                }
            },
            now: { managementNow }
        )
        await signOn(store)
        armed.set(true)

        async let reading: Void = store.refresh()
        await gate.waitForArrival()
        await session.signOutWithoutRevoking()
        await gate.release()
        await reading

        #expect(
            seen.get().filter { $0.operation == listOperation }.count == 1,
            "a request left for an identity that is gone"
        )
    }
}

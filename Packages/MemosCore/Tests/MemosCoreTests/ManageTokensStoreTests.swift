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
        now: @escaping @Sendable () -> Date = { managementNow },
        handler: @escaping @Sendable (String) async throws -> HTTPResponseLike
    ) -> ManageTokensStore {
        ManageTokensStore(
            configuration: ServerConfiguration(baseURL: Stub.baseURL),
            makeClient: { _, grant in
                Stub.client(grant: grant) { request, _, operation in
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
            makeClient: { _, grant in
                Stub.client(grant: grant) { request, _, operation in
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

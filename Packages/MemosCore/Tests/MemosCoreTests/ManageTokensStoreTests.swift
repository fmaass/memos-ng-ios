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

/// A grant minted after the clock has moved past the wait for the browser step, and still live at
/// that instant — what a round trip made from there really buys.
private let grantLiveAfterTheWait = Stub.manageGrant(
    "mg_after_the_wait",
    expiresAt: iso(managementNow.addingTimeInterval(1320))
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

    /// A re-read that did not arrive is not "what is there now". The list still on screen is the
    /// one from before the revoke — the row somebody just pressed included — so calling it current
    /// would hide the failure the read already reported and vouch for a list nobody could read.
    @Test("a vanished token whose re-read failed leaves the failure, not 'already gone'")
    func revokingAVanishedTokenWhoseRereadFailedKeepsTheFailure() async throws {
        let seen = LockedValue<[Seen]>([])
        let attempts = LockedValue<Int>(0)
        let bothRows =
            "[\(Stub.pat(id: 1, name: "Kitchen phone")),\(Stub.pat(id: 7, name: "Lost phone"))]"
        let store = makeStore(seen: seen) { operation in
            switch operation {
            case mintOperation:
                return .json(liveGrant)
            case listOperation:
                let attempt = attempts.get() + 1
                attempts.set(attempt)
                return attempt == 1 ? .json(bothRows) : .status(.internalServerError)
            case revokeOperation:
                return .status(.notFound)
            default:
                return .status(.internalServerError)
            }
        }

        await signOn(store)
        let revoked = await store.revoke(7)

        #expect(!revoked)
        #expect(store.notice != ManageTokensStore.alreadyGone)
        #expect(
            store.notice == APIError.server(status: 500).errorDescription,
            "the re-read's own failure was overwritten"
        )
        let listed = try #require(rows(store.state), "the screen lost the list it already had")
        #expect(listed.map(\.id) == [1, 7], "a list nobody could re-read was called current")
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

    /// A list that did not arrive is not the end of a management session. The grant the sign-on
    /// just bought is live for minutes yet and the only thing missing is the read, so the way out
    /// is another read — which the screen can only offer from a state that is no longer the
    /// sign-on's own.
    @Test("a first list that failed leaves a live session that can be read again")
    func aFailedFirstListLeavesTheSessionReadable() async throws {
        let seen = LockedValue<[Seen]>([])
        let attempts = LockedValue<Int>(0)
        let store = makeStore(seen: seen) { operation in
            switch operation {
            case mintOperation:
                return .json(liveGrant)
            case listOperation:
                let attempt = attempts.get() + 1
                attempts.set(attempt)
                return attempt == 1
                    ? .status(.internalServerError)
                    : .json("[\(Stub.pat(id: 1, name: "Kitchen phone"))]")
            default:
                return .status(.internalServerError)
            }
        }

        let signedOn = await signOn(store)

        #expect(signedOn)
        #expect(store.state != .authenticating, "a read that failed left the screen mid-sign-on")
        #expect(store.notice != nil)
        #expect(!store.isBusy)

        // The read the screen offers, under the grant that was bought before the failure: it can
        // only be served if that grant is still held.
        await store.refresh()

        let listed = try #require(rows(store.state))
        #expect(listed.map(\.name) == ["Kitchen phone"])
        #expect(store.notice == nil)
    }

    /// Asked from the failed state itself, with no read in between. A screen that still believed a
    /// sign-on was under way would refuse this one, and there is nothing else on it to press.
    @Test("a sign-on is offered again from a first list that failed")
    func aFailedFirstListDoesNotRefuseAnotherSignOn() async throws {
        let seen = LockedValue<[Seen]>([])
        let attempts = LockedValue<Int>(0)
        let store = makeStore(seen: seen) { operation in
            switch operation {
            case mintOperation:
                return .json(liveGrant)
            case listOperation:
                let attempt = attempts.get() + 1
                attempts.set(attempt)
                return attempt == 1
                    ? .status(.internalServerError)
                    : .json("[\(Stub.pat(id: 1, name: "Kitchen phone"))]")
            default:
                return .status(.internalServerError)
            }
        }

        await signOn(store)
        let again = await signOn(store)

        #expect(again, "the second sign-on was refused as one already under way")
        let listed = try #require(rows(store.state))
        #expect(listed.map(\.name) == ["Kitchen phone"])
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
    /// EVERY held request, not the latest one. A gate keeping a single continuation would hang on
    /// the exact bug these tests are about: with two requests in the air the second replaces the
    /// first's continuation, so the first is never resumed and the suite stops instead of failing.
    /// A test that hangs when the behaviour breaks reports nothing.
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

    // MEMNG-538 device spike — kill date 2026-11-03, with the method it pins.
    private func spikeStore(
        seen: LockedValue<[Seen]>, gate: RequestGate, session: (any SessionReporting)? = nil
    ) -> ManageTokensStore {
        makeStore(seen: seen, session: session) { operation in
            if operation == createOperation {
                await gate.hold()
                return .created(
                    Stub.patCreated(id: 9, name: "Upload spike", token: "memos_pat_spike")
                )
            }
            switch operation {
            case mintOperation: return .json(liveGrant)
            case listOperation: return .json("[]")
            default: return .status(.internalServerError)
            }
        }
    }

    @Test("two taps on the spike mint put one create on the wire and keep its secret once")
    func spikeMintIsSerialised() async throws {
        let seen = LockedValue<[Seen]>([])
        let gate = RequestGate()
        let kept = LockedValue<[String]>([])
        let store = spikeStore(seen: seen, gate: gate)
        await signOn(store)

        let keep: @Sendable (MintedToken) -> Bool = {
            kept.set(kept.get() + [$0.secret])
            return true
        }
        async let first = store.createForUploadSpike(keep)
        await gate.waitForArrival()
        let second = await store.createForUploadSpike(keep)
        await gate.release()
        let firstFinished = await first

        #expect(firstFinished)
        #expect(!second, "the second tap should have been refused rather than sent")
        #expect(seen.get().filter { $0.operation == createOperation }.count == 1)
        #expect(kept.get() == ["memos_pat_spike"])
        #expect(store.minted == nil, "a kept spike token left its plaintext panel up")
    }

    @Test("a spike token minted after the app identity went is never kept")
    func spikeMintFencedOnIdentity() async throws {
        let seen = LockedValue<[Seen]>([])
        let gate = RequestGate()
        let kept = LockedValue<[String]>([])
        let session = await signedInSession()
        let store = spikeStore(seen: seen, gate: gate, session: session)
        await signOn(store)

        async let minting = store.createForUploadSpike {
            kept.set(kept.get() + [$0.secret])
            return true
        }
        await gate.waitForArrival()
        await session.signOutWithoutRevoking()
        await gate.release()

        #expect(!(await minting))
        #expect(kept.get().isEmpty)
    }

    @Test("a spike secret that could not be stored stays on its panel")
    func spikeMintUnkeptStaysVisible() async throws {
        let seen = LockedValue<[Seen]>([])
        let gate = RequestGate()
        let store = spikeStore(seen: seen, gate: gate)
        await signOn(store)

        async let minting = store.createForUploadSpike { _ in false }
        await gate.waitForArrival()
        await gate.release()

        #expect(!(await minting))
        #expect(store.minted?.secret == "memos_pat_spike")
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

    /// The plaintext of a token minted BEFORE the identity went is on screen, with its Copy action
    /// live, at the one instant this store cannot rely on its own teardown: the session withdraws
    /// its handle synchronously and the sheet goes away afterwards. What the screen can see is
    /// therefore judged when it reads, against the identity the secret was minted under.
    @Test("a plaintext already on screen stops being readable the instant the app identity goes")
    func aShownSecretIsUnreadableOnceTheIdentityWent() async throws {
        let seen = LockedValue<[Seen]>([])
        let session = await signedInSession()
        let store = makeStore(seen: seen, session: session) { operation in
            switch operation {
            case mintOperation: .json(liveGrant)
            case listOperation: .json("[]")
            case createOperation:
                .created(Stub.patCreated(id: 2, name: "Laptop", token: "memos_pat_brand_new"))
            default: .status(.internalServerError)
            }
        }
        await signOn(store)
        await store.create(name: "Laptop")

        #expect(store.minted?.secret == "memos_pat_brand_new", "there was no plaintext to fence")

        await session.signOutWithoutRevoking()
        #expect(session.activeHandle == nil, "the identity was still there to be judged against")

        #expect(store.minted == nil, "a plaintext outlived the identity it was minted under")

        await store.refresh()
        #expect(!store.mintedSecretLost, "a loss was announced to whoever signs in next")
    }

    /// The same fence from the other end. A notice raised while the identity still held was a true
    /// sentence at the instant it was written; it stops being one when that identity goes, and
    /// nothing comes along afterwards to take it back. So the notice is judged where it is read,
    /// not where it was assigned.
    @Test("a loss announced under an identity stops being readable the instant that identity goes")
    func anAnnouncedLossIsUnreadableOnceTheIdentityWent() async throws {
        let seen = LockedValue<[Seen]>([])
        let session = await signedInSession()
        let store = makeStore(seen: seen, session: session) { operation in
            switch operation {
            case mintOperation: .json(liveGrant)
            case listOperation: .json("[]")
            case createOperation:
                .created(Stub.patCreated(id: 2, name: "Laptop", token: "memos_pat_brand_new"))
            default: .status(.internalServerError)
            }
        }
        await signOn(store)
        await store.create(name: "Laptop")

        store.forget()
        #expect(store.mintedSecretLost, "there was no announced loss to fence")

        await session.signOutWithoutRevoking()
        #expect(session.activeHandle == nil, "the identity was still there to be judged against")

        #expect(!store.mintedSecretLost, "a loss outlived the identity it was announced to")
    }

    /// The same start, and the case the notice exists for: the identity holds, the grant runs out,
    /// and the person reading the sheet is the one who asked for the token. A panel that quietly
    /// vanished would leave them believing they still hold the only copy of its text.
    @Test("a grant running out under the same identity takes the plaintext and says so")
    func aLapsedGrantAnnouncesTheLostSecret() async throws {
        let seen = LockedValue<[Seen]>([])
        let clock = LockedValue(managementNow)
        let session = await signedInSession()
        let store = makeStore(seen: seen, session: session, now: { clock.get() }) { operation in
            switch operation {
            case mintOperation: .json(liveGrant)
            case listOperation: .json("[]")
            case createOperation:
                .created(Stub.patCreated(id: 2, name: "Laptop", token: "memos_pat_brand_new"))
            default: .status(.internalServerError)
            }
        }
        await signOn(store)
        await store.create(name: "Laptop")

        #expect(store.minted?.secret == "memos_pat_brand_new", "there was no plaintext to lose")

        clock.set(managementNow.addingTimeInterval(601))
        await store.refresh()

        #expect(store.minted == nil, "a plaintext survived the grant it was shown under")
        #expect(store.mintedSecretLost, "a plaintext went away without the screen saying so")
        #expect(store.state == .locked(.expired))
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

    /// The spinner is the round trip's to take down. Left standing, the screen shows a browser
    /// step that nobody can answer any more — and the next tap is refused for being one already
    /// under way, which leaves nothing on the screen to press.
    @Test("a sign-on abandoned because the identity went takes its own spinner down")
    func anAbandonedSignOnTakesItsSpinnerDown() async throws {
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
        #expect(store.state == .locked(.never), "the abandoned sign-on left its spinner up")
        #expect(seen.get().isEmpty, "a handoff code was exchanged for an identity that is gone")
    }

    /// The other half of the same rule: a spinner belongs to the round trip that is still running,
    /// and an older one coming back has no business taking it down — the person would be left in
    /// front of a browser view whose answer has no screen to land on.
    @Test("a sign-on abandoned for a newer one leaves the newer one's spinner alone")
    func anAbandonedSignOnLeavesANewerSpinnerAlone() async throws {
        let seen = LockedValue<[Seen]>([])
        let release = LockedValue<Bool>(false)
        let store = makeStore(seen: seen) { operation in
            guard operation == mintOperation else { return .json("[]") }
            // Held, so the second round trip is provably still RUNNING — past its browser step, its
            // exchange unanswered, its spinner up — when the first one comes back. Bounded: a hold
            // nobody released would hang the suite, and a suite that hangs when the behaviour
            // breaks reports nothing.
            for _ in 0..<2000 {
                if release.get() { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            return .json(liveGrant)
        }
        let second = LockedValue<Task<Bool, Never>?>(nil)
        let first = ReentrantPresenter(callback: "memosng://auth-callback?code=abc")
        first.reenter = {
            // The screen was closed on purpose, which ends the attempt that was open, and a second
            // sign-on was opened afterwards. Its own generation is the current one from here on,
            // and the spinner on screen is ITS.
            store.forget(.closed)
            second.set(
                Task {
                    await store.authenticate(
                        deviceName: "Fabian's iPhone",
                        presenter: ReentrantPresenter(callback: "memosng://auth-callback?code=def")
                    )
                }
            )
            // Bounded, and it waits for the newer round trip to have really put its spinner up:
            // everything after this has to be about a spinner that belongs to somebody else.
            for _ in 0..<200 {
                if case .authenticating = store.state { break }
                await Task.yield()
            }
            return true
        }

        let firstResult = await store.authenticate(
            deviceName: "Fabian's iPhone",
            presenter: first
        )

        #expect(!firstResult)
        #expect(store.state == .authenticating, "an older sign-on took a newer one's spinner down")
        let running = try #require(second.get())
        release.set(true)
        #expect(await running.value, "control: the newer sign-on was a real round trip")
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

    // MARK: - a sign-on that outlasts the screen it was started from

    /// The browser step is exactly what takes this screen off the display, so a screen that went
    /// away is what a sign-on LOOKS like from in here. Reading it as the end of one abandons every
    /// round trip that leaves the app — and there is nothing to drop either, because a sign-on
    /// that has not come back has bought nothing.
    @Test("a sign-on in flight survives the screen going away and comes back with the list")
    func aSignOnInFlightSurvivesTheScreenGoingAway() async throws {
        let seen = LockedValue<[Seen]>([])
        let store = makeStore(seen: seen) { operation in
            switch operation {
            case mintOperation: .json(liveGrant)
            case listOperation: .json("[\(Stub.pat(id: 1, name: "Kitchen phone"))]")
            default: .status(.internalServerError)
            }
        }
        let presenter = ReentrantPresenter(callback: "memosng://auth-callback?code=abc")
        presenter.reenter = {
            store.forget()
            return true
        }

        let signedOn = await store.authenticate(
            deviceName: "Fabian's iPhone",
            presenter: presenter
        )

        #expect(signedOn)
        #expect(
            seen.get().filter { $0.operation == mintOperation }.count == 1,
            "the handoff code was never spent"
        )
        #expect(rows(store.state)?.map(\.id) == [1])
    }

    /// A list belongs to the account it was read for, not to the screen it is drawn on. An
    /// identity replaced in place — signed out and signed in again, a handle still there — leaves
    /// rows on this screen that are somebody else's, and it may not go on reporting them.
    @Test("a listed screen stops reporting its rows once the app identity is replaced")
    func aListedScreenStopsReportingOnceTheIdentityIsReplaced() async throws {
        let seen = LockedValue<[Seen]>([])
        let session = await signedInSession()
        let store = makeStore(seen: seen, session: session) { operation in
            switch operation {
            case mintOperation: .json(liveGrant)
            case listOperation: .json("[\(Stub.pat(id: 1, name: "Kitchen phone"))]")
            default: .status(.internalServerError)
            }
        }

        await signOn(store)
        #expect(rows(store.state)?.map(\.id) == [1], "there was no list to lose")

        await session.signOutWithoutRevoking()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        #expect(session.activeHandle != nil, "the identity was withdrawn rather than replaced")

        #expect(rows(store.state) == nil, "a list outlived the identity it was read for")
    }

    /// The same replacement while the browser step is still open. Whatever the round trip comes
    /// back with belongs to an account nobody is holding, and the screen may not be left on the
    /// spinner that round trip put up.
    @Test("a browser step that returns after the identity was replaced leaves no spinner")
    func aBrowserStepReturningAfterAReplacementLeavesNoSpinner() async throws {
        let seen = LockedValue<[Seen]>([])
        let session = await signedInSession()
        let store = makeStore(seen: seen, session: session) { operation in
            operation == mintOperation ? .json(liveGrant) : .json("[]")
        }
        let presenter = ReentrantPresenter(callback: "memosng://auth-callback?code=abc")
        presenter.reenter = {
            await session.signOutWithoutRevoking()
            await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
            return true
        }

        let signedOn = await store.authenticate(
            deviceName: "Fabian's iPhone",
            presenter: presenter
        )

        #expect(!signedOn)
        #expect(store.state != .authenticating, "a replaced identity was left on a spinner")
        #expect(seen.get().isEmpty, "a handoff code was exchanged for an identity that is gone")
    }

    /// The other involuntary report, and the one the phone really does send when a sign-on takes
    /// somebody into a browser that puts this app behind it.
    @Test("a sign-on in flight survives the app being put away and comes back with the list")
    func aSignOnInFlightSurvivesTheAppBeingPutAway() async throws {
        let seen = LockedValue<[Seen]>([])
        let store = makeStore(seen: seen) { operation in
            switch operation {
            case mintOperation: .json(liveGrant)
            case listOperation: .json("[\(Stub.pat(id: 1, name: "Kitchen phone"))]")
            default: .status(.internalServerError)
            }
        }
        let presenter = ReentrantPresenter(callback: "memosng://auth-callback?code=abc")
        presenter.reenter = {
            store.forget(.appWentAway)
            return true
        }

        let signedOn = await store.authenticate(
            deviceName: "Fabian's iPhone",
            presenter: presenter
        )

        #expect(signedOn)
        #expect(
            seen.get().filter { $0.operation == mintOperation }.count == 1,
            "the handoff code was never spent"
        )
        #expect(rows(store.state)?.map(\.id) == [1])
    }

    /// Close is the one departure somebody chose, and the only one that is unambiguous. It ends
    /// the attempt in front of them, and the code that comes back afterwards buys nothing.
    @Test("closing the screen ends a sign-on that is still waiting for its browser step")
    func closingTheScreenEndsAnInFlightSignOn() async throws {
        let seen = LockedValue<[Seen]>([])
        let store = makeStore(seen: seen) { operation in
            operation == mintOperation ? .json(liveGrant) : .json("[]")
        }
        let presenter = ReentrantPresenter(callback: "memosng://auth-callback?code=abc")
        presenter.reenter = {
            store.forget(.closed)
            return true
        }

        let signedOn = await store.authenticate(
            deviceName: "Fabian's iPhone",
            presenter: presenter
        )

        #expect(!signedOn)
        #expect(store.state == .locked(.never), "the closed screen was left on its spinner")
        #expect(seen.get().isEmpty, "a handoff code was spent for a screen that was closed")
    }

    /// The ender the person reaches for most: they close the browser. The attempt is over, it says
    /// so, and the screen is free to offer another one.
    @Test("a browser the person closed ends the sign-on and the next tap is a real round trip")
    func aClosedBrowserEndsTheSignOn() async throws {
        let seen = LockedValue<[Seen]>([])
        let store = makeStore(seen: seen) { operation in
            operation == mintOperation ? .json(liveGrant) : .json("[]")
        }

        let refused = await store.authenticate(
            deviceName: "Fabian's iPhone",
            presenter: StubPresenter(behaviour: .failure(.cancelled))
        )

        #expect(!refused)
        #expect(store.state == .locked(.refused(.cancelled)))

        let again = await signOn(store)
        #expect(again, "control: the ended attempt refused the next one")
    }

    // MARK: - the wait for the browser step

    /// A round trip that produces no answer at all has to end in a sentence rather than in a
    /// spinner nobody can stop. The deadline covers the wait for the browser step and nothing
    /// after it, and it is decided from the injected clock rather than from a race.
    @Test("a browser step that never comes back ends with a sentence, not a spinner")
    func anUnansweredBrowserStepEndsWithASentence() async throws {
        let seen = LockedValue<[Seen]>([])
        let clock = LockedValue(managementNow)
        let store = makeStore(seen: seen, now: { clock.get() }) { operation in
            operation == mintOperation ? .json(liveGrant) : .json("[]")
        }
        let presenter = OccupiedPresenter()

        async let signingOn = store.authenticate(
            deviceName: "Fabian's iPhone",
            presenter: presenter
        )
        await presenter.waitUntilOpen()

        #expect(!store.signOnDeadlinePassed(), "the wait ended before it had run out")
        #expect(store.state == .authenticating, "the sign-on was not on screen to begin with")

        clock.set(managementNow.addingTimeInterval(ManageTokensStore.browserStepDeadline))
        #expect(store.signOnDeadlinePassed(), "the wait ran out and nothing said so")
        #expect(store.state == .locked(.unanswered))

        // The answer the deadline beat. It lost the claim, so it writes nothing at all — including
        // the grant it would otherwise have gone on to buy.
        presenter.answer("memosng://auth-callback?code=abc")
        let signedOn = await signingOn

        #expect(!signedOn)
        #expect(store.state == .locked(.unanswered), "a beaten answer wrote the screen anyway")
        #expect(seen.get().isEmpty, "a handoff code was spent for a wait that had ended")
    }

    /// The window the deadline leaves behind: it cannot take the browser down, so the presenter is
    /// still holding that attempt while the person is looking at the browser. A tap in that window
    /// must cost nothing and corrupt nothing, and once the old attempt settles the next tap has to
    /// be a real round trip.
    @Test("a retry while the browser step is still open costs nothing, and the next one works")
    func aRetryWhileTheOldAttemptIsStillOpen() async throws {
        let seen = LockedValue<[Seen]>([])
        let clock = LockedValue(managementNow)
        let store = makeStore(seen: seen, now: { clock.get() }) { operation in
            switch operation {
            // Live at the clock this test ends on, so the round trip it finishes with is a round
            // trip that really lists rather than one that lapses on its way to the list.
            case mintOperation: .json(grantLiveAfterTheWait)
            case listOperation: .json("[\(Stub.pat(id: 1, name: "Kitchen phone"))]")
            default: .status(.internalServerError)
            }
        }
        // ONE presenter for every attempt, as the screen has: a second stub would answer as if
        // nothing were open, which is the whole of what this test is asking about.
        let presenter = OccupiedPresenter()

        async let signingOn = store.authenticate(
            deviceName: "Fabian's iPhone",
            presenter: presenter
        )
        await presenter.waitUntilOpen()
        clock.set(managementNow.addingTimeInterval(ManageTokensStore.browserStepDeadline))
        #expect(store.signOnDeadlinePassed())

        let retried = await store.authenticate(
            deviceName: "Fabian's iPhone",
            presenter: presenter
        )

        #expect(!retried)
        #expect(presenter.refusals == 1, "the retry was not refused by the presenter it shares")
        #expect(seen.get().isEmpty, "a retry spent a handoff code while the old step was open")
        #expect(
            store.state == .locked(.refused(.alreadySigningIn)),
            "the retry left the screen somewhere it cannot be read"
        )

        presenter.answer("memosng://auth-callback?code=abc")
        let signedOn = await signingOn
        #expect(!signedOn)

        // The same presenter, which is the point: it is free again, so this is a real round trip.
        let again = await store.authenticate(
            deviceName: "Fabian's iPhone",
            presenter: presenter
        )
        #expect(again, "control: once the old step settled, the next tap was a real round trip")
        #expect(seen.get().filter { $0.operation == mintOperation }.count == 1)
        #expect(rows(store.state)?.map(\.id) == [1], "control: the round trip listed nothing")
    }

    // MARK: - the window between the browser step and the grant

    /// The exchange is the other half of the same round trip, and it is in the air at exactly the
    /// moment the phone hands the app back. Nothing has been bought until it answers, so the two
    /// reports nobody chose may not end it there either.
    @Test("a sign-on survives the app being put away while its grant exchange is in the air")
    func aSignOnSurvivesTheAppBeingPutAwayDuringTheExchange() async throws {
        let seen = LockedValue<[Seen]>([])
        let gate = RequestGate()
        let store = makeStore(seen: seen) { operation in
            switch operation {
            case mintOperation:
                await gate.hold()
                return .json(liveGrant)
            case listOperation: return .json("[\(Stub.pat(id: 1, name: "Kitchen phone"))]")
            default: return .status(.internalServerError)
            }
        }

        async let signingOn = signOn(store)
        await gate.waitForArrival()
        store.forget(.appWentAway)
        await gate.release()
        let signedOn = await signingOn

        #expect(signedOn)
        #expect(
            seen.get().filter { $0.operation == mintOperation }.count == 1,
            "the exchange was sent more than once"
        )
        #expect(rows(store.state)?.map(\.id) == [1])
    }

    /// The same window, and the report that cannot be told from the browser being presented over
    /// this screen in the first place.
    @Test("a sign-on survives the screen going away while its grant exchange is in the air")
    func aSignOnSurvivesTheScreenGoingAwayDuringTheExchange() async throws {
        let seen = LockedValue<[Seen]>([])
        let gate = RequestGate()
        let store = makeStore(seen: seen) { operation in
            switch operation {
            case mintOperation:
                await gate.hold()
                return .json(liveGrant)
            case listOperation: return .json("[\(Stub.pat(id: 1, name: "Kitchen phone"))]")
            default: return .status(.internalServerError)
            }
        }

        async let signingOn = signOn(store)
        await gate.waitForArrival()
        store.forget(.screenWentAway)
        await gate.release()
        let signedOn = await signingOn

        #expect(signedOn)
        #expect(
            seen.get().filter { $0.operation == mintOperation }.count == 1,
            "the exchange was sent more than once"
        )
        #expect(rows(store.state)?.map(\.id) == [1])
    }

    /// Where the exemption stops, which is the half that keeps the feature's contract: the grant
    /// is HELD by the time the first list read is out, so the app going away destroys it exactly
    /// as it always has, and the list that arrives afterwards has no screen to land on.
    @Test("a report while the first list read is in the air still discards the grant")
    func aReportDuringTheFirstListReadStillDiscards() async throws {
        let seen = LockedValue<[Seen]>([])
        let gate = RequestGate()
        let store = makeStore(seen: seen) { operation in
            switch operation {
            case mintOperation: return .json(liveGrant)
            case listOperation:
                await gate.hold()
                return .json("[\(Stub.pat(id: 1, name: "Kitchen phone"))]")
            default: return .status(.internalServerError)
            }
        }

        async let signingOn = signOn(store)
        await gate.waitForArrival()
        store.forget(.appWentAway)
        await gate.release()
        _ = await signingOn

        #expect(store.state == .locked(.discarded))
        #expect(rows(store.state) == nil, "a held list repopulated a screen whose grant had gone")
        #expect(!store.isBusy)
    }

    /// Close ends the whole round trip wherever it has got to, the exchange included, and what the
    /// server answers afterwards buys nothing anybody can see.
    @Test("closing the screen during the grant exchange ends it, and the answer buys nothing")
    func closingTheScreenDuringTheExchangeEndsIt() async throws {
        let seen = LockedValue<[Seen]>([])
        let gate = RequestGate()
        let store = makeStore(seen: seen) { operation in
            switch operation {
            case mintOperation:
                await gate.hold()
                return .json(liveGrant)
            case listOperation: return .json("[\(Stub.pat(id: 1, name: "Kitchen phone"))]")
            default: return .status(.internalServerError)
            }
        }

        async let signingOn = signOn(store)
        await gate.waitForArrival()
        store.forget(.closed)
        await gate.release()
        let signedOn = await signingOn

        #expect(!signedOn)
        #expect(store.state == .locked(.never), "a screen that was closed was left on its spinner")
        #expect(rows(store.state) == nil)
        #expect(
            seen.get().filter { $0.operation == listOperation }.isEmpty,
            "a list was read for a screen the person had closed"
        )
    }
}

/// One presenter for every attempt on a store, the way the screen has one: it holds the attempt
/// open until the test answers it, and refuses a second one while it is holding the first — which
/// is what the real presenter does while it is presenting or exchanging.
@MainActor
private final class OccupiedPresenter: NativeLoginPresenter {
    private(set) var refusals = 0
    private var open = false
    private var callback: String?

    func answer(_ callback: String) { self.callback = callback }

    /// Bounded, like every other wait in this suite: a poll nobody answered would hang the suite,
    /// and a suite that hangs when the behaviour breaks reports nothing.
    func waitUntilOpen() async {
        for _ in 0..<2000 {
            if open { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func authenticate(
        authorizeURL: URL,
        callbackHost: String,
        callbackPath: String
    ) async throws -> URL {
        guard !open else {
            refusals += 1
            throw NativeLoginError.alreadySigningIn
        }
        open = true
        defer { open = false }
        for _ in 0..<2000 {
            if let callback {
                guard let url = URL(string: callback) else { throw NativeLoginError.cancelled }
                return url
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        throw NativeLoginError.cancelled
    }
}

/// How many deletes a revoke is worth. The case above reads the FIRST matching request and
/// asserts its method and path, which is the shape of the request and not how many of them there
/// were — two would pass it unchanged.
extension ManageTokensStoreTests {
    @Test("a revoke puts exactly one delete on the wire")
    func revokeSendsExactlyOneDelete() async throws {
        let seen = LockedValue<[Seen]>([])
        let store = makeStore(seen: seen) { operation in
            switch operation {
            case mintOperation: .json(liveGrant)
            case listOperation: .json("[\(Stub.pat(id: 1, name: "Kitchen phone"))]")
            case revokeOperation: .status(.noContent)
            default: .status(.internalServerError)
            }
        }

        await signOn(store)
        await store.revoke(7)

        #expect(seen.get().filter { $0.operation == revokeOperation }.count == 1)
    }

    /// Two presses that overlap. The question in front of the control is an affordance and never
    /// the guard: it can be answered twice, and what makes that one delete is the store's own gate,
    /// which REFUSES the second rather than joining it.
    @Test("two overlapping revokes send one delete, not two")
    func revokeIsSerialised() async throws {
        let seen = LockedValue<[Seen]>([])
        let gate = RequestGate()
        let store = makeStore(seen: seen) { operation in
            if operation == revokeOperation {
                await gate.hold()
                return .status(.noContent)
            }
            switch operation {
            case mintOperation: return .json(liveGrant)
            case listOperation: return .json("[\(Stub.pat(id: 7, name: "Lost phone"))]")
            default: return .status(.internalServerError)
            }
        }
        await signOn(store)

        async let first = store.revoke(7)
        await gate.waitForArrival()
        let second = await store.revoke(7)
        await gate.release()
        let firstFinished = await first

        #expect(firstFinished)
        #expect(!second, "the second press should have been refused rather than sent")
        #expect(seen.get().filter { $0.operation == revokeOperation }.count == 1)
    }
}

/// The answer and the deadline race for ONE claim, and the race is decided where the answer
/// ARRIVES, not where the store next runs. Between the browser step's answer and the store reading
/// it there is a continuation hop, and anything else on the main actor — the deadline's own wake
/// included — can run inside it. An answer that had already arrived must not lose to a deadline
/// that woke after it.
///
/// Every sign-on here is OBSERVED rather than awaited (`SignOnOutcome`): a regression in this area
/// is a call that never resumes, and awaiting one would hang the suite instead of failing it.
extension ManageTokensStoreTests {
    private func startSignOn(
        _ store: ManageTokensStore,
        presenter: CallbackSitePresenter
    ) -> SignOnOutcome {
        let outcome = SignOnOutcome()
        Task {
            outcome.finish(
                await store.authenticate(deviceName: "Fabian's iPhone", presenter: presenter)
            )
        }
        return outcome
    }

    @Test("an answer that arrived before the deadline wins, even when the deadline wakes first")
    func anAnswerThatArrivedWinsTheHopBeforeTheStoreResumes() async throws {
        let seen = LockedValue<[Seen]>([])
        let clock = LockedValue(managementNow)
        let store = makeStore(seen: seen, now: { clock.get() }) { operation in
            switch operation {
            // Live at the clock this test ends on: the round trip it finishes with happens after
            // the deadline instant, and must list rather than lapse.
            case mintOperation: .json(grantLiveAfterTheWait)
            case listOperation: .json("[\(Stub.pat(id: 1, name: "Kitchen phone"))]")
            default: .status(.internalServerError)
            }
        }
        let presenter = CallbackSitePresenter()
        defer { presenter.close() }
        let callback = try #require(URL(string: "memosng://auth-callback?code=abc"))

        let signingOn = startSignOn(store, presenter: presenter)
        await presenter.waitUntilOpen()
        #expect(store.state == .authenticating, "the sign-on was not on screen to begin with")

        // ONE main-actor turn with nothing awaited in it: the answer arrives, the deadline's
        // instant comes, and the deadline's wake runs — all before the store's continuation can.
        presenter.deliver(callback)
        clock.set(managementNow.addingTimeInterval(ManageTokensStore.browserStepDeadline))
        let deadlineTook = store.signOnDeadlinePassed()
        guard let signedOn = await signingOn.settled() else { return }

        #expect(presenter.claims == [true], "the answer did not claim where it arrived")
        #expect(!deadlineTook, "the deadline took an attempt whose answer had already arrived")
        #expect(signedOn, "an answer that arrived first was thrown away")
        #expect(store.state != .locked(.unanswered), "the screen blamed a browser that answered")
        #expect(rows(store.state)?.map(\.id) == [1], "the sign-on did not end on the list")
        #expect(seen.get().filter { $0.operation == mintOperation }.count == 1)
    }

    /// The other order of the same race, so the one above is read as "the first to arrive wins"
    /// rather than as "the answer always wins": a deadline that has already taken the attempt is
    /// not undone by an answer arriving after it.
    @Test("a deadline that ran out before the answer arrived still takes the attempt")
    func aDeadlineThatCameFirstBeatsTheAnswerAtTheCallbackSite() async throws {
        let seen = LockedValue<[Seen]>([])
        let clock = LockedValue(managementNow)
        let store = makeStore(seen: seen, now: { clock.get() }) { operation in
            operation == mintOperation ? .json(grantLiveAfterTheWait) : .json("[]")
        }
        let presenter = CallbackSitePresenter()
        defer { presenter.close() }
        let callback = try #require(URL(string: "memosng://auth-callback?code=abc"))

        let signingOn = startSignOn(store, presenter: presenter)
        await presenter.waitUntilOpen()

        clock.set(managementNow.addingTimeInterval(ManageTokensStore.browserStepDeadline))
        let deadlineTook = store.signOnDeadlinePassed()
        presenter.deliver(callback)
        guard let signedOn = await signingOn.settled() else { return }

        #expect(deadlineTook, "the wait ran out and nothing said so")
        #expect(presenter.claims == [false], "a late answer took a claim the deadline held")
        #expect(!signedOn)
        #expect(store.state == .locked(.unanswered), "a beaten answer wrote the screen anyway")
        #expect(seen.get().isEmpty, "a handoff code was spent for a wait that had ended")
    }

    /// The win an answer took at the callback site lives until the store reads it, one hop later.
    /// A Close that lands inside that hop ends the sign-on, and the win goes with it: the answer
    /// still on its way must not go on to spend its handoff code for a screen that was closed.
    @Test("a Close that lands between the answer's claim and the store reading it ends the sign-on")
    func aCloseInsideTheHopEndsTheSignOn() async throws {
        let seen = LockedValue<[Seen]>([])
        let store = makeStore(seen: seen) { operation in
            operation == mintOperation ? .json(liveGrant) : .json("[]")
        }
        let presenter = CallbackSitePresenter()
        defer { presenter.close() }
        let callback = try #require(URL(string: "memosng://auth-callback?code=abc"))

        let signingOn = startSignOn(store, presenter: presenter)
        await presenter.waitUntilOpen()

        presenter.deliver(callback)
        store.forget(.closed)
        guard let signedOn = await signingOn.settled() else { return }

        #expect(presenter.claims == [true], "the answer did not claim where it arrived")
        #expect(!signedOn, "a sign-on the person closed came back signed on")
        #expect(store.state == .locked(.never), "a closed sign-on left something on the screen")
        #expect(seen.get().isEmpty, "a handoff code was spent for a screen that was closed")
    }

    /// An older sign-on's win, taken at its callback site, with its resume still in the air when
    /// the person closes and starts again. The newer sign-on's own answer then loses its claim to
    /// its deadline — and must not be carried through by the older answer's win instead.
    @Test("a newer sign-on never reads the win of an older one that has not resumed")
    func aNewerSignOnNeverReadsAnOlderWin() async throws {
        let seen = LockedValue<[Seen]>([])
        let clock = LockedValue(managementNow)
        let store = makeStore(seen: seen, now: { clock.get() }) { operation in
            switch operation {
            case mintOperation: .json(grantLiveAfterTheWait)
            case listOperation: .json("[\(Stub.pat(id: 1, name: "Kitchen phone"))]")
            default: .status(.internalServerError)
            }
        }
        let older = CallbackSitePresenter()
        let newer = CallbackSitePresenter()
        defer {
            older.close()
            newer.close()
        }
        let oldCallback = try #require(URL(string: "memosng://auth-callback?code=old"))
        let newCallback = try #require(URL(string: "memosng://auth-callback?code=new"))

        let olderSigningOn = startSignOn(store, presenter: older)
        await older.waitUntilOpen()
        // The older answer wins at its callback site; its resume has not happened yet.
        older.answerButHoldTheResume(oldCallback)
        store.forget(.closed)

        let newerSigningOn = startSignOn(store, presenter: newer)
        await newer.waitUntilOpen()
        #expect(store.state == .authenticating, "the newer sign-on was not on screen")
        clock.set(managementNow.addingTimeInterval(ManageTokensStore.browserStepDeadline))
        #expect(store.signOnDeadlinePassed(), "the newer wait ran out and nothing said so")
        newer.deliver(newCallback)
        guard let newerSignedOn = await newerSigningOn.settled() else { return }

        older.releaseTheResume()
        guard let olderSignedOn = await olderSigningOn.settled() else { return }

        #expect(older.claims == [true], "the older answer did not claim where it arrived")
        #expect(newer.claims == [false], "the newer answer took a claim its deadline held")
        #expect(!newerSignedOn, "the newer sign-on was carried through by an older answer's win")
        #expect(!olderSignedOn, "a sign-on the person closed came back signed on")
        #expect(store.state == .locked(.unanswered), "a beaten answer wrote the screen anyway")
        #expect(seen.get().isEmpty, "a handoff code was spent for a sign-on that had ended")
    }
}

/// How one sign-on call ended, written by the call itself when it returns.
@MainActor
private final class SignOnOutcome {
    private var signedOn: Bool?

    func finish(_ signedOn: Bool) { self.signedOn = signedOn }

    /// Bounded: a call that has not ended within the ceiling records an Issue and is given up on,
    /// never awaited — a call that will not return would hang the suite rather than fail it.
    ///
    /// The ceiling is a deadline on the monotonic clock, read once more after it passes, rather
    /// than a count of 1 ms sleeps whose real length is whatever the host's load makes it
    /// (MEMNG-693).
    func settled(
        within patience: Duration = .seconds(10),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool? {
        let deadline = ContinuousClock.now + patience
        while signedOn == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        if let signedOn { return signedOn }
        Issue.record("the sign-on call never returned", sourceLocation: sourceLocation)
        return nil
    }
}

/// A presenter that answers the way the real one does: the claim it was handed is asked at the
/// callback site, synchronously, and only then is the parked call resumed — so when `deliver`
/// returns, the store has not yet read the answer.
@MainActor
private final class CallbackSitePresenter: NativeLoginPresenter {
    private var parked: CheckedContinuation<URL, any Error>?
    private var claim: (@MainActor () -> Bool)?
    private var held: (continuation: CheckedContinuation<URL, any Error>, url: URL)?
    private var closed = false
    /// What each claim asked at the callback site answered, in order.
    private(set) var claims: [Bool] = []

    /// Bounded, like every other wait in this suite.
    func waitUntilOpen() async {
        for _ in 0..<2000 {
            if parked != nil { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func authenticate(
        authorizeURL: URL,
        callbackHost: String,
        callbackPath: String
    ) async throws -> URL {
        try await park(claim: nil)
    }

    func authenticate(
        authorizeURL: URL,
        callbackHost: String,
        callbackPath: String,
        claimingAnswer claim: @escaping @MainActor () -> Bool
    ) async throws -> URL {
        try await park(claim: claim)
    }

    private func park(claim: (@MainActor () -> Bool)?) async throws -> URL {
        guard !closed else { throw NativeLoginError.cancelled }
        self.claim = claim
        return try await withCheckedThrowingContinuation { parked = $0 }
    }

    /// The answer arriving: the claim asked where it arrives, then the parked call resumed.
    func deliver(_ url: URL) {
        answerButHoldTheResume(url)
        releaseTheResume()
    }

    /// The claim asked where the answer arrives, with the resume held back — the hop between the
    /// two stretched for as long as a test needs something to happen inside it.
    func answerButHoldTheResume(_ url: URL) {
        guard let parked else { return }
        self.parked = nil
        if let claim { claims.append(claim()) }
        claim = nil
        held = (parked, url)
    }

    func releaseTheResume() {
        guard let held else { return }
        self.held = nil
        held.continuation.resume(returning: held.url)
    }

    /// Ends whatever is still parked or held and refuses anything that arrives later, so no call
    /// is ever left on a continuation nobody resumes.
    func close() {
        closed = true
        if let parked {
            self.parked = nil
            parked.resume(throwing: NativeLoginError.cancelled)
        }
        if let held {
            self.held = nil
            held.continuation.resume(throwing: NativeLoginError.cancelled)
        }
    }
}

import Foundation
import HTTPTypes
import MemosAPI
import Testing

/// The step-up management credential, at the layer that attaches it.
///
/// The whole point of the scheme being its own is that the two can never be confused, so these
/// tests are as much about what is NOT sent as about what is: a management request carries `Grant`
/// or nothing, and a device token has no path into this middleware at all.
@Suite("GrantAuthMiddleware")
struct GrantAuthMiddlewareTests {
    private func request(_ path: String = "/api/pats") -> HTTPRequest {
        HTTPRequest(method: .get, scheme: "https", authority: "example.invalid", path: path)
    }

    private let baseURL = URL(string: "https://example.invalid")!

    private func send(
        _ middleware: GrantAuthMiddleware,
        operationID: String = "list_pats_api_pats_get"
    ) async throws -> HTTPRequest? {
        var seen: HTTPRequest?
        _ = try await middleware.intercept(
            request(),
            body: nil,
            baseURL: baseURL,
            operationID: operationID,
            next: { forwarded, _, _ in
                seen = forwarded
                return (HTTPResponse(status: .ok), nil)
            }
        )
        return seen
    }

    private let future = Date(timeIntervalSince1970: 4_000_000_000)

    @Test("attaches the grant under its own scheme, never as a bearer")
    func attachesGrantHeader() async throws {
        let grant = ManagementGrant()
        grant.hold("mg_abc", until: future)

        let seen = try await send(
            GrantAuthMiddleware(grant: grant, licence: GrantSendLicence { true })
        )

        #expect(seen?.headerFields[.authorization] == "Grant mg_abc")
    }

    /// The control that makes the assertion above mean something: a middleware that wrote
    /// `Bearer` would satisfy "there is an Authorization header" just as well.
    @Test("nothing this middleware sends is ever a bearer credential")
    func neverSendsABearer() async throws {
        let grant = ManagementGrant()
        grant.hold("mg_abc", until: future)

        let seen = try await send(
            GrantAuthMiddleware(grant: grant, licence: GrantSendLicence { true })
        )

        #expect(seen?.headerFields[.authorization]?.hasPrefix("Bearer") == false)
    }

    @Test("a grant that has been forgotten attaches nothing at all")
    func forgottenGrantAttachesNothing() async throws {
        let grant = ManagementGrant()
        grant.hold("mg_abc", until: future)
        grant.forget()

        let seen = try await send(
            GrantAuthMiddleware(grant: grant, licence: GrantSendLicence { true })
        )

        #expect(seen?.headerFields[.authorization] == nil)
    }

    /// The state the exchange itself runs in: the client is built before there is anything to
    /// present, and that request has to go out anonymously or it could never buy a grant.
    @Test("a grant that was never held attaches nothing")
    func emptyGrantAttachesNothing() async throws {
        let seen = try await send(
            GrantAuthMiddleware(grant: ManagementGrant(), licence: GrantSendLicence { true })
        )

        #expect(seen?.headerFields[.authorization] == nil)
    }

    @Test("the value is read again for every request, so a re-authentication reaches the client")
    func readsTheGrantPerRequest() async throws {
        let grant = ManagementGrant()
        grant.hold("first", until: future)
        let middleware = GrantAuthMiddleware(grant: grant, licence: GrantSendLicence { true })
        var headers: [String?] = []
        for _ in 0..<2 {
            _ = try await middleware.intercept(
                request(),
                body: nil,
                baseURL: baseURL,
                operationID: "list_pats_api_pats_get",
                next: { forwarded, _, _ in
                    headers.append(forwarded.headerFields[.authorization])
                    return (HTTPResponse(status: .ok), nil)
                }
            )
            grant.hold("second", until: future)
        }

        #expect(headers == ["Grant first", "Grant second"])
    }

    /// The instant no check above this layer can cover: work that was current when it started is
    /// sent from another executor, and the identity that bought the grant can be gone by then.
    ///
    /// Nothing is attached and nothing is forwarded — a request that left would be authorised by a
    /// grant nobody holds any more, and its answer would be read by nobody.
    @Test("a refused licence attaches nothing, forwards nothing, and says which refusal it was")
    func aRefusedLicenceSendsNothing() async throws {
        let grant = ManagementGrant()
        grant.hold("mg_abc", until: future)
        let middleware = GrantAuthMiddleware(grant: grant, licence: GrantSendLicence { false })
        var forwarded = false
        var thrown: (any Error)?

        do {
            _ = try await middleware.intercept(
                request(),
                body: nil,
                baseURL: baseURL,
                operationID: "list_pats_api_pats_get",
                next: { _, _, _ in
                    forwarded = true
                    return (HTTPResponse(status: .ok), nil)
                }
            )
        } catch {
            thrown = error
        }

        #expect(!forwarded)
        #expect(thrown is ManagementIdentityWithdrawn)
    }
}

/// The holder itself: what it says it has, and what it stops saying once it is over.
@Suite("ManagementGrant")
struct ManagementGrantTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a held grant reports its value and its deadline")
    func holdsWhatItWasGiven() {
        let grant = ManagementGrant()
        grant.hold("mg_abc", until: now.addingTimeInterval(600))

        #expect(grant.current == "mg_abc")
        #expect(grant.expiry == now.addingTimeInterval(600))
    }

    @Test("forgetting one leaves nothing behind to present")
    func forgetsIt() {
        let grant = ManagementGrant()
        grant.hold("mg_abc", until: now.addingTimeInterval(600))
        grant.forget()

        #expect(grant.current == nil)
        #expect(grant.expiry == nil)
    }

    /// The deadline is the server's, and it is what decides — a screen that kept asking with a
    /// grant whose time is up would collect a 401 for something it could already know.
    @Test("a grant is live until its deadline and not one second after it")
    func liveUntilItsDeadline() {
        let grant = ManagementGrant()
        grant.hold("mg_abc", until: now.addingTimeInterval(600))

        #expect(grant.isLive(at: now))
        #expect(grant.isLive(at: now.addingTimeInterval(599)))
        #expect(!grant.isLive(at: now.addingTimeInterval(600)))
        #expect(!grant.isLive(at: now.addingTimeInterval(601)))
    }

    @Test("a grant that was never held is not live")
    func emptyIsNotLive() {
        #expect(!ManagementGrant().isLive(at: now))
    }
}

/// The management lane's authorize URL: the same round trip the sign-in makes, asking for the
/// other credential.
@Suite("The management login lane")
struct ManageAuthorizeURLTests {
    private let configuration = ServerConfiguration(
        baseURL: URL(string: "https://memos.example.invalid")!
    )
    private let challenge = String(repeating: "a", count: 43)

    private func query(_ url: URL?) -> [String: String] {
        guard let url,
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test("the management round trip names its purpose, on the same route as a sign-in")
    func namesItsPurpose() {
        let url = NativeLogin.authorizeURL(
            configuration: configuration,
            codeChallenge: challenge,
            device: "Fabian's iPhone",
            purpose: .manage
        )

        #expect(url?.path == "/api/auth/login")
        #expect(query(url)["purpose"] == "manage")
        #expect(query(url)["client"] == "ios")
        #expect(query(url)["code_challenge"] == challenge)
        #expect(query(url)["device"] == "Fabian's iPhone")
    }

    /// The sign-in URL is unchanged, and stays unchanged: the server reads an absent `purpose` as
    /// a login, and a client that started naming it would be a new request shape for no reason.
    @Test("a sign-in still names no purpose at all")
    func signInNamesNoPurpose() {
        let url = NativeLogin.authorizeURL(
            configuration: configuration,
            codeChallenge: challenge,
            device: "Fabian's iPhone"
        )

        #expect(query(url)["purpose"] == nil)
        #expect(query(url)["client"] == "ios")
    }

    /// The same validation as the sign-in lane's, because the server applies the same one to both:
    /// a request that could only be a 422 fails on the device, where the screen can say why.
    @Test("a management round trip with an unusable challenge or device is not built")
    func refusesWhatTheServerWould() {
        #expect(
            NativeLogin.authorizeURL(
                configuration: configuration,
                codeChallenge: "too-short",
                device: "Fabian's iPhone",
                purpose: .manage
            ) == nil
        )
        #expect(
            NativeLogin.authorizeURL(
                configuration: configuration,
                codeChallenge: challenge,
                device: "   ",
                purpose: .manage
            ) == nil
        )
    }
}

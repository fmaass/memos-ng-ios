import Foundation
import Testing

@testable import MemosCore

/// Why images were re-fetched from the server several times a minute for URLs that were
/// byte-identical and carried correct `Cache-Control`, `ETag` and `Last-Modified`.
///
/// The answer is not in the headers and not in the URLs: it is that the cache the app installed
/// was never the cache the fetches went through. These two tests are the halves of that, and each
/// one fails if Foundation ever stops behaving the way the diagnosis depends on.
@Suite("The shared session's cache")
struct SharedSessionCacheTests {
    /// Half one: a `default` configuration reads `URLCache.shared` at the moment it is BUILT. It
    /// takes the object that is there; it does not keep a reference to the global.
    @Test("a default configuration snapshots whatever URLCache.shared is when it is created")
    func defaultConfigurationSnapshotsTheSharedCache() {
        let shared = URLCache.shared
        let configuration = URLSessionConfiguration.default
        #expect(configuration.urlCache === shared)
    }

    /// Half two: a `URLSession` COPIES its configuration at init and never reads it again. Proved
    /// on a session of this test's own, so nothing global is touched: mutate the configuration
    /// object after the session exists and the session is unmoved.
    ///
    /// Put the halves together and `URLSession.shared` holds whatever `URLCache.shared` was the
    /// first time anything in the process touched the shared session — so
    /// `URLCache.shared = <a bigger cache>` in a composition root reaches it only if it won a race
    /// it has no way to enter.
    @Test("a session keeps the cache it was created with, whatever its configuration does after")
    func aSessionBindsItsCacheAtInit() {
        let first = MediaCache.makeURLCache()
        let configuration = MediaCache.makeSessionConfiguration(cache: first)
        let session = URLSession(configuration: configuration)

        let second = MediaCache.makeURLCache()
        configuration.urlCache = second

        #expect(configuration.urlCache === second, "the configuration itself did change")
        #expect(session.configuration.urlCache === first, "the session followed it and must not")
        session.finishTasksAndInvalidate()
    }
}

@Suite("MediaSession")
struct MediaSessionTests {
    /// The fix, stated as the property that makes it one: this session's cache is attached
    /// explicitly, so it is true whatever else in the process ran first.
    @Test("the media session holds the cache it was built with, and the protocol's cache policy")
    func mediaSessionHoldsItsOwnCache() {
        let cache = MediaCache.makeURLCache()
        let media = MediaSession(cache: cache)

        #expect(media.session.configuration.urlCache === cache)
        #expect(media.session.configuration.requestCachePolicy == .useProtocolCachePolicy)
        #expect(media.cache === cache)
        media.session.finishTasksAndInvalidate()
    }

    @Test("the shared media session is wired to its own cache too")
    func theSharedOneIsWiredTheSameWay() {
        #expect(MediaSession.shared.session.configuration.urlCache === MediaSession.shared.cache)
    }

    /// The probe the app logs at launch compares IDENTITY. A cache with the same capacities is a
    /// different cache, and reporting it as the same one would make the log say the opposite of
    /// what happened.
    @Test("the launch probe answers on identity, not on resemblance")
    func theProbeComparesIdentity() throws {
        let sharedSessionCache = try #require(URLSession.shared.configuration.urlCache)
        #expect(MediaSession.sharedSessionHolds(sharedSessionCache), "positive control")
        #expect(!MediaSession.sharedSessionHolds(MediaCache.makeURLCache()))
    }

    /// The composition root, observed rather than restated: this bundle is hosted BY the app, so
    /// `MemosNGApp.init()` has already run by the time this executes. It asserts the one thing a
    /// package test can see of it — that the app installs the media session's own cache as the
    /// shared one rather than building a second `URLCache` over the same `diskPath`, which is two
    /// caches over one directory and a corruption waiting to happen.
    @Test("the app installs the media session's cache as the shared cache, not a second one")
    func theAppInstallsTheMediaCacheAsTheSharedCache() {
        #expect(
            URLCache.shared === MediaSession.shared.cache,
            "the app host did not install the media cache — a second URLCache is over memos-media"
        )
    }
}

/// The key is the reason a decoded photo survives the server re-signing its URLs. `bucketed_exp`
/// on the server rounds the mint time down to a one-hour bucket, so `exp` — and therefore `sig` —
/// change on every boundary while the bytes behind them do not.
@Suite("MediaImageKey")
struct MediaImageKeyTests {
    @Test("two different signed URLs for the same attachment and tier are one key")
    func signatureRotationDoesNotChangeTheKey() {
        let early = MediaImageKey(uid: "att-1", tier: "thumb")
        let late = MediaImageKey(uid: "att-1", tier: "thumb")
        #expect(early == late)
        #expect(early.storageKey == late.storageKey)
        // Nothing signature-shaped may have got into it.
        #expect(!early.storageKey.contains("exp"))
        #expect(!early.storageKey.contains("sig"))
    }

    @Test("the tier is part of the key — a thumb is not a preview")
    func tiersAreSeparate() {
        #expect(
            MediaImageKey(uid: "att-1", tier: "thumb").storageKey
                != MediaImageKey(uid: "att-1", tier: "mobile").storageKey
        )
    }

    @Test("no two different attachments can produce the same key")
    func theKeyIsUnambiguous() {
        // The adversarial pair: without the length prefix both of these read as the same string,
        // and one attachment's photo would be served for another's.
        let confusable = MediaImageKey(uid: "a/thumb", tier: "x")
        let plain = MediaImageKey(uid: "a", tier: "thumb/x")
        #expect(confusable.storageKey != plain.storageKey)
        #expect(
            MediaImageKey(uid: "a", tier: "b").storageKey
                != MediaImageKey(uid: "ab", tier: "").storageKey
        )
    }
}

/// The wiring the media layer's whole account-safety story rests on: the clock has to actually be
/// rotated, at both of the two moments the device changes who it is. Asserted through the real
/// `SessionStore` rather than by calling `rotate()` directly, because what could break here is
/// somebody adding a third path in or out of a session and not rotating it.
@MainActor
@Suite("SessionStore rotates the media identity")
struct SessionIdentityRotationTests {
    @Test("signing in rotates it, and signing out rotates it again")
    func bothLifecycleSitesRotate() async {
        let identity = MediaIdentity()
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token) { _, _, operation in
                    operation == "whoami_api_auth_user_get"
                        ? Stub.json(Stub.user) : Stub.empty(.noContent)
                }
            },
            identity: identity
        )
        #expect(identity.generation == 0)

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        #expect(session.state.user != nil, "precondition: the sign-in has to have happened")
        let afterSignIn = identity.generation
        #expect(afterSignIn > 0, "signing in did not rotate the media identity")

        await session.signOut()
        #expect(session.state == .signedOut, "precondition: the sign-out has to have happened")
        #expect(
            identity.generation > afterSignIn,
            "signing out did not rotate the media identity — the next account inherits the cache"
        )
    }
}

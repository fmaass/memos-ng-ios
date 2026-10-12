import Foundation
import HTTPTypes
import MemosAPI
import OpenAPIRuntime
import Testing

@testable import MemosCore

private let patchSettings = "update_settings_api_settings_patch"
private let renameToken = "rename_native_token_api_auth_native_token_patch"

/// Holds every PATCH it is shown until it is opened, counting each one as it ARRIVES — so the
/// count is what reached the wire while the first answer was still outstanding.
private final class HeldPatch: @unchecked Sendable {
    private let lock = NSLock()
    private var arrived = 0
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var count: Int { lock.withLock { arrived } }

    func hold() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let go = lock.withLock { () -> Bool in
                arrived += 1
                if opened { return true }
                waiting.append(continuation)
                return false
            }
            if go { continuation.resume() }
        }
    }

    func open() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { waiting = [] }
            return waiting
        }
        for continuation in resumed { continuation.resume() }
    }

    /// Lets the main actor run until `count` PATCHes have arrived, or gives up.
    func arrivals(_ expected: Int) async -> Bool {
        for _ in 0..<2000 where count < expected { await Task.yield() }
        return count >= expected
    }
}

/// Two overlapping writes of the same setting are ONE request on the wire — the second joins the
/// first when it asks for the same thing and is refused when it asks for something else
/// (CLAUDE.md, «A store serializes its own mutations»). A disabled control is not the guard: the
/// store is driven here directly, the way two quick taps or a tap and a retry would reach it.
@MainActor
@Suite("Overlapping account writes")
struct SessionWriteOverlapTests {
    private func signedIn(_ held: HeldPatch) async -> SessionStore {
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token) { _, _, operation in
                    switch operation {
                    case patchSettings:
                        await held.hold()
                        return Stub.json(
                            #"{"default_visibility":"PRIVATE","theme":"dark","avatar":null}"#)
                    case renameToken:
                        await held.hold()
                        return Stub.json(Stub.nativeToken(name: "Kitchen phone"))
                    default:
                        return Stub.json(Stub.user)
                    }
                }
            }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        return session
    }

    @Test("a second save of the same default joins the first: one PATCH, one answer for both")
    func sameVisibilityJoins() async {
        let held = HeldPatch()
        let session = await signedIn(held)

        async let first = session.setDefaultVisibility(.private)
        #expect(await held.arrivals(1), "the first PATCH never reached the wire")
        async let second = session.setDefaultVisibility(.private)
        _ = await held.arrivals(2)
        held.open()

        let answers = await (first, second)
        #expect(answers.0, "the first save was not adopted")
        #expect(answers.1, "the joined save did not answer with the first one's result")
        #expect(held.count == 1, "\(held.count) PATCHes for one default")
    }

    @Test("a different default while one is on the wire is refused, and sends nothing")
    func differentVisibilityIsRefused() async {
        let held = HeldPatch()
        let session = await signedIn(held)

        async let first = session.setDefaultVisibility(.private)
        #expect(await held.arrivals(1), "the first PATCH never reached the wire")
        async let second = session.setDefaultVisibility(.public)
        _ = await held.arrivals(2)
        held.open()

        let answers = await (first, second)
        #expect(answers.0, "the first write was not adopted")
        #expect(!answers.1, "a differing write was accepted while one was on the wire")
        #expect(held.count == 1, "\(held.count) PATCHes on the wire")
        #expect(session.defaultVisibility == .private)
    }

    @Test("a second rename to the same name joins the first: one PATCH, one answer for both")
    func sameNameJoins() async {
        let held = HeldPatch()
        let session = await signedIn(held)

        async let first = session.renameDeviceToken(to: "Kitchen phone")
        #expect(await held.arrivals(1), "the first rename never reached the wire")
        async let second = session.renameDeviceToken(to: "Kitchen phone")
        _ = await held.arrivals(2)
        held.open()

        let answers = await (first, second)
        #expect(answers.0, "the first save was not adopted")
        #expect(answers.1, "the joined save did not answer with the first one's result")
        #expect(held.count == 1, "\(held.count) renames for one name")
    }

    @Test("a different name while a rename is on the wire is refused, and sends nothing")
    func differentNameIsRefused() async {
        let held = HeldPatch()
        let session = await signedIn(held)

        async let first = session.renameDeviceToken(to: "Kitchen phone")
        #expect(await held.arrivals(1), "the first rename never reached the wire")
        async let second = session.renameDeviceToken(to: "Hall phone")
        _ = await held.arrivals(2)
        held.open()

        let answers = await (first, second)
        #expect(answers.0, "the first write was not adopted")
        #expect(!answers.1, "a differing write was accepted while one was on the wire")
        #expect(held.count == 1, "\(held.count) renames on the wire")
        #expect(session.deviceToken?.name == "Kitchen phone")
    }
}

/// The sender is handed the generation its caller asked in and checks it before it reads the
/// client (CLAUDE.md, «Every credential- or identity-scoped read is epoch-fenced»). Driven here
/// directly, with a generation the store has already left: a second sign-in has installed a
/// working client, so a sender that ignored the generation it was given would send on it.
@MainActor
@Suite("An account write never crosses into the next session")
struct SessionWriteFenceTests {
    private func signedIn(counting patches: LockedValue<Int>) async -> SessionStore {
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token) { _, _, operation in
                    switch operation {
                    case patchSettings:
                        patches.set(patches.get() + 1)
                        return Stub.json(
                            #"{"default_visibility":"PRIVATE","theme":"dark","avatar":null}"#)
                    case renameToken:
                        patches.set(patches.get() + 1)
                        return Stub.json(Stub.nativeToken(name: "Hall phone"))
                    default:
                        return Stub.json(Stub.user)
                    }
                }
            }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        return session
    }

    /// The generation of a session that has been replaced by a second sign-in.
    private func leftBehind(_ session: SessionStore) async -> Int {
        let left = session.sessionGeneration
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_next")
        #expect(session.sessionGeneration != left, "the second sign-in did not replace the session")
        #expect(session.state.user != nil, "the second sign-in left no session to send on")
        return left
    }

    @Test("a default asked for in a session that has ended is not sent on the next one")
    func visibilityFromAnEndedSessionIsNotSent() async {
        let patches = LockedValue<Int>(0)
        let session = await signedIn(counting: patches)
        let left = await leftBehind(session)

        let stale = await session.sendDefaultVisibility(.private, askedIn: left)

        #expect(!stale, "a write from an ended session answered as sent")
        #expect(patches.get() == 0, "\(patches.get()) PATCH(es) went out on the next session")
        // The control: the same sender in the CURRENT session does reach the wire.
        #expect(await session.sendDefaultVisibility(.private, askedIn: session.sessionGeneration))
        #expect(patches.get() == 1, "the current session's write never reached the wire")
    }

    @Test("a rename asked for in a session that has ended is not sent on the next one")
    func renameFromAnEndedSessionIsNotSent() async {
        let patches = LockedValue<Int>(0)
        let session = await signedIn(counting: patches)
        let left = await leftBehind(session)

        let stale = await session.sendDeviceTokenRename("Hall phone", askedIn: left)

        #expect(!stale, "a rename from an ended session answered as sent")
        #expect(patches.get() == 0, "\(patches.get()) rename(s) went out on the next session")
        let current = session.sessionGeneration
        #expect(await session.sendDeviceTokenRename("Hall phone", askedIn: current))
        #expect(patches.get() == 1, "the current session's rename never reached the wire")
    }
}

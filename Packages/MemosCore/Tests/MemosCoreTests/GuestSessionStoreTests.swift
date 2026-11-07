import Foundation
import HTTPTypes
@testable import MemosCore
import MemosOutbox
import OpenAPIRuntime
import Testing

/// Guest mode through the door's real wire shapes (MEMNG-1011): the store under test is real, the
/// credential store and the licence file are real, and only the network is scripted — a
/// `StubTransport` answering the three guest routes by operation id.
///
/// The member half is real too where it matters: a `SessionStore` signed in over the SAME vault, so
/// "never touches the member" is read back from the member's own Keychain items and state.
@MainActor
@Suite("Guest session: redeem, receipts and leave, apart from the member")
struct GuestSessionStoreTests {
    nonisolated static let redeemed = """
        {"device_token": "guest-token-1", "device_id": "device-1",
         "pass": {"label": "Lisbon", "scope": "trip", "expires_at": "2026-11-05T12:00:00Z"},
         "limits": {"max_patch_bytes": 67108864}}
        """
    nonisolated static let receipts = """
        [{"batch_id": "b-1", "status": "received", "file_count": 1, "byte_total": 3,
          "caption": null, "completed_at": "2026-10-30T10:00:00Z",
          "files": [{"filename": "a.jpg", "sha256": "abc", "size": 3}]}]
        """
    nonisolated static let expiry = Date(timeIntervalSince1970: 1_793_880_000)

    /// Everything a test needs, built over one vault and one temporary licence directory.
    @MainActor
    struct Rig {
        let vault = InMemoryCredentials()
        let licenceRoot = FileManager.default.temporaryDirectory
            .appending(path: "guest-session-\(UUID().uuidString)")
        let calls = CallLog()
        /// A scratch suite of its own, so no test reads a name another test remembered.
        let names = UserDefaults(suiteName: "guest-names-\(UUID().uuidString)")!
        let credentials: GuestCredentialStore
        let store: GuestSessionStore

        var licence: OutboxAccountStore { OutboxAccountStore(root: licenceRoot) }

        init(_ answer: @escaping @Sendable (String) async -> (HTTPResponse, HTTPBody?)) {
            credentials = GuestCredentialStore(credentials: vault)
            let calls = calls
            let transport = StubTransport { request, body, operationID in
                await calls.record(operationID, request, body)
                return await answer(operationID)
            }
            store = GuestSessionStore(
                credentials: credentials, licence: OutboxAccountStore(root: licenceRoot),
                transport: transport, names: names
            )
        }

        func guestItems() -> [String: String] {
            vault.snapshot().filter { GuestCredentialStore.accounts.contains($0.key) }
        }

        func memberItems() -> [String: String] {
            vault.snapshot().filter { !GuestCredentialStore.accounts.contains($0.key) }
        }
    }

    actor CallLog {
        private(set) var operations: [String] = []
        private(set) var requests: [HTTPRequest] = []
        private(set) var bodies: [Data] = []

        func record(_ operation: String, _ request: HTTPRequest, _ body: HTTPBody?) async {
            operations.append(operation)
            requests.append(request)
            if let body, let data = try? await Data(collecting: body, upTo: 1 << 20) {
                bodies.append(data)
            }
        }

        func count(_ operation: String) -> Int { operations.filter { $0 == operation }.count }
    }

    /// How often a main-actor callback ran.
    @MainActor
    final class Counter {
        var value = 0
    }

    /// Holds an answer until the test lets it go.
    actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            open = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private func signedInMember(over vault: InMemoryCredentials) async -> SessionStore {
        let session = SessionStore(
            credentials: vault,
            makeClient: { _, token in
                Stub.client(token: token) { _, _, _ in Stub.json(Stub.user) }
            },
            sleeper: { _ in throw CancellationError() }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        return session
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<5000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("the condition never became true")
    }

    nonisolated private static func status(_ code: Int) -> (HTTPResponse, HTTPBody?) {
        (HTTPResponse(status: .init(code: code)), nil)
    }

    // Mutation that turns it red: delete the `licence?.publish(...)` call in `activate`.
    @Test("a redeem stores the pass in the guest accounts and publishes a GUEST licence only")
    func redeemWritesTheGuestAccountsAndLicence() async throws {
        let rig = Rig { operation in
            operation == "guestRedeem"
                ? Stub.json(Self.redeemed, status: .created) : Self.status(500)
        }
        let member = await signedInMember(over: rig.vault)
        let memberBefore = rig.memberItems()
        #expect(!memberBefore.isEmpty)

        let outcome = await rig.store.redeem(secret: "pass-secret")

        #expect(outcome == .active(label: "Lisbon", expiresAt: Self.expiry))
        #expect(rig.store.state == outcome)
        #expect(rig.guestItems()[GuestCredentialStore.tokenAccount] == "guest-token-1")
        #expect(rig.guestItems()[GuestCredentialStore.deviceAccount] == "device-1")
        #expect(rig.memberItems() == memberBefore)
        #expect(member.state.user != nil)
        let licence = try #require(rig.licence.currentLicence())
        #expect(licence.binding.kind == .guest)
        #expect(licence.binding.ownerSubject == "device-1")
        #expect(licence.binding.serverBaseURL == GuestDoor.baseURL)

        let request = try #require(await rig.calls.requests.first)
        #expect(request.method == .post)
        #expect(request.path == "/api/pass/redeem")
        #expect(request.headerFields[.authorization] == nil)
        let body = try #require(await rig.calls.bodies.first)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["secret"] as? String == "pass-secret")
        #expect(sent["platform"] as? String == "app")
        #expect(sent["display_name"] as? String == GuestName.lastResort)
    }

    // Mutation that turns it red: `case 410: .passEnded` → `case 410: .unknownPass`.
    @Test(
        "a refused redeem names why and leaves no pass behind",
        arguments: [
            (404, GuestSessionStore.RedeemRefusal.unknownPass),
            (410, .passEnded),
            (429, .tooManyAttempts),
            (500, .unavailable),
        ])
    func refusedRedeems(code: Int, refusal: GuestSessionStore.RedeemRefusal) async throws {
        let rig = Rig { _ in Self.status(code) }

        let outcome = await rig.store.redeem(secret: "pass-secret")

        #expect(outcome == .refused(refusal))
        #expect(rig.store.state == .refused(refusal))
        #expect(rig.guestItems().isEmpty)
        #expect(rig.licence.currentLicence() == nil)
    }

    @Test("a link that is not a trip pass is refused without a request")
    func notAPassLink() async throws {
        let rig = Rig { _ in Stub.json(Self.redeemed, status: .created) }

        let outcome = await rig.store.redeem(
            passLink: URL(string: "https://memos.example.invalid/p/secret")!)

        #expect(outcome == .refused(.notAPassLink))
        #expect(await rig.calls.operations.isEmpty)
    }

    // Mutation that turns it red: delete `if let redeeming { return await redeeming.value }` in
    // `redeem(secret:)`.
    @Test("two overlapping redeems are ONE request, and both callers get its outcome")
    func overlappingRedeemsJoin() async throws {
        let gate = Gate()
        let rig = Rig { _ in
            await gate.wait()
            return Stub.json(Self.redeemed, status: .created)
        }
        let store = rig.store

        let first = Task { await store.redeem(secret: "pass-secret") }
        try await waitUntil { await rig.calls.count("guestRedeem") == 1 }
        let second = Task { await store.redeem(secret: "pass-secret") }
        await Task.yield()
        await gate.release()
        let outcomes = [await first.value, await second.value]

        let active = GuestSessionStore.State.active(label: "Lisbon", expiresAt: Self.expiry)
        #expect(outcomes == [active, active])
        #expect(await rig.calls.count("guestRedeem") == 1)
    }

    // MARK: - the name a guest joins under

    private func sentName(_ rig: Rig, at index: Int = 0) async throws -> String? {
        let bodies = await rig.calls.bodies
        try #require(bodies.count > index)
        let sent = try #require(
            try JSONSerialization.jsonObject(with: bodies[index]) as? [String: Any])
        return sent["display_name"] as? String
    }

    private static func redeemedRig() -> Rig {
        Rig { operation in
            operation == "guestRedeem"
                ? Stub.json(Self.redeemed, status: .created) : Self.status(500)
        }
    }

    // Mutation that turns it red: send `presentedName` without remembering `typedName` first.
    @Test("a redeem is sent under the name typed, trimmed, remembered, and shown as joined")
    func typedNameIsSentAndRemembered() async throws {
        let rig = Self.redeemedRig()
        // Quotes and a backslash: the name is a JSON string on the wire, not a template.
        let name = #"Ana "Bean" O\Neil"#

        await rig.store.redeem(secret: "pass-secret", typedName: "  \(name) \n")

        #expect(try await sentName(rig) == name)
        #expect(rig.names.string(forKey: GuestSessionStore.rememberedNameKey) == name)
        #expect(rig.store.joinedName == name)
        #expect(rig.store.presentedName == name)
    }

    // Mutation that turns it red: let `GuestName.cleaned` return a blank name instead of `nil`,
    // or fall back to a device or model name ("iPhone") before `lastResort`.
    @Test(
        "nothing typed, or only blanks, is sent as the door's own word, never a model name",
        arguments: [nil, "", "   ", "\n\t\u{00A0}"] as [String?])
    func blankNameFallsBackToGuest(_ typed: String?) async throws {
        let rig = Self.redeemedRig()

        await rig.store.redeem(secret: "pass-secret", typedName: typed)

        #expect(try await sentName(rig) == "Guest")
        #expect(rig.names.string(forKey: GuestSessionStore.rememberedNameKey) == nil)
        #expect(rig.store.joinedName == "Guest")
    }

    // Mutation that turns it red: resolve a blank typed name against the remembered one.
    @Test(
        "a Join field cleared to blank joins as Guest, and the remembered name is kept",
        arguments: ["", "  \n"])
    func clearedFieldJoinsAsGuest(_ typed: String) async throws {
        let rig = Self.redeemedRig()
        await rig.store.redeem(secret: "pass-secret", typedName: "Ana")
        await rig.store.leave()

        await rig.store.redeem(secret: "pass-secret", typedName: typed)

        #expect(try await sentName(rig, at: 1) == GuestName.lastResort)
        #expect(rig.store.joinedName == GuestName.lastResort)
        #expect(rig.names.string(forKey: GuestSessionStore.rememberedNameKey) == "Ana")
        #expect(rig.store.joinFieldName == "Ana")
    }

    // Mutation that turns it red: start the field with `presentedName`, which is never empty.
    @Test("the Join field starts empty on a fresh device, then with the name typed last time")
    func joinFieldStartsEmptyThenRemembers() async throws {
        let rig = Self.redeemedRig()
        #expect(rig.store.joinFieldName == "")

        await rig.store.redeem(secret: "pass-secret", typedName: "  Ana ")
        await rig.store.leave()

        #expect(rig.store.joinFieldName == "Ana")
    }

    // Capped, not refused: the door would answer 422 to 65, and the person typed a name.
    @Test("a name over the door's 64 is capped to 64, never sent whole")
    func overlongNameIsCapped() async throws {
        let rig = Self.redeemedRig()
        let typed = String(repeating: "x", count: 70)

        await rig.store.redeem(secret: "pass-secret", typedName: typed)

        #expect(try await sentName(rig) == String(repeating: "x", count: 64))
    }

    // Mutation that turns it red: remember `typedName` before the `if let redeeming` join check.
    @Test("two overlapping redeems under different names are ONE request, under the first name")
    func overlappingRedeemsKeepTheFirstName() async throws {
        let gate = Gate()
        let rig = Rig { _ in
            await gate.wait()
            return Stub.json(Self.redeemed, status: .created)
        }
        let store = rig.store

        let first = Task { await store.redeem(secret: "pass-secret", typedName: "Ana") }
        try await waitUntil { await rig.calls.count("guestRedeem") == 1 }
        let second = Task { await store.redeem(secret: "pass-secret", typedName: "Ben") }
        await Task.yield()
        await gate.release()
        _ = (await first.value, await second.value)

        #expect(await rig.calls.count("guestRedeem") == 1)
        #expect(try await sentName(rig) == "Ana")
        #expect(store.joinedName == "Ana")
        #expect(rig.names.string(forKey: GuestSessionStore.rememberedNameKey) == "Ana")
    }

    // Mutation that turns it red: write the joined name as soon as the door answers, before the
    // switch and the generation guard in `performRedeem`.
    @Test("a refused redeem remembers the name typed but joins under nothing")
    func refusedRedeemJoinsUnderNothing() async throws {
        let rig = Rig { _ in Self.status(404) }

        await rig.store.redeem(secret: "pass-secret", typedName: "Ana")

        #expect(rig.store.state == .refused(.unknownPass))
        #expect(rig.store.joinedName == nil)
        #expect(rig.names.string(forKey: GuestSessionStore.joinedNameKey) == nil)
        #expect(rig.names.string(forKey: GuestSessionStore.rememberedNameKey) == "Ana")
    }

    // Mutation that turns it red: the same early write as above.
    @Test("a redeem answered after a leave joins under no name")
    func lateRedeemAfterLeaveKeepsNoName() async throws {
        let gate = Gate()
        let rig = Rig { _ in
            await gate.wait()
            return Stub.json(Self.redeemed, status: .created)
        }
        let store = rig.store

        let redeem = Task { await store.redeem(secret: "pass-secret", typedName: "Ana") }
        try await waitUntil { await rig.calls.count("guestRedeem") == 1 }
        await store.leave()
        await gate.release()
        _ = await redeem.value

        #expect(store.joinedName == nil)
        #expect(rig.names.string(forKey: GuestSessionStore.joinedNameKey) == nil)
    }

    @Test("leaving forgets the name the pass joined under, and keeps the name typed")
    func leaveForgetsTheJoinedName() async throws {
        let rig = Self.redeemedRig()
        await rig.store.redeem(secret: "pass-secret", typedName: "Ana")

        await rig.store.leave()

        #expect(rig.store.joinedName == nil)
        #expect(rig.names.string(forKey: GuestSessionStore.joinedNameKey) == nil)
        #expect(rig.store.presentedName == "Ana")
    }

    @Test("the names live in the suite the store was given, not the app's own defaults")
    func namesStayInTheirSuite() async throws {
        let rig = Self.redeemedRig()

        await rig.store.redeem(secret: "pass-secret", typedName: "Ana")

        #expect(UserDefaults.standard.string(forKey: GuestSessionStore.rememberedNameKey) == nil)
        #expect(UserDefaults.standard.string(forKey: GuestSessionStore.joinedNameKey) == nil)
        #expect(rig.names.string(forKey: GuestSessionStore.rememberedNameKey) == "Ana")
    }

    // Mutation that turns it red: drop the joined-name read in `restore`.
    @Test("after a relaunch the typed name is offered and sent, and the pass shows its own name")
    func namesSurviveARelaunch() async throws {
        let rig = Self.redeemedRig()
        await rig.store.redeem(secret: "pass-secret", typedName: "Ana")
        let calls = CallLog()
        let relaunched = GuestSessionStore(
            credentials: GuestCredentialStore(credentials: rig.vault),
            licence: rig.licence,
            transport: StubTransport { request, body, operationID in
                await calls.record(operationID, request, body)
                return operationID == "guestRedeem"
                    ? Stub.json(Self.redeemed, status: .created) : Self.status(500)
            },
            names: rig.names
        )

        await relaunched.restore()
        #expect(relaunched.state.isActive)
        #expect(relaunched.joinedName == "Ana")
        #expect(relaunched.presentedName == "Ana")

        await relaunched.leave()
        await relaunched.redeem(secret: "pass-secret")
        let body = try #require(await calls.bodies.last)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["display_name"] as? String == "Ana")
    }

    // Mutation that turns it red: delete the generation guard after `door.redeem` in
    // `performRedeem`.
    @Test("a redeem answered after a leave brings nothing back: no pass, no licence, no state")
    func lateRedeemAfterLeave() async throws {
        let gate = Gate()
        let rig = Rig { _ in
            await gate.wait()
            return Stub.json(Self.redeemed, status: .created)
        }
        let store = rig.store
        let activations = Counter()
        store.onActivated = { activations.value += 1 }

        let redeem = Task { await store.redeem(secret: "pass-secret") }
        try await waitUntil { await rig.calls.count("guestRedeem") == 1 }
        await store.leave()
        await gate.release()
        let outcome = await redeem.value

        #expect(!outcome.isActive)
        #expect(store.state == .none)
        #expect(rig.credentials.current == nil)
        #expect(rig.guestItems().isEmpty)
        #expect(rig.licence.currentLicence() == nil)
        #expect(activations.value == 0)
    }

    // Mutation that turns it red: let `settle` write the state without the generation guard.
    @Test(
        "a redeem refused or failed after a leave leaves the state the leave set",
        arguments: [410, 500, 0])
    func lateRefusalAfterLeave(code: Int) async throws {
        let gate = Gate()
        let rig = Rig { _ in
            await gate.wait()
            // 0 stands for an answer this app cannot read: the `.failed` lane.
            return code == 0
                ? (HTTPResponse(status: .created), HTTPBody("not json"))
                : Self.status(code)
        }
        let store = rig.store

        let redeem = Task { await store.redeem(secret: "pass-secret") }
        try await waitUntil { await rig.calls.count("guestRedeem") == 1 }
        await store.leave()
        await gate.release()
        _ = await redeem.value

        #expect(store.state == .none)
        #expect(rig.credentials.current == nil)
        #expect(rig.licence.currentLicence() == nil)
    }

    // Mutation that turns it red: delete the `guard credentials.epoch.isCurrent(grant.epoch)` line
    // in `refreshReceipts`.
    @Test("a receipts answer that outlived a leave repopulates nothing")
    func staleReceiptsAfterLeave() async throws {
        let gate = Gate()
        let rig = Rig { operation in
            switch operation {
            case "guestRedeem": return Stub.json(Self.redeemed, status: .created)
            default:
                await gate.wait()
                return Stub.json(Self.receipts)
            }
        }
        let store = rig.store
        await store.redeem(secret: "pass-secret")

        let read = Task { await store.refreshReceipts() }
        try await waitUntil { await rig.calls.count("guestBatches") == 1 }
        await store.leave()
        await gate.release()
        await read.value

        #expect(store.receipts.isEmpty)
        #expect(store.state == .none)
        #expect(rig.guestItems().isEmpty)
        #expect(rig.licence.currentLicence() == nil)
    }

    @Test("receipts are read with the guest token, at the door")
    func receiptsAreRead() async throws {
        let rig = Rig { operation in
            operation == "guestRedeem"
                ? Stub.json(Self.redeemed, status: .created) : Stub.json(Self.receipts)
        }
        await rig.store.redeem(secret: "pass-secret")

        await rig.store.refreshReceipts()

        #expect(rig.store.receipts.map(\.batchID) == ["b-1"])
        let request = try #require(await rig.calls.requests.last)
        #expect(request.path == "/api/guest/batches")
        #expect(request.headerFields[.authorization] == "Bearer guest-token-1")
    }

    // Mutation that turns it red: `kind: .guest` → `kind: .member` in
    // `refused(_:issuedUnder:what:)`.
    @Test("the door ending the pass on a receipts read ends guest mode, nothing of the member's")
    func passEndedOnReceiptsEndsGuestModeOnly() async throws {
        let rig = Rig { operation in
            operation == "guestRedeem"
                ? Stub.json(Self.redeemed, status: .created) : Self.status(410)
        }
        let member = await signedInMember(over: rig.vault)
        let memberEpoch = member.epoch.current
        await rig.store.redeem(secret: "pass-secret")
        let memberBefore = rig.memberItems()

        await rig.store.refreshReceipts()

        #expect(rig.store.state == .ended)
        #expect(rig.credentials.current == nil)
        #expect(rig.guestItems().isEmpty)
        #expect(rig.licence.currentLicence() == nil)
        #expect(rig.memberItems() == memberBefore)
        #expect(member.state.user != nil)
        #expect(member.epoch.current == memberEpoch)
    }

    // Mutation that turns it red: delete `withdrawLicence()` in `leave`.
    @Test("leaving withdraws the guest licence, so the share sheet stops offering the trip")
    func leaveWithdrawsTheLicence() async throws {
        let rig = Rig { _ in Stub.json(Self.redeemed, status: .created) }
        await rig.store.redeem(secret: "pass-secret")
        #expect(rig.licence.currentLicence() != nil)

        await rig.store.leave()

        #expect(rig.licence.currentLicence() == nil)
        #expect(rig.guestItems().isEmpty)
        #expect(rig.store.state == .none)
    }

    @Test("a restored pass is shown, then confirmed with the door")
    func restoreConfirms() async throws {
        let rig = Rig { operation in
            operation == "guestRedeem"
                ? Stub.json(Self.redeemed, status: .created) : Self.status(410)
        }
        await rig.store.redeem(secret: "pass-secret")
        let relaunched = GuestSessionStore(
            credentials: GuestCredentialStore(credentials: rig.vault),
            licence: rig.licence,
            transport: StubTransport { _, _, operationID in
                operationID == "guestMe" ? Self.status(410) : Self.status(500)
            },
            names: rig.names
        )

        await relaunched.restore()

        #expect(relaunched.state == .ended)
        #expect(rig.guestItems().isEmpty)
        #expect(rig.licence.currentLicence() == nil)
    }

    // MARK: - the guest queue's held captures

    nonisolated private static func job(
        device: String, kind: CredentialKind = .guest, state: JobState = .held,
        reason: HoldReason? = .signInRequired, id: UUID = UUID()
    ) -> UploadJob {
        UploadJob(
            id: id, content: "", capturedAt: .distantPast, files: [],
            binding: AccountBinding(
                serverBaseURL: GuestDoor.baseURL, ownerSubject: device, kind: kind),
            state: state, holdReason: reason
        )
    }

    // Mutation that turns it red: drop `&& $0.binding.ownerSubject == device` (the earlier pass's
    // hold is counted), or drop the `credentialKind == .guest` clause (the member's is).
    @Test("only a guest capture of THIS pass, held for credentials, is a question about the pass")
    func heldForCredentialsClassifies() {
        let mine = Self.job(device: "device-1")
        let jobs = [
            mine,
            Self.job(device: "device-0"),
            Self.job(device: "device-1", kind: .member),
            Self.job(device: "device-1", reason: .serverRefused),
            Self.job(device: "device-1", state: .waiting, reason: nil),
        ]

        #expect(GuestHeldJobs.heldForCredentials(jobs, device: "device-1") == [mine.id])
        #expect(GuestHeldJobs.heldForCredentials(jobs, device: nil).isEmpty)
        #expect(GuestHeldJobs.heldForCredentials([], device: "device-1").isEmpty)
    }

    // Mutation that turns it red: delete `await confirm()` in `guestQueueChanged`.
    @Test("a capture held for credentials asks the door again, and its 410 ends guest mode only")
    func heldGuestCaptureConfirmsThePass() async throws {
        let rig = Rig { operation in
            operation == "guestRedeem"
                ? Stub.json(Self.redeemed, status: .created) : Self.status(410)
        }
        let member = await signedInMember(over: rig.vault)
        let memberEpoch = member.epoch.current
        await rig.store.redeem(secret: "pass-secret")
        let memberBefore = rig.memberItems()

        await rig.store.guestQueueChanged([Self.job(device: "device-1")])

        #expect(await rig.calls.count("guestMe") == 1)
        #expect(rig.store.state == .ended)
        #expect(rig.credentials.current == nil)
        #expect(rig.guestItems().isEmpty)
        #expect(rig.licence.currentLicence() == nil)
        #expect(rig.memberItems() == memberBefore)
        #expect(member.state.user != nil)
        #expect(member.epoch.current == memberEpoch)
    }

    // Mutation that turns it red: move `noticedHolds = held` after `await confirm()` — the claim
    // then lands after the hop, and the overlapping change asks too.
    @Test("two overlapping queue changes about one hold are ONE question to the door")
    func overlappingQueueChangesAskOnce() async throws {
        let gate = Gate()
        let rig = Rig { operation in
            if operation == "guestRedeem" { return Stub.json(Self.redeemed, status: .created) }
            await gate.wait()
            return Self.status(500)
        }
        let store = rig.store
        await store.redeem(secret: "pass-secret")
        let held = [Self.job(device: "device-1")]

        let first = Task { await store.guestQueueChanged(held) }
        try await waitUntil { await rig.calls.count("guestMe") == 1 }
        let second = Task { await store.guestQueueChanged(held) }
        await Task.yield()
        await gate.release()
        await first.value
        await second.value

        #expect(await rig.calls.count("guestMe") == 1)
        #expect(rig.store.state.isActive)
    }

    // Mutation that turns it red: `noticedHolds = held` → `noticedHolds.formUnion(held)`.
    @Test("a capture retried and held again asks again; one still held does not")
    func aHoldThatEndedAsksAgain() async throws {
        let rig = Rig { operation in
            operation == "guestRedeem"
                ? Stub.json(Self.redeemed, status: .created) : Self.status(500)
        }
        await rig.store.redeem(secret: "pass-secret")
        let id = UUID()

        await rig.store.guestQueueChanged([Self.job(device: "device-1", id: id)])
        await rig.store.guestQueueChanged([Self.job(device: "device-1", id: id)])
        #expect(await rig.calls.count("guestMe") == 1)
        await rig.store.guestQueueChanged([
            Self.job(device: "device-1", state: .waiting, reason: nil, id: id)
        ])
        await rig.store.guestQueueChanged([Self.job(device: "device-1", id: id)])

        #expect(await rig.calls.count("guestMe") == 2)
    }

    // MARK: - renaming after joining (PATCH /api/guest/device)

    /// The door stores its own spelling of the name, which may differ from what was sent: the
    /// store must show the stored one. So the scripted door answers a name nobody typed.
    nonisolated static let renamed = #"{"display_name": "Ana Beta"}"#

    /// Redeems answered, renames answered by `rename` (held behind `gate` when one is given).
    private static func renameRig(
        gate: Gate? = nil,
        _ rename: @escaping @Sendable () -> (HTTPResponse, HTTPBody?) = {
            Stub.json(GuestSessionStoreTests.renamed)
        }
    ) -> Rig {
        Rig { operation in
            switch operation {
            case "guestRedeem": return Stub.json(Self.redeemed, status: .created)
            case "guestRenameDevice":
                await gate?.wait()
                return rename()
            default: return Self.status(500)
            }
        }
    }

    private func sentRename(_ rig: Rig) async throws -> (HTTPRequest, String?) {
        let requests = await rig.calls.requests
        let bodies = await rig.calls.bodies
        let index = try #require(
            await rig.calls.operations.firstIndex(of: "guestRenameDevice"), "no rename was sent")
        let sent = try #require(
            try JSONSerialization.jsonObject(with: bodies[index]) as? [String: Any])
        return (requests[index], sent["display_name"] as? String)
    }

    // Mutation that turns it red: write the name that was SENT instead of the one the door stored,
    // or skip remembering it.
    @Test("a rename is sent to the door with the guest token, and the door's stored name is kept")
    func renameStoresTheDoorsName() async throws {
        let rig = Self.renameRig()
        await rig.store.redeem(secret: "pass-secret", typedName: "Ana")

        let outcome = await rig.store.rename(to: "  Ana B \n")

        #expect(outcome == .renamed("Ana Beta"))
        #expect(rig.store.joinedName == "Ana Beta")
        #expect(rig.names.string(forKey: GuestSessionStore.joinedNameKey) == "Ana Beta")
        #expect(rig.names.string(forKey: GuestSessionStore.rememberedNameKey) == "Ana Beta")
        #expect(rig.store.joinFieldName == "Ana Beta")
        #expect(rig.store.state.isActive)
        let (request, name) = try await sentRename(rig)
        #expect(request.method == .patch)
        #expect(request.path == "/api/guest/device")
        #expect(request.headerFields[.authorization] == "Bearer guest-token-1")
        #expect(request.headerFields[.contentType] == "application/json")
        #expect(name == "Ana B")
    }

    // Mutation that turns it red: send `typed` as it came instead of `GuestName.cleaned(typed)`.
    @Test("a rename over the door's 64 is capped to 64 before it is sent")
    func renameIsCapped() async throws {
        let rig = Self.renameRig()
        await rig.store.redeem(secret: "pass-secret", typedName: "Ana")

        await rig.store.rename(to: String(repeating: "x", count: 70))

        #expect(try await sentRename(rig).1 == String(repeating: "x", count: 64))
    }

    // Mutation that turns it red: build the body by interpolating the name into a JSON template.
    @Test("a rename's name is a JSON string on the wire, quotes and backslashes included")
    func renameNameIsEncodedNotTemplated() async throws {
        let rig = Self.renameRig()
        await rig.store.redeem(secret: "pass-secret", typedName: "Ana")
        let name = #"Ana "Bean" O\Neil"#

        await rig.store.rename(to: name)

        #expect(try await sentRename(rig).1 == name)
    }

    // Mutation that turns it red: send the blank name and let the door refuse it.
    @Test("a blank rename is refused here, with nothing sent and the old name kept")
    func blankRenameSendsNothing() async throws {
        let rig = Self.renameRig()
        await rig.store.redeem(secret: "pass-secret", typedName: "Ana")

        let outcome = await rig.store.rename(to: " \n ")

        #expect(outcome == .refused(.emptyName))
        #expect(await rig.calls.count("guestRenameDevice") == 0)
        #expect(rig.store.joinedName == "Ana")
    }

    // Mutation that turns it red: map every refusal to `.unavailable`, or write the typed name on
    // a refusal.
    @Test(
        "a rename the door refuses keeps the old name and says what to do",
        arguments: [
            (422, GuestSessionStore.RenameRefusal.invalidName),
            (500, .unavailable),
            (404, .unavailable),
        ])
    func refusedRenameKeepsTheOldName(
        code: Int, refusal: GuestSessionStore.RenameRefusal
    ) async throws {
        let rig = Self.renameRig { Self.status(code) }
        await rig.store.redeem(secret: "pass-secret", typedName: "Ana")

        let outcome = await rig.store.rename(to: "Ana B")

        #expect(outcome == .refused(refusal))
        #expect(!refusal.message.isEmpty)
        #expect(rig.store.joinedName == "Ana")
        #expect(rig.names.string(forKey: GuestSessionStore.joinedNameKey) == "Ana")
        #expect(rig.names.string(forKey: GuestSessionStore.rememberedNameKey) == "Ana")
        #expect(rig.store.state.isActive)
        #expect(rig.credentials.current != nil)
    }

    // Mutation that turns it red: treat 401 like any other refusal instead of handing it to the
    // one guest refusal rule.
    @Test(
        "a rename refused for the credential or an ended pass ends guest mode by the one rule",
        arguments: [401, 410])
    func renameRefusedForTheCredentialEndsGuestMode(code: Int) async throws {
        let rig = Self.renameRig { Self.status(code) }
        await rig.store.redeem(secret: "pass-secret", typedName: "Ana")

        let outcome = await rig.store.rename(to: "Ana B")

        #expect(outcome == .refused(.passEnded))
        #expect(rig.store.state == .ended)
        #expect(rig.credentials.current == nil)
        #expect(rig.licence.currentLicence() == nil)
        #expect(rig.store.joinedName == nil)
        #expect(rig.names.string(forKey: GuestSessionStore.rememberedNameKey) == "Ana")
    }

    // Mutation that turns it red: drop the in-flight join in `rename`, so the second call sends.
    @Test("two overlapping renames are ONE request, under the first name, and both get its outcome")
    func overlappingRenamesJoin() async throws {
        let gate = Gate()
        let rig = Self.renameRig(gate: gate)
        let store = rig.store
        await store.redeem(secret: "pass-secret", typedName: "Ana")

        let first = Task { await store.rename(to: "Ana B") }
        try await waitUntil { await rig.calls.count("guestRenameDevice") == 1 }
        let second = Task { await store.rename(to: "Cleo") }
        await Task.yield()
        await gate.release()
        let outcomes = [await first.value, await second.value]

        #expect(outcomes == [.renamed("Ana Beta"), .renamed("Ana Beta")])
        #expect(await rig.calls.count("guestRenameDevice") == 1)
        #expect(try await sentRename(rig).1 == "Ana B")
        #expect(store.joinedName == "Ana Beta")
    }

    // Mutation that turns it red: drop the generation fence after the rename's answer.
    @Test("a rename answered after a leave writes no name back")
    func renameAnsweredAfterLeaveWritesNothing() async throws {
        let gate = Gate()
        let rig = Self.renameRig(gate: gate)
        let store = rig.store
        await store.redeem(secret: "pass-secret", typedName: "Ana")

        let rename = Task { await store.rename(to: "Ana B") }
        try await waitUntil { await rig.calls.count("guestRenameDevice") == 1 }
        await store.leave()
        await gate.release()

        #expect(await rename.value == .superseded)
        #expect(store.joinedName == nil)
        #expect(rig.names.string(forKey: GuestSessionStore.joinedNameKey) == nil)
        #expect(rig.names.string(forKey: GuestSessionStore.rememberedNameKey) == "Ana")
        #expect(store.state == .none)
    }

    // Mutation that turns it red: the same dropped fence — the re-join is what it would overwrite.
    @Test("a rename answered after a leave and a re-join leaves the new pass's name alone")
    func renameAnsweredAfterRejoinWritesNothing() async throws {
        let gate = Gate()
        let rig = Self.renameRig(gate: gate)
        let store = rig.store
        await store.redeem(secret: "pass-secret", typedName: "Ana")

        let rename = Task { await store.rename(to: "Ana B") }
        try await waitUntil { await rig.calls.count("guestRenameDevice") == 1 }
        await store.leave()
        await store.redeem(secret: "pass-secret", typedName: "Cleo")
        await gate.release()

        #expect(await rename.value == .superseded)
        #expect(store.joinedName == "Cleo")
        #expect(rig.names.string(forKey: GuestSessionStore.joinedNameKey) == "Cleo")
        #expect(rig.names.string(forKey: GuestSessionStore.rememberedNameKey) == "Cleo")
    }

    // Mutation that turns it red: join ANY rename in flight, so a save under the new pass waits on
    // the old pass's request and sends nothing.
    @Test("a rename under a new pass is never joined to one the old pass left on the wire")
    func renameAfterRejoinIsItsOwnRequest() async throws {
        let gate = Gate()
        let rig = Self.renameRig(gate: gate)
        let store = rig.store
        await store.redeem(secret: "pass-secret", typedName: "Ana")

        let stale = Task { await store.rename(to: "Ana B") }
        try await waitUntil { await rig.calls.count("guestRenameDevice") == 1 }
        await store.leave()
        await store.redeem(secret: "pass-secret", typedName: "Cleo")
        let fresh = Task { await store.rename(to: "Dee") }
        try await waitUntil { await rig.calls.count("guestRenameDevice") == 2 }
        await gate.release()

        #expect(await stale.value == .superseded)
        #expect(await fresh.value == .renamed("Ana Beta"))
        #expect(store.joinedName == "Ana Beta")
    }

    @Test("a rename with no pass on the device sends nothing")
    func renameWithoutAPassSendsNothing() async throws {
        let rig = Self.renameRig()

        #expect(await rig.store.rename(to: "Ana") == .refused(.notJoined))
        #expect(await rig.calls.count("guestRenameDevice") == 0)
    }

    // MARK: - the joined name field (GuestNameDraft)

    // Mutation that turns it red: let `edit` or `beginSave` act while a Save is pending, or let
    // `finish` write the stored name over a field that changed.
    @Test("the name field is locked while a Save is pending, so the answer clobbers no typing")
    func draftLocksWhileSaving() {
        var draft = GuestNameDraft(stored: "Ana")
        draft.edit("Ana B")

        #expect(draft.beginSave(stored: "Ana") == "Ana B")
        #expect(!draft.isEditable)
        draft.edit("Cleo")
        draft.storedChanged("Ana Beta")
        #expect(draft.text == "Ana B")
        #expect(draft.beginSave(stored: "Ana") == nil)

        #expect(draft.finish(.renamed("Ana Beta")) == nil)
        #expect(draft.text == "Ana Beta")
        #expect(draft.isEditable)
    }

    @Test("a refused Save unlocks the field, keeps the typed text and says what to do")
    func draftRefusalKeepsTypedText() {
        var draft = GuestNameDraft(stored: "Ana")
        draft.edit("Ana B")
        _ = draft.beginSave(stored: "Ana")

        let notice = draft.finish(.refused(.invalidName))

        #expect(notice == GuestSessionStore.RenameRefusal.invalidName.message)
        #expect(draft.text == "Ana B")
        #expect(draft.isEditable)
    }

    @Test("Save has nothing to send when the field holds the stored name, trimmed or capped")
    func draftUnchangedSendsNothing() {
        var draft = GuestNameDraft(stored: "Ana")
        #expect(draft.beginSave(stored: "Ana") == nil)
        draft.edit(" Ana ")
        #expect(draft.beginSave(stored: "Ana") == nil)
        draft.edit(String(repeating: "x", count: 70))
        #expect(draft.text == String(repeating: "x", count: 64))
    }
}

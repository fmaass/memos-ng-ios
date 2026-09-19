import Foundation
import MemosOutbox
import Testing

/// The rule itself, one case per category of network.
///
/// It is a pure function over three Booleans, so it is asserted directly rather than inferred from
/// a drain: every combination that decides anything is here, including the two that must refuse
/// however the toggle is set.
@Suite("What network a capture may go over")
struct UploadNetworkPolicyTests {
    @Test("the home wifi sends, toggle or no toggle")
    func wifiAlwaysSends() {
        #expect(UploadNetworkPolicy(allowsMobileData: false).permits(.wifi))
        #expect(UploadNetworkPolicy(allowsMobileData: true).permits(.wifi))
    }

    @Test("mobile data waits until it is turned on")
    func cellularNeedsTheToggle() {
        #expect(!UploadNetworkPolicy(allowsMobileData: false).permits(.cellular))
        #expect(UploadNetworkPolicy(allowsMobileData: true).permits(.cellular))
    }

    /// A personal hotspot: iOS reports it as expensive without reporting it as cellular, and it
    /// costs someone the same money. It is the toggle's business for exactly that reason.
    @Test("an expensive network that is not cellular is still mobile data")
    func expensiveCountsAsMobileData() {
        let hotspot = NetworkPath(usesCellular: false, isExpensive: true, isConstrained: false)
        #expect(!UploadNetworkPolicy(allowsMobileData: false).permits(hotspot))
        #expect(UploadNetworkPolicy(allowsMobileData: true).permits(hotspot))
    }

    /// Low Data Mode is a decision a person made about the whole phone. The toggle says "you may
    /// spend my data plan", never "ignore what I told the phone".
    @Test("Low Data Mode refuses whatever the toggle says")
    func constrainedAlwaysWaits() {
        let constrained = NetworkPath(usesCellular: false, isExpensive: false, isConstrained: true)
        let onCellular = NetworkPath(usesCellular: true, isExpensive: true, isConstrained: true)
        #expect(!UploadNetworkPolicy(allowsMobileData: false).permits(constrained))
        #expect(!UploadNetworkPolicy(allowsMobileData: true).permits(constrained))
        #expect(!UploadNetworkPolicy(allowsMobileData: true).permits(onCellular))
    }
}

/// The setting, and that it is one: a value a second reader over the same storage finds.
@Suite("The upload preference")
struct UploadPreferencesTests {
    @Test("a store with nothing written keeps captures on the home network")
    func defaultsToWifiOnly() {
        let name = "memosng.outbox.tests.\(UUID().uuidString)"
        defer { Fixture.forgetting(name) }
        let defaults = UserDefaults(suiteName: name)!

        #expect(UploadPreferences(defaults: defaults).allowsMobileData == false)
    }

    /// The property that makes it a setting rather than a switch on a screen: a second store over
    /// the same suite — which is what the next launch, and the other process, are — reads it back.
    @Test("a choice is still there for the next launch")
    func choiceSurvivesTheStore() async {
        let name = "memosng.outbox.tests.\(UUID().uuidString)"
        defer { Fixture.forgetting(name) }
        let defaults = UserDefaults(suiteName: name)!

        await UploadPreferences(defaults: defaults).set(true)

        #expect(UploadPreferences(defaults: defaults).allowsMobileData)
        await UploadPreferences(defaults: defaults).set(false)
        #expect(UploadPreferences(defaults: defaults).allowsMobileData == false)
    }

    /// Whoever is waiting on the choice hears about it, in the same call — that is what makes a
    /// queued capture go the moment the toggle moves rather than at the next launch.
    @Test("choosing tells whoever asked to be told")
    func choosingReportsTheChange() async {
        let (store, name) = Fixture.preferences()
        defer { Fixture.forgetting(name) }
        let told = Counter()
        store.onChange { told.increment() }

        await store.set(true)

        #expect(told.count == 1)
    }
}

/// A queue written by a build that had never heard of `waitReason` is still read.
///
/// The field is optional for this reason alone, and this is the assertion that holds it optional:
/// a manifest that will not decode is QUARANTINED, so the failure mode of getting this wrong is a
/// phone full of captures nothing will ever send again.
@Suite("A manifest from before the network policy")
struct LegacyManifestTests {
    @Test("a job written without a wait reason decodes, and waits for nothing in particular")
    func decodesAManifestWithoutAWaitReason() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try OutboxRepository(root: root.appending(path: "outbox"))
        let id = UUID(uuidString: "1B4E28BA-2FA1-11D2-883F-0016D3CCA427")!
        // Written by hand rather than by this build's encoder on purpose: an encoder that learned
        // a new field would write it, and the manifest this test is about never had one.
        let manifest = """
            {
              "id": "\(id.uuidString)",
              "idempotencyKey": "6BA7B810-9DAD-11D1-80B4-00C04FD430C8",
              "content": "on the beach",
              "visibility": "PRIVATE",
              "capturedAt": "2026-06-20T09:15:00Z",
              "files": [
                {
                  "id": "6BA7B811-9DAD-11D1-80B4-00C04FD430C8",
                  "relativePath": "one.heic",
                  "filename": "IMG_0001.HEIC",
                  "mime": "image/heic",
                  "byteSize": 1024,
                  "bytesConfirmed": 400,
                  "chunkSize": 400,
                  "uploadUID": "u1"
                }
              ],
              "binding": {
                "serverBaseURL": "https://memos.example.invalid",
                "ownerSubject": "fabian"
              },
              "state": "uploading",
              "attemptCount": 0,
              "nextAttemptAt": "2026-06-20T09:15:00Z"
            }
            """
        let jobs = root.appending(path: "outbox/jobs")
        try Data(manifest.utf8).write(to: jobs.appending(path: "\(id.uuidString).json"))

        let loaded = try await repository.loadJobs()

        #expect(loaded.count == 1)
        let job = try #require(loaded.first)
        #expect(job.id == id)
        #expect(job.state == .uploading, "not quarantined, and not held")
        #expect(job.holdReason == nil)
        #expect(job.waitReason == nil)
        #expect(job.files[0].bytesConfirmed == 400)
    }
}

/// The two events that make a held capture sendable, and that each of them is enough on its own.
///
/// Neither test calls `drain`. That is the assertion: a capture put down for the home network has
/// to move when the wifi comes back or when the toggle goes on, and an outbox that only tried
/// again at the next launch would look exactly like one that had lost the capture.
@MainActor
@Suite("What makes a waiting capture move")
struct UploadTriggerTests {
    private struct Harness {
        let root: URL
        let repository: OutboxRepository
        let scheduler: ScriptedScheduler
        let network: StubNetworkPath
        let outbox: Outbox
        let preferencesName: String
        let jobID: UUID

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            Fixture.forgetting(preferencesName)
        }

        func reload() async -> UploadJob? { await repository.job(jobID) }
    }

    private func makeHarness() async throws -> Harness {
        let root = try Fixture.temporaryDirectory()
        // `StaticCredentials` answers "nothing moves", passed explicitly rather than defaulted so
        // the intent is written down beside the repository an engine is behind.
        let credentials = StaticCredentials(credentials: Fixture.credentials())
        let repository = try OutboxRepository(
            root: root.appending(path: "outbox"),
            stillCurrent: { credentials.stillCurrent(epoch: $0) }
        )
        let source = try Fixture.file(in: root, named: "one.heic", bytes: 400)
        let job = try await repository.enqueue(
            content: "on the beach",
            visibility: nil,
            capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
            binding: Fixture.binding(),
            sources: [StagedSource(url: source, filename: "one.heic", mime: "image/heic")]
        )
        let scheduler = ScriptedScheduler()
        let network = StubNetworkPath(.cellular)
        let preferences = Fixture.preferences()
        let outbox = Outbox(
            repository: repository,
            credentials: credentials,
            http: ScriptedHTTP.standard(chunkSize: 400),
            scheduler: scheduler,
            completion: ScriptedCompletion([.retry("not now")], repeating: .retry("not now")),
            network: network,
            preferences: preferences.store
        )
        return Harness(
            root: root,
            repository: repository,
            scheduler: scheduler,
            network: network,
            outbox: outbox,
            preferencesName: preferences.name,
            jobID: job.id
        )
    }

    @Test("the wifi coming back sends what was waiting for it")
    func thePathChangeDrains() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanUp() }
        await harness.outbox.start()
        #expect(harness.scheduler.uploads.isEmpty)
        let waiting = try #require(await harness.reload())
        #expect(waiting.waitReason == .homeNetwork)

        await harness.network.move(to: .wifi)

        #expect(harness.scheduler.uploads.count == 1, "the event alone was enough")
        let sending = try #require(await harness.reload())
        #expect(sending.state == .uploading)
        #expect(sending.waitReason == nil)
    }

    @Test("turning the toggle on sends what was already queued")
    func thePreferenceChangeDrains() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanUp() }
        await harness.outbox.start()
        #expect(harness.scheduler.uploads.isEmpty)

        await harness.outbox.uploadPreferences.set(true)

        #expect(harness.scheduler.uploads.count == 1, "without waiting for the next launch")
        let sending = try #require(await harness.reload())
        #expect(sending.state == .uploading)
        #expect(sending.waitReason == nil)
    }
}

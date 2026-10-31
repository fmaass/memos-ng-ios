import Foundation
import MemosOutbox
import Testing

/// "Send videos over mobile data: Always / Only under 200 MB / Never" and "Use mobile data for this
/// one" (MEMNG-960), through the real outbox, the real repository and the real engine over a
/// scripted server — what was scheduled is read from the scheduler, and what was decided from the
/// manifest the engine wrote.
@MainActor
@Suite("Video over mobile data")
struct MobileVideoPolicyTests {
    /// One outbox on mobile data with mobile data allowed, and a place to queue captures.
    @MainActor
    private struct Rig {
        let root: URL
        let preferences: (store: UploadPreferences, name: String)
        let repository: OutboxRepository
        let scheduler: ScriptedScheduler
        let network: StubNetworkPath
        let outbox: Outbox

        init(policy: String? = nil, path: NetworkPath = .cellular) throws {
            let root = try Fixture.temporaryDirectory()
            let preferences = Fixture.preferences(allowsMobileData: true)
            // Written the way the Settings app writes it: the raw value, into the same suite.
            if let policy {
                UserDefaults(suiteName: preferences.name)!.set(
                    policy, forKey: UploadPreferences.mobileVideoPolicyKey)
            }
            let credentials = StaticCredentials(credentials: Fixture.credentials())
            let repository = try OutboxRepository(
                root: root.appending(path: "outbox"),
                stillCurrent: { credentials.stillCurrent(epoch: $0) }
            )
            let network = StubNetworkPath(path)
            let scheduler = ScriptedScheduler()
            self.scheduler = scheduler
            self.root = root
            self.preferences = preferences
            self.repository = repository
            self.network = network
            self.outbox = Outbox(
                repository: repository,
                credentials: credentials,
                http: ScriptedHTTP.standard(chunkSize: 400),
                scheduler: scheduler,
                completion: ScriptedCompletion([.retry("not now")], repeating: .retry("not now")),
                network: network,
                preferences: preferences.store
            )
        }

        /// A capture of one file of `bytes` bytes. A large one is SPARSE — its size is real, its
        /// blocks are not — so a 300 MB video costs the test nothing on disk.
        func queue(_ name: String, mime: String, bytes: Int64) async throws -> UploadJob {
            let url = root.appending(path: name)
            let path = url.path(percentEncoded: false)
            #expect(FileManager.default.createFile(atPath: path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(bytes))
            try handle.close()
            return try await repository.enqueue(
                content: name,
                visibility: nil,
                capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
                binding: Fixture.binding(),
                sources: [StagedSource(url: url, filename: name, mime: mime)]
            )
        }

        func scheduled(_ job: UploadJob) -> Bool {
            scheduler.uploads.contains { $0.identity.jobID == job.id }
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            Fixture.forgetting(preferences.name)
        }
    }

    /// 300 MB: over the 200 MB limit.
    private static let big: Int64 = 300_000_000

    // MARK: - (a) the default

    @Test("default: a 300 MB video on mobile data schedules nothing, and Wi-Fi then sends it")
    func defaultHoldsALargeVideoUntilWiFi() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        // The key absent: the default, never another choice.
        #expect(rig.preferences.store.mobileVideoPolicy == .underLimit)
        let video = try await rig.queue("big.mov", mime: "video/quicktime", bytes: Self.big)

        await rig.outbox.start()

        #expect(rig.scheduler.uploads.isEmpty, "a video over 200 MB went over mobile data")
        let waiting = try #require(await rig.repository.job(video.id))
        #expect(waiting.state == .waiting)
        #expect(waiting.waitReason == .videoOverMobileLimit)
        #expect(waiting.waitReason?.retryClass == .connectivity)
        // The connectivity class: nothing counted, no timer.
        #expect(waiting.attemptCount == 0)
        #expect(waiting.nextAttemptAt == video.nextAttemptAt)

        await rig.network.move(to: .wifi)

        #expect(rig.scheduled(video), "the Wi-Fi path event alone resumed it")
        let sending = try #require(await rig.repository.job(video.id))
        #expect(sending.waitReason != .videoOverMobileLimit)
    }

    // MARK: - (b) the override

    @Test("Use mobile data for this one: that capture goes on mobile data, nothing else changes")
    func overrideSendsThatOneCaptureOnly() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let chosen = try await rig.queue("one.mov", mime: "video/quicktime", bytes: Self.big)
        let other = try await rig.queue("two.mov", mime: "video/quicktime", bytes: Self.big)
        await rig.outbox.start()
        #expect(rig.scheduler.uploads.isEmpty)

        let written = await rig.outbox.releaseVideoOverMobile(chosen.id)

        #expect(written == .released)
        #expect(rig.scheduled(chosen), "the released capture was not sent on mobile data")
        #expect(!rig.scheduled(other), "a capture nobody released went too")
        let held = try #require(await rig.repository.job(other.id))
        #expect(held.waitReason == .videoOverMobileLimit)
        #expect(held.videoOverMobileAllowed == nil)
        // Neither setting moved: nothing was written for the video choice. The persistent domain
        // is asked, not `object(forKey:)`, which also answers the pane's registered default.
        let stored = UserDefaults.standard.persistentDomain(forName: rig.preferences.name)
        #expect(stored?[UploadPreferences.mobileVideoPolicyKey] == nil)
        #expect(rig.preferences.store.mobileVideoPolicy == .underLimit)
        #expect(rig.preferences.store.allowsMobileData)
        // On the manifest, so a relaunch — a new repository over the same root — still has it.
        let credentials = StaticCredentials(credentials: Fixture.credentials())
        let relaunched = try OutboxRepository(
            root: rig.root.appending(path: "outbox"),
            stillCurrent: { credentials.stillCurrent(epoch: $0) }
        )
        #expect(await relaunched.job(chosen.id)?.videoOverMobileAllowed == true)
    }

    @Test("two overlapping releases of one capture are one write, and the second writes nothing")
    func overlappingReleasesAreOneWrite() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let video = try await rig.queue("one.mov", mime: "video/quicktime", bytes: Self.big)
        await rig.outbox.start()

        let repository = rig.repository
        let id = video.id
        async let first = repository.releaseVideoOverMobile(of: id)
        async let second = repository.releaseVideoOverMobile(of: id)
        let answers = try await [first, second]

        #expect(answers.filter { $0 == .released }.count == 1, "answers: \(answers)")
        #expect(answers.filter { $0 == .unchanged }.count == 1, "answers: \(answers)")
    }

    @Test("a capture taken back to the editor, or gone, is refused and nothing is written")
    func releaseRefusesACancelledOrMissingCapture() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let video = try await rig.queue("one.mov", mime: "video/quicktime", bytes: Self.big)
        try await rig.repository.save(video.cancelled(at: Date()))

        #expect(await rig.outbox.releaseVideoOverMobile(video.id) == .refused)
        #expect(await rig.repository.job(video.id)?.videoOverMobileAllowed == nil)
        #expect(await rig.outbox.releaseVideoOverMobile(UUID()) == .refused)
    }

    @Test("with mobile data off, a released capture still waits for the home network")
    func releaseNeverWidensTheMobileDataSwitch() {
        var job = Fixture.job(files: [Self.video(Self.big)])
        job.videoOverMobileAllowed = true
        let off = UploadNetworkPolicy(allowsMobileData: false, mobileVideo: .always)
        #expect(off.waitReason(on: .cellular, for: job) == .homeNetwork)
        let on = UploadNetworkPolicy(allowsMobileData: true, mobileVideo: .never)
        #expect(on.waitReason(on: .cellular, for: job) == nil)
        let small = Fixture.job(files: [Self.video(1)])
        #expect(on.waitReason(on: .cellular, for: small) == .videoOnWiFiOnly)
    }

    // MARK: - (c) Always and Never

    @Test("Always: a 300 MB video goes on mobile data")
    func alwaysSendsALargeVideo() async throws {
        let rig = try Rig(policy: "always")
        defer { rig.cleanUp() }
        #expect(rig.preferences.store.mobileVideoPolicy == .always)
        let video = try await rig.queue("big.mov", mime: "video/quicktime", bytes: Self.big)

        await rig.outbox.start()

        #expect(rig.scheduled(video))
    }

    @Test("Never: even a small video waits for Wi-Fi and says why; a photo still goes")
    func neverHoldsEveryVideo() async throws {
        let rig = try Rig(policy: "never")
        defer { rig.cleanUp() }
        #expect(rig.preferences.store.mobileVideoPolicy == .never)
        let video = try await rig.queue("small.mov", mime: "video/quicktime", bytes: 400)
        let photo = try await rig.queue("one.heic", mime: "image/heic", bytes: 400)

        await rig.outbox.start()

        #expect(!rig.scheduled(video), "a video went over mobile data under Never")
        #expect(rig.scheduled(photo), "Never held a photo")
        let waiting = try #require(await rig.repository.job(video.id))
        #expect(waiting.waitReason == .videoOnWiFiOnly)
        #expect(waiting.waitReason?.retryClass == .connectivity)

        await rig.network.move(to: .wifi)

        #expect(rig.scheduled(video), "the Wi-Fi path event alone resumed it")
    }

    @Test("the rule per policy, at the 200 MB boundary, for videos and nothing else")
    func rulePerPolicy() {
        let atLimit = Fixture.job(files: [Self.video(UploadNetworkPolicy.mobileVideoLimit)])
        let overLimit = Fixture.job(files: [Self.video(UploadNetworkPolicy.mobileVideoLimit + 1)])
        let photo = Fixture.job(files: [
            OutboxFile(
                relativePath: "p.heic", filename: "p.heic", mime: "image/heic",
                byteSize: Self.big)
        ])
        let sent = Fixture.job(files: [
            OutboxFile(
                relativePath: "v.mov", filename: "v.mov", mime: "video/quicktime",
                byteSize: Self.big, uploadUID: "u", bytesConfirmed: Self.big)
        ])
        for job in [atLimit, overLimit, photo, sent] {
            #expect(job.mobileVideoWait(under: .always) == nil)
        }
        #expect(atLimit.mobileVideoWait(under: .underLimit) == nil)
        #expect(overLimit.mobileVideoWait(under: .underLimit) == .videoOverMobileLimit)
        #expect(atLimit.mobileVideoWait(under: .never) == .videoOnWiFiOnly)
        #expect(overLimit.mobileVideoWait(under: .never) == .videoOnWiFiOnly)
        for policy in MobileVideoPolicy.allCases {
            #expect(photo.mobileVideoWait(under: policy) == nil, "\(policy) held a photo")
            #expect(sent.mobileVideoWait(under: policy) == nil, "\(policy) held a sent video")
        }
        // Wi-Fi asks no video rule at all.
        let never = UploadNetworkPolicy(allowsMobileData: true, mobileVideo: .never)
        #expect(never.waitReason(on: .wifi, for: overLimit) == nil)
    }

    // MARK: - (d) the key

    @Test("the policy reads the Settings app's raw values, and the default when absent or unknown")
    func preferenceKeyAndDefault() {
        let preferences = Fixture.preferences()
        defer { Fixture.forgetting(preferences.name) }
        let suite = UserDefaults(suiteName: preferences.name)!
        #expect(UploadPreferences.mobileVideoPolicyKey == "uploadVideoOverMobileData")
        #expect(MobileVideoPolicy.allCases.map(\.rawValue) == ["always", "under200MB", "never"])
        #expect(preferences.store.mobileVideoPolicy == .underLimit)
        for policy in MobileVideoPolicy.allCases {
            suite.set(policy.rawValue, forKey: UploadPreferences.mobileVideoPolicyKey)
            #expect(preferences.store.mobileVideoPolicy == policy)
            #expect(preferences.store.networkPolicy.mobileVideo == policy)
        }
        suite.set("sometimes", forKey: UploadPreferences.mobileVideoPolicyKey)
        #expect(preferences.store.mobileVideoPolicy == .underLimit)
        suite.removeObject(forKey: UploadPreferences.mobileVideoPolicyKey)
        #expect(preferences.store.mobileVideoPolicy == .underLimit)
    }

    @Test("the per-capture mark survives the manifest's round trip, and its absence reads as unset")
    func overrideRoundTrips() throws {
        var job = Fixture.job(files: [Self.video(Self.big)])
        job.videoOverMobileAllowed = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(job)
        #expect(try decoder.decode(UploadJob.self, from: data).videoOverMobileAllowed == true)
        var fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fields["videoOverMobileAllowed"] as? Bool == true)
        fields.removeValue(forKey: "videoOverMobileAllowed")
        let older = try JSONSerialization.data(withJSONObject: fields)
        #expect(try decoder.decode(UploadJob.self, from: older).videoOverMobileAllowed == nil)
    }

    private static func video(_ bytes: Int64) -> OutboxFile {
        OutboxFile(
            relativePath: "v.mov", filename: "v.mov", mime: "video/quicktime", byteSize: bytes)
    }
}

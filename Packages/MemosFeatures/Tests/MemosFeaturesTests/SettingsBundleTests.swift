import Foundation
import MemosCore
import MemosOutbox
import Testing

@testable import MemosFeatures

/// A suite of its own per test, named so it can be forgotten afterwards. The app's real defaults
/// are the gate simulator's, and a test that wrote into them would leave its choice behind.
private func scratchSuite() -> (defaults: UserDefaults, name: String) {
    let name = "memosng.bundle.tests.\(UUID().uuidString)"
    return (defaults: UserDefaults(suiteName: name)!, name: name)
}

private func forget(_ names: String...) {
    for name in names { UserDefaults.standard.removePersistentDomain(forName: name) }
}

/// The pane as the BUILT app carries it. `Bundle.main` is the app, because every test bundle in
/// this project is hosted in it (`PrivacyManifestTests` reads the shipped manifests the same way),
/// so a pane that never made it into the bundle fails here rather than on someone's phone.
@MainActor
private func bundledRows() throws -> [[String: Any]] {
    let plist = try #require(
        SettingsBundleSync.rootPlist(in: .main),
        "the built app carries no Settings.bundle/Root.plist"
    )
    let rows = SettingsBundleSync.specifiers(in: plist)
    #expect(!rows.isEmpty, "Root.plist has no PreferenceSpecifiers")
    return rows
}

@MainActor
private func row(keyed key: String, in rows: [[String: Any]]) throws -> [String: Any] {
    try #require(rows.first { $0["Key"] as? String == key }, "no row keyed \(key)")
}

@MainActor
@Suite("The Settings app's pane")
struct SettingsBundlePaneTests {
    @Test("the pane holds exactly the seven keys the app reads, in the order it shows them")
    func exactlySevenKeys() throws {
        let keys = try bundledRows().compactMap { $0["Key"] as? String }
        // The last is the MEMNG-538 spike switch (kill date 2026-11-03), under About. The third is
        // the transfers switch (MEMNG-947), under Uploads.
        let expected = [
            AppSettings.appearanceKey, UploadSettings.key, TransfersFlag.toggleKey,
            SettingsBundleSync.mediaCacheSizeKey,
            SettingsBundleSync.clearMediaCacheKey, SettingsBundleSync.versionKey,
            UploadSpike.toggleKey,
        ]
        #expect(keys == expected)
    }

    /// The cache is cleared from the phone's Settings (MEMNG-781): the size the app last wrote,
    /// and a switch read at the next cold launch, both under a Storage group of their own between
    /// Uploads and About.
    @Test("the size and the clear switch stand under Storage, between Uploads and About")
    func storageGroupHoldsTheCacheRows() throws {
        let rows = try bundledRows()
        let groupTitles = rows.filter { $0["Type"] as? String == "PSGroupSpecifier" }
            .compactMap { $0["Title"] as? String }
        #expect(groupTitles == ["Appearance", "Uploads", "Storage", "About"])
        // Each new row's group is the nearest group row above it.
        func group(of key: String) -> [String: Any]? {
            guard let at = rows.firstIndex(where: { $0["Key"] as? String == key }) else {
                return nil
            }
            return rows[..<at].last { $0["Type"] as? String == "PSGroupSpecifier" }
        }
        #expect(group(of: SettingsBundleSync.mediaCacheSizeKey)?["Title"] as? String == "Storage")
        #expect(group(of: SettingsBundleSync.clearMediaCacheKey)?["Title"] as? String == "Storage")
        #expect(
            group(of: SettingsBundleSync.clearMediaCacheKey)?["FooterText"] as? String
                == SettingsBundleSync.clearMediaCacheFooter)
        let size = try row(keyed: SettingsBundleSync.mediaCacheSizeKey, in: rows)
        #expect(size["Type"] as? String == "PSTitleValueSpecifier")
        #expect(size["Title"] as? String == "Media cache")
        let toggle = try row(keyed: SettingsBundleSync.clearMediaCacheKey, in: rows)
        #expect(toggle["Type"] as? String == "PSToggleSwitchSpecifier")
        #expect(toggle["Title"] as? String == "Clear media cache on next launch")
        #expect(toggle["DefaultValue"] as? Bool == false)
    }

    @Test("the appearance row offers the app's own choices, by their stored names, System first")
    func appearanceRowIsTheEnum() throws {
        let rows = try bundledRows()
        let appearance = try row(keyed: AppSettings.appearanceKey, in: rows)
        #expect(appearance["Type"] as? String == "PSMultiValueSpecifier")
        #expect(
            appearance["Values"] as? [String] == AppearancePreference.allCases.map(\.rawValue)
        )
        #expect(appearance["Titles"] as? [String] == AppearancePreference.allCases.map(\.label))
        #expect(appearance["DefaultValue"] as? String == AppearancePreference.system.rawValue)
    }

    @Test("the upload switch says what the model says, under the footer the model promises")
    func uploadRowIsTheModel() throws {
        let rows = try bundledRows()
        let toggle = try row(keyed: UploadSettings.key, in: rows)
        #expect(toggle["Type"] as? String == "PSToggleSwitchSpecifier")
        #expect(toggle["Title"] as? String == UploadSettings.title)
        #expect(toggle["DefaultValue"] as? Bool == false)
        let groups = rows.filter { $0["Type"] as? String == "PSGroupSpecifier" }
        #expect(groups.contains { $0["FooterText"] as? String == UploadSettings.footer })
    }

    /// What makes the Settings app's write the outbox's read: the pane's root names the very group
    /// `UploadPreferences.live` and the share extension read. Without it the Settings app writes
    /// the app's own defaults, and a switch flipped there reaches no reader until the app comes to
    /// the front (2026-10-11).
    @Test("the pane writes into the app group the outbox and the share extension read")
    func paneWritesTheOutboxGroup() throws {
        let plist = try #require(SettingsBundleSync.rootPlist(in: .main))
        #expect(SettingsBundleSync.paneGroup(in: plist) == OutboxDefaults.appGroup)
    }

    @Test("the version row is one the pane can only display")
    func versionRowIsReadOnly() throws {
        let rows = try bundledRows()
        let version = try row(keyed: SettingsBundleSync.versionKey, in: rows)
        #expect(version["Type"] as? String == "PSTitleValueSpecifier")
        #expect(version["Title"] as? String == "Version")
    }
}

@MainActor
@Suite("Launch: the pane's defaults, the carried-over choice, the version")
struct SettingsBundleLaunchTests {
    @Test("registering the pane's defaults answers System without writing anything")
    func registeringWritesNothing() throws {
        let (standard, name) = scratchSuite()
        defer { forget(name) }
        let plist = try #require(SettingsBundleSync.rootPlist(in: .main))

        SettingsBundleSync.registerDefaults(from: plist, into: standard)

        #expect(standard.string(forKey: AppSettings.appearanceKey) == "system")
        #expect(standard.persistentDomain(forName: name)?[AppSettings.appearanceKey] == nil)
    }

    /// A key nothing else in the process registers, so the answer can only have come from this
    /// call — the registration domain is not something a test can assume is empty.
    @Test("every keyed row's default is registered, whatever the key")
    func everyKeyedRowIsRegistered() throws {
        let (standard, name) = scratchSuite()
        defer { forget(name) }
        let key = "memosng.bundle.tests.key.\(UUID().uuidString)"
        let plist = FileManager.default.temporaryDirectory
            .appending(path: "Root-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: plist) }
        let rows: [[String: Any]] = [
            ["Type": "PSGroupSpecifier", "Title": "Only a heading"],
            ["Type": "PSMultiValueSpecifier", "Key": key, "DefaultValue": "chosen"],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["PreferenceSpecifiers": rows], format: .xml, options: 0
        )
        try data.write(to: plist)

        SettingsBundleSync.registerDefaults(from: plist, into: standard)

        #expect(standard.string(forKey: key) == "chosen")
    }

    /// A saved "system" included: key presence decides, so the registered default of the same
    /// value can never stand in for a choice nobody made, nor hide one somebody did.
    @Test("an appearance an earlier build saved in the app's suite is carried into the group")
    func seedCarriesTheAppsAppearance() {
        for saved in ["dark", "system"] {
            let (standard, name) = scratchSuite()
            let (group, groupName) = scratchSuite()
            defer { forget(name, groupName) }
            standard.set(saved, forKey: AppSettings.appearanceKey)

            SettingsBundleSync.seedAppearance(
                standard: standard, domain: name, group: group, groupDomain: groupName)

            #expect(
                group.persistentDomain(forName: groupName)?[AppSettings.appearanceKey] as? String
                    == saved,
                "\(saved) was not carried into the group"
            )
        }
    }

    @Test("an appearance already in the group is never overwritten by the seed")
    func seedLeavesTheGroupsAppearanceAlone() {
        for (inGroup, inApp) in [("light", "dark"), ("system", "dark")] {
            let (standard, name) = scratchSuite()
            let (group, groupName) = scratchSuite()
            defer { forget(name, groupName) }
            group.set(inGroup, forKey: AppSettings.appearanceKey)
            standard.set(inApp, forKey: AppSettings.appearanceKey)

            SettingsBundleSync.seedAppearance(
                standard: standard, domain: name, group: group, groupDomain: groupName)

            #expect(
                group.persistentDomain(forName: groupName)?[AppSettings.appearanceKey] as? String
                    == inGroup,
                "the seed replaced \(inGroup) chosen in the pane with \(inApp)"
            )
        }
    }

    /// A first install, or an earlier build nobody changed the appearance in: there is nothing to
    /// carry, so the group stays unwritten and the pane's registered default is the answer.
    @Test("an app suite holding no appearance seeds nothing")
    func seedFromAnEmptyAppSuiteWritesNothing() {
        let (standard, name) = scratchSuite()
        let (group, groupName) = scratchSuite()
        defer { forget(name, groupName) }

        SettingsBundleSync.seedAppearance(
            standard: standard, domain: name, group: group, groupDomain: groupName)

        #expect(group.persistentDomain(forName: groupName)?[AppSettings.appearanceKey] == nil)
    }

    /// Through the composed entry the app calls, not the helper: a launch that forgot the seed
    /// would show "System" to someone who chose Dark before this build.
    @Test("launch carries the appearance across and writes the pane's version, into the group")
    func launchSeedsAndWritesTheVersion() {
        let (standard, name) = scratchSuite()
        let (group, groupName) = scratchSuite()
        defer { forget(name, groupName) }
        standard.set(AppearancePreference.dark.rawValue, forKey: AppSettings.appearanceKey)

        SettingsBundleSync.launch(
            from: .main, standard: standard, domain: name, group: group, groupDomain: groupName)

        let written = group.persistentDomain(forName: groupName)
        #expect(written?[AppSettings.appearanceKey] as? String == "dark")
        #expect(AppSettings(defaults: group).appearance == .dark)
        #expect(
            written?[SettingsBundleSync.versionKey] as? String
                == AboutInfo.versionLine(from: .main)
        )
        #expect(
            standard.persistentDomain(forName: name)?[SettingsBundleSync.versionKey] == nil,
            "the version went to the app's own suite, which the pane no longer reads"
        )
    }
}

/// Counts the notices a preference store gives, from whichever isolation gives them.
private nonisolated final class NoticeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

@MainActor
@Suite("Activation: what the Settings app changed while the app was away")
struct SettingsBundleActivationTests {
    @Test("an appearance chosen in the Settings app is the one painted on return")
    func activationReloadsTheAppearance() {
        let (group, groupName) = scratchSuite()
        defer { forget(groupName) }
        let settings = AppSettings(defaults: group)
        #expect(settings.appearance == .system)
        group.set(AppearancePreference.dark.rawValue, forKey: AppSettings.appearanceKey)

        SettingsBundleSync.activate(settings: settings, uploads: nil, outbox: nil)

        #expect(settings.appearance == .dark)
    }

    /// The defect this closes (2026-10-11): the pane wrote the app's own defaults and only the
    /// main app's activation copied the choice into the group, so a switch turned off in the
    /// Settings app, and pictures shared through the extension before the app came to the front,
    /// went over mobile data. The Settings app writes the domain the BUILT pane's root names —
    /// the app's own defaults when it names none (Settings Application Schema Reference) — and
    /// the store the outbox and the extension read must see that write with no activation at all.
    @Test("a switch flipped in the Settings app is read by the outbox with no activation")
    func settingsAppWriteIsReadWithoutActivation() throws {
        let plist = try #require(SettingsBundleSync.rootPlist(in: .main))
        let paneGroup = SettingsBundleSync.paneGroup(in: plist)
        for (before, flipped) in [(true, false), (false, true)] {
            let (own, ownName) = scratchSuite()
            let (group, groupName) = scratchSuite()
            defer { forget(ownName, groupName) }
            own.set(before, forKey: UploadSettings.key)
            group.set(before, forKey: UploadSettings.key)
            let outboxReads = UploadPreferences(defaults: group)
            #expect(outboxReads.allowsMobileData == before, "precondition: \(before) in the group")

            let settingsApp = paneGroup == OutboxDefaults.appGroup ? group : own
            settingsApp.set(flipped, forKey: UploadSettings.key)

            #expect(
                outboxReads.allowsMobileData == flipped,
                "the outbox missed \(flipped) (pane group: \(paneGroup ?? "none"))"
            )
        }
    }

    /// What the pane's write has not reached is this process's memory: the switch's model and
    /// the queue's verdict. Activation brings the model to the group's value and tells the queue.
    @Test("a switch flipped in the Settings app reaches the app's model on return")
    func activationBringsTheModelToTheGroup() {
        let (group, groupName) = scratchSuite()
        defer { forget(groupName) }
        let preferences = UploadPreferences(defaults: group)
        let uploads = UploadSettings(preferences: preferences)
        #expect(!uploads.allowsMobileData, "precondition: off")
        let notices = NoticeCount()
        preferences.onChangeNow { notices.add() }
        group.set(true, forKey: UploadSettings.key)

        SettingsBundleSync.activate(
            settings: AppSettings(defaults: group), uploads: uploads, outbox: nil)

        #expect(uploads.allowsMobileData)
        #expect(preferences.allowsMobileData)
        #expect(notices.value == 1, "the queue was told \(notices.value) times")
    }

    @Test("the in-app switch writes the group, so the next activation has nothing to undo")
    func inAppSelectWritesTheGroupAndActivationLeavesItAlone() async {
        let (group, groupName) = scratchSuite()
        defer { forget(groupName) }
        let preferences = UploadPreferences(defaults: group)
        let uploads = UploadSettings(preferences: preferences)

        await uploads.select(true).value

        #expect(group.bool(forKey: UploadSettings.key))
        let notices = NoticeCount()
        preferences.onChangeNow { notices.add() }

        SettingsBundleSync.activate(
            settings: AppSettings(defaults: group), uploads: uploads, outbox: nil)

        #expect(group.bool(forKey: UploadSettings.key), "activation put the group back")
        #expect(uploads.allowsMobileData)
        #expect(notices.value == 0)
    }

    /// Read with nothing awaited between the call and the reads: whatever `select` leaves to its
    /// drain cannot have happened yet, so only what it wrote before returning is seen here.
    @Test("the in-app switch has written the group and told the queue by the time it returns")
    func inAppSelectIsDownWhenItReturns() async {
        let (group, groupName) = scratchSuite()
        defer { forget(groupName) }
        let preferences = UploadPreferences(defaults: group)
        let uploads = UploadSettings(preferences: preferences)
        let notices = NoticeCount()
        preferences.onChangeNow { notices.add() }

        let drain = uploads.select(true)

        #expect(group.bool(forKey: UploadSettings.key), "the group was left to the drain")
        #expect(notices.value == 1, "the queue was told by the drain, or not at all")
        await drain.value
        #expect(notices.value == 1, "one switch, \(notices.value) notices")
    }

    /// Per WRITE, not per change: the store does not compare, and the queue's verdict is
    /// recomputed from the suite on every notice, so a repeat costs one idle re-read. Telling
    /// only on a change is the activation path's job (`activate` writes nothing unchanged).
    @Test("a write through the store tells the synchronous notice once, and once again on a repeat")
    func setTellsTheNoticeOncePerWrite() async {
        let (group, groupName) = scratchSuite()
        defer { forget(groupName) }
        let preferences = UploadPreferences(defaults: group)
        let notices = NoticeCount()
        preferences.onChangeNow { notices.add() }

        await preferences.set(true)
        #expect(notices.value == 1, "set told the synchronous notice \(notices.value) times")
        await preferences.set(true)
        #expect(notices.value == 2, "a repeated write told \(notices.value - 1) times")
    }
}

// MARK: - The production activation over a real outbox

private final class WireLog: OutboxHTTPPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { seen } }

    func perform(_ request: URLRequest, under authority: SendAuthority) async throws
        -> OutboxHTTPResponse
    {
        guard authority.holds() else { throw SendAuthorityWithdrawn() }
        lock.withLock { seen.append(request) }
        switch (request.httpMethod ?? "", request.url?.path() ?? "") {
        case ("GET", "/health"):
            return OutboxHTTPResponse(statusCode: 200)
        case ("POST", "/api/memos"):
            let body = try JSONSerialization.data(withJSONObject: ["uid": "m1"])
            return OutboxHTTPResponse(
                statusCode: 201, body: body, headers: ["Content-Type": "application/json"])
        default:
            return OutboxHTTPResponse(statusCode: 500)
        }
    }
}

private nonisolated func signedIn() -> OutboxCredentials {
    OutboxCredentials(
        serverBaseURL: URL(string: "https://memos.example.invalid")!,
        ownerSubject: "alice", token: "pat-token")
}

private struct AlwaysSignedIn: OutboxCredentialsProviding {
    func currentCredentials() async -> OutboxCredentials? { signedIn() }
    func isCurrent(_ credentials: OutboxCredentials) -> Bool { true }
    func stillCurrent(epoch: Int) -> Bool { true }
}

private struct NoChunkLane: OutboxChunkScheduling {
    func inFlight() async -> [OutboxTaskIdentity] { [] }
    func upload(
        _ request: URLRequest, fromFile file: URL, identity: OutboxTaskIdentity,
        under authority: SendAuthority, issuedUnder epoch: Int
    ) async {}
    func cancel(_ identities: [OutboxTaskIdentity]) async {}
    func cancelEveryTask() async {}
}

/// Mobile data, and it never changes: whatever the queue does here, a path event did not cause it.
private struct OnMobileData: NetworkPathProviding {
    func currentPath() -> NetworkPath {
        NetworkPath(usesCellular: true, isExpensive: true, isConstrained: false)
    }
    func onPathChange(_ handler: @escaping OutboxTrigger) {}
}

/// One synchronous boundary each: the preference store's notice, and the scheduling gate opening.
private struct ActivationEvent: Equatable {
    enum Kind: Equatable { case applied, verdictRefreshed, schedulingOpened }
    let kind: Kind
    let groupAllows: Bool
    let verdict: UploadVerdict
}

@MainActor
private final class ActivationRig {
    let group: UserDefaults
    let groupName: String
    let http: WireLog
    let preferences: UploadPreferences
    let uploads: UploadSettings
    let outbox: Outbox
    let repository: OutboxRepository
    let jobID: UUID
    var events: [ActivationEvent] = []
    let asyncNotices = NoticeCount()

    /// - Parameters:
    ///   - modelAllows: the group's value when the app last read it — what the switch's model and
    ///     the queue's verdict were built from.
    ///   - settingsAppAllows: what the Settings app wrote into the group while the app was away.
    init(modelAllows: Bool, settingsAppAllows: Bool) async throws {
        let shared = scratchSuite()
        group = shared.defaults
        groupName = shared.name
        shared.defaults.set(modelAllows, forKey: UploadSettings.key)
        let preferences = UploadPreferences(defaults: shared.defaults)
        self.preferences = preferences
        let http = WireLog()
        self.http = http
        let credentials = AlwaysSignedIn()
        let repository = try OutboxRepository(
            root: FileManager.default.temporaryDirectory
                .appending(path: "settings-bundle-activation").appending(path: shared.name)
                .appending(path: "outbox"),
            stillCurrent: { credentials.stillCurrent(epoch: $0) })
        self.repository = repository
        jobID = try await repository.enqueue(
            content: "held for the home network", visibility: nil,
            capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
            binding: signedIn().binding, sources: []
        ).id
        // Closed, as it is while the app is away, so the activation's open is an event.
        let gate = SchedulingGate(isOpen: false)
        let outbox = Outbox(
            repository: repository,
            credentials: credentials,
            http: http,
            scheduler: NoChunkLane(),
            completion: MemoCompletionEndpoint(http: http),
            network: OnMobileData(),
            preferences: preferences,
            schedulingGate: gate
        )
        self.outbox = outbox
        uploads = UploadSettings(preferences: preferences)
        // The Settings app's write, straight into the group: nothing in this process is told.
        shared.defaults.set(settingsAppAllows, forKey: UploadSettings.key)
        // Registered after the outbox's own, so it is told after the verdict was recomputed.
        preferences.onChangeNow { [weak self] in
            self?.note(.applied)
            self?.note(.verdictRefreshed)
        }
        // Counts the ASYNCHRONOUS observer in the outbox's place: activation must not use it,
        // because its drain would race the foreground's.
        let counted = self.asyncNotices
        preferences.onChange { counted.add() }
        gate.observe { [weak self] in
            MainActor.assumeIsolated { self?.note(.schedulingOpened) }
        }
    }

    private func note(_ kind: ActivationEvent.Kind) {
        events.append(
            ActivationEvent(
                kind: kind, groupAllows: group.bool(forKey: UploadSettings.key),
                verdict: outbox.uploadVerdict))
    }

    func activate() async {
        let drain = SettingsBundleSync.activate(
            settings: AppSettings(defaults: group), uploads: uploads, outbox: outbox)
        await drain?.value
    }

    var sentTheMemo: Bool {
        http.requests.contains { $0.httpMethod == "POST" && $0.url?.path() == "/api/memos" }
    }

    func cleanUp() {
        forget(groupName)
        try? FileManager.default.removeItem(
            at: FileManager.default.temporaryDirectory
                .appending(path: "settings-bundle-activation").appending(path: groupName))
    }
}

@MainActor
@Suite("Activation over the real outbox, with no network change")
struct SettingsBundleOutboxActivationTests {
    private let refused = UploadVerdict.refused(.cellularWhileMobileDataOff)

    @Test("switched off in the Settings app: the drain sends nothing, and the queue says why")
    func activationOnToOffMakesNoMobileDataWorkEligibleAndRefreshesVerdict() async throws {
        let rig = try await ActivationRig(modelAllows: true, settingsAppAllows: false)
        defer { rig.cleanUp() }
        #expect(rig.outbox.uploadVerdict == .permitted)

        await rig.activate()

        #expect(
            rig.events == [
                ActivationEvent(kind: .applied, groupAllows: false, verdict: refused),
                ActivationEvent(kind: .verdictRefreshed, groupAllows: false, verdict: refused),
                ActivationEvent(kind: .schedulingOpened, groupAllows: false, verdict: refused),
            ])
        #expect(rig.outbox.uploadVerdict == refused)
        #expect(rig.http.requests.isEmpty, "mobile data was spent with the switch off")
        let held = try #require(await rig.repository.job(rig.jobID))
        #expect(held.waitReason == .homeNetwork)
        #expect(rig.asyncNotices.value == 0)
    }

    @Test("switched on in the Settings app: the held capture goes, and the queue stops waiting")
    func activationOffToOnMakesMobileDataWorkEligibleAndRefreshesVerdict() async throws {
        let rig = try await ActivationRig(modelAllows: false, settingsAppAllows: true)
        defer { rig.cleanUp() }
        #expect(rig.outbox.uploadVerdict == refused)

        await rig.activate()

        #expect(
            rig.events == [
                ActivationEvent(kind: .applied, groupAllows: true, verdict: .permitted),
                ActivationEvent(kind: .verdictRefreshed, groupAllows: true, verdict: .permitted),
                ActivationEvent(kind: .schedulingOpened, groupAllows: true, verdict: .permitted),
            ])
        #expect(rig.outbox.uploadVerdict == .permitted)
        #expect(rig.sentTheMemo, "the capture held for the home network was not sent")
        #expect(rig.asyncNotices.value == 0)
    }

    /// Steps two and three are skipped by design when nothing changed, so this witnesses neither
    /// the order nor the notice — only that an unchanged choice tells nobody anything.
    @Test("nothing changed in the Settings app: nothing is told, and the verdict stands")
    func activationWithNothingChangedNotifiesNothing() async throws {
        let rig = try await ActivationRig(modelAllows: false, settingsAppAllows: false)
        defer { rig.cleanUp() }
        let before = rig.outbox.uploadVerdict

        await rig.activate()

        let opened = ActivationEvent(kind: .schedulingOpened, groupAllows: false, verdict: before)
        #expect(rig.events == [opened])
        #expect(rig.outbox.uploadVerdict == before)
        #expect(rig.asyncNotices.value == 0)
        #expect(rig.http.requests.isEmpty)
    }
}

/// A derived cache that counts its clears and answers the sizes a test sets.
private nonisolated final class CountingCache: DerivedMediaCache {
    var currentDiskUsage: Int
    let diskCapacity: Int
    private(set) var clears = 0

    init(used: Int, capacity: Int = 256 << 20) {
        currentDiskUsage = used
        diskCapacity = capacity
    }

    func removeAllCachedResponses() {
        clears += 1
        currentDiskUsage = 0
    }
}

/// The media cache from the phone's Settings (MEMNG-781, decision 2): cleared at a cold launch
/// when the switch is on, never on a return to the front, and its size written for the pane.
@MainActor
@Suite("The media cache in the Settings app")
struct SettingsBundleMediaCacheTests {
    private func launch(_ group: UserDefaults, _ groupName: String, cache: CountingCache) {
        let (standard, name) = scratchSuite()
        defer { forget(name) }
        SettingsBundleSync.launch(
            from: .main, standard: standard, domain: name, group: group, groupDomain: groupName,
            cache: cache)
    }

    private func size(_ used: Int, of cache: CountingCache) -> String {
        MediaCacheMaintenance.summary(
            MediaCacheMaintenance.Usage(usedBytes: used, capacityBytes: cache.diskCapacity))
    }

    @Test("the switch on at launch: cleared once, the switch off again, the new size written")
    func launchClearsWhenAsked() {
        let (group, groupName) = scratchSuite()
        defer { forget(groupName) }
        group.set(true, forKey: SettingsBundleSync.clearMediaCacheKey)
        let cache = CountingCache(used: 12 << 20)

        launch(group, groupName, cache: cache)

        #expect(cache.clears == 1)
        let written = group.persistentDomain(forName: groupName)
        #expect(written?[SettingsBundleSync.clearMediaCacheKey] as? Bool == false)
        #expect(written?[SettingsBundleSync.mediaCacheSizeKey] as? String == size(0, of: cache))
    }

    @Test("the switch off at launch: nothing cleared, the size as it stands written")
    func launchLeavesTheCacheAlone() {
        let (group, groupName) = scratchSuite()
        defer { forget(groupName) }
        let cache = CountingCache(used: 12 << 20)

        launch(group, groupName, cache: cache)

        #expect(cache.clears == 0)
        #expect(group.bool(forKey: SettingsBundleSync.clearMediaCacheKey) == false)
        #expect(
            group.string(forKey: SettingsBundleSync.mediaCacheSizeKey) == "12.0 MB of 256.0 MB")
    }

    @Test("the switch turned on after launch: a return to the front clears nothing, keeps it on")
    func activationNeverClears() {
        let (group, groupName) = scratchSuite()
        defer { forget(groupName) }
        let cache = CountingCache(used: 12 << 20)
        launch(group, groupName, cache: cache)
        group.set(true, forKey: SettingsBundleSync.clearMediaCacheKey)
        cache.currentDiskUsage = 20 << 20

        SettingsBundleSync.activate(
            settings: AppSettings(defaults: group), uploads: nil, outbox: nil, cache: cache,
            group: group)

        #expect(cache.clears == 0, "a return to the front cleared the cache")
        #expect(group.bool(forKey: SettingsBundleSync.clearMediaCacheKey) == true)
        #expect(
            group.string(forKey: SettingsBundleSync.mediaCacheSizeKey) == size(20 << 20, of: cache))
    }

    @Test("going to the background writes the size as it stands, and clears nothing")
    func backgroundWritesTheSize() {
        let (group, groupName) = scratchSuite()
        defer { forget(groupName) }
        group.set(true, forKey: SettingsBundleSync.clearMediaCacheKey)
        let cache = CountingCache(used: 3 << 20)

        SettingsBundleSync.enteredBackground(outbox: nil, cache: cache, group: group)

        #expect(cache.clears == 0)
        #expect(
            group.string(forKey: SettingsBundleSync.mediaCacheSizeKey) == "3.0 MB of 256.0 MB")
        #expect(group.bool(forKey: SettingsBundleSync.clearMediaCacheKey) == true)
    }
}

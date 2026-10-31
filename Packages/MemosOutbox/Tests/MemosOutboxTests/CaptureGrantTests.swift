import Foundation
@testable import MemosOutbox
import Testing

/// The capture grant beside the licence (MEMNG-938): which capture it may serve, and how the
/// licence's own lifecycle removes it.
@Suite("Capture grant")
struct CaptureGrantTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private static func grant(
        id: Int = 9, under licence: PublishedLicence, expiresIn: TimeInterval = 86_400
    ) throws -> PublishedCaptureGrant {
        PublishedCaptureGrant(
            id: id, token: "memos_cap_\(id)", expiresAt: now.addingTimeInterval(expiresIn),
            binding: licence.binding, incarnation: try #require(licence.incarnation))
    }

    @Test("a grant of issue n is never used for a capture enqueued under issue n+1")
    func grantOfOneIssueNeverServesTheNext() throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = OutboxAccountStore(root: root)
        let grants = CaptureGrantStore(root: root)
        account.publish(Fixture.binding())
        let issueN = try #require(account.currentLicence())
        let stamped = try Self.grant(under: issueN)
        try grants.write(stamped)
        // The foreground republish of the same account keeps the issue, and the grant with it.
        account.publish(Fixture.binding())
        #expect(grants.current() == stamped)
        #expect(
            grants.uploadCredential(enqueuedUnder: issueN, now: Self.now)?.token == "memos_cap_9")

        // Signed out and back in to the SAME account: identical binding, a new issue.
        try account.clear()
        account.publish(Fixture.binding())
        let issueN1 = try #require(account.currentLicence())
        #expect(issueN1.binding == issueN.binding)
        #expect(issueN1.incarnation != issueN.incarnation)
        // Even when the old grant is still on disk — a removal that failed — it is refused.
        try grants.write(stamped)
        #expect(grants.uploadCredential(enqueuedUnder: issueN1, now: Self.now) == nil)
    }

    @Test("a grant that lapses within the margin, or another account's, is not handed over")
    func lapsingOrForeignGrantIsRefused() throws {
        let licence = PublishedLicence(binding: Fixture.binding(), incarnation: UUID())
        let lapsing = try Self.grant(
            under: licence, expiresIn: PublishedCaptureGrant.minimumRemaining - 1)
        #expect(lapsing.credential(enqueuedUnder: licence, at: Self.now) == nil)
        let foreign = PublishedLicence(
            binding: Fixture.binding(owner: "brenda"), incarnation: licence.incarnation)
        let live = try Self.grant(under: licence)
        #expect(live.credential(enqueuedUnder: foreign, at: Self.now) == nil)
        #expect(live.credential(enqueuedUnder: licence, at: Self.now) != nil)
        let legacy = PublishedLicence(binding: Fixture.binding(), incarnation: nil)
        #expect(live.credential(enqueuedUnder: legacy, at: Self.now) == nil)
    }

    @Test("revoking the licence removes the grant; an account change removes it before publishing")
    func licenceLifecycleRemovesTheGrant() throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = OutboxAccountStore(root: root)
        let grants = CaptureGrantStore(root: root)
        account.publish(Fixture.binding())
        try grants.write(try Self.grant(under: try #require(account.currentLicence())))
        try account.clear()
        #expect(grants.current() == nil)
        #expect(!FileManager.default.fileExists(atPath: grants.url.path()))

        account.publish(Fixture.binding())
        try grants.write(try Self.grant(under: try #require(account.currentLicence())))
        account.publish(Fixture.binding(owner: "brenda"))
        #expect(grants.current() == nil)
    }

    @Test("a grant stands only while the file holds that grant under the capture's licence")
    func standingFollowsTheFiles() throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = OutboxAccountStore(root: root)
        let grants = CaptureGrantStore(root: root)
        account.publish(Fixture.binding())
        let licence = try #require(account.currentLicence())
        try grants.write(try Self.grant(id: 9, under: licence))
        #expect(grants.stillStands(epoch: 9, enqueuedUnder: licence, standing: licence))
        // The app re-minted: the server revoked grant 9 when it issued 10.
        try grants.write(try Self.grant(id: 10, under: licence))
        #expect(!grants.stillStands(epoch: 9, enqueuedUnder: licence, standing: licence))
        // Signed out: no licence standing.
        #expect(!grants.stillStands(epoch: 10, enqueuedUnder: licence, standing: nil))
    }
}

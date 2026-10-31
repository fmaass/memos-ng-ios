import Foundation
import MemosOutbox
import MemosShareKit
import Testing

/// Who sends a share's bytes, and what the sheet says about it (MEMNG-938).
@Suite("Share upload plan")
struct ShareUploadPlanTests {
    @Test("without a usable grant the sheet says the app will upload it; with one it says nothing")
    func noticeFollowsTheGrant() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "plan-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = OutboxAccountStore(root: root)
        let grants = CaptureGrantStore(root: root)
        let server = try #require(URL(string: "https://memos.example.invalid"))
        account.publish(AccountBinding(serverBaseURL: server, ownerSubject: "fabian"))
        let licence = try #require(account.currentLicence())
        #expect(
            ShareUploadPlan.notice(licence: licence, grants: grants)
                == "Will upload when you open memos")
        #expect(ShareUploadPlan.credential(enqueuedUnder: licence, grants: grants) == nil)

        try grants.write(
            PublishedCaptureGrant(
                id: 5, token: "memos_cap_5", expiresAt: Date().addingTimeInterval(86_400),
                binding: licence.binding, incarnation: try #require(licence.incarnation)))
        #expect(ShareUploadPlan.notice(licence: licence, grants: grants) == nil)
        let handed = ShareUploadPlan.credential(enqueuedUnder: licence, grants: grants)
        #expect(handed?.token == "memos_cap_5")
        // Nobody signed in: the sheet's own sign-in sentence covers it.
        #expect(ShareUploadPlan.notice(licence: nil, grants: grants) == nil)
    }
}

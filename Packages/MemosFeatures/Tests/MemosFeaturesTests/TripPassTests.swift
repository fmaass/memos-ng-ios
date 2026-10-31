import Foundation
import MemosCore
import MemosOutbox
import Testing

@testable import MemosFeatures

/// Which URL the app is opened with reaches guest mode, and which still reaches the sign-in inbox.
@Suite("Routing an opened URL")
struct RootURLRouteTests {
    @Test("a trip pass link goes to guest mode, carrying its secret")
    func passLinkIsATripPass() throws {
        let url = try #require(URL(string: "https://trip.discomarder.live/p/k3y-Secret_9"))
        #expect(RootURLRoute.route(url) == .tripPass("k3y-Secret_9"))
    }

    @Test(
        "every sign-in callback, and anything else, still reaches the inbox",
        arguments: [
            "memosng://auth-callback?code=abc&state=xyz",
            "memosng:auth-callback?code=abc",
            "https://memos.discomarder.live/ios/auth/callback?code=abc&state=xyz",
            "https://trip.discomarder.live/",
            "https://trip.discomarder.live/p/",
            "https://trip.discomarder.live/p/abc/extra",
            "http://trip.discomarder.live/p/abc",
            "https://trip.discomarder.live.example/p/abc",
            // A pass link written INSIDE another URL is not that URL.
            "memosng://auth-callback?code=abc&next=https://trip.discomarder.live/p/abc",
            "https://memos.discomarder.live/ios/auth/callback?r=trip.discomarder.live%2Fp%2Fx",
        ]
    )
    func everythingElseIsTheInbox(_ spelled: String) throws {
        let url = try #require(URL(string: spelled))
        #expect(RootURLRoute.route(url) == .inbox)
    }
}

/// The scanner's one answer, claimed synchronously where VisionKit reports a code.
@Suite("The trip pass scanner's claim")
struct TripPassScanClaimTests {
    static let pass = "https://trip.discomarder.live/p/abc"

    @Test("the first pass link is claimed and every later report is not")
    func firstPassLinkWinsOnce() {
        let claim = TripPassScanClaim()
        #expect(claim.claim(Self.pass) == URL(string: Self.pass))
        #expect(claim.claim(Self.pass) == nil)
        #expect(claim.claim("https://trip.discomarder.live/p/other") == nil)
        #expect(claim.claimed == URL(string: Self.pass))
    }

    @Test("a code that is not a pass link does not use the claim up")
    func strayCodeLeavesTheClaim() {
        let claim = TripPassScanClaim()
        #expect(claim.claim("WIFI:S:home;T:WPA;P:secret;;") == nil)
        #expect(claim.claim("https://example.com/menu") == nil)
        #expect(claim.claim(nil) == nil)
        #expect(claim.claimed == nil)
        #expect(claim.claim(Self.pass) == URL(string: Self.pass))
    }
}

@Suite("Trip pass presentation")
struct TripPassPresentationTests {
    static let active = GuestSessionStore.State.active(
        label: "Lisbon", expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    @Test("no visibility is offered while a pass stands")
    func activePassHidesVisibility() {
        #expect(TripPassPresentation.showsVisibility(Self.active) == false)
    }

    @Test(
        "visibility is offered whenever no pass stands",
        arguments: [
            GuestSessionStore.State.none,
            .redeeming,
            .ended,
            .refused(.unknownPass),
            .refused(.passEnded),
            .refused(.tooManyAttempts),
        ]
    )
    func noPassShowsVisibility(_ state: GuestSessionStore.State) {
        #expect(TripPassPresentation.showsVisibility(state))
    }

    @Test("a host with no guest store offers visibility")
    func noGuestStoreShowsVisibility() {
        #expect(TripPassPresentation.showsVisibility(nil))
    }

    @Test("the entry opens a standing pass and otherwise offers to join one")
    func entryTitle() {
        #expect(TripPassPresentation.entryTitle(for: Self.active) == "Trip pass")
        #expect(TripPassPresentation.entryTitle(for: .none) == "Join a trip with a pass")
        #expect(TripPassPresentation.entryTitle(for: .ended) == "Join a trip with a pass")
        #expect(TripPassPresentation.entryTitle(for: nil) == "Join a trip with a pass")
    }

    @Test(
        "each refused redeem says its own reason",
        arguments: [
            GuestSessionStore.RedeemRefusal.notAPassLink,
            .unknownPass,
            .passEnded,
            .tooManyAttempts,
            .unavailable,
        ]
    )
    func refusalSaysWhy(_ refusal: GuestSessionStore.RedeemRefusal) {
        #expect(TripPassPresentation.notice(for: .refused(refusal)) == refusal.message)
    }

    @Test("an ended pass says so, and nothing else has a notice")
    func endedAndQuietStates() {
        #expect(TripPassPresentation.notice(for: .ended) == TripPassPresentation.endedNotice)
        #expect(TripPassPresentation.notice(for: .none) == nil)
        #expect(TripPassPresentation.notice(for: .redeeming) == nil)
        #expect(TripPassPresentation.notice(for: Self.active) == nil)
    }

    @Test("a pasted link is trimmed, and read as https when it has no scheme")
    func pastedLink() {
        let expected = URL(string: "https://trip.discomarder.live/p/abc")
        #expect(
            TripPassPresentation.passLink(fromPasted: "  https://trip.discomarder.live/p/abc\n")
                == expected
        )
        #expect(
            TripPassPresentation.passLink(fromPasted: "trip.discomarder.live/p/abc") == expected
        )
        #expect(TripPassPresentation.passLink(fromPasted: " \n") == nil)
    }

    @Test("a receipt says how many files, and whether the owner still holds them")
    func receiptSummary() throws {
        func receipt(status: String, files: Int) throws -> GuestWire.Receipt {
            let json = """
                {"batch_id": "b1", "status": "\(status)", "file_count": \(files),
                 "completed_at": "2026-10-30T10:00:00Z", "files": []}
                """
            return try #require(GuestWire.decode(GuestWire.Receipt.self, from: Data(json.utf8)))
        }
        #expect(
            TripPassPresentation.receiptSummary(try receipt(status: "received", files: 1))
                == "1 file · received"
        )
        #expect(
            TripPassPresentation.receiptSummary(try receipt(status: "held", files: 3))
                == "3 files · waiting for the trip's owner"
        )
    }
}

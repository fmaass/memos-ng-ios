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

/// What a universal link from the trip door can look like when it arrives.
///
/// The door's association claims `/p/*` for this app (read live 2026-10-31), so the system hands
/// the app every URL under `/p/` on that host — from the Camera, from Messages — through
/// `onOpenURL` or a browsing activity, and both reach `RootURLRoute`. What the system delivers is
/// the URL as it was shared, query and fragment included, so each of those shapes must still be
/// read as the pass; a claimed shape that is not a pass, and the home host, must not.
@Suite("Universal links from the trip door")
struct TripDoorUniversalLinkTests {
    @Test(
        "every shape of a /p/<secret> link the door's association hands over opens that pass",
        arguments: [
            ("https://trip.discomarder.live/p/abc123", "abc123"),
            ("https://trip.discomarder.live/p/abc123?utm_source=qr", "abc123"),
            ("https://trip.discomarder.live/p/abc123#join", "abc123"),
            ("https://trip.discomarder.live/p/abc123/", "abc123"),
            ("https://trip.discomarder.live/p/k3y%2DSecret", "k3y-Secret"),
            ("https://TRIP.discomarder.live/p/abc123", "abc123"),
        ]
    )
    func claimedPassShapesOpenThePass(_ spelled: String, _ secret: String) throws {
        let url = try #require(URL(string: spelled))
        #expect(RootURLRoute.route(url) == .tripPass(secret))
    }

    @Test(
        "a path the wildcard claims but no pass has, and the home host, never redeem",
        arguments: [
            // Rejected host: the home server is internal-only and is no guest door.
            "https://memos.discomarder.live/p/abc123",
            // Rejected paths: `/p/*` also matches these, and none of them names one pass.
            "https://trip.discomarder.live/p/abc123/extra",
            "https://trip.discomarder.live/p/",
            // Rejected paths outside the claim, should one ever reach the app.
            "https://trip.discomarder.live/x/abc123",
            "https://trip.discomarder.live/.well-known/apple-app-site-association",
        ]
    )
    func unclaimedShapesReachTheInbox(_ spelled: String) throws {
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

/// The name the Join screen and an opened link send (`GuestName.resolve`), one case per input.
@Suite("The name a guest joins under")
struct GuestNameResolutionTests {
    @Test("a typed name wins over the remembered one and the device's, trimmed")
    func typedWins() {
        let name = GuestName.resolve(typed: "  Ana ", remembered: "Ben", deviceName: "iPhone")
        #expect(name == "Ana")
    }

    @Test(
        "a typed name of blanks only counts as nothing typed",
        arguments: [("   ", "Ben", "Ben"), ("\n\t", nil, "iPhone")] as [(String, String?, String)])
    func whitespaceOnly(typed: String, remembered: String?, expected: String) {
        let name = GuestName.resolve(typed: typed, remembered: remembered, deviceName: "iPhone")
        #expect(name == expected)
    }

    @Test("nothing typed sends the name remembered from last time")
    func emptyWithRemembered() {
        #expect(GuestName.resolve(typed: "", remembered: "Ben", deviceName: "iPhone") == "Ben")
        #expect(GuestName.resolve(typed: nil, remembered: " Ben ", deviceName: "iPhone") == "Ben")
    }

    @Test("nothing typed and nothing remembered sends the device's name")
    func emptyWithNone() {
        #expect(GuestName.resolve(typed: "", remembered: nil, deviceName: "iPhone") == "iPhone")
        #expect(GuestName.resolve(typed: nil, remembered: "  ", deviceName: "iPhone") == "iPhone")
    }

    // The door's own fallback, reached only when the device reports a blank name too.
    @Test("a blank device name sends the door's own word, never an empty string")
    func blankEverywhere() {
        #expect(GuestName.resolve(typed: " ", remembered: nil, deviceName: " ") == "Guest")
    }

    @Test("over 64 is capped to the first 64, at 64 and below it is kept whole")
    func overTheLimit() {
        let x = { (count: Int) in String(repeating: "x", count: count) }
        #expect(GuestName.resolve(typed: x(70), remembered: nil, deviceName: "iPhone") == x(64))
        #expect(GuestName.resolve(typed: x(65), remembered: nil, deviceName: "iPhone") == x(64))
        #expect(GuestName.resolve(typed: x(64), remembered: nil, deviceName: "iPhone") == x(64))
        #expect(GuestName.resolve(typed: x(63), remembered: nil, deviceName: "iPhone") == x(63))
    }

    // The door counts code points; a thumbs-up with a skin tone is two of them and one character.
    @Test("the cap counts code points and never cuts a character in half")
    func capCountsScalars() {
        let thumb = "\u{1F44D}\u{1F3FD}"
        let x63 = String(repeating: "x", count: 63)
        let x62 = String(repeating: "x", count: 62)
        #expect(GuestName.capped(x63 + thumb) == x63)
        #expect(GuestName.capped(x62 + thumb) == x62 + thumb)
        #expect(GuestName.capped(x62 + thumb).unicodeScalars.count == GuestName.limit)
    }

    // A cut landing just after a space must not send that space.
    @Test("a cap that ends on a space is trimmed again")
    func capThenTrim() {
        let x63 = String(repeating: "x", count: 63)
        let name = GuestName.resolve(typed: x63 + " yz", remembered: nil, deviceName: "iPhone")
        #expect(name == x63)
    }
}

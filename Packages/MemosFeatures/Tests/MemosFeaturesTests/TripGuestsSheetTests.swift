import CoreImage
import Foundation
import MemosCore
import Testing
import UIKit

@testable import MemosFeatures

/// Trip Pass on the trip screen: the QR code Invite Guests draws, what the share row hands over,
/// and the words of the Guests list and the inbox.
@MainActor
@Suite("Trip guests sheet")
struct TripGuestsSheetTests {
    static let url = URL(string: "https://door.example.invalid/p/AbC123-xyz_9")!

    @Test("the QR code Invite Guests draws reads back as the issued guest URL")
    func theCodeCarriesTheURL() throws {
        let image = try #require(PassQRCode.image(for: Self.url))
        let picture = try #require(CIImage(image: image))
        let detector = try #require(
            CIDetector(
                ofType: CIDetectorTypeQRCode, context: nil,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let found = detector.features(in: picture).compactMap {
            ($0 as? CIQRCodeFeature)?.messageString
        }
        #expect(found == [Self.url.absoluteString])
    }

    @Test("the share row hands over the guest URL first, and the code beside it")
    func theShareRowCarriesTheURL() {
        let issued = IssuedTripPass(
            pass: TripPass(uid: "p1", label: "Sardinia", expiresAt: Date(), maxDevices: 30),
            url: Self.url)
        let items = InviteShareSheet.items(for: issued)
        #expect(items.first as? URL == Self.url)
        #expect(items.count == 2)
        #expect(items.last is UIImage)
    }

    @Test("a device reads as its name, its platform, its photos and when it was last seen")
    func deviceLine() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let anna = TripPassDevice(
            uid: "d1", displayName: "Anna", platform: .app, firstSeen: now,
            lastSeen: now.addingTimeInterval(-120), uploadsCount: 412)
        let line = TripGuestsText.deviceLine(anna, now: now)
        #expect(line.hasPrefix("Anna · iPhone app · 412 photos · last seen "))
        var revoked = anna
        revoked.revoked = true
        revoked.uploadsCount = 1
        #expect(
            TripGuestsText.deviceLine(revoked, now: now) == "Anna · iPhone app · 1 photo · revoked")
    }

    @Test("End the Pass names how many devices it stops", arguments: [0, 1, 3])
    func endQuestionNamesTheDevices(_ devices: Int) {
        let question = TripGuestsText.endQuestion(devices: devices)
        if devices == 0 {
            #expect(question.contains("Nobody"))
        } else {
            #expect(question.contains("\(devices) device"))
        }
    }

    @Test("Select All from a device picks exactly that device's uploads")
    func selectAllFromADevice() {
        let rows = [
            TripContribution(
                attachmentUid: "a", memoUid: "m", passUid: "p", contributorName: "Anna",
                deviceUid: "d1", createdAt: Date()),
            TripContribution(
                attachmentUid: "b", memoUid: "m", passUid: "p", contributorName: "Ben",
                deviceUid: "d2", createdAt: Date()),
            TripContribution(
                attachmentUid: "c", memoUid: "m", passUid: "p", contributorName: "Anna",
                deviceUid: "d1", createdAt: Date()),
        ]
        #expect(TripGuestsText.devices(in: rows).map(\.1) == ["Anna", "Ben"])
        #expect(TripGuestsText.uploads(from: "d1", in: rows) == ["a", "c"])
    }

    @Test("a moderation that changed everything says nothing; a partial one says how many failed")
    func moderationNote() {
        #expect(TripGuestsText.moderationNote(TripModerationOutcome(applied: 3)) == nil)
        #expect(
            TripGuestsText.moderationNote(TripModerationOutcome(applied: 1, failed: 2))
                == "2 photos could not be changed.")
    }
}

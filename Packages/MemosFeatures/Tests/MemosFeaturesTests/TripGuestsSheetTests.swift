import CoreImage
import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import SwiftUI
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

/// The server behind the Guest Uploads inbox: one pass, `p1`, whose contributions are held here and
/// change as the moderation routes are called, so what the inbox reads back is what a call left.
/// Every moderation call is kept with the uids it carried. A picture's record is not served.
nonisolated private final class GuestInboxServer: ClientTransport, @unchecked Sendable {
    nonisolated struct Call: Equatable {
        let path: String
        let uids: [String]
    }

    private let lock = NSLock()
    private var listed: [(uid: String, day: Int, hidden: Bool)]
    private var sent: [Call] = []

    init(_ listed: [(uid: String, day: Int, hidden: Bool)]) { self.listed = listed }

    var calls: [Call] { lock.withLock { sent } }
    /// While set, a moderation call waits after it is recorded, so a second can be started behind it.
    var holding: Bool {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
    /// While set, a moderation call is recorded and answered 503.
    var refusing: Bool {
        get { lock.withLock { refused } }
        set { lock.withLock { refused = newValue } }
    }
    private var held = false
    private var refused = false

    private static let pass =
        #"{"uid":"p1","collectionUid":"t1","label":"Sardinia","scope":"contribute","#
        + #""state":"active","expiresAt":"2026-12-01T00:00:00Z","maxDevices":30,"#
        + #""notes":null,"version":1,"revokedAt":null,"revokedVersion":null,"#
        + #""deviceCount":1,"createdBy":"me","createdAt":"2026-10-01T00:00:00Z","#
        + #""updatedAt":"2026-10-01T00:00:00Z"}"#

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        switch operationID {
        case "list_passes_api_collections__uid__passes_get":
            return (response, HTTPBody("[\(Self.pass)]"))
        case "list_contributions_api_passes__uid__contributions_get":
            let rows = lock.withLock { listed }.map { row in
                #"{"attachmentUid":"\#(row.uid)","memoUid":"m1","contributorName":"Anna","#
                    + #""deviceUid":"d1","caption":null,"hidden":\#(row.hidden),"#
                    + #""createdAt":"2026-10-\#(String(format: "%02d", row.day))T00:00:00Z"}"#
            }
            return (response, HTTPBody("[\(rows.joined(separator: ","))]"))
        case "hide_contributions_api_passes__uid__contributions_hide_post",
            "unhide_contributions_api_passes__uid__contributions_unhide_post",
            "remove_contributions_api_passes__uid__contributions_remove_post":
            let data = try await Data(collecting: body ?? HTTPBody(), upTo: 1 << 20)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let uids = object?["attachmentUids"] as? [String] ?? []
            let path = request.path ?? ""
            let outcome =
                path.hasSuffix("/hide")
                ? "hidden" : path.hasSuffix("/unhide") ? "unhidden" : "removed"
            lock.withLock { sent.append(Call(path: path, uids: uids)) }
            while holding { try await Task.sleep(for: .milliseconds(1)) }
            if refusing { return (HTTPResponse(status: .serviceUnavailable), nil) }
            lock.withLock {
                switch outcome {
                case "removed": listed.removeAll { uids.contains($0.uid) }
                default:
                    for index in listed.indices where uids.contains(listed[index].uid) {
                        listed[index].hidden = outcome == "hidden"
                    }
                }
            }
            let results = uids.map { #"{"attachmentUid":"\#($0)","outcome":"\#(outcome)"}"# }
            return (response, HTTPBody(#"{"results":[\#(results.joined(separator: ","))]}"#))
        default:
            return (HTTPResponse(status: .notFound), nil)
        }
    }
}

/// The Guest Uploads inbox's rows (MEMNG-1159): what a row says, where a tap on it goes, and what
/// its swipe and its context menu do — through the REAL store over the generated client.
@MainActor
@Suite("Guest Uploads rows", .timeLimit(.minutes(1)))
struct GuestUploadsRowTests {
    private static let base = URL(string: "https://memos.example.invalid")!
    private static let uploaded = Date(timeIntervalSince1970: 1_790_000_000)
    private static let taken = Date(timeIntervalSince1970: 1_780_000_000)

    private static func access(_ server: GuestInboxServer) -> CollectionsAccess {
        CollectionsAccess(
            handle: SessionHandle(
                client: APIClientFactory.make(
                    configuration: ServerConfiguration(baseURL: base),
                    token: { "memos_pat_guests" }, transport: server),
                generation: 1),
            baseURL: base)
    }

    private static func contribution(_ uid: String, name: String? = "Anna", hidden: Bool = false)
        -> TripContribution
    {
        TripContribution(
            attachmentUid: uid, memoUid: "m1", passUid: "p1", contributorName: name,
            deviceUid: "d1", hidden: hidden, createdAt: uploaded)
    }

    private static func picture(_ uid: String, mime: String, taken: Date?) -> MemoAttachment {
        let signed = "https://memos.example.invalid/api/attachments/\(uid)"
        return MemoAttachment(
            uid: uid, mime: mime, status: .ready, width: 4000, height: 3000,
            captureInstant: taken, mine: true,
            thumbnailURL: URL(string: "\(signed)/thumb?sig=1"),
            previewURL: URL(string: "\(signed)/mobile?sig=1"),
            webURL: URL(string: "\(signed)/web?sig=1"),
            posterURL: URL(string: "\(signed)/poster?sig=1"),
            downloadURL: URL(string: "\(signed)/original"), memoUID: "m1")
    }

    @Test("a row reads its file's name, when it was taken, its kind and who brought it")
    func aRowCarriesTheFourFacts() {
        let video = GuestUploadRow(
            Self.contribution("a1"),
            picture: Self.picture("a1", mime: "video/quicktime", taken: Self.taken),
            filename: "IMG_0412.MOV")
        #expect(video.filename == "IMG_0412.MOV")
        #expect(video.takenAt == Self.taken)
        #expect(video.uploadedAt == Self.uploaded)
        #expect(video.kind == .video)
        #expect(video.contributor == "Anna")
        #expect(video.byline == "Video · Anna")

        let photo = GuestUploadRow(
            Self.contribution("a2", name: nil),
            picture: Self.picture("a2", mime: "image/heic", taken: nil), filename: nil)
        #expect(photo.kind == .image)
        #expect(photo.filename == nil)
        #expect(photo.takenAt == nil)
        #expect(photo.byline == "Photo · A guest")
    }

    @Test("a row whose picture is not read yet says who brought it and when, and invents no name")
    func aRowWithoutItsPicture() {
        let row = GuestUploadRow(Self.contribution("a1", hidden: true), picture: nil, filename: nil)
        #expect(row.filename == nil)
        #expect(row.kind == nil)
        #expect(row.takenAt == nil)
        #expect(row.uploadedAt == Self.uploaded)
        #expect(row.hidden)
        #expect(row.byline == "Anna")
    }

    @Test("the capture time leads and the upload follows; without one the upload stands alone")
    func timeLines() {
        let now = Self.uploaded.addingTimeInterval(7_200)
        let taken = GuestUploadRow(
            Self.contribution("a1"),
            picture: Self.picture("a1", mime: "image/jpeg", taken: Self.taken), filename: nil)
        let lines = TripGuestsText.timeLines(taken, now: now)
        #expect(lines.primary.hasPrefix("Taken "))
        #expect(lines.secondary?.hasPrefix("Uploaded ") == true)
        #expect(lines.secondary?.hasSuffix(" ago") == true)

        let undated = GuestUploadRow(
            Self.contribution("a2"),
            picture: Self.picture("a2", mime: "image/jpeg", taken: nil), filename: nil)
        let alone = TripGuestsText.timeLines(undated, now: now)
        #expect(alone.primary.hasPrefix("Uploaded "))
        #expect(alone.secondary == nil)
    }

    @Test("tapping a row opens the viewer on that picture, at a derived tier, never the original")
    func aTapOpensTheViewer() throws {
        let rows = [Self.contribution("a1"), Self.contribution("a2"), Self.contribution("a3")]
        let read: [String: MemoAttachment] = [
            "a1": Self.picture("a1", mime: "image/jpeg", taken: nil),
            "a2": Self.picture("a2", mime: "video/mp4", taken: nil),
        ]
        let selection = try #require(
            GuestUploadsViewer.viewer(for: rows, pictures: { read[$0] }, startingAt: "a2"))
        #expect(selection.startPage.id == "a2")
        #expect(selection.startPage.kind == .video)
        // Only what has been read can be a page; the unread a3 is not one.
        #expect(selection.pages.map(\.id) == ["a1", "a2"])
        for page in selection.pages {
            #expect(page.stillURL?.path.hasSuffix("/original") == false)
            #expect(page.playbackURL?.path.hasSuffix("/original") != true)
            #expect(page.stillURL != page.attachment.downloadURL)
            // The inbox is not where a guest's picture is deleted from: Remove is.
            #expect(!selection.deletable(page.attachment))
        }
        #expect(
            GuestUploadsViewer.viewer(for: rows, pictures: { read[$0] }, startingAt: "a3") == nil)
    }

    @Test("a row offers Hide, or Show Again on a hidden one, and Remove")
    func rowActions() {
        #expect(GuestUploadsModeration.rowActions(hidden: false) == [.hide, .remove])
        #expect(GuestUploadsModeration.rowActions(hidden: true) == [.unhide, .remove])
    }

    @Test("a row's Hide and Remove go out as the moderation Select sends, and are read back")
    func aRowModeratesThroughTheStore() async throws {
        let server = GuestInboxServer([("a1", 5, false), ("a2", 3, false)])
        let access = Self.access(server)
        let store = TripGuestStore(collectionUid: "t1")
        await store.loadContributions(using: access.handle)
        let row = try #require(store.contributions?.first)
        #expect(row.attachmentUid == "a1")

        let hidden = await GuestUploadsModeration.run(
            .hide, [row.attachmentUid], store: store, handle: access.handle)
        #expect(hidden == GuestUploadsModeration.Landed(note: nil, changed: true))
        #expect(
            server.calls == [.init(path: "/api/passes/p1/contributions/hide", uids: ["a1"])])
        // Hidden stays listed, as Hidden.
        #expect(store.contributions?.map(\.attachmentUid) == ["a1", "a2"])
        #expect(store.contributions?.first?.hidden == true)

        let removed = await GuestUploadsModeration.run(
            .remove, ["a1"], store: store, handle: access.handle)
        #expect(removed.changed)
        #expect(
            server.calls.last == .init(path: "/api/passes/p1/contributions/remove", uids: ["a1"]))
        // Removed leaves the list.
        #expect(store.contributions?.map(\.attachmentUid) == ["a2"])
    }

    @Test("a refused moderation says why, keeps the selection, and still has the grid read again")
    func aRefusedModerationIsNotSwallowed() async throws {
        let server = GuestInboxServer([("a1", 5, false)])
        let access = Self.access(server)
        let store = TripGuestStore(collectionUid: "t1")
        await store.loadContributions(using: access.handle)
        server.refusing = true
        let landed = await GuestUploadsModeration.run(
            .hide, ["a1"], store: store, handle: access.handle)
        #expect(server.calls.count == 1)
        #expect(!landed.succeeded)
        #expect(landed.changed)
        #expect(landed.note != nil)
        #expect(store.contributions?.first?.hidden == false)
    }

    @Test("a second row action while one is out joins it if it is the same, else is refused")
    func overlappingRowActionsAreOneRequest() async throws {
        let server = GuestInboxServer([("a1", 5, false), ("a2", 3, false)])
        let access = Self.access(server)
        let store = TripGuestStore(collectionUid: "t1")
        await store.loadContributions(using: access.handle)
        server.holding = true
        let first = Task {
            await GuestUploadsModeration.run(.hide, ["a1"], store: store, handle: access.handle)
        }
        while server.calls.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        let same = Task {
            await GuestUploadsModeration.run(.hide, ["a1"], store: store, handle: access.handle)
        }
        // The same Hide gets its turn on this actor, finds the first one out and joins it.
        for _ in 0..<5 { await Task.yield() }
        let other = await GuestUploadsModeration.run(
            .remove, ["a2"], store: store, handle: access.handle)
        server.holding = false
        let (one, two) = (await first.value, await same.value)
        #expect(server.calls == [.init(path: "/api/passes/p1/contributions/hide", uids: ["a1"])])
        #expect(one.succeeded && two.succeeded)
        #expect(!other.succeeded)
        #expect(other.note == TripGuestStore.Failure.busy.errorDescription)
        #expect(store.contributions?.map(\.attachmentUid) == ["a1", "a2"])
    }

    @Test("the inbox says what happens to a guest's pictures, under the rows")
    func theFooterExplainsTheModel() async {
        let server = GuestInboxServer([("a1", 5, false)])
        let access = Self.access(server)
        let store = TripGuestStore(collectionUid: "t1")
        let sentence =
            "Guest pictures appear in the trip right away as Just us. "
            + "Hide or remove the ones you do not want."
        let (rows, footer) = await PressProbe.withScreen(
            NavigationStack {
                GuestUploadsInbox(store: store, access: { access }, onModerated: {})
            },
            height: 800
        ) { screen -> (Bool, Bool) in
            let rows = await TripProbe.settled(seconds: 5) { screen.says("Anna") }
            return (rows, screen.says(sentence))
        }
        #expect(rows, "the inbox never listed the guest's picture")
        #expect(footer)
    }
}

import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// The Library tab's grid outside a trip (MEMNG-919): another member's pictures are there only to
/// fill out a trip, so the store the tab opens with is on "Captured by me", and its first page is
/// read with `mine=true` through the real generated client over a scripted transport.
///
/// An extension of the cards' suite: the Collections cards and the Library tab are the two places
/// outside a trip that the rule narrows, and one scope runs both.
extension CollectionCardsTests {
    @Test("the Library's grid starts on Captured by me and Public: mine=true, visibility=PUBLIC")
    func theGridStartsOnMine() async {
        let session = CollectionsWire.signedOutSession(CollectionsTransport())
        let library = MediaLibraryView.makeLibrary(order: .newestFirst, session: session)
        #expect(library.mine, "the grid opened on everyone's pictures")
        // A Just us picture is seen only inside its trip or album (MEMNG-933).
        #expect(library.visibility == .public, "the grid opened on \(library.visibility)")
        let wire = TripWire()
        await library.refresh(using: wire.access.handle, baseURL: TripWire.baseURL)
        let reads = wire.transport.listReads
        #expect(reads.count == 1, "\(reads)")
        #expect(reads.first?["mine"] == "true", "an everyone read: \(reads)")
        #expect(reads.first?["visibility"] == "PUBLIC", "a Just us picture was read: \(reads)")
        // Any, chosen on purpose, widens it: the parameter is absent.
        library.setVisibility(.any)
        await library.refresh(using: wire.access.handle, baseURL: TripWire.baseURL)
        #expect(wire.transport.listReads.last?["visibility"] == nil, "\(wire.transport.listReads)")
        // Unchecked on purpose, the grid is everyone's again.
        library.setMine(false)
        await library.refresh(using: wire.access.handle, baseURL: TripWire.baseURL)
        #expect(wire.transport.listReads.last?["mine"] == nil, "\(wire.transport.listReads)")
    }
}

/// The Collections root's Tags row (MEMNG-933): a Just us picture is counted and covers a card
/// only inside its trip or album, so the tag counts, the Favorites count and every card's cover
/// are read with `visibility=PUBLIC`, through the stores the root builds and the real generated
/// client over a scripted transport.
extension CollectionCardsTests {
    @Test("the Tags row's counts and covers, Favorites' included, read visibility=PUBLIC")
    func theTagsRowReadsPublic() async {
        let wire = CollectionsWire()
        wire.transport.answerTags(#"[{"name":"lisbon","count":2}]"#)
        wire.transport.answerPictureTags(#"[{"name":"favorites","count":1}]"#)
        let session = CollectionsWire.signedOutSession(wire.transport)
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_trips")
        // Signed in, so the stores' session fences let the reads out.
        guard let handle = session.activeHandle else {
            Issue.record("precondition: signed in")
            return
        }
        let baseURL = CollectionsWire.baseURL

        let tags = CollectionsRootView.makeTags(session: session)
        let pictureTags = CollectionsRootView.makePictureTags(session: session)
        let covers = CollectionsRootView.makeTagCovers(session: session)
        #expect(tags.visibility == .public && pictureTags.visibility == .public)
        #expect(covers.visibility == .public)
        await tags.load(for: .all, using: handle)
        await pictureTags.load(for: .all, using: handle)
        await covers.load(.tag("lisbon"), using: handle, baseURL: baseURL)
        await covers.load(.pictureTag("favorites"), using: handle, baseURL: baseURL)

        let sent = wire.transport.sent
        let reads = [
            sent.filter { $0.hasPrefix("attachment_tags_api") },
            sent.filter { $0.hasPrefix("attachment_picture_tags_api") },
            sent.filter { $0.hasPrefix("list_attachments_api_attachments_get") },
        ]
        #expect(reads.map(\.count) == [1, 1, 2], "\(sent)")
        for read in reads.joined() {
            #expect(read.contains("visibility=PUBLIC"), "a Just us read: \(read)")
        }
    }
}

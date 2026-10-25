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
    @Test("the Library's grid starts on Captured by me, and its first page reads mine=true")
    func theGridStartsOnMine() async {
        let session = CollectionsWire.signedOutSession(CollectionsTransport())
        let library = MediaLibraryView.makeLibrary(order: .newestFirst, session: session)
        #expect(library.mine, "the grid opened on everyone's pictures")
        let wire = TripWire()
        await library.refresh(using: wire.access.handle, baseURL: TripWire.baseURL)
        let reads = wire.transport.listReads
        #expect(reads.count == 1, "\(reads)")
        #expect(reads.first?["mine"] == "true", "an everyone read: \(reads)")
        // Unchecked on purpose, the grid is everyone's again.
        library.setMine(false)
        await library.refresh(using: wire.access.handle, baseURL: TripWire.baseURL)
        #expect(wire.transport.listReads.last?["mine"] == nil, "\(wire.transport.listReads)")
    }
}

import Foundation
import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// The cache's one control since the Settings screen went: the LAST row of the Library's ⋯ menu,
/// labelled with the size, unavailable when there is nothing to clear, and emptying BOTH halves.
@MainActor
@Suite("Clearing the media cache from the Library menu")
struct LibraryClearCacheTests {
    private struct Harness: View {
        @State var order = MediaLibraryOrder.newestFirst
        @State var filter = MediaLibraryFilter.all
        @State var tag: String?
        @State var usage: MediaCacheMaintenance.Usage

        var body: some View {
            List {
                LibraryOptionsMenuContent(
                    order: $order, filter: $filter, tag: $tag,
                    tagRows: MediaLibraryPresentation.tagRows([], selected: nil),
                    cache: $usage
                )
            }
        }
    }

    private let used = MediaCacheMaintenance.Usage(usedBytes: 412 << 20, capacityBytes: 1 << 30)
    private let empty = MediaCacheMaintenance.Usage(usedBytes: 0, capacityBytes: 1 << 30)

    @Test("the menu's last row is the clear button, and it says how much it would clear")
    func theLastRowIsTheClearButton() throws {
        let title = ClearMediaCacheItem.title(for: used)
        #expect(title.contains(MediaCacheMaintenance.summary(used)))

        let labels = ScreenProbe.labels(of: Harness(tag: nil, usage: used))

        // The control: the pickers above it were drawn, so the order read below is real.
        #expect(labels.contains("Videos"), "the menu's rows were not drawn: \(labels)")
        let clear = try #require(labels.lastIndex(of: title), "no clear button: \(labels)")
        let pickers = ["Sort by Newest First", "Videos", "All tags"].compactMap {
            labels.firstIndex(of: $0)
        }
        #expect(pickers.count == 3, "a picker row is missing: \(labels)")
        #expect(pickers.allSatisfy { $0 < clear }, "the clear button is not last: \(labels)")
    }

    @Test("with nothing to clear the button is there and cannot be pressed")
    func anEmptyCacheCannotBeCleared() {
        let refused = PressProbe.withElement(
            labelled: ClearMediaCacheItem.title(for: empty),
            in: ClearMediaCacheItem(usage: .constant(empty))
        ) { $0?.accessibilityTraits.contains(.notEnabled) ?? false }

        #expect(refused, "an empty cache offered a Clear button that does something")
    }

    @Test("pressing it empties both halves of the cache and reads the size again")
    func pressingEmptiesBothHalves() throws {
        let cache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 0, diskPath: nil)
        let url = try #require(URL(string: "https://memos.example.invalid/api/attachments/x/thumb"))
        let request = URLRequest(url: url)
        let response = try #require(
            HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png"]
            )
        )
        let png = MediaFixture.png(.red, side: 4)
        cache.storeCachedResponse(CachedURLResponse(response: response, data: png), for: request)
        let decoded = MediaImageStore(countLimit: 8, totalCostLimit: 1 << 20)
        let image = try #require(UIImage(data: png))
        let key = MediaImageKey(uid: "x", tier: "thumb")
        decoded.store(image, forKey: key, generation: decoded.generation)
        let shown = Held(usage: used)
        let binding = Binding(get: { shown.usage }, set: { shown.usage = $0 })

        let pressed = PressProbe.withElement(
            labelled: ClearMediaCacheItem.title(for: used),
            in: ClearMediaCacheItem(usage: binding, cache: cache, decoded: decoded)
        ) { $0?.accessibilityActivate() ?? false }

        #expect(pressed, "the clear button refused an activation")
        #expect(cache.cachedResponse(for: request) == nil)
        #expect(decoded.image(forKey: key) == nil)
        #expect(shown.usage == MediaCacheClearing.usage(of: cache), "the size was not read again")
        #expect(shown.usage != used, "the label still shows the size from before the clear")
    }

    private final class Held {
        var usage: MediaCacheMaintenance.Usage
        init(usage: MediaCacheMaintenance.Usage) { self.usage = usage }
    }
}

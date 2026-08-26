import Foundation
import MemosAPI

/// One hashtag the account can see, and how many memos carry it.
///
/// `GET /api/tags` answers with every tag and its count, unwindowed and already deduplicated
/// (memos-ng `app/routers/memos.py`). What a surface does with that — which ones to show, in what
/// order — is a presentation decision and belongs to the view that draws them, not here.
public struct MemoTag: Identifiable, Equatable, Sendable {
    /// The tag WITHOUT its hash, exactly as the server stores it and as `MemoQuery.tags` sends it.
    public let name: String
    public let count: Int

    public var id: String { name }

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

extension MemoTag {
    public init(_ generated: Components.Schemas.TagCount) {
        self.init(name: generated.name, count: generated.count)
    }
}

import Foundation
import MarkdownUI
import MemosCore
import SwiftUI
import Testing

@testable import MemosFeatures

/// The backstop, on the production render path.
///
/// `MemoMarkdownSource.prepare` models how cmark-gfm decides block structure. Three review rounds
/// have now found spellings that model missed, each of them a live `javascript:` destination in
/// front of a reader. These tests are about the OTHER layer: what happens when a live unsafe link
/// reaches the renderer anyway, which is the only thing a future divergence can do.
@MainActor
@Suite("the render-time backstop")
struct MarkdownRenderGuardTests {
    /// A definition smuggled past the source layer by one of the spellings the review found: a tab
    /// after the list marker. Whether or not the source layer catches this spelling today, nothing
    /// it resolves may be something the app will open.
    static let smuggledByATab = "-\t[evil]: javascript:alert(1)\n\n[click][evil]"

    @Test("nothing the renderer resolves out of a smuggled definition is opened")
    func smuggledDestinationsAreNotOpenable() {
        let opened = ProductionMarkdownProjection.destinations(in: Self.smuggledByATab)
            .filter { MemoRenderPolicy.mayOpen(destination: $0) }
        #expect(opened.isEmpty, "the app would open \(opened)")
    }

    /// With the source layer deliberately out of the way: the renderer DOES resolve a
    /// `javascript:` destination when nothing has prepared the text, and the seam refuses it.
    /// This is the assertion that stays true no matter what the scanner learns to catch.
    @Test("a live unsafe link that reached the renderer is refused at the seam")
    func aLiveUnsafeLinkIsRefused() {
        let rendered = MarkdownContent("[click](javascript:alert(1))").renderMarkdown()
        let resolved = ProductionMarkdownProjection.destinations(ofRendered: rendered)
        #expect(
            resolved.contains { $0.hasPrefix("javascript:") },
            "the renderer did not resolve the link at all: \(rendered) -> \(resolved)"
        )
        #expect(
            resolved.allSatisfy { !MemoRenderPolicy.mayOpen(destination: $0) },
            "the seam would open \(resolved)"
        )
    }

    /// The image half. `AsyncImage` is never built, so there is no request to make: the provider
    /// the view installs answers with nothing at all.
    @Test("the image provider hands back nothing, so nothing is fetched")
    func blockImagesAreRefused() {
        let provider = RefusedImageProvider()
        let url = URL(string: "https://tracker.example/1x1.gif")
        #expect(provider.makeImage(url: url) is EmptyView)
        #expect(provider.makeImage(url: nil) is EmptyView)
    }

    @Test("the inline image provider refuses every URL it is asked for")
    func inlineImagesAreRefused() async throws {
        let provider = RefusedInlineImageProvider()
        let url = try #require(URL(string: "https://tracker.example/1x1.gif"))
        await #expect(throws: RefusedInlineImageProvider.Refused.self) {
            _ = try await provider.image(with: url, label: "shot")
        }
    }
}

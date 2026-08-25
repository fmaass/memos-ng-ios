import Foundation
import MemosCore
import Testing

/// Locates the fixture inside the test bundle. Swift Testing has no test class to hand
/// `Bundle(for:)`, so this token supplies one.
private final class BundleToken {}

/// What is left of the parity gate down here, and why it is only a remainder.
///
/// The gate itself moved to `MarkdownRenderParityTests` in MemosFeaturesTests, where every case is
/// projected out of the renderer the app actually ships. `MarkdownParity.project` is a second,
/// hand-written parser: holding the fixture against it proves that this file agrees with the
/// fixture, and says nothing at all about MarkdownUI — which is the renderer a reader sees. Two
/// suites asserting the same 20 cases against two different parsers would also make the weaker one
/// look like coverage.
///
/// Two cases genuinely cannot be read back out of the shipped renderer, so they stay here. Both
/// are limits of `MarkdownContent.renderHTML()`, not of what the app draws:
///
/// - `raw-html-literal`: cmark's HTML renderer is safe by default since cmark-gfm 0.29 and
///   replaces raw HTML with `<!-- raw HTML omitted -->`. The VIEW keeps it — an inline HTML node
///   renders as its literal characters and an HTML block renders as a paragraph, which is what the
///   SPA's `html: false` produces as well.
/// - `table`: `renderHTML()` rebuilds a cmark document from the block model and renders it with no
///   extension list, so the rows come out without their cell tags (`<tr>tiersizenote</tr>`). The
///   view renders the same block model through `TableView` and loses nothing.
///
/// A projection of that HTML would therefore report divergences no reader ever sees. The block
/// model is the only place left to assert them.
@Suite("markdown parity: what the shipped renderer cannot be asked")
struct MarkdownParityTests {
    static let fixture: MarkdownParityFixture = {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "markdown-parity", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let decoded = try? MarkdownParityFixture.decode(from: data)
        else {
            fatalError("markdown-parity.json is not in the test bundle — check project.yml")
        }
        return decoded
    }()

    @Test("the vendored fixture is schema 1 and has enough cases to be worth anything")
    func fixtureShape() {
        #expect(Self.fixture.schema == 1)
        #expect(Self.fixture.cases.count >= 15)
    }

    @Test(
        "the cases the shipped renderer cannot be asked about still hold",
        arguments: ["raw-html-literal", "table"]
    )
    func unreadableFromHTML(id: String) throws {
        let testCase = try #require(Self.fixture.cases.first { $0.id == id })
        #expect(MarkdownParity.project(testCase.markdown) == testCase.projection, "case \(id)")
    }
}

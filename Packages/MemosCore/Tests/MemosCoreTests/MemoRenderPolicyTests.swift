import Foundation
import MemosCore
import Testing

/// The backstop, tested where it is decided rather than where it is installed.
///
/// This is the rule that does not depend on `MemoMarkdownSource` having modelled cmark-gfm's
/// block structure correctly: whatever reaches the renderer, only these schemes open, and no
/// memo-Markdown image is fetched at all.
@Suite("what a rendered memo may reach out to")
struct MemoRenderPolicyTests {
    @Test(
        "the allowlist is the SPA's, and nothing else opens",
        arguments: [
            ("https", "https://example.com/a?b=1", true),
            ("http", "http://example.com", true),
            ("mailto", "mailto:memo@example.com", true),
            ("uppercase scheme", "HTTPS://example.com", true),
            ("javascript", "javascript:alert(1)", false),
            ("uppercase javascript", "JavaScript:alert(1)", false),
            ("data html", "data:text/html,hi", false),
            ("data image", "data:image/png;base64,iVBOR", false),
            ("vbscript", "vbscript:msgbox(1)", false),
            ("file", "file:///etc/passwd", false),
            ("ftp", "ftp://example.com/f", false),
            ("tel", "tel:+49123", false),
            ("a relative path", "/settings", false),
            ("a bare fragment", "#tag", false),
            ("nothing at all", "", false),
        ]
    )
    func onlyAllowedSchemesOpen(name: String, destination: String, expected: Bool) {
        #expect(MemoRenderPolicy.mayOpen(destination: destination) == expected, "\(name)")
        if let url = URL(string: destination) {
            #expect(MemoRenderPolicy.mayOpen(url) == expected, "\(name) as a URL")
        }
    }

    /// Whitespace around a destination is not a way past the allowlist: a URL built from
    /// `\njavascript:alert(1)` has the same scheme once it is read.
    @Test("padding a destination does not smuggle a scheme past the rule")
    func paddingDoesNotHelp() {
        #expect(!MemoRenderPolicy.mayOpen(destination: " javascript:alert(1)"))
        #expect(!MemoRenderPolicy.mayOpen(destination: "\njavascript:alert(1)"))
        #expect(!MemoRenderPolicy.mayOpen(destination: "\tjavascript:alert(1)"))
        #expect(MemoRenderPolicy.mayOpen(destination: " https://example.com "))
    }

    /// No image written in memo Markdown is ever fetched — the SPA's sanitiser shows none, so an
    /// image that reaches the renderer is a divergence, and the request it would make is the harm.
    @Test("no image in a memo body may be loaded, whatever its URL")
    func noImageIsEverLoaded() {
        #expect(!MemoRenderPolicy.mayLoadImage(from: URL(string: "https://example.com/red.png")))
        #expect(
            !MemoRenderPolicy.mayLoadImage(from: URL(string: "https://tracker.example/1x1.gif"))
        )
        #expect(!MemoRenderPolicy.mayLoadImage(from: nil))
    }
}

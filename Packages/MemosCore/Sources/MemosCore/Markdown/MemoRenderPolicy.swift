import Foundation

/// The last word on what a rendered memo is allowed to reach out to.
///
/// `MemoMarkdownSource.prepare` rewrites the SOURCE so that the renderer never sees an unsafe
/// link in the first place, which is what keeps the app's output identical to the SPA's. That
/// rewrite is a model of how cmark-gfm decides block structure, and a model can be wrong: three
/// rounds of review found four spellings of "a definition sitting where the scanner did not
/// look", each of which put a live `javascript:` destination in front of a reader.
///
/// So the scheme rule is enforced a second time, at the seam where a decision actually becomes an
/// action — opening a URL, fetching an image — where no parser is involved at all. Whatever the
/// source layer missed, a destination that is not `http`, `https` or `mailto` is not opened, and
/// no image in memo Markdown is ever fetched. A future divergence between the scanner and the
/// parser can then cost parity, which is a bug, rather than a live link, which is a hole.
public enum MemoRenderPolicy {
    /// Whether tapping this destination may open it.
    ///
    /// The predicate is `MarkdownInline.isTappableScheme`, the same one the source layer uses and
    /// the same one DOMPurify's `ALLOWED_URI_REGEXP` implements in the SPA — one rule, asked
    /// twice, so the two layers can never drift into disagreeing about what is safe.
    public static func mayOpen(_ url: URL) -> Bool {
        mayOpen(destination: url.absoluteString)
    }

    /// The same decision made about a raw destination string, for the places that have one before
    /// it has been through `URL`.
    public static func mayOpen(destination: String) -> Bool {
        MarkdownInline.isTappableScheme(destination.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether the renderer may fetch an image written in memo Markdown. Never.
    ///
    /// `img` is not in the SPA's sanitiser allowlist, so no image in a memo body is ever shown
    /// there — memo media is attachments, rendered by the app itself. An inline image that
    /// reaches the renderer is therefore always a divergence, and fetching it would send a
    /// request the SPA never sends, to a URL chosen by whoever wrote the memo.
    public static func mayLoadImage(from url: URL?) -> Bool {
        false
    }
}

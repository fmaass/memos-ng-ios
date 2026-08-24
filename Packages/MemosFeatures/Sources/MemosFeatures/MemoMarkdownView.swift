import MarkdownUI
import MemosCore
import SwiftUI

/// Renders a memo body.
///
/// The source is prepared by `MemoMarkdownSource.prepare` first, never handed to the renderer raw:
/// that is where tag-only lines are dropped and where a link the SPA would leave as plain text is
/// turned back into plain text. A general-purpose Markdown renderer will happily make
/// `[x](javascript:…)` tappable, so the safety decision is taken before it ever sees the string.
///
/// And then it is taken AGAIN here, at the seam where it stops being a decision and becomes an
/// action. Preparing the source means modelling how cmark-gfm decides block structure; every
/// review round so far has found another spelling that model missed. `MemoRenderPolicy` closes
/// that class by construction: a destination outside the allowlist is not opened however it was
/// parsed, and no image written in memo Markdown is ever fetched — the SPA shows none either.
///
/// Everything about how it looks lives in `MemoMarkdownTheme` — including the size, which is the
/// platform's body size and grows with the reader's setting from there.
///
/// The soft-break mode is part of the contract, not a preference: the SPA renders with
/// `breaks: true`, so a single newline is a line break there, and the parity fixture pins that
/// (`line one\nline two` is two lines). MarkdownUI's default is `.space`, which silently turns a
/// memo written one thought per line into one run-on paragraph.
struct MemoMarkdownView: View {
    let content: String

    var body: some View {
        Markdown(MemoMarkdownSource.prepare(content))
            .markdownTheme(MemoMarkdownTheme.memo)
            .markdownSoftBreakMode(.lineBreak)
            .markdownImageProvider(.refused)
            .markdownInlineImageProvider(.refused)
            .environment(\.openURL, MemoRenderGuard.openAllowedSchemesOnly)
            .textSelection(.enabled)
    }
}

/// The render-time half of the scheme rule, as the values a `Markdown` view is handed.
enum MemoRenderGuard {
    /// Opens what `MemoRenderPolicy` allows and drops the rest on the floor. `.discarded` is the
    /// SwiftUI way to say "this tap does nothing": no browser, no scheme handler, no other app.
    static let openAllowedSchemesOnly = OpenURLAction { url in
        MemoRenderPolicy.mayOpen(url) ? .systemAction : .discarded
    }
}

/// An image provider that never loads anything.
///
/// Memo media is attachments, drawn by the app; the SPA's sanitiser removes every `img` from
/// rendered Markdown. An inline image reaching the renderer is therefore always a divergence, and
/// the harm is not what it draws but the REQUEST it makes — a URL of the memo author's choosing,
/// fetched the moment a reader opens the memo. Returning nothing means `AsyncImage` is never
/// built, so there is nothing to fetch.
struct RefusedImageProvider: ImageProvider {
    nonisolated func makeImage(url: URL?) -> some View {
        EmptyView()
    }
}

extension ImageProvider where Self == RefusedImageProvider {
    static var refused: Self { .init() }
}

/// The same refusal for an image inside a line of text.
struct RefusedInlineImageProvider: InlineImageProvider {
    struct Refused: Error {}

    nonisolated func image(with url: URL, label: String) async throws -> Image {
        throw Refused()
    }
}

extension InlineImageProvider where Self == RefusedInlineImageProvider {
    static var refused: Self { .init() }
}

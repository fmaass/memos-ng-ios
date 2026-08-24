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
/// Everything about how it looks lives in `MemoMarkdownTheme` — including the size, which is the
/// platform's body size and grows with the reader's setting from there.
struct MemoMarkdownView: View {
    let content: String

    var body: some View {
        Markdown(MemoMarkdownSource.prepare(content))
            .markdownTheme(MemoMarkdownTheme.memo)
            .textSelection(.enabled)
    }
}

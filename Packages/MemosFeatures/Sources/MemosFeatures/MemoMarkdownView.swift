import MarkdownUI
import MemosCore
import SwiftUI

/// Renders a memo body.
///
/// The source is prepared by `MemoMarkdownSource.prepare` first, never handed to the renderer raw:
/// that is where tag-only lines are dropped and where a link the SPA would leave as plain text is
/// turned back into plain text. A general-purpose Markdown renderer will happily make
/// `[x](javascript:…)` tappable, so the safety decision is taken before it ever sees the string.
struct MemoMarkdownView: View {
    let content: String

    var body: some View {
        Markdown(MemoMarkdownSource.prepare(content))
            .markdownTextStyle(\.text) {
                FontSize(16)
            }
            .textSelection(.enabled)
    }
}

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
/// The size comes from a Dynamic Type ROLE resolved to points at render time, never from a
/// literal: MarkdownUI needs a point size, and `@ScaledMetric(relativeTo: .body)` is what turns
/// "body" into the number of points THIS reader's settings ask for.
struct MemoMarkdownView: View {
    let content: String
    @ScaledMetric(relativeTo: .body) private var bodyPointSize =
        MemoMarkdownTheme.baseBodyPointSize

    var body: some View {
        Markdown(MemoMarkdownSource.prepare(content))
            .markdownTheme(MemoMarkdownTheme.memo(bodyPointSize: bodyPointSize))
            .textSelection(.enabled)
    }
}

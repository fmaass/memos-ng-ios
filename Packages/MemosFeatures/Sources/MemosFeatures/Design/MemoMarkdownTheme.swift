import MarkdownUI
import SwiftUI

/// How a memo body is painted, as a value rather than a pile of modifiers on a view.
///
/// It is a value for one reason: a `Theme`'s text styles can be run into an `AttributeContainer`
/// with `_collectAttributes(in:)` — the same call MarkdownUI's own inline renderer makes when it
/// paints a link — so what a link will actually look like is assertable without rendering
/// anything. `DesignTokensTests` uses that to hold links to the accent; before this phase nothing
/// set the colour at all, which is why they came out system blue beside a green icon.
///
/// The body size is the PLATFORM'S body point size and nothing else. MarkdownUI resolves every run
/// through `FontProperties`, whose size is a point value, so the theme has to name one — and the
/// only honest number to name is the one `.body` resolves to at the default text size. The old
/// `FontSize(16)` was a point short of the role and never said why.
///
/// Deliberately NOT scaled here. Measured on the simulator: a memo body at this size renders
/// 20.33pt tall at the default text size and 57.33pt at `.accessibility5` — MarkdownUI's own
/// output already tracks the reader's setting. Feeding it a size that had ALREADY been scaled
/// through `@ScaledMetric` scaled it twice and produced a 161pt line. `DynamicTypeFittingTests`
/// holds both ends of that: it must grow, and it must not grow more than the platform does.
public enum MemoMarkdownTheme {
    /// The point size `.body` resolves to at the default text size. Asserted against
    /// `UIFont.preferredFont(forTextStyle: .body)` rather than trusted as a literal.
    public static let baseBodyPointSize: CGFloat = 17

    public static let memo: Theme =
        Theme()
        .text {
            FontSize(baseBodyPointSize)
        }
        .link {
            ForegroundColor(DesignTokens.accent)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
        }
        .strong {
            FontWeight(.semibold)
        }
}

extension MemoMarkdownTheme {
    /// The attributes MarkdownUI will actually apply to a link, collected through the very call
    /// its inline renderer makes: `AttributedStringInlineRenderer` merges `theme.link` into the
    /// run for a `.link` inline. Exposed as a plain `AttributeContainer` so what a link looks like
    /// can be asserted without a renderer, a screenshot or an import of MarkdownUI in the test.
    public static func linkAttributes() -> AttributeContainer {
        var attributes = AttributeContainer()
        memo.text._collectAttributes(in: &attributes)
        memo.link._collectAttributes(in: &attributes)
        return attributes
    }
}

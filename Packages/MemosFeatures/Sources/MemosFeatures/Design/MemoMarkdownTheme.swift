import MarkdownUI
import SwiftUI

/// How a memo body is painted, as a value rather than a pile of modifiers on a view.
///
/// It is a value for one reason: a `Theme`'s text styles can be run into an `AttributeContainer`
/// with `_collectAttributes(in:)` — the same call MarkdownUI's own inline renderer makes when it
/// paints a link — so what a link and a paragraph will actually look like is assertable without
/// rendering anything. `MemoMarkdownThemeTests` uses that to hold links to the accent and the body
/// to the reader's own text size.
///
/// The size has to be passed IN, and that is the whole Dynamic Type fix. MarkdownUI resolves every
/// run through `FontProperties`, whose environment default is a fixed 17pt system font
/// (`Environment+TextStyle.swift`), and turns it into `Font.system(size:)` — a point size, which
/// does not grow with the reader's setting. Simply deleting the old `FontSize(16)` would have left
/// the body pinned at 17 instead of 16. So the view resolves the `.body` ROLE to points with
/// `@ScaledMetric` and hands the result here; at the largest accessibility size that is roughly
/// 53pt, and every relative size in the theme moves with it.
public enum MemoMarkdownTheme {
    public static func memo(bodyPointSize: CGFloat) -> Theme {
        Theme()
            .text {
                FontSize(bodyPointSize)
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

    /// The point size the `.body` role resolves to at the default text size — the base a
    /// `@ScaledMetric(relativeTo: .body)` scales up and down from.
    public static let baseBodyPointSize: CGFloat = 17
}

extension MemoMarkdownTheme {
    /// The attributes MarkdownUI will actually apply to a link, collected through the very call
    /// its inline renderer makes: `AttributedStringInlineRenderer` merges `theme.link` into the
    /// run for a `.link` inline. Exposed as a plain `AttributeContainer` so what a link looks like
    /// can be asserted without a renderer, a screenshot or an import of MarkdownUI in the test.
    public static func linkAttributes(bodyPointSize: CGFloat) -> AttributeContainer {
        var attributes = AttributeContainer()
        let theme = memo(bodyPointSize: bodyPointSize)
        theme.text._collectAttributes(in: &attributes)
        theme.link._collectAttributes(in: &attributes)
        return attributes
    }
}

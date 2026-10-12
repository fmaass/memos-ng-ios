import SwiftUI

/// The account's picture, or its monogram.
///
/// The monogram is not a placeholder waiting for a picture: an account without an avatar has no
/// picture coming, and an empty grey circle reads as one that failed to load.
///
/// `scale` is a multiple of the shared avatar metric rather than a free size, and it is read
/// through `@ScaledMetric`, so the picture grows with the type size. The toolbar draws one at the
/// metric itself (`AccountToolbarButton`) and the account sheet one at 1.6 times it; the metric is
/// shared because the size of a face is a token, not a number either of them invented.
struct AccountAvatarView: View {
    let image: Image?
    let name: String
    var scale: CGFloat = 1

    @ScaledMetric private var base = DesignTokens.Metric.avatar

    private var side: CGFloat { base * scale }

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                Circle()
                    .fill(DesignTokens.accent.opacity(0.15))
                    .overlay {
                        Text(AccountAvatar.initials(for: name))
                            .font(.system(size: side * 0.42, weight: .semibold))
                            .foregroundStyle(DesignTokens.accent)
                    }
            }
        }
        .frame(width: side, height: side)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}

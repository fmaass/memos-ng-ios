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
    @Environment(\.accountAvatarWitness) private var witness

    private var side: CGFloat { base * scale }

    private var monogram: String { AccountAvatar.initials(for: name) }

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                Circle()
                    .fill(DesignTokens.accent.opacity(0.15))
                    .overlay {
                        Text(monogram)
                            .font(.system(size: side * 0.42, weight: .semibold))
                            .foregroundStyle(DesignTokens.accent)
                            .onChange(of: monogram, initial: true) { witness?.drew(monogram) }
                    }
            }
        }
        .frame(width: side, height: side)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}

/// What the monograms on screen read, for a test to look at.
///
/// The avatar is hidden from VoiceOver — the row or button around it already says whose it is —
/// so the accessibility tree a probe reads has no initials in it, and a site that stopped handing
/// the account's name to the avatar would draw "?" with every probe green (MEMNG-697). The
/// environment rather than a preference, because of where the two avatars sit: one in a list
/// cell, the other in a toolbar item, both hosted by UIKit apart from the screen around them. An
/// answer that has to climb back out of those could go quiet; the environment flows down into
/// both, so a test hands a witness in and reads back what was drawn. Nothing in the app sets one;
/// with none, the avatar records nothing and reads to VoiceOver exactly as before.
final class AccountAvatarWitness {
    /// Every monogram drawn, in the order drawn: one entry when an avatar appears, and another
    /// whenever the name under it changes.
    private(set) var drawn: [String] = []

    func drew(_ monogram: String) { drawn.append(monogram) }
}

extension EnvironmentValues {
    /// Where an avatar reports the monogram it drew; nil, and so silent, outside a test.
    @Entry var accountAvatarWitness: AccountAvatarWitness?
}

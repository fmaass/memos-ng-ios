import Foundation
import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// What the app says when it cannot reach the server: which of the two notices is on screen, and
/// whether the one that carries an action can still be read and pressed at the largest text size.
@MainActor
@Suite("The unreachable-server banner")
struct UnreachableBannerTests {
    /// The narrowest iPhone still sold, less the padding the mount puts either side of the card.
    private static let contentWidth: CGFloat = 393 - 2 * DesignTokens.Space.regular

    /// The longest sentence the session can put in this banner: the classification that names the
    /// host AND a detail, with the suggestion that follows it.
    private static let longest = SessionRestoreFailure.unreachable(
        host: "memos.example.invalid",
        detail: "timed out"
    ).message

    @Test("the notice with the retry wins while the store says the server is out of reach")
    func theUnreachableNoticeWins() {
        let notice = SessionBanner.notice(
            showingUnreachable: true,
            verification: .unverified(Self.longest)
        )
        #expect(notice == .unreachable(Self.longest))
    }

    @Test("and the plain line is what an unconfirmed session shows until then")
    func thePlainLineUntilThen() {
        let notice = SessionBanner.notice(
            showingUnreachable: false,
            verification: .unverified("Can't reach home.")
        )
        #expect(notice == .unverified("Can't reach home."))
    }

    /// The sentence has exactly one source — the session's own — so there is nothing to show for a
    /// session that is not unconfirmed, whatever the flag says. The store only ever raises it under
    /// `.unverified`, and a banner that invented a second sentence would say something the session
    /// does not.
    @Test("a confirmed session says nothing, and neither does the first check of a launch")
    func nothingWithoutASentence() {
        #expect(SessionBanner.notice(showingUnreachable: true, verification: .verifying) == nil)
        #expect(SessionBanner.notice(showingUnreachable: true, verification: .verified) == nil)
        #expect(SessionBanner.notice(showingUnreachable: false, verification: .verified) == nil)
    }

    /// A fitting assertion rather than a render: it fails when the banner would stop growing with
    /// the text size, and when the sentence would be cut short instead of wrapping. Measured at the
    /// width the mount really offers it, because the card fills that width by design and asking it
    /// what it wants with nothing squeezing it answers with the proposal.
    @Test("the banner grows with the text size and still says the whole sentence")
    func theBannerGrowsAndIsNotTruncated() {
        let banner = UnreachableBanner(text: Self.longest, retry: {})
        let width = Self.contentWidth
        let atDefault = LayoutProbe.size(banner, width: width, typeSize: .large)
        let atLargest = LayoutProbe.size(banner, width: width, typeSize: .accessibility5)

        // It grows because it is relative, not because it happened to fit: a banner with a fixed
        // font measures the same at both sizes.
        #expect(
            atLargest.height > atDefault.height,
            "\(atLargest.height)pt at the largest size, \(atDefault.height)pt at the default"
        )
        // And it is tall enough for every line of the sentence at that size. The text inside the
        // card is narrower than the card — padding and the warning glyph — so it needs at least
        // what UIKit needs for the same sentence at the full width, and a banner that truncated
        // to one line would be far short of it.
        let needed = LayoutProbe.textHeight(
            Self.longest,
            style: .footnote,
            category: .accessibilityExtraExtraExtraLarge,
            width: Self.contentWidth
        )
        #expect(atLargest.height >= needed, "\(atLargest.height)pt for \(needed)pt of sentence")
    }

    @Test("pressing retry asks the session to check again")
    func pressingRetryAsksForACheck() async throws {
        let asked = Box(0)

        let pressed = PressProbe.withElement(
            labelled: UnreachableBanner.retryLabel,
            in: UnreachableBanner(text: "Can't reach home.", retry: { asked.value += 1 })
        ) { $0?.accessibilityActivate() ?? false }

        #expect(pressed, "the retry control did not accept an activation")
        // The button hands the check to a task, which runs once the main actor is let go of.
        try await Task.sleep(for: .milliseconds(100))
        #expect(asked.value == 1)
    }
}

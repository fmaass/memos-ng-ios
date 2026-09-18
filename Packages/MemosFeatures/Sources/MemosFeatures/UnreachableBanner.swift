import SwiftUI

/// The "can't reach the server" notice, with the one action that can do something about it.
///
/// A sentence and a closure, and nothing from the environment: `MainTabView` reads `SessionStore`
/// out of the environment and the test bundle cannot build one, so a banner that read the session
/// itself could be neither measured nor pressed by a test. The split is what makes it hostable.
struct UnreachableBanner: View {
    /// The label a screen reader reads on the retry control, so a test can find it by the same
    /// name a person hears.
    static let retryLabel = "Retry"

    let text: String
    let retry: @MainActor () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            // The card every other notice in the app is drawn as, so this one is not a second
            // vocabulary for the same kind of thing. All of it is relative — footnote text, token
            // padding, token radius — which is what lets it grow with the text size.
            NoticeCard(text: text, tone: .warning)
            Button(Self.retryLabel) { Task { await retry() } }
                .font(.footnote.weight(.semibold))
        }
        // Once per appearance rather than per render: a body is re-evaluated whenever anything
        // around it changes, and a screen reader that said the sentence again each time would talk
        // over whatever the person was reading.
        .onAppear { AccessibilityNotification.Announcement(text).post() }
    }
}

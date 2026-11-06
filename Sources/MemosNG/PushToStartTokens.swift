import ActivityKit
import Foundation
import MemosCore
import MemosOutbox

/// Feeds ActivityKit's push-to-start token to the session's registration (MEMNG-946), for the
/// life of the process. It decides nothing: `LiveActivityTokenStore` posts, fences and deletes.
///
/// Each token is handed over with the session generation that is current at the instant it
/// arrives, read on the main actor in the same step — so a token is never posted under a session
/// other than the one it was observed under. A sign-in after the token arrived asks for it again
/// (`resubmit`), because ActivityKit is silent until the token changes.
@MainActor
enum PushToStartTokens {
    /// A development build's push tokens are sandbox tokens.
    static var environment: LiveActivityTokenStore.Environment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }

    static func follow(
        _ store: LiveActivityTokenStore, session: SessionStore
    ) -> Task<Void, Never> {
        Task { @MainActor [weak session, weak store] in
            for await token in Activity<TransferActivityAttributes>.pushToStartTokenUpdates {
                guard let session, let store else { return }
                await store.tokenArrived(token, observedUnder: session.activeHandle?.generation)
            }
        }
    }
}

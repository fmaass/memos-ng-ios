import MemosCore
import SwiftUI

/// Chooses between the timeline and sign-in, and restores a stored credential at launch.
public struct RootView: View {
    @Environment(SessionStore.self) private var session

    public init() {}

    public var body: some View {
        Group {
            switch session.state {
            case .signedIn:
                TimelineView()
            case .signedOut, .signingIn:
                SignInView()
            }
        }
        .task {
            guard session.state.user == nil else { return }
            #if DEBUG
            if let credentials = DebugCredentials.fromEnvironment(
                ProcessInfo.processInfo.environment
            ) {
                await session.signIn(
                    serverAddress: credentials.serverAddress,
                    token: credentials.token
                )
                return
            }
            #endif
            await session.restore()
        }
    }
}

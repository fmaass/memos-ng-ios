import Foundation

#if DEBUG

/// A pair of environment variables that signs a DEBUG build in without typing.
///
/// This exists for one reason: the acceptance run drives a simulator with no keyboard and no way
/// to paste a token. The whole type is inside `#if DEBUG`, so a release build does not merely
/// avoid calling it — it does not contain it.
public struct DebugCredentials: Sendable, Equatable {
    public var serverAddress: String
    public var token: String

    public static let serverKey = "MEMOS_SERVER"
    public static let tokenKey = "MEMOS_PAT"

    public static func fromEnvironment(_ environment: [String: String]) -> DebugCredentials? {
        guard let server = environment[serverKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            let token = environment[tokenKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !server.isEmpty, !token.isEmpty
        else { return nil }
        return DebugCredentials(serverAddress: server, token: token)
    }
}

#endif

import Foundation

/// A pair of environment variables that signs a DEBUG build in without typing.
///
/// This exists for one reason: the acceptance run drives a simulator with no keyboard and no way
/// to paste a token. It is compiled into DEBUG builds only: a release build has no code path
/// that reads a credential out of the environment, and none that could be handed one by a launch
/// argument.
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

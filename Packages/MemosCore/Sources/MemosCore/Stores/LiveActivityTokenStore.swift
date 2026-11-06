import Foundation
import MemosAPI

/// The device's Live Activity push-to-start token, as the server holds it (MEMNG-946).
///
/// ActivityKit hands the app a token it may change at any time; the server needs the current one
/// to start a transfer activity for a capture the app never saw — one the share extension queued
/// while the app was not running. This store is the one place that token reaches the server:
/// `POST /api/devices/live-activity-token` through the generated client, again whenever the token
/// changes, and `DELETE` of the same path when the person signs out.
///
/// Every token is OBSERVED under one session generation and is posted only under that one. A token
/// answer from a previous sign-in is never posted under the next — the request would present the
/// new account's credential for a token watched under the old one — and an answer that lands after
/// the session it was asked under has ended records nothing.
///
/// Two asks for the same token under the same generation are ONE request: the second joins the
/// first. A changed token is its own request; whichever lands, only the token ActivityKit gave last
/// is recorded as registered.
@MainActor
public final class LiveActivityTokenStore {
    /// Which APNs environment the token was issued for — a development build's tokens are
    /// sandbox tokens.
    public enum Environment: Sendable, Equatable {
        case production
        case sandbox
    }

    private let session: () -> SessionHandle?
    private let environment: Environment
    /// The token ActivityKit handed over last, hex in lower case.
    private var latest: String?
    /// What the server holds for this device, and the generation it was posted under.
    private var registered: (token: String, generation: Int)?
    /// The POSTs on the wire, keyed by what they post: a second ask for the same pair joins it.
    private var inFlight: [Key: Task<Bool, Never>] = [:]
    /// Generations a sign-out is retiring: no POST starts for one while its DELETE is out.
    private var retiring: Set<Int> = []

    private struct Key: Hashable {
        let token: String
        let generation: Int
    }

    /// - Parameter session: the client and the generation it belongs to, read as ONE value.
    public init(
        environment: Environment = .production,
        session: @escaping () -> SessionHandle?
    ) {
        self.environment = environment
        self.session = session
    }

    /// The registered token, for a test or a diagnostic.
    public var registeredToken: String? { registered?.token }

    /// The token's hex form, the way the server stores it.
    public nonisolated static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// ActivityKit handed over `token` while the session of `generation` was this device's.
    ///
    /// - Returns: true when the server holds this token for this generation once this returns.
    @discardableResult
    /// Nil while nobody is signed in: the token is kept for the next session's `resubmit`.
    public func tokenArrived(_ token: Data, observedUnder generation: Int?) async -> Bool {
        let hex = Self.hex(token)
        latest = hex
        guard let generation else { return false }
        return await post(hex, under: generation)
    }

    /// The token ActivityKit gave last, posted under the session of `generation` — for a sign-in
    /// that happened after the token arrived. ActivityKit says nothing until the token changes, so
    /// without this a new session would not hold it until then.
    @discardableResult
    public func resubmit(under generation: Int) async -> Bool {
        guard let latest else { return false }
        return await post(latest, under: generation)
    }

    private func post(_ hex: String, under generation: Int) async -> Bool {
        // Asked synchronously, before any await: the generation the token was watched under must
        // still be the session's, or the token is not posted under whoever is signed in now.
        guard let handle = session(), handle.generation == generation,
            !retiring.contains(generation)
        else { return false }
        if let registered, registered.token == hex, registered.generation == generation {
            return true
        }
        let key = Key(token: hex, generation: generation)
        if let joined = inFlight[key] { return await joined.value }
        let body = Components.Schemas.LiveActivityTokenIn(
            environment: environment == .sandbox ? .sandbox : .production, token: hex)
        let client = handle.client
        let task = Task<Bool, Never> {
            do {
                let response = try await client
                    .registerLiveActivityTokenApiDevicesLiveActivityTokenPost(
                        .init(body: .json(body)))
                if case .noContent = response { return true }
                return false
            } catch {
                return false
            }
        }
        inFlight[key] = task
        let accepted = await task.value
        inFlight[key] = nil
        // Judged against the generation that ISSUED the POST, and against the token ActivityKit
        // gave last: an answer that outlived either records nothing.
        guard accepted, session()?.generation == generation, !retiring.contains(generation),
            latest == hex
        else { return false }
        registered = (hex, generation)
        return true
    }

    /// The sign-out's half: DELETE the token registered under `generation`, with the client that
    /// can still present that session's credential. Best effort — the session ends whatever the
    /// answer. A POST still out for that generation is waited for first, so its answer cannot
    /// land after the DELETE and leave the token behind.
    public func unregister(generation: Int, with client: any APIProtocol) async {
        retiring.insert(generation)
        defer { retiring.remove(generation) }
        // A POST the server accepted is a token it holds, recorded or not: the recording is
        // refused while this generation retires, so its token is collected here instead.
        var tokens: [String] = []
        for (key, task) in inFlight where key.generation == generation {
            if await task.value, !tokens.contains(key.token) { tokens.append(key.token) }
        }
        if let registered, registered.generation == generation,
            !tokens.contains(registered.token)
        {
            tokens.append(registered.token)
        }
        if registered?.generation == generation { registered = nil }
        for token in tokens {
            do {
                _ = try await client.unregisterLiveActivityTokenApiDevicesLiveActivityTokenDelete(
                    .init(body: .json(.init(token: token))))
            } catch {
                MemosLog.session.info("the live activity token was not unregistered")
            }
        }
    }
}

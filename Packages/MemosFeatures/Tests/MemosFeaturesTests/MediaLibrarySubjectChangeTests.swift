import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import MemosOutbox
import OpenAPIRuntime
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// Nonisolated because the transport below is: the generated client calls it off the main actor.
private enum SwapWire {
    nonisolated static let whoami = "whoami_api_auth_user_get"
    nonisolated static let listAttachments = "list_attachments_api_attachments_get"
    nonisolated static let attachmentTags = "attachment_tags_api_attachments_tags_get"
    nonisolated static let outgoing = "fabian"
    nonisolated static let incoming = "someone-else"
    /// What every one of the outgoing account's files is named after, so a picture request can be
    /// told apart as one of THEIRS.
    nonisolated static let outgoingPrefix = "outgoing-"
}

/// A server whose answer to "who is this" changes under a credential the device keeps presenting,
/// and which holds every library read made after that change until the test lets it go.
///
/// Held rather than answered, because an answer is the other way the outgoing rows could leave
/// the grid: the incoming account's first page replaces them. With that page still on the wire,
/// the only thing left that can empty the grid is the screen's own reaction to the new subject.
private final class SubjectSwapTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var swapped = false
    private var released = false

    /// From now on the server says the credential belongs to somebody else.
    func swapSubject() {
        lock.withLock { swapped = true }
    }

    /// Lets a held read finish, so nothing is left asleep in the process when the case ends.
    func release() {
        lock.withLock { released = true }
    }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let isSwapped = lock.withLock { swapped }
        switch operationID {
        case SwapWire.whoami:
            let subject = isSwapped ? SwapWire.incoming : SwapWire.outgoing
            return Self.json(
                """
                {"subject":"\(subject)","display_name":"\(subject)","email":null,\
                "role":"user","auth_kind":"oidc"}
                """
            )
        case SwapWire.listAttachments:
            guard isSwapped else {
                let rows = (1...6).map { Self.row("\(SwapWire.outgoingPrefix)\($0)") }
                return Self.json("[\(rows.joined(separator: ","))]")
            }
            while !lock.withLock({ released }) {
                try await Task.sleep(for: .milliseconds(20))
            }
            return Self.json("[\(Self.row("incoming-1"))]")
        case SwapWire.attachmentTags:
            return Self.json("[]")
        default:
            // The health handshake: nothing this case is about, and a plain failure keeps it out.
            return (HTTPResponse(status: .notFound), nil)
        }
    }

    /// One row of `GET /api/attachments`, with real dimensions: the grid solves its rows from
    /// them, so a row without them would put no tile on screen whether or not it was still held.
    private static func row(_ uid: String) -> String {
        """
        {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,\
        "width":1000,"height":800,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
        "renditions":[],"orphan":true,"memoUid":null,\
        "takenAt":"2026-09-26T10:00:00Z","filename":"\(uid).jpg",\
        "thumbnailUrl":"/api/attachments/\(uid)/thumb",\
        "previewUrl":"/api/attachments/\(uid)/mobile",\
        "webUrl":"/api/attachments/\(uid)/web",\
        "posterUrl":"/api/attachments/\(uid)/poster",\
        "downloadUrl":"/api/attachments/\(uid)/download",\
        "printUrl":"/api/attachments/\(uid)/print"}
        """
    }

    private static func json(_ payload: String) -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(payload))
    }
}

/// The picture fetches of every tile on screen, each one refused at once.
///
/// This is how the test sees which rows the grid is drawing. A tile whose picture failed asks
/// again when `MediaRetrySignal` is published, and only a MOUNTED tile hears the signal — so the
/// requests one publication causes name exactly the files on screen at that moment. The scroll's
/// own content size cannot be read instead: under the screen's navigation stack it stays at the
/// stack's padding with six tiles drawn.
private actor MountedTileProbe: MediaTransport {
    private var requested: [String] = []

    /// How many picture requests so far were for one of the outgoing account's files.
    var outgoingFetches: Int {
        requested.count(where: { $0.contains("/\(SwapWire.outgoingPrefix)") })
    }

    func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
    {
        requested.append(request.url?.path() ?? "")
        throw URLError(.timedOut)
    }
}

/// The keychain, in memory.
private final class SwapCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func set(_ value: String, for account: String) async throws {
        lock.withLock { values[account] = value }
    }

    func string(for account: String) async throws -> String? {
        lock.withLock { values[account] }
    }

    func remove(_ account: String) async throws {
        _ = lock.withLock { values.removeValue(forKey: account) }
    }
}

/// MEMNG-411's acceptance, at the level the defect lived at: the Library screen hosted over a real
/// `SessionStore`, populated as one account, then told by a revalidation that the credential is
/// somebody else's.
///
/// `MediaLibraryStore` already empties itself when asked (`MediaLibraryStoreTests`), and asking it
/// from here would prove that again. What only a hosted screen can show is that the screen ASKS:
/// the store is the view's own state, so the tiles it draws are the one place the answer is
/// visible, and they are read through the picture loader every tile fetches through.
///
/// In this suite rather than one of its own because it installs the loader's transport and
/// publishes its retry signal, both process-wide: the suite is serialized, and `.mediaGlobals`
/// keeps every other suite that replaces them from running beside it.
extension MediaImageLoaderTests {
    private func swapSession(_ transport: SubjectSwapTransport) -> SessionStore {
        SessionStore(
            credentials: SwapCredentials(),
            makeClient: { configuration, credential in
                APIClientFactory.make(
                    configuration: configuration,
                    credential: credential,
                    transport: transport
                )
            },
            // Parked: a retry rung firing inside the case would be a question nobody here asked.
            sleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            noticeSleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            // The suite's clock, which the installed picture store is bound to: a new subject
            // rotates it, as the shared one is rotated in the app.
            identity: identity
        )
    }

    /// Lets SwiftUI draw what changed and run the tasks it handed work to.
    private func swapSettle(_ window: UIWindow, turns: Int = 20) async {
        for _ in 0..<turns {
            window.setNeedsLayout()
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Whether the signal this case publishes on is still the one its tiles were drawn watching.
    /// A tile reads `MediaRetrySignal.shared` when its body runs, so a replacement leaves the
    /// case publishing to nobody — and the silence after the swap would then prove nothing.
    private func stillObserved(_ signal: MediaRetrySignal, _ step: String) -> Bool {
        guard MediaRetrySignal.shared === signal else {
            Issue.record("MediaRetrySignal.shared was replaced \(step); this case proves nothing")
            return false
        }
        return true
    }

    @Test("a revalidation that names another account takes A's tiles off before B's page lands")
    func subjectChangeTakesTheOutgoingTilesOff() async {
        let wire = SubjectSwapTransport()
        let probe = MountedTileProbe()
        await withTransport(probe) {
            let session = swapSession(wire)
            await session.enteredForeground()
            await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_swap")
            #expect(session.state.user?.subject == SwapWire.outgoing, "precondition: signed in")

            // Taken before anything is drawn: every tile below reads this one when it mounts.
            let signal = MediaRetrySignal.shared
            let host = UIHostingController(rootView: MediaLibraryView().environment(session))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                wire.release()
                window.isHidden = true
                window.rootViewController = nil
            }

            #expect(
                await eventually(tries: 200) { await probe.outgoingFetches >= 1 },
                "precondition: A's library was read and its tiles put on screen"
            )
            await swapSettle(window)

            // The probe's own control: while A's tiles are on screen, a signal makes them ask
            // again. Without it, silence after the swap would prove nothing.
            guard stillObserved(signal, "before the control") else { return }
            let mounted = await probe.outgoingFetches
            signal.publish()
            #expect(
                await eventually { await probe.outgoingFetches > mounted },
                "precondition: a signal reaches A's tiles while they are on screen"
            )
            await swapSettle(window)

            wire.swapSubject()
            await session.retryNow()
            #expect(
                session.state.user?.subject == SwapWire.incoming,
                "precondition: the revalidation established B"
            )
            await swapSettle(window)

            guard stillObserved(signal, "before the swap was probed") else { return }
            let beforeSignal = await probe.outgoingFetches
            signal.publish()
            let askedAgain = await eventually { await probe.outgoingFetches > beforeSignal }
            let asks = await probe.outgoingFetches - beforeSignal
            guard stillObserved(signal, "while the swap was probed") else { return }
            // No page for B has been answered, so no page of B's is what took A's tiles off. That
            // the screen does not ask for B's first page at all is MEMNG-591, not this case.
            #expect(
                !askedAgain,
                "A's tiles are still on screen after B was established: \(asks) asked again"
            )
        }
    }
}

import Foundation

/// How creating the memo ended.
public enum MemoCompletionOutcome: Sendable, Equatable {
    /// The memo exists, exactly once, with every original linked to it, and the server SAID SO by
    /// naming it. This is the ONLY outcome that lets a job — and the originals it holds — leave
    /// the outbox, so it carries the uid rather than an optional: a success nobody can read is not
    /// proof that anything was stored, and deleting someone's only copy of a photo on the strength
    /// of a status code is the one mistake in this file that cannot be undone.
    case created(uid: String)
    /// The server refused to link the uploads and said which ones, per file.
    case unlinkable(UploadsUnlinkableFailure)
    /// Try again later with the same idempotency key: a timeout, a 5xx, a lost connection. Safe by
    /// construction — a replay of a create that DID commit returns the original memo.
    case retry(String)
    /// A refusal that repeating cannot fix. The job is held and surfaced; it is never looped on.
    ///
    /// The second value is which GRANT earned it, when the server is the one that refused. It
    /// rides the return because the hold is written one actor hop away, inside `OutboxRepository`,
    /// and by then nothing else knows which credential this refusal was about. `nil` where the
    /// refusal is this device's own — a memo that could not even be prepared.
    case refused(String, OutboxRefusal?)
}

/// The seam the completion path lives behind.
///
/// One protocol, one implementation: the drain, the recovery rules and every test around them are
/// exercised against a scripted completion, and the wire contract is asserted in exactly one place
/// against the vendored document (see `ContractTests`). That is what makes the hand-rolled
/// transport safe to keep — a schema re-sync that moves any of these fields fails a test rather
/// than silently changing what the outbox sends.
public protocol MemoCompleting: Sendable {
    func create(
        job: UploadJob,
        credentials: OutboxCredentials,
        under authority: SendAuthority
    ) async -> MemoCompletionOutcome
}

/// The completion path, spoken to the strict contract.
///
/// - every attempt carries the job's `idempotency_key`, so a crash between the server's commit and
///   the local delete produces the SAME memo on the retry rather than a second one. A replay
///   answers `201` with the memo the first call stored — the same status as the original create,
///   deliberately: the body is the answer, and a safe retry looks exactly like the success it is
///   repeating;
/// - `201` means the memo exists with all originals linked — the server no longer skips uploads it
///   cannot link, so a success is not ambiguous;
/// - `409 uploads_unlinkable` is read as per-file recovery, and nothing else is;
/// - `503 create_raced` is the server saying nothing was stored under the key: retry it, with the
///   same key, which is exactly what the key is for;
/// - a plain `422` is a validation error, not upload loss: it holds the job rather than starting a
///   re-upload loop.
public struct MemoCompletionEndpoint: MemoCompleting {
    private let http: any OutboxHTTPPerforming

    public init(http: any OutboxHTTPPerforming) {
        self.http = http
    }

    public func create(
        job: UploadJob,
        credentials: OutboxCredentials,
        under authority: SendAuthority
    ) async -> MemoCompletionOutcome {
        let request: URLRequest
        do {
            request = try OutboxRequests.createMemo(
                baseURL: credentials.serverBaseURL,
                token: credentials.token,
                job: job
            )
        } catch {
            return .refused("The memo could not be prepared: \(error.localizedDescription)", nil)
        }

        let response: OutboxHTTPResponse
        do {
            response = try await http.perform(request, under: authority)
        } catch is SendAuthorityWithdrawn {
            // Not a failure of the memo: the account this job belongs to is no longer the one this
            // device is signed in as. Retried, so the next pass under the right authority sends it.
            return .retry("The account this memo belongs to is not signed in any more.")
        } catch {
            return .retry(error.localizedDescription)
        }
        // A 401 earned by a grant that has SINCE been replaced is not a refusal of the one this
        // device is holding, and holding the job on it strands a capture behind a "sign in again"
        // the person has already done. Retried, so the next pass sends under the current grant —
        // and if THAT is refused, its epoch is the current one and the job holds.
        if response.statusCode == 401, !authority.holds() {
            return .retry("The credential this memo was sent under was replaced.")
        }
        return outcome(for: response, issuedUnder: credentials.epoch)
    }

    /// Separated from the call so the status-to-decision mapping is asserted directly.
    ///
    /// - Parameter issuedUnder: the authority epoch the request went out under, stamped onto a
    ///   refusal so the write that acts on it can ask whether that grant still stands. Defaulted
    ///   for the callers that are only asserting the mapping.
    public func outcome(
        for response: OutboxHTTPResponse,
        issuedUnder epoch: Int? = nil
    ) -> MemoCompletionOutcome {
        switch response.statusCode {
        case 200, 201:
            guard let uid = Self.uid(from: response.body) else {
                // A success this client cannot read. The capture STAYS, and the retry carries the
                // same idempotency key — a replay answers with the memo the first call stored, so
                // the next attempt is another chance to read the same answer, not a second memo.
                return .retry("The server's answer could not be read; retrying with the same key.")
            }
            return .created(uid: uid)
        case 409:
            if let failure = UploadsUnlinkableFailure.decode(response.body) {
                return .unlinkable(failure)
            }
            return .refused("The server refused the memo (409).", refusal(409, epoch))
        case 503 where OutboxWire.detailCode(response.body) == Self.racedCode:
            // Concurrent writes raced this keyed create and nothing was stored under the key.
            return .retry("The server raced this memo; retrying with the same key.")
        case 408, 425, 429, 500...599:
            return .retry("The server could not take the memo (\(response.statusCode)).")
        case 401:
            return .refused("Sign in again to finish sending this memo.", refusal(401, epoch))
        default:
            return .refused(
                "The server rejected the memo (\(response.statusCode)).",
                refusal(response.statusCode, epoch)
            )
        }
    }

    private func refusal(_ statusCode: Int, _ epoch: Int?) -> OutboxRefusal {
        OutboxRefusal(statusCode: statusCode, issuedUnder: epoch, what: "this memo")
    }

    /// The one refusal code that means "nothing was stored, repeat the identical request".
    public static let racedCode = "create_raced"

    private static func uid(from body: Data) -> String? {
        struct Created: Decodable {
            var uid: String
        }
        return (try? JSONDecoder().decode(Created.self, from: body))?.uid
    }
}

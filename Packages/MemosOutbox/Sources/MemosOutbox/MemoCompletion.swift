import Foundation

/// How creating the memo ended.
public enum MemoCompletionOutcome: Sendable, Equatable {
    /// The memo exists, exactly once, with every original linked to it. This is the ONLY outcome
    /// that lets a job — and the originals it holds — leave the outbox.
    case created(uid: String?)
    /// The server refused to link the uploads and said which ones, per file.
    case unlinkable(UploadsUnlinkableFailure)
    /// Try again later with the same idempotency key: a timeout, a 5xx, a lost connection. Safe by
    /// construction — a replay of a create that DID commit returns the original memo.
    case retry(String)
    /// A refusal that repeating cannot fix. The job is held and surfaced; it is never looped on.
    case refused(String)
}

/// The seam the completion path lives behind.
///
/// Everything else in this package is finished; the memo create is the one call whose contract —
/// the `idempotency_key` field and the strict `409 uploads_unlinkable` refusal — is backend work
/// that lands alongside this phase. Keeping it behind one protocol means the drain, the recovery
/// rules and every test around them are exercised against a scripted completion, and the day the
/// contract merges exactly one implementation is re-verified against the merged schema.
public protocol MemoCompleting: Sendable {
    func create(job: UploadJob, credentials: OutboxCredentials) async -> MemoCompletionOutcome
}

/// The completion path, spoken to the strict contract.
///
/// - every attempt carries the job's `idempotency_key`, so a crash between the server's commit and
///   the local delete produces the SAME memo on the retry rather than a second one;
/// - `201` means the memo exists with all originals linked — under the strict contract the server
///   no longer skips uploads it cannot link, so a success is not ambiguous;
/// - `409 uploads_unlinkable` is read as per-file recovery, and nothing else is;
/// - a plain `422` is a validation error, not upload loss: it holds the job rather than starting a
///   re-upload loop.
public struct MemoCompletionEndpoint: MemoCompleting {
    private let http: any OutboxHTTPPerforming

    public init(http: any OutboxHTTPPerforming) {
        self.http = http
    }

    public func create(
        job: UploadJob,
        credentials: OutboxCredentials
    ) async -> MemoCompletionOutcome {
        let request: URLRequest
        do {
            request = try OutboxRequests.createMemo(
                baseURL: credentials.serverBaseURL,
                token: credentials.token,
                job: job
            )
        } catch {
            return .refused("The memo could not be prepared: \(error.localizedDescription)")
        }

        let response: OutboxHTTPResponse
        do {
            response = try await http.perform(request)
        } catch {
            return .retry(error.localizedDescription)
        }
        return outcome(for: response)
    }

    /// Separated from the call so the status-to-decision mapping is asserted directly.
    public func outcome(for response: OutboxHTTPResponse) -> MemoCompletionOutcome {
        switch response.statusCode {
        case 200, 201:
            return .created(uid: Self.uid(from: response.body))
        case 409:
            if let failure = UploadsUnlinkableFailure.decode(response.body) {
                return .unlinkable(failure)
            }
            return .refused("The server refused the memo (409).")
        case 408, 425, 429, 500...599:
            return .retry("The server could not take the memo (\(response.statusCode)).")
        case 401:
            return .refused("Sign in again to finish sending this memo.")
        default:
            return .refused("The server rejected the memo (\(response.statusCode)).")
        }
    }

    private static func uid(from body: Data) -> String? {
        struct Created: Decodable {
            var uid: String
        }
        return (try? JSONDecoder().decode(Created.self, from: body))?.uid
    }
}

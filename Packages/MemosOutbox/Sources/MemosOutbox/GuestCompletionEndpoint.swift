import Foundation

/// The guest door's completion: the received uploads of one capture become one batch.
///
/// The door keys the batch on the device and the uid list, so a replay of the same list answers
/// with the batch the first one made — the guest twin of the member create's idempotency key.
/// A capture whose every file the door already held names no upload at all, and then there is
/// nothing to complete: no request is sent, because the bytes are already the pass's.
///
/// Credential refusals go through `OutboxRefusal`, stamped `.guest`, so the door's "this pass has
/// ended" holds the capture exactly as a turned-away token does, judged against the epoch the
/// request presented.
public struct GuestCompletionEndpoint: MemoCompleting {
    private let http: any OutboxHTTPPerforming

    public init(http: any OutboxHTTPPerforming) {
        self.http = http
    }

    public func create(
        job: UploadJob,
        credentials: OutboxCredentials,
        under authority: SendAuthority
    ) async -> MemoCompletionOutcome {
        let uploadUIDs = job.uploadUIDs
        guard !uploadUIDs.isEmpty else {
            // Nothing for the door to link, and nothing lost: it said it holds every byte. The
            // job's own key names this resolution, since no batch was made for it.
            return .created(uid: job.idempotencyKey.uuidString)
        }
        let request: URLRequest
        do {
            request = try OutboxRequests.guestComplete(
                baseURL: credentials.serverBaseURL,
                token: credentials.token,
                uploadUIDs: uploadUIDs,
                caption: job.content.isEmpty ? nil : job.content
            )
        } catch {
            return .refused("The photos could not be prepared: \(error.localizedDescription)", nil)
        }
        let response: OutboxHTTPResponse
        do {
            response = try await http.perform(request, under: authority)
        } catch is SendAuthorityWithdrawn {
            return .retry("The trip pass these photos belong to is not the one on this device.")
        } catch {
            return .retry(error.localizedDescription)
        }
        let refusal = OutboxRefusal(
            statusCode: response.statusCode, issuedUnder: credentials.epoch, what: "these photos",
            kind: .guest
        )
        // A refusal earned by a pass that has SINCE been replaced says nothing about the one this
        // device holds now: the next pass sends under it instead of holding on a stale answer.
        if refusal.concernsCredential, !authority.credentialHolds() {
            return .retry("The trip pass these photos were sent under was replaced.")
        }
        return outcome(for: response, refusal: refusal)
    }

    /// Separated from the call so the status-to-decision mapping is asserted directly.
    func outcome(for response: OutboxHTTPResponse, refusal: OutboxRefusal) -> MemoCompletionOutcome
    {
        if refusal.concernsCredential {
            return .refused("This trip pass has ended.", refusal)
        }
        switch response.statusCode {
        case 200, 201:
            // Only the batch is read: the rest of the receipt is the guest's to be shown, not this
            // decision's, and a field it does not need must not turn a success into a retry.
            struct Batch: Decodable {
                var batchID: String
                enum CodingKeys: String, CodingKey { case batchID = "batch_id" }
            }
            guard let receipt = GuestWire.decode(Batch.self, from: response.body),
                !receipt.batchID.isEmpty
            else {
                // The same uid list goes again and the door answers with the batch it made.
                return .retry("The trip's answer could not be read; sending again.")
            }
            return .created(uid: receipt.batchID)
        case 408, 425, 429, 500...599:
            return .retry(
                "The trip could not take these photos (\(response.statusCode)).",
                retryAfter: WholeOutcome.seconds(inRetryAfter: response.header("Retry-After"))
            )
        default:
            return .refused("The trip refused these photos (\(response.statusCode)).", refusal)
        }
    }
}

import Foundation

/// What one whole-file task's answer means for its file, decided from the answer alone.
///
/// Pure, like the planner: the answer can arrive in a process that was relaunched for it and knows
/// nothing else, so the mapping is asserted against statuses rather than read off a running upload.
public enum WholeOutcome: Sendable, Equatable {
    /// The server holds the whole file.
    case completed(bytesReceived: Int64)
    /// A success whose body said nothing readable about how much arrived. Neither complete nor
    /// short: the server is asked for its offset before anything is sent again.
    case unreadable
    /// Nothing the server said about this file — no answer at all, a timeout, a rate limit, a
    /// server error. Spaced out by `RetrySchedule`; the capture is never dropped.
    case backOff
    /// The server said it is too busy (429, 503). Only this file waits, for as long as the answer's
    /// `Retry-After` said in seconds when it said so. Never a hold: nothing is wrong with the capture.
    case backpressure(retryAfter: TimeInterval?)
    /// The upload session is gone, disagrees about the offset, or kept less than the whole file.
    /// A whole task cannot carry on from where it stopped, so the file is sent again from its first
    /// byte under a fresh session and a new attempt term (`UploadJob.retryingWhole`).
    case retryWhole
    /// A refusal repeating the same request cannot change. What the queue does about it is
    /// `OutboxRefusal`'s decision, made with the epoch the request presented.
    case refused(statusCode: Int)

    /// - Parameters:
    ///   - statusCode: the HTTP status, or nil when the task ended without one — a lost network,
    ///     a cancelled task, a process the person swiped away.
    ///   - bytesReceived: `bytes_received` from the success body, or nil when it could not be read.
    ///   - byteSize: the size of the original the task carried.
    ///   - retryAfter: the answer's `Retry-After` header, as sent.
    public static func classify(
        statusCode: Int?,
        bytesReceived: Int64?,
        byteSize: Int64,
        retryAfter: String? = nil
    ) -> WholeOutcome {
        guard let statusCode else { return .backOff }
        switch statusCode {
        case 200...299:
            guard let bytesReceived else { return .unreadable }
            guard bytesReceived >= byteSize else { return .retryWhole }
            return .completed(bytesReceived: bytesReceived)
        case 404, 409:
            return .retryWhole
        case 429, 503:
            return .backpressure(retryAfter: seconds(inRetryAfter: retryAfter))
        case 408:
            return .backOff
        case 400...499:
            return .refused(statusCode: statusCode)
        default:
            // Server errors, and anything a finished transfer has no business answering with: a
            // status this table does not name is spaced out rather than trusted either way.
            return .backOff
        }
    }

    /// `Retry-After` as delta-seconds, or nil. The HTTP-date form is ignored: it is read against a
    /// server clock this device has no reason to share. So is a value past
    /// `UploadBudget.longestRetryAfter`.
    public static func seconds(inRetryAfter header: String?) -> TimeInterval? {
        guard let raw = header?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
            raw.allSatisfy(\.isASCII), raw.allSatisfy(\.isNumber), let value = Int(raw),
            TimeInterval(value) <= UploadBudget.longestRetryAfter
        else { return nil }
        return TimeInterval(value)
    }
}

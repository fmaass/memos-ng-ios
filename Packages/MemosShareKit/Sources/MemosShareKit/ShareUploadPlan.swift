import Foundation
import MemosOutbox

/// Who sends a share's bytes: the extension itself, with the capture grant the app left beside the
/// licence, or the app on its next foreground or background refresh.
public enum ShareUploadPlan {
    /// What the sheet says when the extension holds no usable grant, so the capture is queued and
    /// nothing more.
    public static let deferredNotice = "Will upload when you open memos"

    /// The credential the extension may upload a capture with — only a grant that is present,
    /// unexpired and stamped with the licence issue the capture was ENQUEUED under. Nil means
    /// enqueue-only.
    public static func credential(
        enqueuedUnder licence: PublishedLicence, grants: CaptureGrantStore?, now: Date = Date()
    ) -> ShareUploadCredential? {
        grants?.uploadCredential(enqueuedUnder: licence, now: now)
    }

    /// What the sheet says before Post about where the bytes will go: the deferred notice when no
    /// grant would be handed to a capture admitted under the licence standing now, else nothing.
    /// Nobody signed in says nothing here — the sheet has its own sentence for that.
    public static func notice(
        licence: PublishedLicence?, grants: CaptureGrantStore?, now: Date = Date()
    ) -> String? {
        guard let licence else { return nil }
        return credential(enqueuedUnder: licence, grants: grants, now: now) == nil
            ? deferredNotice : nil
    }
}

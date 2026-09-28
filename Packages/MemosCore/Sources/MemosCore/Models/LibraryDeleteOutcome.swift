import Foundation

/// What one run of `MediaLibraryStore.delete(_:using:)` did to the selection it was handed
/// (MEMNG-589).
///
/// The run is sequential and stops at the first failure, so every uid it was given lands in
/// exactly one of the three places below, in selection order: gone, the one that failed, or
/// never sent. A screen reporting "N deleted, M failed" reads the counts; a screen pruning its grid
/// reads `deleted`.
public struct LibraryDeleteOutcome: Sendable, Equatable {
    /// The uids the server no longer holds — answered 204, or 404 because somebody got there first.
    public let deleted: [String]
    /// The uid whose delete the server refused or never answered, or nil when none failed. At most
    /// one: the run stops there.
    public let failed: String?
    /// The uids after the stop that were never sent.
    public let notAttempted: [String]
    /// Whether the run stopped because the session it started under is no longer the one this
    /// device is running. Nothing the run did is applied to the rows then.
    public let stoppedForSessionChange: Bool

    public init(
        deleted: [String],
        failed: String?,
        notAttempted: [String],
        stoppedForSessionChange: Bool
    ) {
        self.deleted = deleted
        self.failed = failed
        self.notAttempted = notAttempted
        self.stoppedForSessionChange = stoppedForSessionChange
    }

    public var deletedCount: Int { deleted.count }
    public var failedCount: Int { failed == nil ? 0 : 1 }
    public var notAttemptedCount: Int { notAttempted.count }
}

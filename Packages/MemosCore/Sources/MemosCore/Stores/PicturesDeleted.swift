import Foundation

/// Told of the pictures a delete took: the uids the server confirmed gone — a partial run's
/// included — and the handle that sent them (MEMNG-809).
public typealias PicturesDeleted = @MainActor (Set<String>, SessionHandle) async -> Void

/// Where a store that deletes pictures reports them, asked once when the delete is ISSUED. What
/// it returns is the listener's answer for the identity that sent the delete, so a delete that
/// lands after the session became somebody else's is judged against the identity it was issued
/// under and dropped, never applied to the next account's state.
public typealias PicturesDeletedHook = @MainActor () -> PicturesDeleted

import OSLog

/// The app's own log.
///
/// One subsystem, categories per concern, so a run can be read back with
/// `xcrun simctl spawn booted log show --predicate 'subsystem == "live.discomarder.memosng"'`.
/// Nothing here ever interpolates a credential: the token is the one value that must not reach a
/// log, and `Logger` redacts non-numeric interpolations by default anyway.
public enum MemosLog {
    public static let api = Logger(subsystem: "live.discomarder.memosng", category: "api")
    public static let session = Logger(subsystem: "live.discomarder.memosng", category: "session")
}

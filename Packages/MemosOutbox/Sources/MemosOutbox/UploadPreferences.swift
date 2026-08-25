import Foundation

/// Whether this phone may spend mobile data on a capture, and where that choice is kept.
///
/// The APP GROUP's defaults rather than the app's own. Both processes that touch the queue read
/// from the same container already — the extension writes captures into it, the app drains them —
/// and a preference kept in the app's private domain would be one the extension could never honour
/// if it ever had to. It is also read at the MOMENT OF USE rather than cached: a suite two
/// processes share can be written by the one this drain is not running in.
///
/// The observer is the other half of the setting. A capture held for the wrong network has to move
/// on the very event that makes it permissible, and the toggle IS one of those two events.
public final class UploadPreferences: @unchecked Sendable {
    /// Namespaced by nothing, deliberately: this suite belongs to the outbox alone, and the key is
    /// read on every launch forever — renaming it would silently put everyone back on wifi-only.
    public static let allowsMobileDataKey = "uploadOverMobileData"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var observer: OutboxTrigger?

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The app group's suite, falling back to the app's own when the group is unreachable — the
    /// same degradation the queue itself makes, for the same reason: a missing entitlement must
    /// cost a shared preference, never a capture.
    public static func live(appGroup: String = OutboxDefaults.appGroup) -> UploadPreferences {
        UploadPreferences(defaults: UserDefaults(suiteName: appGroup) ?? .standard)
    }

    /// Off unless someone turned it on: an absent key reads as false, which is the answer that
    /// costs nobody a phone plan.
    public var allowsMobileData: Bool {
        defaults.bool(forKey: Self.allowsMobileDataKey)
    }

    public func onChange(_ handler: @escaping OutboxTrigger) {
        lock.withLock { observer = handler }
    }

    /// Writes the choice down and then lets whatever was waiting on it move, in that order — a
    /// drain that ran before the write landed would read the old answer and hold the job again.
    public func set(_ value: Bool) async {
        defaults.set(value, forKey: Self.allowsMobileDataKey)
        let observer = lock.withLock { self.observer }
        await observer?()
    }
}

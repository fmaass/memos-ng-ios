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
    /// "Send videos over mobile data" (`MobileVideoPolicy`), written by the Settings app beside the
    /// switch above. Read on every launch forever, like it: a rename would silently put everyone
    /// back on the default.
    public static let mobileVideoPolicyKey = "uploadVideoOverMobileData"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var observer: OutboxTrigger?
    private var nowObservers: [UploadPreferenceNotice] = []

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

    /// Only under 200 MB unless someone chose otherwise: an absent key — the pane never opened, a
    /// process that registered no defaults — and a value no build wrote both read as the default.
    public var mobileVideoPolicy: MobileVideoPolicy {
        let stored = defaults.string(forKey: Self.mobileVideoPolicyKey)
        return stored.flatMap(MobileVideoPolicy.init(rawValue:)) ?? .underLimit
    }

    /// Both choices as the policy reads them, read now — the one way the drain asks.
    public var networkPolicy: UploadNetworkPolicy {
        UploadNetworkPolicy(allowsMobileData: allowsMobileData, mobileVideo: mobileVideoPolicy)
    }

    public func onChange(_ handler: @escaping OutboxTrigger) {
        lock.withLock { observer = handler }
    }

    /// The synchronous half: told once after every write, in registration order, before anything
    /// is awaited. What the queue SAYS it is waiting for has to follow the choice in the same
    /// instant, on both paths — the in-app switch and the Settings app's, which writes this suite
    /// itself and is applied to the app's model when the app becomes active, draining through
    /// `appBecameActive` rather than `onChange`.
    public func onChangeNow(_ handler: @escaping UploadPreferenceNotice) {
        lock.withLock { nowObservers.append(handler) }
    }

    /// Writes the choice down and then lets whatever was waiting on it move, in that order — a
    /// drain that ran before the write landed would read the old answer and hold the job again.
    public func set(_ value: Bool) async {
        defaults.set(value, forKey: Self.allowsMobileDataKey)
        await MainActor.run { self.notifyNow() }
        await drainAfterApply()
    }

    /// The asynchronous half alone, for a caller that has already written the choice with `apply`
    /// on the main actor before its first await — so that a process ended inside this drain has
    /// already written every suite it was going to, and is not left with only some of them.
    public func drainAfterApply() async {
        let observer = lock.withLock { self.observer }
        await observer?()
    }

    /// The same write, with only the synchronous notice: the caller starts the drain itself, so
    /// the asynchronous observer would be a second drain racing it.
    @MainActor
    public func apply(_ value: Bool) {
        defaults.set(value, forKey: Self.allowsMobileDataKey)
        notifyNow()
    }

    @MainActor
    private func notifyNow() {
        let told = lock.withLock { nowObservers }
        for notice in told { notice() }
    }
}

/// Told on the main actor, synchronously, after a write of the mobile-data choice.
public typealias UploadPreferenceNotice = @MainActor @Sendable () -> Void

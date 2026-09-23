import Foundation

/// The network this phone is on right now, reduced to the three facts a capture is judged against.
///
/// Three Booleans rather than an interface type, because that is what the decision actually turns
/// on: a personal hotspot is not cellular yet costs the same, and Low Data Mode is a choice the
/// person made about every app on the phone. `NWPath` answers all three; a test states them.
public struct NetworkPath: Sendable, Equatable {
    /// The path runs over the phone's own radio.
    public var usesCellular: Bool
    /// The system says this network costs money — cellular, and a hotspot shared from another
    /// phone, which iOS reports as expensive without reporting it as cellular.
    public var isExpensive: Bool
    /// Low Data Mode, on this network or on the whole phone.
    public var isConstrained: Bool

    public init(usesCellular: Bool, isExpensive: Bool, isConstrained: Bool) {
        self.usesCellular = usesCellular
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    /// The network a capture may always go over: the home wifi.
    public static let wifi = NetworkPath(
        usesCellular: false, isExpensive: false, isConstrained: false
    )

    /// The phone's own radio, at its ordinary cost.
    public static let cellular = NetworkPath(
        usesCellular: true, isExpensive: true, isConstrained: false
    )
}

/// Whether the bytes of a capture may leave this device over the network it is on.
///
/// One rule, in one place, so that every network-producing step of the drain asks the same
/// question. Low Data Mode is not part of the toggle and never becomes it: a person who told the
/// phone to spare their data plan did not mean "except for photos".
public struct UploadNetworkPolicy: Sendable, Equatable {
    /// What the person chose in Settings.
    public var allowsMobileData: Bool

    public init(allowsMobileData: Bool) {
        self.allowsMobileData = allowsMobileData
    }

    public func permits(_ path: NetworkPath) -> Bool {
        // Low Data Mode always waits, whatever the toggle says.
        if path.isConstrained { return false }
        if path.usesCellular || path.isExpensive { return allowsMobileData }
        return true
    }
}

/// How the two things that can unblock a queued capture — the network changing under it, and the
/// person changing their mind — say so.
///
/// Named once, and with its isolation SPELLED OUT rather than defaulted, because the default is
/// not the same on both sides of this package's own boundary: SwiftPM builds this module without
/// `SWIFT_APPROACHABLE_CONCURRENCY`, Xcode builds the test bundle with it (project.yml), and a
/// bare `@Sendable () async -> Void` therefore means `@concurrent` here and
/// `nonisolated(nonsending)` there. A protocol witness has to match exactly, so the type says
/// which rather than letting each module decide.
public typealias OutboxTrigger = @concurrent @Sendable () async -> Void

/// What the phone is on, and the event that says it changed.
///
/// The path is read FRESH at every step rather than snapshotted for a drain: a pass that started
/// on wifi can finish on a train, and the only honest moment to ask is the moment before bytes
/// would move. The change callback is the other half of the same fact — a capture held for the
/// wrong network has to move on the event that makes it right, not on the next launch.
public protocol NetworkPathProviding: Sendable {
    func currentPath() -> NetworkPath
    func onPathChange(_ handler: @escaping OutboxTrigger)
}

/// Whether the queue may spend bytes on the network this phone is on, as a screen can read it.
///
/// The policy answers a Bool; a card has to say WHY. The reason is a value rather than a sentence,
/// because the sentence belongs to the presentation and the fact belongs here.
public enum UploadVerdict: Sendable, Equatable {
    case permitted
    case refused(Reason)

    public enum Reason: Sendable, Equatable {
        /// Low Data Mode, which the toggle never overrides.
        case lowDataMode
        /// The phone's own radio, with mobile data turned off in Settings.
        case cellularWhileMobileDataOff
        /// A network the system calls expensive — a hotspot — with mobile data turned off.
        case expensiveWhileMobileDataOff
    }

    public init(policy: UploadNetworkPolicy, path: NetworkPath) {
        if path.isConstrained {
            self = .refused(.lowDataMode)
        } else if path.usesCellular, !policy.allowsMobileData {
            self = .refused(.cellularWhileMobileDataOff)
        } else if path.isExpensive, !policy.allowsMobileData {
            self = .refused(.expensiveWhileMobileDataOff)
        } else {
            self = .permitted
        }
    }
}

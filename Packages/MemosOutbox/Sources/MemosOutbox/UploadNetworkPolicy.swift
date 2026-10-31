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
    /// There is a path at all. False is the connectivity class's other half: nothing is tried and
    /// no timer is set, because only the path coming back changes anything.
    public var isSatisfied: Bool

    public init(
        usesCellular: Bool, isExpensive: Bool, isConstrained: Bool, isSatisfied: Bool = true
    ) {
        self.usesCellular = usesCellular
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.isSatisfied = isSatisfied
    }

    /// No network at all — airplane mode, a dead zone.
    public static let offline = NetworkPath(
        usesCellular: false, isExpensive: false, isConstrained: false, isSatisfied: false
    )

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
    /// Which videos may go over mobile data when mobile data is allowed at all — the second
    /// choice in Settings, which only ever narrows the first.
    public var mobileVideo: MobileVideoPolicy

    public init(allowsMobileData: Bool, mobileVideo: MobileVideoPolicy = .underLimit) {
        self.allowsMobileData = allowsMobileData
        self.mobileVideo = mobileVideo
    }

    public func permits(_ path: NetworkPath) -> Bool {
        // No path sends nothing, whatever anything else says.
        if !path.isSatisfied { return false }
        // Low Data Mode always waits, whatever the toggle says.
        if path.isConstrained { return false }
        if path.usesCellular || path.isExpensive { return allowsMobileData }
        return true
    }

    /// The largest video a capture may send over mobile data even with mobile data allowed: the
    /// "only under 200 MB" default of the network policy. A capture still owing bytes of a larger
    /// one waits for Wi-Fi, and says so.
    public static let mobileVideoLimit: Int64 = 200_000_000

    /// What this capture waits for on this path, or nil when its bytes may leave now — the
    /// connectivity class (`RetryClass.connectivity`), one reason per cause, and no timer.
    ///
    /// - Parameter job: the capture, for the rule that is about its files; nil asks about the path
    ///   alone, as the pass does before its probe.
    public func waitReason(on path: NetworkPath, for job: UploadJob? = nil) -> WaitReason? {
        if !path.isSatisfied { return .noNetwork }
        if !permits(path) { return .homeNetwork }
        if let job, path.usesCellular || path.isExpensive {
            return job.mobileVideoWait(under: mobileVideo)
        }
        return nil
    }
}

/// Which videos may leave over mobile data once mobile data is allowed: the Settings pane's
/// "Send videos over mobile data". It never widens the mobile-data switch — with that off nothing
/// goes over mobile data, videos included — it only narrows it for videos.
///
/// The raw values are what the Settings app writes into the app group's suite under
/// `UploadPreferences.mobileVideoPolicyKey`, and are read on every launch forever: renaming one
/// would silently put everyone who chose it back on the default.
public enum MobileVideoPolicy: String, Sendable, Equatable, CaseIterable {
    /// Every video goes over mobile data, whatever its size.
    case always
    /// A video over `UploadNetworkPolicy.mobileVideoLimit` waits for Wi-Fi; a smaller one goes.
    /// The default, and what an absent or unreadable value means.
    case underLimit = "under200MB"
    /// No video goes over mobile data; photos still do.
    case never
}

extension UploadJob {
    /// Whether a file of this capture still to be sent is a video over the mobile-data limit.
    /// A file whose bytes the server already holds owes nothing to any network.
    public var owesVideoOverMobileLimit: Bool {
        owedVideos.contains { $0.byteSize > UploadNetworkPolicy.mobileVideoLimit }
    }

    /// Whether a file of this capture still to be sent is a video of any size.
    public var owesVideo: Bool { !owedVideos.isEmpty }

    private var owedVideos: [OutboxFile] {
        files.filter { !$0.isComplete && $0.mime.lowercased().hasPrefix("video/") }
    }

    /// What this capture waits for, on a network that costs money with mobile data allowed, under
    /// the video policy `policy` — or nil when its files may go. A capture the person let go over
    /// mobile data with "Use mobile data for this one" (`videoOverMobileAllowed`) waits for no
    /// video rule, whatever the policy says.
    public func mobileVideoWait(under policy: MobileVideoPolicy) -> WaitReason? {
        if videoOverMobileAllowed == true { return nil }
        switch policy {
        case .always: return nil
        case .underLimit: return owesVideoOverMobileLimit ? .videoOverMobileLimit : nil
        case .never: return owesVideo ? .videoOnWiFiOnly : nil
        }
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
        /// There is no network at all.
        case noPath
        /// Low Data Mode, which the toggle never overrides.
        case lowDataMode
        /// The phone's own radio, with mobile data turned off in Settings.
        case cellularWhileMobileDataOff
        /// A network the system calls expensive — a hotspot — with mobile data turned off.
        case expensiveWhileMobileDataOff
    }

    public init(policy: UploadNetworkPolicy, path: NetworkPath) {
        if !path.isSatisfied {
            self = .refused(.noPath)
        } else if path.isConstrained {
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

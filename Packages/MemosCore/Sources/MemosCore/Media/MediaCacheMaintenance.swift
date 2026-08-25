import Foundation

/// The cache a Storage screen is allowed to measure and empty.
///
/// A protocol rather than `URLCache` directly, for one reason that is not testing convenience: the
/// promise this feature makes is "this button empties the DERIVED media cache and nothing else",
/// and the only way to hold code to a promise about what it does NOT touch is to give it a seam
/// narrow enough that the other things are not reachable through it. Nothing here can delete a
/// queued capture or a quarantined manifest, because nothing here can name a file at all.
///
/// Not `Sendable`: `URLCache` is documented as safe to use from several threads but is not
/// declared `Sendable`, and conforming it to a `Sendable` protocol would be a claim the standard
/// library has not made. The callers are all main-actor screens, so nothing here crosses an
/// isolation boundary.
public protocol DerivedMediaCache: AnyObject {
    /// What the cache is holding on disk, in bytes.
    var currentDiskUsage: Int { get }
    /// The ceiling it was built with, in bytes.
    var diskCapacity: Int { get }
    func removeAllCachedResponses()
}

// `URLCache` already declares all three members with these exact names, so this conformance adds
// no behaviour — it only says that the cache the media layer fetches through is the thing the
// Storage screen measures.
extension URLCache: DerivedMediaCache {}

/// Measuring and emptying the derived media cache — the thumbnails and mobile tiers the timeline
/// has downloaded, and nothing that has not also been downloaded.
///
/// What is deliberately NOT reachable from here: the outbox's queued captures and its quarantine.
/// Those are files somebody made and the server has not accepted yet, they live in the app group
/// container rather than in a `URLCache`, and losing them loses the only copy. A "free up space"
/// button that could reach them would be a data-loss button with a friendly label.
public enum MediaCacheMaintenance {
    /// What the cache is holding, and what it may hold.
    public struct Usage: Sendable, Equatable {
        public let usedBytes: Int
        public let capacityBytes: Int

        public init(usedBytes: Int, capacityBytes: Int) {
            self.usedBytes = usedBytes
            self.capacityBytes = capacityBytes
        }
    }

    public static func usage(of cache: any DerivedMediaCache) -> Usage {
        Usage(usedBytes: cache.currentDiskUsage, capacityBytes: cache.diskCapacity)
    }

    /// Empties the derived cache. One call, to one cache.
    public static func clear(_ cache: any DerivedMediaCache) {
        cache.removeAllCachedResponses()
    }

    /// The size as a person reads it.
    ///
    /// Hand-rolled rather than `ByteCountFormatStyle` on purpose: the formatter's output depends on
    /// the locale and on the ICU version the OS shipped with, so a test asserting a string it
    /// produced would be asserting a property of the build machine. This is arithmetic, and the
    /// same arithmetic everywhere.
    ///
    /// Binary megabytes, because the capacity this is shown beside is declared in them
    /// (`MediaCache.makeURLCache` is `256 * 1024 * 1024`), and a "12 MB of 256 MB" whose two halves
    /// counted differently would be a line nobody could check.
    public static func formatted(bytes: Int) -> String {
        let mega = 1024 * 1024
        let giga = 1024 * mega
        if bytes <= 0 { return "Empty" }
        if bytes >= giga { return "\(oneDecimal(bytes, over: giga)) GB" }
        // Below a megabyte there is nothing worth reclaiming, and "0.0 MB" reads like a defect.
        if bytes < mega { return "Less than 1 MB" }
        return "\(oneDecimal(bytes, over: mega)) MB"
    }

    /// What the Storage row says: what is held, against what may be.
    public static func summary(_ usage: Usage) -> String {
        "\(formatted(bytes: usage.usedBytes)) of \(formatted(bytes: usage.capacityBytes))"
    }

    /// Whether there is anything to clear. A button that does nothing should not be tappable.
    public static func isClearable(_ usage: Usage) -> Bool { usage.usedBytes > 0 }

    /// One decimal place, rounded rather than truncated, without going through a formatter.
    private static func oneDecimal(_ bytes: Int, over unit: Int) -> String {
        let tenths = (bytes * 10 + unit / 2) / unit
        return "\(tenths / 10).\(tenths % 10)"
    }
}

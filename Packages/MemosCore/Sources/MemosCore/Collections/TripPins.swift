import Foundation
import Observation

/// One pinned trip as this device keeps it: enough for the composer chip to say which trip and
/// which tag at a cold launch, before any list has answered.
public struct TripPin: Sendable, Equatable, Codable {
    public var uid: String
    public var title: String
    public var tag: String?
    public var pinnedUntil: Date

    public init(uid: String, title: String, tag: String?, pinnedUntil: Date) {
        self.uid = uid
        self.title = title
        self.tag = tag
        self.pinnedUntil = pinnedUntil
    }
}

/// The device-local pin of the signed-in identity's trips: `<root>/<scope key>/pins.json`.
///
/// The pin is the one part of a trip that never reaches the server. One file per identity scope,
/// the same scope key `CollectionStore` files under, replaced whole through a temporary sibling so
/// a write that dies half way leaves the previous file intact. When the session becomes somebody
/// else's, the outgoing scope's rows leave memory and the incoming scope's file is read, so
/// account B never sees A's pinned tag and A gets it back on return.
@MainActor
@Observable
public final class TripPins {
    public static let fileName = "pins.json"
    public static let currentFormatVersion = 1
    /// How long a pin outlives the trip's last picture (or the moment of pinning without one).
    public static let pinDuration: TimeInterval = 7 * 24 * 60 * 60

    /// The scope's pins. `pin` keeps at most one.
    public private(set) var rows: [TripPin] = []
    public private(set) var identity: TimelineSnapshotIdentity?

    private let root: URL?
    private let writeBytes: (Data, URL) throws -> Void
    @ObservationIgnored private var writable = false

    public init(
        identity: TimelineSnapshotIdentity?,
        root: URL? = CollectionStore.appGroupRoot(),
        writeBytes: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1) }
    ) {
        self.identity = identity
        self.root = root
        self.writeBytes = writeBytes
        load()
    }

    /// The session became somebody else's, or nobody's.
    public func sessionIdentityChanged(to identity: TimelineSnapshotIdentity?) {
        guard identity != self.identity else { return }
        self.identity = identity
        load()
    }

    /// Pins `trip` — and only it: any other pin of the scope goes in the same write. It lasts
    /// `pinDuration` past `lastTaken`, or past `now` when the trip has no picture yet.
    public func pin(_ trip: Trip, lastTaken: Date?, now: Date) {
        let until = (lastTaken ?? now).addingTimeInterval(Self.pinDuration)
        commit([TripPin(uid: trip.uid, title: trip.title, tag: trip.tag, pinnedUntil: until)])
    }

    public func unpin(uid: String) {
        guard rows.contains(where: { $0.uid == uid }) else { return }
        commit(rows.filter { $0.uid != uid })
    }

    /// Until when trip `uid` is pinned, expired or not, or nil.
    public func pinnedUntil(uid: String) -> Date? {
        rows.first { $0.uid == uid }?.pinnedUntil
    }

    /// The pin in force at `now`: one whose `pinnedUntil` lies strictly after it. Of several (a
    /// file edited by hand), the one that lasts longest.
    public func activePin(now: Date) -> TripPin? {
        rows.filter { $0.pinnedUntil > now }.max { $0.pinnedUntil < $1.pinnedUntil }
    }

    /// A drain's extrema for trip `uid`: a pinned trip's pin moves to seven days after its last
    /// picture when that is LATER than it stands — an expired pin included — and never earlier.
    /// A trip that is not pinned stays unpinned.
    public func noteMembers(uid: String, firstTaken: Date?, lastTaken: Date?, now: Date) {
        guard let index = rows.firstIndex(where: { $0.uid == uid }), let lastTaken else { return }
        let derived = lastTaken.addingTimeInterval(Self.pinDuration)
        guard derived > rows[index].pinnedUntil else { return }
        var next = rows
        next[index].pinnedUntil = derived
        commit(next)
    }

    /// A list answered: each pinned row takes its trip's title and tag as the server has them now.
    public func noteTrips(_ trips: [Trip]) {
        var next = rows
        for index in next.indices {
            guard let trip = trips.first(where: { $0.uid == next[index].uid }) else { continue }
            next[index].title = trip.title
            next[index].tag = trip.tag
        }
        guard next != rows else { return }
        commit(next)
    }

    // MARK: - File

    private struct PinFile: Codable {
        var formatVersion: Int
        var pins: [TripPin]
    }

    private var fileURL: URL? {
        guard let root, let identity else { return nil }
        return root.appending(path: CollectionStore.scopeKey(for: identity))
            .appending(path: Self.fileName)
    }

    private func load() {
        rows = []
        writable = false
        guard let fileURL else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            writable = true
            return
        }
        if let data = try? Data(contentsOf: fileURL),
            let file = try? Self.decoder.decode(PinFile.self, from: data),
            file.formatVersion == Self.currentFormatVersion
        {
            rows = file.pins
            writable = true
            return
        }
        // A pin is a convenience: an unreadable file is set aside rather than written over.
        let aside = fileURL.deletingLastPathComponent()
            .appending(path: "\(Self.fileName).bad-\(UUID().uuidString.prefix(8))")
        do {
            try FileManager.default.moveItem(at: fileURL, to: aside)
            writable = true
            MemosLog.session.error("a pins file that would not decode was set aside")
        } catch {
            MemosLog.session.error("a bad pins file could not be set aside; read-only")
        }
    }

    private func commit(_ next: [TripPin]) {
        guard writable, let fileURL else { return }
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appending(path: "\(Self.fileName).tmp-\(UUID().uuidString)")
        do {
            let data = try Self.encoder.encode(
                PinFile(formatVersion: Self.currentFormatVersion, pins: next))
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                try writeBytes(data, temporary)
                if manager.fileExists(atPath: fileURL.path) {
                    _ = try manager.replaceItemAt(fileURL, withItemAt: temporary)
                } else {
                    try manager.moveItem(at: temporary, to: fileURL)
                }
            } catch {
                try? manager.removeItem(at: temporary)
                throw error
            }
            rows = (try? Self.decoder.decode(PinFile.self, from: data).pins) ?? next
        } catch {
            MemosLog.session.error("the pins file was not written; nothing changed")
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

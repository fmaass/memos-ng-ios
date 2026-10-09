import CryptoKit
import Foundation
import Observation

/// The signed-in identity's collections, as this device keeps them.
///
/// One JSON file per identity scope: `<root>/<scope key>/collections.json`, where the scope key is
/// a SHA-256 of the `(server, subject)` pair `TimelineSnapshotIdentity` already fences — stable
/// across launches, unlike `hashValue`. A record is shown, pinned and applied only under the scope
/// that wrote it: when the session becomes somebody else's (or nobody's), `sessionIdentityChanged`
/// drops every record, summary and pin of the outgoing scope from memory and reads the incoming
/// scope's file, so account B never inherits A's titles or pinned tag, and A gets them back on
/// return.
///
/// **Serialization.** The store is `@MainActor` and every mutation is synchronous: it builds the
/// next list, writes the WHOLE file and only then publishes the list, with no suspension point
/// anywhere in between. Two calls in one turn — two `create`s included — therefore run one after
/// the other by construction, the second building on what the first wrote; there is no request on
/// any wire to join or refuse, and nothing in flight that could outlive an identity change.
///
/// **Durability.** Every write goes to a temporary sibling and then replaces the file in one step
/// (`replaceItemAt`), so a write that dies half way leaves the previous file whole. What is in
/// `records` is always what the file says: a mutation whose write failed changes nothing. A file
/// that will not decode is renamed aside to `collections.json.bad-<utc>` and the scope starts
/// empty — never a crash, and never a silent overwrite of the bad bytes: if they cannot be moved
/// aside, the scope stays read-only for this run.
///
/// Read once per scope; no network.
@MainActor
@Observable
public final class CollectionStore {
    /// The file's name inside its scope directory.
    public static let fileName = "collections.json"

    /// The shape of the file. A file written under any other number is set aside like one that
    /// will not decode, rather than overwritten.
    public static let currentFormatVersion = 1

    /// How long a pin outlives the trip's last picture (or the moment of pinning, when the trip
    /// has none yet).
    public static let pinDuration: TimeInterval = 7 * 24 * 60 * 60

    /// The scope's records, sorted by `order`.
    public private(set) var records: [CollectionRecord] = []

    /// Whose records these are, or nil when nobody is signed in — in which case there are none.
    public private(set) var identity: TimelineSnapshotIdentity?

    private let root: URL?
    private let now: () -> Date
    private let writeBytes: (Data, URL) throws -> Void
    private let moveAside: (URL, URL) throws -> Void
    /// False when the scope's file could not be read or set aside: writing would destroy it.
    @ObservationIgnored private var writable = false

    /// - Parameters:
    ///   - identity: the signed-in session's identity, or nil.
    ///   - root: the directory the scope directories live under. Defaults to `Collections` in the
    ///     app-group container; nil (no container) means nothing is read or written.
    ///   - now: the clock creation dates, pin fallbacks and quarantine names are read from.
    ///   - writeBytes: the bytes-to-disk step for the TEMPORARY file. Injected so a test can make a
    ///     write die half way and prove the real file survived it.
    public convenience init(
        identity: TimelineSnapshotIdentity?,
        root: URL? = CollectionStore.appGroupRoot(),
        now: @escaping () -> Date = { Date() },
        writeBytes: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1) }
    ) {
        self.init(
            identity: identity,
            root: root,
            now: now,
            writeBytes: writeBytes,
            moveAside: { try FileManager.default.moveItem(at: $0, to: $1) }
        )
    }

    /// The same, with the step that moves a bad file aside injected: a test makes it fail and
    /// proves the bad bytes are then never written over.
    init(
        identity: TimelineSnapshotIdentity?,
        root: URL?,
        now: @escaping () -> Date,
        writeBytes: @escaping (Data, URL) throws -> Void,
        moveAside: @escaping (URL, URL) throws -> Void
    ) {
        self.identity = identity
        self.root = root
        self.now = now
        self.writeBytes = writeBytes
        self.moveAside = moveAside
        load()
    }

    /// `Collections` inside the app group, or nil when the container is not reachable.
    public nonisolated static func appGroupRoot(
        appGroup: String = DeviceCredentials.appGroup
    ) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "Collections")
    }

    /// The directory name an identity's records are filed under: the SHA-256 of the pair, in hex.
    ///
    /// A digest because neither a base URL nor an issuer's subject is a legal path component, and
    /// a stable one because the same identity has to find its file again on the next launch.
    public nonisolated static func scopeKey(for identity: TimelineSnapshotIdentity) -> String {
        let material = Data("\(identity.server.absoluteString)\n\(identity.subject)".utf8)
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    /// The session became somebody else's, or nobody's: drop everything of the outgoing scope and
    /// read the incoming one's file. Called from the same `onChange` of the session's subject that
    /// moves `TimelineStore`.
    public func sessionIdentityChanged(to identity: TimelineSnapshotIdentity?) {
        guard identity != self.identity else { return }
        self.identity = identity
        load()
    }

    // MARK: - Mutations

    /// Adds a trip at the end of the order and returns it as written. With nobody signed in, or a
    /// write that failed, the returned record exists nowhere else.
    @discardableResult
    public func create(title: String, tags: [String]) -> CollectionRecord {
        let record = CollectionRecord(
            id: UUID(),
            kind: .trip,
            title: title,
            tags: tags,
            order: (records.map(\.order).max() ?? -1) + 1,
            createdAt: now()
        )
        commit(records + [record])
        return records.first { $0.id == record.id } ?? record
    }

    public func rename(id: UUID, to title: String) {
        update(id) { $0.title = title }
    }

    public func delete(id: UUID) {
        guard records.contains(where: { $0.id == id }) else { return }
        commit(records.filter { $0.id != id })
    }

    /// Moves the record to `index` in the sorted list (clamped into it) and renumbers every
    /// record's `order` to its position.
    public func move(id: UUID, to index: Int) {
        guard let from = records.firstIndex(where: { $0.id == id }) else { return }
        var next = records
        let record = next.remove(at: from)
        next.insert(record, at: min(max(index, 0), next.count))
        for position in next.indices { next[position].order = position }
        commit(next)
    }

    /// Picks the cover, or with nil goes back to "the first member".
    public func setCover(id: UUID, uid: String?) {
        update(id) { $0.coverUid = uid }
    }

    public func exclude(id: UUID, uid: String) {
        update(id) { record in
            if !record.excludedUids.contains(uid) { record.excludedUids.append(uid) }
        }
    }

    public func include(id: UUID, uid: String) {
        update(id) { $0.excludedUids.removeAll { $0 == uid } }
    }

    /// Pins this trip — and only this one: any other pin in the scope is cleared in the same
    /// write. It lasts `pinDuration` past the trip's last picture, or past `now` when the trip has
    /// none yet.
    public func pin(id: UUID, now: Date) {
        guard let target = records.first(where: { $0.id == id }) else { return }
        let until = (target.lastSummary?.lastTaken ?? now).addingTimeInterval(Self.pinDuration)
        commit(
            records.map { record in
                var record = record
                record.pinnedUntil = record.id == id ? until : nil
                return record
            }
        )
    }

    public func unpin(id: UUID) {
        update(id) { $0.pinnedUntil = nil }
    }

    /// Stores the trip's summary and, for a pinned trip, re-derives its pin in the same write.
    ///
    /// The rule is "seven days after its last picture": when the new summary's `lastTaken` plus
    /// `pinDuration` is LATER than the record's `pinnedUntil`, the pin takes it — an expired pin
    /// included, since a picture taken later moves the expiry with it. It never shortens a pin (a
    /// refresh that dropped pictures, or an exclusion that moved `lastTaken` earlier, leaves the
    /// expiry as it is) and never pins a trip that is not pinned.
    public func setSummary(id: UUID, _ summary: TripSummary?) {
        update(id) { record in
            record.lastSummary = summary
            guard let pinned = record.pinnedUntil, let last = summary?.lastTaken else { return }
            let derived = last.addingTimeInterval(Self.pinDuration)
            if derived > pinned { record.pinnedUntil = derived }
        }
    }

    // MARK: - Reading the pin

    /// The trip pinned at `now`: the record whose `pinnedUntil` lies strictly after `now` — a pin
    /// that ends exactly at `now` has expired — or nil.
    ///
    /// `pin` keeps at most one pin in the scope, so there is at most one. A file edited by hand
    /// can hold several: the one that lasts longest wins, and on a tie the first in `order`.
    public func activePin(now: Date) -> CollectionRecord? {
        var best: (record: CollectionRecord, until: Date)?
        for record in records {
            guard let until = record.pinnedUntil, until > now else { continue }
            if let current = best, until <= current.until { continue }
            best = (record, until)
        }
        return best?.record
    }

    // MARK: - File

    private struct CollectionFile: Codable {
        var formatVersion: Int
        var records: [CollectionRecord]
    }

    private var fileURL: URL? {
        guard let root, let identity else { return nil }
        return root.appending(path: Self.scopeKey(for: identity))
            .appending(path: Self.fileName)
    }

    private func update(_ id: UUID, _ change: (inout CollectionRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var next = records
        change(&next[index])
        guard next != records else { return }
        commit(next)
    }

    /// Reads the current scope's file into `records`, starting from nothing.
    private func load() {
        records = []
        writable = false
        guard let fileURL else { return }
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else {
            writable = true
            return
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            MemosLog.session.error("the collections file could not be read; left untouched")
            return
        }
        if let file = try? Self.decoder.decode(CollectionFile.self, from: data),
            file.formatVersion == Self.currentFormatVersion
        {
            records = file.records.sorted { $0.order < $1.order }
            writable = true
            return
        }
        writable = quarantine(fileURL)
    }

    /// Moves an unreadable file aside, never over another one. False when it stayed where it was.
    private func quarantine(_ fileURL: URL) -> Bool {
        let directory = fileURL.deletingLastPathComponent()
        let stamp = Self.utcStamp(now())
        var target = directory.appending(path: "\(Self.fileName).bad-\(stamp)")
        if FileManager.default.fileExists(atPath: target.path) {
            target = directory.appending(
                path: "\(Self.fileName).bad-\(stamp)-\(UUID().uuidString.prefix(8))"
            )
        }
        do {
            try moveAside(fileURL, target)
            MemosLog.session.error("a collections file that would not decode was set aside")
            return true
        } catch {
            MemosLog.session.error("a bad collections file could not be set aside; read-only")
            return false
        }
    }

    /// Writes `next` as the whole file through a temporary sibling and, once it is in place,
    /// publishes what the file now says.
    private func commit(_ next: [CollectionRecord]) {
        guard writable, let fileURL else { return }
        let sorted = next.sorted { $0.order < $1.order }
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appending(path: "\(Self.fileName).tmp-\(UUID().uuidString)")
        do {
            let data = try Self.encoder.encode(
                CollectionFile(formatVersion: Self.currentFormatVersion, records: sorted)
            )
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
            // What the file says, dates at the precision it keeps them — so memory never holds a
            // value the next launch would read back differently.
            records =
                (try? Self.decoder.decode(CollectionFile.self, from: data).records) ?? sorted
        } catch {
            MemosLog.session.error("the collections file was not written; nothing changed")
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

    /// `yyyyMMddTHHmmssZ` in UTC — a legal, sortable file-name suffix.
    static func utcStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }
}

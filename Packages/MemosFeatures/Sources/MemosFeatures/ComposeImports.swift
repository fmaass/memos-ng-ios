import Foundation
import MemosOutbox
import Observation

/// What the photo picker has produced, which selection it belongs to, and when each file says it
/// was taken.
///
/// Picking photos, changing your mind and picking again before the first pick has finished loading
/// is ordinary behaviour, and the two loads then overlap. Only one of them may write the attachment
/// list — the pick made LAST — and that is what the stamp decides.
///
/// The stamp is taken SYNCHRONOUSLY, in `selected()`, at the moment the selection lands: it orders
/// SELECTIONS. Taken inside the loading task instead, it would order the tasks' START TIMES, which
/// the scheduler chooses and not the person picking photos — two unstructured tasks started from an
/// `.onChange` have no defined order between them — so a pick made second could be stamped first
/// and then lose to the very pick it was meant to replace.
///
/// It is the same shape as `MediaImageStore`'s generation, for the same reason: the caller reads the
/// fence before it goes away to do slow work, and an answer is refused on arrival once the fence has
/// moved.
///
/// The capture reads add a SECOND fence, and it is a different one. A read is issued for one ITEM
/// and is judged against that item's identity when it comes back: a result for an item that has
/// been removed, replaced or retried since must not be written anywhere, because the item it
/// describes is not on the screen any more. Both fences are checked after every await below, and
/// the awaits are enumerated in the comments that guard them.
@MainActor
@Observable
final class ComposeImports {
    /// Everything attached, in PICK order — the order things entered the list, which never changes
    /// once they have. The order the composer SHOWS and SENDS is `ordered` below; keeping the two
    /// apart is what lets ties, and items that never get an instant, fall back on the order a
    /// person actually put them in.
    private(set) var items: [ComposeAttachment] = []
    /// Whether a selection is still loading.
    private(set) var isImporting = false

    /// The zone a civil capture time is resolved in — the device's, read at pick. Injected so a
    /// test can name the zone its expectations are written in rather than the one the machine
    /// running it happens to be set to.
    let zone: TimeZone
    /// The file reader. Injected for the same reason: the fences are about ORDER, and a test that
    /// had to produce a real HEIC to exercise one would be testing ImageIO instead.
    private let readCapture: @MainActor (PickedMedia) async -> CaptureReading

    /// The newest selection's stamp. Anything older is stale on arrival.
    private var current = 0
    /// Which read each item is on. It is bumped every time a read is ISSUED for that item, and an
    /// answer is applied only if the item is still holding the number its read was issued under.
    ///
    /// The identity alone is not quite enough, and the missing case is the retry: a retried item
    /// keeps its identity on purpose — it is the same tile — so two reads for one identity can be
    /// in flight, and the older one must not be allowed to answer last. An entry is dropped when
    /// the item leaves, which is what makes a read for a removed or replaced item land nowhere.
    private var readGeneration: [UUID: Int] = [:]
    /// How to ask for one item again, by the identity it was picked under.
    ///
    /// Held here rather than on the attachment because a retry handle is a closure and an
    /// attachment is a value a test compares — and because the handle must die with the pick that
    /// made it: a retry that outlived its selection would put back an item the next pick replaced.
    private var retries: [UUID: @MainActor () async -> ComposePickerAnswer] = [:]

    init(
        zone: TimeZone = .autoupdatingCurrent,
        readCapture: @escaping @MainActor (PickedMedia) async -> CaptureReading = {
            await CaptureReader.read(fileAt: $0.url, mime: $0.mime)
        }
    ) {
        self.zone = zone
        self.readCapture = readCapture
    }

    // MARK: - what is attached

    /// Everything attached, in CAPTURE ORDER: what has a settled instant first, ascending; what has
    /// none after it, in pick order. This is the one array — the tile row draws it and the outbox
    /// manifest is built from it, so what a person sees is what the server is told.
    var ordered: [ComposeAttachment] { AutoMemoDate.captureOrder(items, in: zone) }

    /// The files, in that same order. Only the ones that actually arrived: an item that failed is
    /// still on the screen, but there is no file to send.
    var attachments: [PickedMedia] { ordered.compactMap(\.media) }

    /// How many files of the current selection could not be read.
    var failed: Int { items.filter(\.isFailed).count }

    /// Whether any item's capture read has not come back yet.
    var hasPendingCapture: Bool { items.contains { $0.capture.isPending } }

    /// The memo's Auto date, recomputed from whatever is attached right now — which is why every
    /// add, removal, retry and late-arriving read moves it without anything having to remember to.
    var autoDate: AutoMemoDateResult { AutoMemoDate.autoMemoDate(items, in: zone) }

    // MARK: - picking

    /// A selection landed. Call this at the call site the selection lands on, before the loading
    /// task is started, and hand the stamp it returns to `load`.
    func selected() -> Int {
        current += 1
        isImporting = true
        return current
    }

    /// Loads one selection's files and writes them — unless a newer selection has landed since this
    /// one was stamped, in which case the whole outcome is dropped, `isImporting` included: that
    /// pick no longer describes what is on the screen, and the newer one is still owed its spinner.
    ///
    /// Every item is kept, whether or not its file arrived. A failure is a placeholder tile with a
    /// reason and a retry, never a silently missing photograph — that is the failure somebody
    /// discovers weeks later.
    ///
    /// - Returns: whether this selection's outcome was the one kept.
    @discardableResult
    func load<Item: Sendable>(
        _ items: [Item],
        stamp: Int,
        using loader: @escaping @MainActor (Item) async -> ComposePickerAnswer
    ) async -> Bool {
        var imported: [ComposeAttachment] = []
        var handles: [UUID: @MainActor () async -> ComposePickerAnswer] = [:]
        for item in items {
            // AWAIT 1. Nothing is written from inside this loop, so a stale answer cannot reach the
            // list here; the ownership check for all of them is the stamp test below, immediately
            // before the one write.
            let answer = await loader(item)
            let attachment = Self.attachment(from: answer)
            imported.append(attachment)
            handles[attachment.id] = { await loader(item) }
        }
        guard stamp == current else { return false }
        // A pick replaces what was picked; the captures made in this app's own camera stay, which
        // is what `keptCaptures` holds on to (see `captured`).
        // `keptCaptures` is read off the list as it still stands, before the assignment replaces
        // it — the camera's photographs survive a pick, and only they do.
        self.items = imported + keptCaptures
        // The camera's items carry no retry handle: a photograph taken here cannot be taken again
        // by asking a picker for it, so what a failed capture offers is the camera itself.
        retries = handles
        // Everything the replaced pick was reading is fenced out here: its items are gone from the
        // list above, and their generations go with them.
        readGeneration = readGeneration.filter { cameraIDs.contains($0.key) }
        isImporting = false
        for attachment in imported where attachment.media != nil {
            beginCaptureRead(for: attachment.id)
        }
        return true
    }

    /// A capture made in this app's camera, added to what is already attached.
    ///
    /// It does NOT fence a pick in flight, and it does not have to: a pick replaces the picked
    /// files and leaves this one where it is. That is deliberate — a pick can always be made again,
    /// and a photo taken here and dropped because somebody afterwards chose two from the library is
    /// a photo nobody can take again.
    func captured(_ media: PickedMedia) {
        let attachment = ComposeAttachment(
            id: media.id, media: media, load: .ready, capture: .pending, label: media.filename)
        items.append(attachment)
        cameraIDs.insert(attachment.id)
        // Fenced by its identity alone, deliberately: this photograph SURVIVES the next pick, so a
        // read of it must not be thrown away because a selection landed while it was running.
        beginCaptureRead(for: attachment.id)
    }

    /// Drops what is attached AND fences everything in flight, loads that have not begun included:
    /// a pick still on its way when "Remove them" is tapped must never land afterwards, or the
    /// removal undoes itself a second later.
    func clear() {
        current += 1
        items = []
        retries = [:]
        readGeneration = [:]
        cameraIDs = []
        isImporting = false
    }

    /// "Remove them": the items that could not be read, and only those.
    ///
    /// The successful imports and the camera captures stay. Removing them too is how somebody loses
    /// four photographs because a fifth would not download.
    func removeFailed() {
        let removed = items.filter(\.isFailed).map(\.id)
        items.removeAll(where: \.isFailed)
        for id in removed {
            retries[id] = nil
            readGeneration[id] = nil
            cameraIDs.remove(id)
        }
    }

    /// One item only.
    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        retries[id] = nil
        readGeneration[id] = nil
        cameraIDs.remove(id)
    }

    /// Asks for one failed item again, under the identity it was picked with.
    ///
    /// The identity is the point: the answer is applied to THAT item or to nothing at all. A retry
    /// whose item has been removed, or whose whole selection has been replaced, lands nowhere.
    func retry(id: UUID) async {
        guard let handle = retries[id], let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        let stamp = current
        items[index].load = .loading
        items[index].uploadFailed = nil
        // AWAIT 2. The list can change completely while this runs.
        let answer = await handle()
        guard stamp == current, let landing = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        let arrived = Self.attachment(from: answer)
        // The identity survives the retry: it is the same tile. Which is exactly why the read that
        // follows carries a generation as well — the previous attempt's read, if one is still out
        // there, is for this same identity and must not be allowed to answer last.
        items[landing] = ComposeAttachment(
            id: id,
            media: arrived.media,
            load: arrived.load,
            capture: arrived.media == nil ? .settled(.empty) : .pending,
            label: arrived.label
        )
        if arrived.media != nil { beginCaptureRead(for: id) }
    }

    /// Marks the files that were being added to an existing memo as not having gone up.
    ///
    /// The sheet stays open when an edit fails, and these are the tiles that say why. Only what is
    /// attached right now is marked: an item removed in between is not part of this attempt.
    func markUploadFailed(_ category: ComposeLoadFailure) {
        for index in items.indices where items[index].media != nil {
            items[index].uploadFailed = category
        }
    }

    /// Clears those marks — a retry is a fresh attempt, and a tile that still says "needs
    /// connection" while it is being uploaded again is a tile lying about the present.
    func clearUploadFailures() {
        for index in items.indices { items[index].uploadFailed = nil }
    }

    // MARK: - capture reads

    /// Reads one file's own capture date, and applies it only if the item is still there and still
    /// on this read.
    ///
    /// The fence is checked after the ONE await this makes, and it is two conditions: the item must
    /// still be in the list under the identity the read was issued for, and it must still be on the
    /// generation the read was issued under. Without them a read that outlived its item repopulates
    /// a removed tile, re-dates the memo from a photograph nobody attached, and moves the order
    /// under the person's hands — and a retried item takes its predecessor's answer.
    private func beginCaptureRead(for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), let media = items[index].media
        else { return }
        let generation = (readGeneration[id] ?? 0) + 1
        readGeneration[id] = generation
        items[index].capture = .pending
        let read = readCapture
        Task { [weak self] in
            // AWAIT 3.
            let reading = await read(media)
            guard let self, self.readGeneration[id] == generation,
                let landing = self.items.firstIndex(where: { $0.id == id })
            else { return }
            self.items[landing].capture = .settled(reading)
        }
    }

    // MARK: - the camera's own items

    /// Which items came from this app's camera. A pick replaces the picked files and keeps these.
    private var cameraIDs: Set<UUID> = []

    private var keptCaptures: [ComposeAttachment] {
        items.filter { cameraIDs.contains($0.id) }
    }

    private static func attachment(from answer: ComposePickerAnswer) -> ComposeAttachment {
        switch answer {
        case .file(let media):
            return ComposeAttachment(
                id: media.id, media: media, load: .ready, capture: .pending,
                label: media.filename)
        case .failed(let category):
            // An item with no file has no capture read to wait for: its decision is settled at
            // nothing, so it never holds up a Post that its own failure is already refusing.
            return ComposeAttachment(
                id: UUID(), media: nil, load: .failed(category), capture: .settled(.empty),
                label: "A file")
        }
    }
}

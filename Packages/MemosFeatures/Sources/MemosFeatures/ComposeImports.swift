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
/// Items appear AT ONCE, as placeholders, and each one fills in as its own file arrives. A list
/// that appeared only when the slowest file had finished is the modal spinner in another costume:
/// four photographs that are ready cannot be looked at because a fifth is coming down from iCloud.
///
/// Three fences, and they answer three different questions. The SELECTION stamp: does this answer
/// still describe what is on the screen? The item's IDENTITY: is the item this answer was issued
/// for still here? The item's READ GENERATION: is this still the read that item is waiting for — a
/// retry keeps the identity on purpose, so identity alone would let an older read answer last.
/// Every await below is followed by the checks that guard it, and each is named in a comment.
@MainActor
@Observable
final class ComposeImports {
    /// Everything attached, in PICK order — one order across the library and the camera, which is
    /// what `sequence` carries. The order the composer SHOWS and SENDS is `ordered` below; keeping
    /// the two apart is what lets ties, and items that never get an instant, fall back on the order
    /// a person actually put them in.
    private(set) var items: [ComposeAttachment] = []
    /// Whether a selection is still loading.
    private(set) var isImporting = false
    /// Whether a submission built from this list is on the wire.
    ///
    /// What a save carries is fixed when Save is pressed — the submission takes the list as it then
    /// stands (`ComposeView.post()`) — so anything that changes the list afterwards changes the row
    /// and not the upload: the memo is saved with one set of pictures and the sheet closes on
    /// another, a divergence nobody is shown. It lives HERE, on the object each of those changes is
    /// about to be made to, rather than in the sheet's own state, because every one of them arrives
    /// in a callback and one of those — the camera's, kept for the life of the cover it was handed
    /// to (`CameraView`) — carries the sheet as it stood when the camera was opened, which can be
    /// before the save began. A flag read out of that copy answers about an instant that has
    /// passed.
    private(set) var isSubmitting = false

    /// Where the zone comes from, asked ONCE PER PICK rather than once per composer.
    ///
    /// A civil capture time has no zone of its own, so the client supplies one — and which one is a
    /// fact about the moment of picking: a phone can be picked up in another country, or its
    /// setting corrected, between two picks in the same sheet. Each item is stamped with the answer
    /// as it read WHEN IT WAS PICKED (`ComposeAttachment.captureZone`), so nothing already on
    /// screen re-resolves. Injected so a test can name the zone its expectations are written in,
    /// and change it between two picks.
    private let zoneAtPick: @MainActor () -> TimeZone

    /// The zone the DISPLAY works in — the span hint's calendar days. Sampled once, here, because
    /// it is about what the person is looking at now rather than about any one item.
    let zone: TimeZone
    /// The file reader. Injected for the same reason: the fences are about ORDER, and a test that
    /// had to produce a real HEIC to exercise one would be testing ImageIO instead.
    private let readCapture: @MainActor (PickedMedia) async -> CaptureReading

    /// The newest selection's stamp. Anything older is stale on arrival.
    private var current = 0
    /// Pick order, across everything: the library and the camera share it (see
    /// `ComposeAttachment.sequence`).
    private var sequence = 0
    /// How to ask for one item again, by the identity it was picked under.
    ///
    /// Held here rather than on the attachment because a retry handle is a closure and an
    /// attachment is a value a test compares — and because the handle must die with the pick that
    /// made it: a retry that outlived its selection would put back an item the next pick replaced.
    private var retries: [UUID: @MainActor () async -> ComposePickerAnswer] = [:]
    /// Which items have a retry on the wire. A second retry of the same item is REFUSED rather than
    /// joined: there is one file and one tile, the answer in flight is about exactly this item, and
    /// two overlapping imports would race to write it — the older one landing last would put a
    /// failure back over a success.
    private var retryInFlight: Set<UUID> = []
    /// Which read each item is on. Bumped every time a read is ISSUED for that item; an answer is
    /// applied only if the item is still holding the number its read was issued under.
    private var readGeneration: [UUID: Int] = [:]
    /// Which items came from this app's camera. A pick replaces the picked files and keeps these.
    private var cameraIDs: Set<UUID> = []

    init(
        zone: TimeZone? = nil,
        zoneAtPick: (@MainActor () -> TimeZone)? = nil,
        readCapture: @escaping @MainActor (PickedMedia) async -> CaptureReading = {
            await CaptureReader.read(fileAt: $0.url, mime: $0.mime)
        }
    ) {
        // `.current` rather than `.autoupdatingCurrent`, and read rather than remembered: an
        // autoupdating zone re-resolves every civil reading the moment the device's setting moves,
        // which would re-date and reorder what is already on the screen.
        let atPick = zoneAtPick ?? { zone ?? .current }
        self.zoneAtPick = atPick
        self.zone = zone ?? atPick()
        self.readCapture = readCapture
    }

    // MARK: - what is attached

    /// Everything attached, in CAPTURE ORDER: what has a settled instant first, ascending; what has
    /// none after it, in pick order. This is the one array — the tile row draws it and the outbox
    /// manifest is built from it, so what a person sees is what the server is told.
    var ordered: [ComposeAttachment] { AutoMemoDate.captureOrder(items, in: zone) }

    /// The files, in that same order. Only the ones that actually arrived: an item that failed or
    /// is still loading is on the screen, but there is no file to send.
    var attachments: [PickedMedia] { ordered.compactMap(\.media) }

    /// How many items could not be read.
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

    /// Loads one selection's files. The tiles appear immediately, in pick order, each one loading;
    /// every file then lands in its own place as it arrives.
    ///
    /// Nothing is written once a newer selection has landed: that pick no longer describes what is
    /// on the screen, and the newer one is still owed its spinner.
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
        // A selection that lands once a submission has been built is not this memo's selection any
        // more: a pick REPLACES what was picked, and what was picked is what the save is carrying
        // up while this sheet waits to close on it. Refused, not queued.
        guard !isSubmitting else {
            // The stamp was taken as the selection landed, and taking it turned the busy flag on.
            // A refusal that walked away from here would leave the composer importing for ever.
            if stamp == current { isImporting = false }
            return false
        }
        guard stamp == current else { return false }
        var placeholders: [ComposeAttachment] = []
        var handles: [UUID: @MainActor () async -> ComposePickerAnswer] = [:]
        // Sampled HERE, as the pick lands, and stamped onto every item of it.
        let picked = zoneAtPick()
        for item in items {
            sequence += 1
            let id = UUID()
            placeholders.append(
                ComposeAttachment(
                    id: id, media: nil, load: .loading, capture: .pending,
                    label: Self.arrivingLabel,
                    sequence: sequence, captureZone: picked))
            handles[id] = { await loader(item) }
        }
        // The placeholders are on screen before a single byte is read. `keptCaptures` is read off
        // the list as it still stands — the camera's photographs survive a pick, and only they do —
        // and the two are merged in ONE pick order rather than concatenated by source.
        self.items = (placeholders + keptCaptures).sorted { $0.sequence < $1.sequence }
        // The camera's items carry no retry handle: a photograph taken here cannot be taken again
        // by asking a picker for it, so what a failed capture offers is the camera itself.
        retries = handles
        // Everything the replaced pick was reading is fenced out here: its items are gone from the
        // list above, and their generations go with them.
        readGeneration = readGeneration.filter { cameraIDs.contains($0.key) }
        isImporting = !placeholders.isEmpty

        for placeholder in placeholders {
            guard let handle = handles[placeholder.id] else { continue }
            // AWAIT 1, once per item.
            let answer = await handle()
            // The selection must still be the one on screen. A pick that has been replaced is
            // finished with: everything after this item belongs to it too, and the pick that took
            // its place is owed the list.
            guard stamp == current else { return false }
            // This ITEM, though, is one item. Taken off the row while its file was coming, it is
            // the only thing this answer is dropped for — the rest of the pick is still on its
            // way, and a loop that returned here would leave every one of them on its spinner
            // with nothing left to settle them or the busy flag.
            guard let index = self.items.firstIndex(where: { $0.id == placeholder.id }) else {
                continue
            }
            self.items[index] = Self.settle(self.items[index], with: answer)
            if self.items[index].media != nil { beginCaptureRead(for: placeholder.id) }
        }
        guard stamp == current else { return false }
        isImporting = false
        return true
    }

    /// A capture made in this app's camera, added to what is already attached.
    ///
    /// It does NOT fence a pick in flight, and it does not have to: a pick replaces the picked
    /// files and leaves this one where it is. That is deliberate — a pick can always be made again,
    /// and a photo taken here and dropped because somebody afterwards chose two from the library is
    /// a photo nobody can take again.
    func captured(_ media: PickedMedia) {
        // The camera stages the file and hands it over in the same breath, and the cover closes
        // on the count that hand-over moves (`CameraCapture.keep`, `CameraView`). What is on its
        // own timing is the camera itself: it can be opened over a sheet whose save is already
        // running, and a shutter pressed then delivers into a list the submission was built from.
        // This is the one refusal here that costs something nobody can take again, and it is still
        // the lesser cost: attached, it would sit on a row that is about to close, left out of the
        // memo that closed it.
        guard !isSubmitting else { return }
        sequence += 1
        let attachment = ComposeAttachment(
            id: media.id, media: media, load: .ready, capture: .pending, label: media.filename,
            sequence: sequence, captureZone: zoneAtPick())
        items.append(attachment)
        cameraIDs.insert(attachment.id)
        // Fenced by its identity and its read generation alone, deliberately: this photograph
        // SURVIVES the next pick, so its read must not be thrown away because a selection landed
        // while it was running.
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
        for id in removed { forget(id) }
    }

    /// One item only.
    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        forget(id)
    }

    /// Asks for one failed item again, under the identity it was picked with.
    ///
    /// The identity is the point twice over. The answer is applied to THAT item or to nothing at
    /// all — a retry whose item has been removed, or whose whole selection has been replaced, lands
    /// nowhere. And the item keeps it, so an edit that is retried is the same edit to the server:
    /// the file is re-imported under a new temporary name, but what identifies it does not change
    /// (`PickedMedia.stagedSource`).
    ///
    /// A second retry while one is on the wire is REFUSED rather than joined. There is one file and
    /// one tile; two overlapping imports would race to write it, and the older answer landing last
    /// would put a failure back over a success.
    func retry(id: UUID) async {
        // A retry is asked at a tap and written here, and a Save pressed in between claims the
        // list first: what the tap knew was true at the tap. Landing afterwards, a re-import puts
        // a different file under an identity the upload is already carrying, and a retry that
        // fails puts "Remove them" back on a sheet whose list is fixed. Refused before anything
        // here is claimed or written.
        guard !isSubmitting else { return }
        guard !retryInFlight.contains(id),
            let index = items.firstIndex(where: { $0.id == id })
        else { return }
        guard let handle = retries[id] else {
            // Nothing to ask again, and something to do anyway: this item's FILE is already here —
            // a photograph taken with the camera, or an import whose upload was what failed. The
            // retry is then about the mark and the read, not about fetching the file, and a tile
            // that offers "Try again" and does nothing is worse than one that does not offer it.
            guard items[index].media != nil else { return }
            items[index].uploadFailed = nil
            beginCaptureRead(for: id)
            return
        }
        retryInFlight.insert(id)
        defer { retryInFlight.remove(id) }
        let stamp = current
        items[index].load = .loading
        items[index].capture = .pending
        items[index].uploadFailed = nil
        // AWAIT 2. The list can change completely while this runs.
        let answer = await handle()
        guard stamp == current, let landing = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        items[landing] = Self.settle(items[landing], with: answer)
        if items[landing].media != nil { beginCaptureRead(for: id) }
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

    /// A fresh attempt at posting: why it may not go, or nil.
    ///
    /// The previous attempt's upload marks are cleared BEFORE the list is judged, and the order is
    /// the whole point. A save that failed on transport marks its tiles; judged with those marks
    /// still on, the very next tap is refused as "could not be read" — so the one thing somebody
    /// can do about an upload that failed, which is to try it again, would be the one thing the
    /// sheet would not let them do.
    func beginPostAttempt() -> String? {
        clearUploadFailures()
        return ComposeAttachments.postRefusal(items: items)
    }

    /// Claimed as the submission is taken, and released when the save has come back
    /// (`ComposeView.post()`). Both are synchronous, and nothing is awaited between the claim and
    /// the building of the submission, so a change that lands in the same frame falls on one side
    /// of it or the other and never in between.
    func beginSubmission() {
        isSubmitting = true
    }

    /// The save has come back. What was refused while it ran is not replayed: a change applied a
    /// moment later to a sheet that has already closed is no change at all, and applied to one
    /// still open it is a tap away.
    func endSubmission() {
        isSubmitting = false
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

    // MARK: - bookkeeping

    /// What a tile says before its file has arrived.
    static let arrivingLabel = "A file"

    private func forget(_ id: UUID) {
        retries[id] = nil
        readGeneration[id] = nil
        cameraIDs.remove(id)
    }

    private var keptCaptures: [ComposeAttachment] {
        items.filter { cameraIDs.contains($0.id) }
    }

    /// What one item becomes when its picker answer arrives. Its identity, its place in pick order
    /// and the zone it was picked in all survive — only the file and the state change.
    private static func settle(_ attachment: ComposeAttachment, with answer: ComposePickerAnswer)
        -> ComposeAttachment
    {
        switch answer {
        case .file(var media):
            // The COMPOSER's identity wins over the import's own: a retry re-imports the picker's
            // export under a new name, and the same photograph has to stay the same attachment —
            // to the tile, and to the edit key the server replays a lost answer under.
            media.id = attachment.id
            return ComposeAttachment(
                id: attachment.id, media: media, load: .ready, capture: .pending,
                label: media.filename, sequence: attachment.sequence,
                captureZone: attachment.captureZone)
        case .failed(let category):
            // An item with no file has no capture read to wait for: its decision is settled at
            // nothing, so it never holds up a Post that its own failure is already refusing.
            return ComposeAttachment(
                id: attachment.id, media: nil, load: .failed(category), capture: .settled(.empty),
                label: attachment.label, sequence: attachment.sequence,
                captureZone: attachment.captureZone)
        }
    }
}

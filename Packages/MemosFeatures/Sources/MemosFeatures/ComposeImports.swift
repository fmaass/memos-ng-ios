import Foundation
import MemosCore
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
    var isImporting: Bool { awaitingPick || items.contains(where: \.isLoading) }
    /// Whether a pick has landed whose tiles are not on the row yet.
    ///
    /// The spinner belongs to the person who just chose photographs, and it has to start at the
    /// moment they did — before `load` has installed a single placeholder there is nothing in the
    /// list to read it from, so this is what carries it across that gap.
    private var awaitingPick = false
    /// Where a settled item is announced while a hand-off is following the items Post left
    /// loading (`handOff`); nil otherwise.
    private var arrivals: AsyncStream<UUID>.Continuation?
    /// Whether a submission built from this list is on the wire.
    ///
    /// What a save carries is fixed when Save is pressed — the submission takes the list as it then
    /// stands (`ComposeView.post()`) — so anything that changes the list afterwards changes the row
    /// and not the upload: the memo is saved with one set of pictures and the sheet closes on
    /// another, a divergence nobody is shown. It lives HERE, on the object every one of those
    /// changes is about to be made to, rather than in the sheet's own state: the guard and the
    /// change that follows it are then one synchronous read and write on the same object, with
    /// nothing in between that could suspend. And every callback that can bring such a change in —
    /// the picker's, the camera's (kept for the life of the cover it was handed to, `CameraView`),
    /// a retry's, an x's — holds this object itself, whichever copy of the sheet handed it over.
    private(set) var isSubmitting = false
    /// Whether the set of files as it stands was carried to the server by a save nobody knows the
    /// outcome of.
    ///
    /// A save answered `.transport(sent: true)` or `.serverFailure` left a request the server may
    /// well have applied. The retry that follows is safe only because it goes out under the same
    /// edit key — and that key is minted from the files the attempt carried
    /// (`TimelineStore.editKey(for:)`). Change the set in between and the key changes with it: the
    /// server's replay lookup misses, the patch is read as an edit it has never seen, and its
    /// files are APPENDED
    /// to the ones the first attempt had already committed. So from that answer onwards the set is
    /// frozen, exactly as it is frozen while a save is on the wire. One-way, because what ends it
    /// is the draft ending: a save that succeeds closes the sheet, and a dismissal takes the list
    /// with it.
    private(set) var mayHaveLanded = false

    /// The sentence of the answer that froze the set, and nil for as long as nothing has.
    ///
    /// Written in the same synchronous step as the freeze and kept from then on, because it is the
    /// one sentence the sheet can still show truthfully about this list: a later answer may say
    /// that nothing was changed, and about a set an earlier attempt may already have committed
    /// that is not something anybody here knows.
    private(set) var freezingSentence: String?

    /// Whether a change to what is attached may be taken at this instant.
    ///
    /// The ONE question every such refusal asks, here and on the sheet, so that the answer cannot
    /// be spelled two ways.
    var acceptsChanges: Bool { !isSubmitting && !mayHaveLanded }

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
    /// Which picked item each attachment was made from, for the selection on screen.
    private var pickIdentity: [UUID: AnyHashable] = [:]
    /// The library's persisted identifier of each picked item that has one (MEMNG-952): an item
    /// still loading at Post goes to the queue under it and is copied from Photos there.
    private var assetIdentifiers: [UUID: String] = [:]
    /// The picked items an x has taken off the row while the picker still holds them selected.
    ///
    /// A selection is not diffed and cannot be: it lands as the whole array, and `load` rebuilds
    /// the list from it under fresh identities. Without this, choosing one more photograph after
    /// taking another off puts the removed one back — it is still in the array the picker hands
    /// over. The refusal lasts as long as that selection carries the item: deselecting it in the
    /// picker and choosing it again is a fresh choice, and a selection that arrives without it is
    /// where it is forgotten.
    private var removedPicks: Set<AnyHashable> = []

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
        awaitingPick = true
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
    func load<Item: Sendable & Hashable>(
        _ items: [Item],
        stamp: Int,
        identify: (Item) -> String? = { _ in nil },
        using loader: @escaping @MainActor (Item) async -> ComposePickerAnswer
    ) async -> Bool {
        // A selection that lands once a submission has been built is not this memo's selection any
        // more: a pick REPLACES what was picked, and what was picked is what the save is carrying
        // up while this sheet waits to close on it. Refused, not queued — and refused for as long
        // afterwards as that save may have reached the server (`mayHaveLanded`).
        guard acceptsChanges else {
            // The stamp was taken as the selection landed, and taking it turned the busy flag on.
            // A refusal that walked away from here would leave the composer importing for ever.
            if stamp == current { awaitingPick = false }
            return false
        }
        guard stamp == current else { return false }
        // A selection arriving without a removed item is where that removal is forgotten:
        // choosing it in the picker again is somebody asking for it again.
        removedPicks.formIntersection(items.map(AnyHashable.init))
        var placeholders: [ComposeAttachment] = []
        var handles: [UUID: @MainActor () async -> ComposePickerAnswer] = [:]
        var identities: [UUID: AnyHashable] = [:]
        var assets: [UUID: String] = [:]
        // Sampled HERE, as the pick lands, and stamped onto every item of it.
        let picked = zoneAtPick()
        for item in items {
            let identity = AnyHashable(item)
            // Taken off the row already. The picker still has it selected, so it arrives in every
            // selection made after the removal, and a list rebuilt from the array as it stands
            // would put it back.
            guard !removedPicks.contains(identity) else { continue }
            sequence += 1
            let id = UUID()
            placeholders.append(
                ComposeAttachment(
                    id: id, media: nil, load: .loading, capture: .pending,
                    label: Self.arrivingLabel,
                    sequence: sequence, captureZone: picked))
            handles[id] = { await loader(item) }
            identities[id] = identity
            assets[id] = identify(item)
        }
        // The placeholders are on screen before a single byte is read. `keptCaptures` is read off
        // the list as it still stands — the camera's photographs survive a pick, and only they do —
        // and the two are merged in ONE pick order rather than concatenated by source.
        self.items = (placeholders + keptCaptures).sorted { $0.sequence < $1.sequence }
        // The camera's items carry no retry handle: a photograph taken here cannot be taken again
        // by asking a picker for it, so what a failed capture offers is the camera itself.
        retries = handles
        pickIdentity = identities
        assetIdentifiers = assets
        // Everything the replaced pick was reading is fenced out here: its items are gone from the
        // list above, and their generations go with them.
        readGeneration = readGeneration.filter { cameraIDs.contains($0.key) }
        awaitingPick = false

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
            // with nothing left to settle them.
            guard let index = self.items.firstIndex(where: { $0.id == placeholder.id }) else {
                continue
            }
            self.items[index] = Self.settle(self.items[index], with: answer)
            if self.items[index].media != nil { beginCaptureRead(for: placeholder.id) }
            // Said after the item is settled, so a hand-off reading it finds it final.
            arrivals?.yield(placeholder.id)
        }
        guard stamp == current else { return false }
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
        // memo that closed it. The same holds while a save that may have reached the server is
        // unanswered for: the set that save carried is what its retry has to carry too.
        guard acceptsChanges else { return }
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
        pickIdentity = [:]
        assetIdentifiers = [:]
        // A list dropped whole is not a set of removals to hold against the next selection.
        removedPicks = []
        awaitingPick = false
    }

    /// "Remove them": the items that could not be read, and only those.
    ///
    /// The successful imports and the camera captures stay. Removing them too is how somebody loses
    /// four photographs because a fifth would not download.
    ///
    /// Refused while a save is on the wire, and while one that may have reached the server is
    /// unanswered for: the tiles this offers to clear are part of the set that save carried.
    func removeFailed() {
        guard acceptsChanges else { return }
        let removed = items.filter(\.isFailed).map(\.id)
        items.removeAll(where: \.isFailed)
        for id in removed { forget(id) }
    }

    /// One item only, refused on the same question for the same reason.
    func remove(id: UUID) {
        guard acceptsChanges else { return }
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
        // here is claimed or written. And for as long afterwards as a save that may have reached
        // the server is unanswered for: its retry carries the files the attempt carried.
        guard acceptsChanges else { return }
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
        // Nothing is marked on a frozen set. A mark puts "Try again" on the tile, and every
        // per-tile answer — the retry and the x alike — is refused while the freeze holds
        // (`acceptsChanges`), so the mark would be a control that cannot act for the rest of this
        // sheet's life. What a frozen row is acted on through is the sentence across it and Save.
        // Asked of `mayHaveLanded` alone rather than of `acceptsChanges`: this runs inside the
        // save's own task, where the submission claim is still held and has not been released yet
        // (`ComposeView.post()`), so `acceptsChanges` here would be false for every save.
        guard !mayHaveLanded else { return }
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
    func beginPostAttempt(loadingGoesLater: Bool = false) -> String? {
        clearUploadFailures()
        return ComposeAttachments.postRefusal(items: items, loadingGoesLater: loadingGoesLater)
    }

    // MARK: - Post while importing (MEMNG-951)

    /// Whether Post may be pressed.
    ///
    /// `whileImporting` is a capture whose loads can outlive this sheet: what has loaded goes at
    /// once and the rest follows it into the queue (`handOff`), so an item still loading neither
    /// greys the button nor counts as nothing — a photograph on its way is something to post. A
    /// pick that has landed with no tile on the row yet still holds Post for that instant: there
    /// is nothing to hand off until its placeholders exist.
    func mayPost(text: String, existing: Int, whileImporting: Bool) -> Bool {
        let arriving = whileImporting ? items.filter(\.isLoading).count : 0
        return ComposeAttachments.canPost(
            text: text,
            imported: attachments.count + existing + arriving,
            isBusy: isSubmitting || awaitingPick || (!whileImporting && isImporting)
        )
    }

    /// The items still loading, read at the instant Post takes the list.
    var stillLoading: [UUID] { items.filter(\.isLoading).map(\.id) }

    /// The library's persisted identifier of an item, when the picker gave one.
    func assetIdentifier(for id: UUID) -> String? { assetIdentifiers[id] }

    /// Follows `ids` as they land, handing each file that arrived to `deliver`, one at a time and
    /// in the order they land, until every one has settled or `limit` has passed.
    ///
    /// It belongs to no sheet: it runs on whatever task called it, and the sheet closing cancels
    /// nothing. An item that failed is counted and nothing is delivered for it; an item still
    /// loading at the limit is abandoned, and anything it brings afterwards is not delivered —
    /// the capture it was meant for has been let go by then.
    func handOff(
        _ ids: [UUID],
        within limit: Duration,
        deliver: @escaping @MainActor (PickedMedia) async -> Void
    ) async -> ComposeHandOff {
        var outstanding = Set(ids)
        var outcome = ComposeHandOff()
        // Nothing to follow is nothing to wait for: the stream below would only end at the limit.
        guard !outstanding.isEmpty else { return outcome }
        let (stream, continuation) = AsyncStream<UUID>.makeStream()
        arrivals = continuation
        // What settled between Post and here is said now, in the list's own order.
        for id in ids where items.first(where: { $0.id == id })?.isLoading != true {
            continuation.yield(id)
        }
        let timer = Task { @MainActor in
            try? await Task.sleep(for: limit)
            continuation.finish()
        }
        for await id in stream {
            guard outstanding.remove(id) != nil else { continue }
            if let media = items.first(where: { $0.id == id })?.media {
                outcome.delivered += 1
                await deliver(media)
            } else {
                outcome.failed += 1
            }
            if outstanding.isEmpty { break }
        }
        timer.cancel()
        continuation.finish()
        arrivals = nil
        outcome.abandoned = outstanding.count
        return outcome
    }

    /// Claimed as the submission is taken, and released when the save has come back
    /// (`ComposeView.post()`). Both are synchronous, and nothing is awaited between the claim and
    /// the building of the submission, so a change that lands in the same frame falls on one side
    /// of it or the other and never in between.
    func beginSubmission() {
        isSubmitting = true
    }

    /// The save has come back. What was refused while it ran is not replayed: a change applied a
    /// moment later to a sheet that has already closed is no change at all. Whether it is a tap
    /// away on a sheet still open is the answer's to decide — an answer that may have reached the
    /// server holds the list where it is for the rest of this sheet's life (`mayHaveLanded`), and
    /// while no answer has, a save that is back leaves every change free to be made again.
    func endSubmission() {
        isSubmitting = false
    }

    /// The save came back with no answer about what the server did with it.
    ///
    /// Taken from the failure VALUE, because only two values mean the request left this device:
    /// `.transport(sent: true)` and `.serverFailure`. The tile category is a different question —
    /// what a tile can say about a file — and answers that never left share one with answers that
    /// did, so it can decide nothing here.
    ///
    /// The freeze and the sentence that comes with it are written together and only once. A first
    /// answer of this kind is what the set is frozen ON; anything after it is about a set that was
    /// already frozen, and overwriting the sentence would replace what somebody has to act on with
    /// a later, narrower account of the same uncertainty.
    func mayHaveLandedOnServer(_ failure: ComposeFailure) {
        guard !mayHaveLanded else { return }
        mayHaveLanded = true
        freezingSentence = ComposeFailurePresentation.sentence(for: failure)
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
        // Remembered against the picker's selection, which still has this item in it: the next
        // one arrives as the whole array, this item included (`removedPicks`).
        if let identity = pickIdentity[id] { removedPicks.insert(identity) }
        pickIdentity[id] = nil
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

/// What following the items Post left loading came to.
struct ComposeHandOff: Equatable {
    var delivered = 0
    var failed = 0
    var abandoned = 0
}

import Foundation
import MemosOutbox

/// What became of a share.
public enum ShareOutcome: Sendable, Equatable {
    /// The capture is on disk in the app group, whole, under this job id. What sends it is decided
    /// after this returns: the extension's own per-capture session when it holds an upload
    /// credential (`ShareTransfer`), else the app's next drain.
    case enqueued(UUID)
    /// Nobody is signed in as far as anything outside the app can tell, so nothing was written.
    case notSignedIn
    /// The account changed between the sheet opening and Post — a sign-out and a sign-in, or a
    /// switch to another account. Nothing was written: the person composed this capture for the
    /// account they were looking at, and posting it into a different one is not a smaller mistake
    /// than losing it.
    case accountChanged
    /// No files and no words: there is no memo here to keep.
    case nothingToPost
}

/// The first half of a share: persist the capture, bind it to the account, and return.
///
/// It sends nothing itself. The single-attach rule holds PER IDENTIFIER, not per process: one
/// `URLSession` per background identifier in each process. So once this has committed, the
/// extension may start the uploads under a session of the capture's own
/// (`live.discomarder.memosng.uploads.share.<jobUUID>`, `ShareTransfer`), never the app's, and
/// registers that identifier in the app group (`SessionRegistry`); the app attaches to every
/// registered identifier on any wake, reconciles its tasks against the manifest and retires it
/// once the capture landed. Without an upload credential nothing is started, and the app's next
/// launch or background refresh moves the bytes.
public enum ShareIngest {
    /// - Parameter licence: how to READ the licence, not a licence somebody read earlier. It is a
    ///   closure because this method awaits — the capture reads below — and a share sheet can stand
    ///   for as long as somebody leaves it there: a value sampled before those awaits is a value
    ///   that can be out of date by the time anything is written. Nil means nobody is signed in, and
    ///   then NOTHING is written rather than a capture being stamped with a guess: a job bound to
    ///   the wrong account is one the engine holds forever, which looks exactly like a memo that
    ///   was lost. It reads a whole licence rather than a binding because signing out and back into
    ///   the same account republishes the identical pair: only the grant it was published under
    ///   tells the two apart, and this method can be waiting on a busy queue while that happens.
    /// - Parameter expecting: the licence the sheet was opened with. A share sheet can sit on
    ///   screen for as long as someone leaves it there, and a sign-out or an account switch in the
    ///   app underneath it must not be posted through.
    /// - Parameter capturedAt: what to date the memo when the files say nothing — the moment of
    ///   sharing. A file that DOES carry a capture date wins over it: the same Auto rule the
    ///   composer follows, because a photograph shared from Photos is exactly the case the rule was
    ///   written for.
    /// - Parameter zone: the DISPLAY zone — what "different calendar days" is counted in. Each
    ///   file's own reading is resolved in the zone IT was imported in (`SharedFile.captureZone`),
    ///   which is a different moment: the sheet takes the files as it opens and Post can come much
    ///   later, from somewhere else.
    /// - Parameter read: how a file's own capture date is read. Injected so the ORDER and the DATE
    ///   can be tested without a real photograph, and so this stays one read per file.
    /// - Parameter clock: the time a queue held by the app is waited out on — the deadline and the
    ///   waiting are one clock, so a test can drive both without spending either. The default is
    ///   real time, which is what the extension runs on.
    public static func commit(
        items: [SharedItem],
        note: String,
        visibility: ShareVisibility?,
        licence readLicence: @escaping @Sendable () -> PublishedLicence?,
        expecting: AccountBinding?,
        capturedAt: Date = Date(),
        zone: TimeZone = .current,
        read: (SharedFile) async -> CaptureReading = {
            await CaptureReader.read(fileAt: $0.url, mime: $0.mime)
        },
        waitingOn clock: any OutboxWaitClock = OutboxSystemWaitClock(),
        into repository: OutboxRepository
    ) async throws -> ShareOutcome {
        // Everything that can be answered without leaving is answered first, so a share with
        // nothing in it, or one whose account has already gone, costs no reads at all.
        guard let opening = readLicence() else { return .notSignedIn }
        if let expecting, expecting != opening.binding { return .accountChanged }
        let content = ShareComposition.content(note: note, items: items)
        let files = items.compactMap(\.file)
        guard !content.isEmpty || !files.isEmpty else { return .nothingToPost }

        // One read per file. It is the ONLY await this makes before the write, and it is taken
        // BEFORE the licence is settled rather than after: a share sheet can stand for as long as
        // somebody leaves it there, and a sign-out or an account switch during these reads must not
        // be posted through. What the answers decide is the same as in the app — the memo's date,
        // and the order the pictures go in. (There is no per-item fence to keep: a share sheet holds
        // ONE set of files that cannot be replaced while it stands, so every answer belongs to the
        // item it was asked about.)
        var carried: [CapturedShare] = []
        for file in files {
            carried.append(CapturedShare(file: file, capture: .settled(await read(file))))
        }
        let ordered = AutoMemoDate.captureOrder(carried, in: zone)
        let auto = AutoMemoDate.autoMemoDate(carried, in: zone)

        // The licence RE-READ, as the last thing before the write and after every await above. It
        // is read from the file rather than remembered, because the app is a different process and
        // the file is the only shared truth: a sign-out during the reads has to stop this write.
        guard let standing = readLicence() else { return .notSignedIn }
        // Against what was standing when this commit BEGAN, whether or not the sheet supplied an
        // expectation of its own. `expecting` is what the sheet was opened with — a longer window,
        // and one a caller may not have — and neither of them covers an account that changes inside
        // this call.
        if standing != opening { return .accountChanged }
        if let expecting, expecting != standing.binding { return .accountChanged }
        do {
            // The copy is the slow part, and the licence is asked for AGAIN inside the repository,
            // immediately before the manifest is committed: an account that changes while the bytes
            // are being copied must not leave a capture stamped with the one that has gone.
            // And retried while the QUEUE is the thing refusing: the app holds the outbox root for
            // the length of a sweep, and a share sheet that gave up on that instant would ask
            // somebody to write their memo again over a lock they cannot see. Bounded, so a hold
            // that does not end is still an answer. The whole attempt is inside the wait rather
            // than the copy alone — the authority below is a fresh closure over the same opening
            // licence on every attempt, so a capture accepted on the third one is as fenced as one
            // accepted on the first.
            let job = try await retryingWhileQueueBusy(on: clock) {
                try await repository.enqueue(
                    content: content,
                    visibility: visibility?.rawValue,
                    capturedAt: auto.instant ?? capturedAt,
                    binding: standing.binding,
                    sources: ordered.map(\.file.stagedSource),
                    // The WHOLE licence, not the pair inside it: a forget and a sign-in to the
                    // same account during the wait publishes the identical binding, and the grant
                    // is the only thing that says the capture was admitted under a session that
                    // has since ended.
                    under: SendAuthority { readLicence() == opening }
                )
            }
            return .enqueued(job.id)
        } catch is SendAuthorityWithdrawn {
            return .accountChanged
        }
    }
}

/// One shared file and what it said about when it was taken, so the shared set can be ordered by
/// the same function the composer's tiles are — each in the zone it was IMPORTED in.
struct CapturedShare: CaptureCarrying {
    var file: SharedFile
    var capture: CaptureDecision

    var captureZone: TimeZone? { file.captureZone }
}

import Foundation
import MemosOutbox

/// What became of a share.
public enum ShareOutcome: Sendable, Equatable {
    /// The capture is on disk in the app group, whole, under this job id. It uploads when the app
    /// next drains the queue — the extension never sends anything itself.
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

/// The share extension's whole job: persist the capture, bind it to the account, and stop.
///
/// It deliberately cannot upload. The single-attach rule means one process owns the background
/// session, and that process is the app: an extension that started its own would race the app for
/// the same chunks and lose its host mid-transfer. So this writes to the queue the app drains, and
/// the app's next launch or background refresh moves the bytes.
public enum ShareIngest {
    /// - Parameter binding: the licence as it reads NOW, at the moment of use — not as it read
    ///   when the sheet opened. Nil means nobody is signed in, and then NOTHING is written rather
    ///   than a capture being stamped with a guess: a job bound to the wrong account is one the
    ///   engine holds forever, which looks exactly like a memo that was lost.
    /// - Parameter expecting: the licence the sheet was opened with. A share sheet can sit on
    ///   screen for as long as someone leaves it there, and a sign-out or an account switch in the
    ///   app underneath it must not be posted through.
    /// - Parameter capturedAt: what to date the memo when the files say nothing — the moment of
    ///   sharing. A file that DOES carry a capture date wins over it: the same Auto rule the
    ///   composer follows, because a photograph shared from Photos is exactly the case the rule was
    ///   written for.
    /// - Parameter zone: the zone a wall-clock EXIF time with no offset is resolved in.
    /// - Parameter read: how a file's own capture date is read. Injected so the ORDER and the DATE
    ///   can be tested without a real photograph, and so this stays one read per file.
    public static func commit(
        items: [SharedItem],
        note: String,
        visibility: ShareVisibility?,
        binding: AccountBinding?,
        expecting: AccountBinding?,
        capturedAt: Date = Date(),
        zone: TimeZone = .autoupdatingCurrent,
        read: (SharedFile) async -> CaptureReading = {
            await CaptureReader.read(fileAt: $0.url, mime: $0.mime)
        },
        into repository: OutboxRepository
    ) async throws -> ShareOutcome {
        guard let binding else { return .notSignedIn }
        if let expecting, expecting != binding { return .accountChanged }
        let content = ShareComposition.content(note: note, items: items)
        let files = items.compactMap(\.file)
        guard !content.isEmpty || !files.isEmpty else { return .nothingToPost }
        // One read per file, before anything is written down. There is no fence to keep here the
        // way the composer keeps one: a share sheet holds ONE set of files that cannot be replaced
        // while it stands, so every answer belongs to the item it was asked about. What the answers
        // decide is the same as in the app — the memo's date, and the order the pictures go in.
        var carried: [CapturedShare] = []
        for file in files {
            carried.append(CapturedShare(file: file, capture: .settled(await read(file))))
        }
        let ordered = AutoMemoDate.captureOrder(carried, in: zone)
        let auto = AutoMemoDate.autoMemoDate(carried, in: zone)
        let job = try await repository.enqueue(
            content: content,
            visibility: visibility?.rawValue,
            capturedAt: auto.instant ?? capturedAt,
            binding: binding,
            sources: ordered.map(\.file.stagedSource)
        )
        return .enqueued(job.id)
    }
}

/// One shared file and what it said about when it was taken, so the shared set can be ordered by
/// the same function the composer's tiles are.
struct CapturedShare: CaptureCarrying {
    var file: SharedFile
    var capture: CaptureDecision
}

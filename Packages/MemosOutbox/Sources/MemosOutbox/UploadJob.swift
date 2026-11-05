import Foundation

/// Which server, and whose account, a capture was made under.
///
/// It is persisted with the job because the phone outlives the session: a memo written offline
/// under one account must never be posted later under whoever happens to be signed in when the
/// wifi comes back. The token is deliberately NOT part of this — a credential in a queue file is
/// a credential in a backup.
public struct AccountBinding: Codable, Sendable, Equatable {
    public var serverBaseURL: URL
    public var ownerSubject: String
    /// Whose credential the capture travels under. Optional and last, so every manifest written
    /// before guests existed decodes unchanged and reads as `.member`; never written for a member,
    /// so a member capture's manifest stays byte-identical. An older build that reads a guest
    /// capture ignores this key, but the guest door's server never equals the member's, so that
    /// build holds the capture as another account's rather than posting it home.
    public var kind: CredentialKind?

    public init(serverBaseURL: URL, ownerSubject: String, kind: CredentialKind? = nil) {
        self.serverBaseURL = serverBaseURL
        self.ownerSubject = ownerSubject
        self.kind = kind == .member ? nil : kind
    }

    private enum CodingKeys: String, CodingKey {
        case serverBaseURL
        case ownerSubject
        case kind
    }

    /// A spelled-out `member` decodes as the absent key every member manifest has, so two bindings
    /// for the same member account are equal however the key was written.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            serverBaseURL: try fields.decode(URL.self, forKey: .serverBaseURL),
            ownerSubject: try fields.decode(String.self, forKey: .ownerSubject),
            kind: try fields.decodeIfPresent(CredentialKind.self, forKey: .kind)
        )
    }

    /// The kind, with an absent one read as what every older manifest was.
    public var credentialKind: CredentialKind { kind ?? .member }

    public func matches(_ credentials: OutboxCredentials) -> Bool {
        serverBaseURL == credentials.serverBaseURL && ownerSubject == credentials.ownerSubject
            && credentialKind == credentials.kind
    }
}

/// Where a queued capture is, as the person would describe it.
public enum JobState: String, Codable, Sendable, Equatable {
    /// Nothing is in flight: either the server has not been reachable yet, or the job is spacing
    /// out a retry.
    case waiting
    /// Bytes are moving, or a chunk is with the background session.
    case uploading
    /// Every byte is on the server; the memo itself is being created.
    case creating
    /// Stopped until a person does something. A held job is never retried on a timer — that is
    /// the difference between a queue and a loop.
    case held
}

/// Why a job stopped needing a person.
public enum HoldReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// Captured under a different account or a different server than the one signed in now.
    case accountMismatch
    /// The server refused in a way that repeating cannot fix.
    case serverRefused
    /// The capture's manifest on disk could not be read. Its originals and the manifest itself are
    /// both KEPT — the manifest set aside rather than deleted — and this is what the outbox says
    /// about it, because a capture that disappears without a word is the one failure this package
    /// exists to prevent.
    case unreadableManifest
    /// A change to this capture could not be written to disk, so as far as anything is concerned
    /// the change did not happen. The capture stops here rather than being carried on from a state
    /// only memory believes in.
    case storageFailed
    /// A picture this capture's change keeps is not nameable to the server: its bytes are gone from
    /// this device, or the change names a file the capture no longer has. Nothing was sent.
    case editIncomplete
    /// The memo this capture's change is owed to is no longer on the server. It is a reason of its
    /// own rather than a sentence under `serverRefused`, because the row's actions are read from
    /// the reason, and this is the one unanswered change a person may remove outright — the editor
    /// stays closed to it while the change is unanswered.
    case memoGone
    /// The server lost this capture's upload session every time a fresh one was opened, up to
    /// `UploadBudget.maxFreshSessionsPerFile`. Opening yet another would only repeat it.
    case uploadSessionLost
    /// The server will not take a file this large (413). Sending it again sends the same bytes, so
    /// the fix is the person's: take the file out, or remove the capture.
    case tooLarge
    /// The grant this capture was sent under was turned away and is still the device's. The fix
    /// is signing in again; nothing the queue repeats changes the answer.
    case signInRequired

    /// The one move that resumes a capture held for this reason, named beside the reason. A hold
    /// has no timer (`RetryClass.hold`), so this names its only way out. It is logged with the
    /// reason (`OutboxEngine.logReason`) and pins which button leads a row — the pending row's own
    /// actions are still chosen by `PendingMemoPresentation.action(for:)`, which agrees with it.
    public var fixAction: FixAction {
        switch self {
        case .accountMismatch: .switchAccount
        case .signInRequired: .signIn
        case .unreadableManifest, .memoGone, .tooLarge: .remove
        case .editIncomplete: .reopen
        case .serverRefused, .storageFailed, .uploadSessionLost: .retry
        }
    }

    /// Every hold is the hold class: no timer, resumed by its fix.
    public var retryClass: RetryClass { .hold }
}

/// What a person does to resume a held capture. The raw value is the same word the log and any
/// metric label use, so the three never disagree about which fix a row was waiting on.
public enum FixAction: String, Codable, Sendable, Equatable, CaseIterable {
    /// Try again as it stands — the cause is not the capture's.
    case retry
    /// Throw the capture (or the offending file) away; sending it again cannot succeed.
    case remove
    /// Sign in again, so a fresh grant sends it.
    case signIn
    /// Sign in as the account the capture was made under.
    case switchAccount
    /// Open the capture in the editor again, where the missing part can be put right.
    case reopen
}

/// Why a waiting job is waiting, by class: on an EVENT (the network) or on the clock (`retrying`).
///
/// It is nil for a job that has not been tried yet, which is also how a manifest written before
/// this existed decodes — the field is optional so that a queue from an older build is read, never
/// quarantined. The raw value is the reason string the app, the log and any metric label share.
public enum WaitReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// The phone is on a network this capture may not use: mobile data with the toggle off, or
    /// Low Data Mode, which waits whatever the toggle says.
    case homeNetwork
    /// The phone has no network at all. Nothing is tried and no timer is set; the path coming
    /// back is what sends it.
    case noNetwork
    /// Mobile data is allowed, but this capture still has a video over
    /// `UploadNetworkPolicy.mobileVideoLimit` to send, and that waits for Wi-Fi.
    case videoOverMobileLimit
    /// Mobile data is allowed, but videos are set to go on Wi-Fi only (`MobileVideoPolicy.never`)
    /// and this capture still has one to send.
    case videoOnWiFiOnly
    /// A transient failure is spacing itself out (`RetrySchedule`): the one reason that waits on
    /// the clock rather than on an event. Written by every backoff, so a row between attempts
    /// says it is retrying instead of guessing at a network it was never waiting for (MEMNG-657).
    case retrying

    /// Which class this wait belongs to: the clock for `retrying`, the path event for the rest.
    public var retryClass: RetryClass {
        switch self {
        case .retrying: .transient
        case .homeNetwork, .noNetwork, .videoOverMobileLimit, .videoOnWiFiOnly: .connectivity
        }
    }

    /// The two reasons a video rule gives — the ones "Use mobile data for this one" ends.
    public var isVideoRule: Bool {
        self == .videoOverMobileLimit || self == .videoOnWiFiOnly
    }
}

/// Which background transport carries a capture's bytes.
///
/// The lane is chosen once per capture and persisted with it, because a relaunch has to know which
/// session's tasks the row's files ride on. A manifest written before the second lane existed has
/// no such field, and that reads as `.chunk`: every row an older build began finishes on the lane
/// it began on.
public enum UploadTransport: String, Codable, Sendable, Equatable {
    /// One slice per task on the chunk session, resumed at the offset the server confirmed.
    case chunk
    /// One task per file carrying the whole original from its first byte, sent again whole when it
    /// fails.
    case whole
}

/// One captured file, and how much of it the SERVER says it has.
///
/// `bytesConfirmed` is only ever written from a server answer (the PATCH response body or the
/// offset HEAD). Local arithmetic about what "should" have arrived is how a resumed upload
/// corrupts a file.
public struct OutboxFile: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Path of the copied original, relative to the job's media directory.
    public var relativePath: String
    public var filename: String
    public var mime: String
    public var byteSize: Int64
    /// The original's modification date, sent as the upload session's `last_modified`.
    public var lastModified: Date?
    /// The server's handle for this file's upload session, once one exists.
    public var uploadUID: String?
    public var bytesConfirmed: Int64
    /// The chunk size the server asked for when the session was created.
    public var chunkSize: Int
    /// Which retry of this file the current upload belongs to. Optional and last, so a manifest
    /// written before retries were counted decodes unchanged and reads as nil — which is what an
    /// equally attempt-less task description says, and the two have to agree to be adopted.
    public var uploadAttempt: Int?
    /// The uid the memo's own picture carries, once the create's answer has been matched to this
    /// original. It is the ONLY name an edit may use for a picture the memo already holds — an
    /// upload uid is not one — and it is written once, where that answer is applied. Optional and
    /// last, so a manifest written before this existed decodes unchanged and reads as unnamed. An
    /// edit never names an unnamed original by a guess: before the edit is claimed it is uploaded
    /// again and named by that upload, or, where this device can no longer read it, the edit holds
    /// as incomplete.
    public var attachmentUID: String?
    /// Set on a picture picked while the capture was back in the editor, and on a kept original
    /// uploaded again because the create's answer could not name it (`stageUnnamedOriginals`).
    ///
    /// It is what keeps that picture OUT of the create: the create is replayed exactly as it was
    /// first sent — that is what resolves an uncertain create to the memo it made rather than to a
    /// second one — and a picture the first send never named cannot appear in the replay. It
    /// reaches the memo through the edit instead. Optional and last, so a manifest written before
    /// this existed decodes unchanged and reads as "captured", which is what it is.
    public var stagedForEdit: Bool?
    /// When this file on the whole lane may be sent again, and how many of its sends have failed in
    /// a row. The file's own, not the capture's: a sibling's success says nothing about this file's
    /// server, and clearing it there was a retry storm. Optional and last, so a manifest written
    /// before they existed decodes unchanged and reads as "never failed".
    public var nextAttemptAt: Date?
    public var attemptCount: Int?
    /// How many fresh upload sessions this file has been given in a row because the offset HEAD
    /// found its session gone. Bounded by `UploadBudget.maxFreshSessionsPerFile`: past it the
    /// capture holds rather than opening sessions the server keeps losing. Reset when the file is
    /// confirmed or a person releases the capture. Optional and last, so an older manifest decodes.
    public var freshSessions: Int?
    /// Set when a resumed transfer was refused for disagreeing about the offset: the next step is
    /// ONE offset HEAD, and a second disagreement in a row starts a fresh session instead of
    /// asking again. Optional and last, so an older manifest decodes.
    public var conflictResync: Bool?
    /// Set when the guest door answered the create with "already received": the pass holds these
    /// exact bytes, so nothing is PATCHed and the file is named in no completion. Never set on the
    /// member lane. Optional and last, so an older manifest decodes.
    public var alreadyReceived: Bool?

    public init(
        id: UUID = UUID(),
        relativePath: String,
        filename: String,
        mime: String,
        byteSize: Int64,
        lastModified: Date? = nil,
        uploadUID: String? = nil,
        bytesConfirmed: Int64 = 0,
        chunkSize: Int = OutboxDefaults.chunkSize,
        uploadAttempt: Int? = nil,
        attachmentUID: String? = nil,
        stagedForEdit: Bool? = nil,
        nextAttemptAt: Date? = nil,
        attemptCount: Int? = nil,
        freshSessions: Int? = nil,
        conflictResync: Bool? = nil,
        alreadyReceived: Bool? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.filename = filename
        self.mime = mime
        self.byteSize = byteSize
        self.lastModified = lastModified
        self.uploadUID = uploadUID
        self.bytesConfirmed = bytesConfirmed
        self.chunkSize = chunkSize
        self.uploadAttempt = uploadAttempt
        self.attachmentUID = attachmentUID
        self.stagedForEdit = stagedForEdit
        self.nextAttemptAt = nextAttemptAt
        self.attemptCount = attemptCount
        self.freshSessions = freshSessions
        self.conflictResync = conflictResync
        self.alreadyReceived = alreadyReceived
    }

    public var isComplete: Bool {
        alreadyReceived == true || (uploadUID != nil && bytesConfirmed >= byteSize)
    }
}

/// A capture waiting for the server: the note, the originals, and everything needed to finish the
/// job from a cold start.
/// The edits a restored draft carries back, held beside the capture as it was FIRST SENT.
///
/// The create is replayed unchanged under the original key — that is what resolves a create whose
/// answer was lost to the memo it made — and these are what is then applied to that memo. A
/// manifest written before this existed carries no such value at all, which is what "nothing is
/// pending" decodes as.
public struct PendingEdit: Codable, Sendable, Equatable {
    public var content: String
    public var visibility: String?
    public var capturedAt: Date
    /// The pictures the memo keeps, in the order the editor left them.
    public var fileIDs: [UUID]

    public init(content: String, visibility: String?, capturedAt: Date, fileIDs: [UUID]) {
        self.content = content
        self.visibility = visibility
        self.capturedAt = capturedAt
        self.fileIDs = fileIDs
    }
}

/// What makes a job an EDIT of a memo that already exists rather than a capture that becomes one
/// (MEMNG-954). The rest of the edit lives where a capture's owed edit already lives — the memo in
/// `resolvedMemoUID`, the words, audience and date in `pendingEdit`, the key in `editKey` (minted
/// once, when the job is written), the new files in `files` marked `stagedForEdit` — so the engine
/// sends it through the branch that replays an owed edit. This carries only what an edit of an
/// existing memo says differently.
public struct MemoEdit: Codable, Sendable, Equatable {
    /// False leaves `created_at` out of the PATCH: an edit that did not touch the date has no
    /// business rewriting it.
    public var statesDate: Bool
    /// The memo's WHOLE picture list in the sheet's order, or nil to leave its pictures untouched
    /// (`attachment_uids` omitted).
    public var pictures: [Picture]?

    public enum Picture: Codable, Sendable, Equatable {
        /// A picture the memo already holds, by its attachment uid.
        case kept(String)
        /// One of this job's own files, by its id.
        case added(UUID)
    }

    public init(statesDate: Bool, pictures: [Picture]?) {
        self.statesDate = statesDate
        self.pictures = pictures
    }
}

/// What a caller asks of an existing memo when it adds files to it — the input `Outbox.enqueueEdit`
/// turns into an edit job. An added picture is named by its place in the sources handed over beside
/// this, since it has no identity until it is copied in.
public struct MemoEditOrder: Sendable, Equatable {
    public var memoUID: String
    public var content: String
    /// The audience's wire value, or nil to leave it.
    public var visibility: String?
    /// The display date, or nil to leave it.
    public var createdAt: Date?
    /// The memo's whole picture list, or nil to leave its pictures untouched.
    public var pictures: [Picture]?

    public enum Picture: Sendable, Equatable {
        case kept(String)
        case adding(Int)
    }

    public init(
        memoUID: String, content: String, visibility: String?, createdAt: Date?,
        pictures: [Picture]?
    ) {
        self.memoUID = memoUID
        self.content = content
        self.visibility = visibility
        self.createdAt = createdAt
        self.pictures = pictures
    }
}

public struct UploadJob: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Generated once, at capture, and sent on every create attempt for this job. It is what makes
    /// a retry after a lost response produce the same memo instead of a second one.
    public var idempotencyKey: UUID
    public var content: String
    /// The wire value (`PRIVATE`/`PROTECTED`/`PUBLIC`), or nil to let the account's default apply.
    public var visibility: String?
    /// When the person made the capture — sent as the memo's `created_at`, so a memo written on
    /// Monday and uploaded on Wednesday is still dated Monday.
    public var capturedAt: Date
    public var files: [OutboxFile]
    public var binding: AccountBinding
    public var state: JobState
    public var holdReason: HoldReason?
    /// What a waiting job is waiting FOR, when it is waiting for something a person can change.
    public var waitReason: WaitReason?
    public var attemptCount: Int
    public var nextAttemptAt: Date
    public var lastError: String?
    /// When a person took this capture back to the editor. Optional because a manifest written
    /// before this existed has no such field, and absent has to keep meaning "never cancelled"
    /// rather than making that manifest unreadable.
    public var cancelledAt: Date?
    /// The memo a create resolved to, once the server named it.
    public var resolvedMemoUID: String?
    /// The key the edit below is applied under, minted once per logical edit and kept across
    /// every transmission of that edit, so a replay is the same apply rather than a second one.
    /// A second edit of the same memo is a different edit and mints a key of its own — but a
    /// create that resolved while an edit was already owed and no key had been minted adopts the
    /// create's idempotency key here, once (`OutboxEngine.complete`).
    public var editKey: String?
    /// How often the pending edit has been CLAIMED for transmission, advanced by the fenced write
    /// made after the request is built and before it is sent — so it counts intents to send, not
    /// arrivals. A relaunch deliberately claims the edit again — that is the recovery — and this
    /// counts those claims rather than preventing them; what makes the extra transmission harmless
    /// is the key above, which turns it into a replay of the same edit.
    public var patchAttempt: Int?
    /// What the editor changed while the create was in flight, still owed to the memo above.
    public var pendingEdit: PendingEdit?
    /// When this logical edit was FIRST claimed for transmission — written once the request has
    /// been built and before it is sent, and kept at that first instant across every replay, so a
    /// re-transmission does not make the capture look newly uncertain. Cleared only by an edit the
    /// server applied or by a refusal the frozen body determines; while it is set, no answer about
    /// this key has come back, so the body, the picture list and the key are frozen and the
    /// capture cannot be taken back to the editor. Optional because a manifest written before this
    /// existed has none, and absent means the key's fate is known.
    public var editUnansweredSince: Date?
    /// The lane this capture's bytes travel on, once one was chosen. Optional and last, so a
    /// manifest written before the choice existed decodes unchanged — `lane` says what nil means.
    public var transport: UploadTransport?
    /// The launch whose editor is still bringing files into this capture: Post was pressed while
    /// some of them were loading, and they are appended here as they land (MEMNG-951). While it is
    /// set the create is not sent — a create replayed under the same key with more files would be
    /// a different request the server answers with the first memo — and the files already here
    /// upload meanwhile. Cleared by that editor when its last file has landed or its time is up,
    /// and by the next launch's adoption when the process that set it died first. Optional and
    /// absent on every manifest written before it, which is "nothing is still arriving".
    public var stagingLaunch: UUID?

    /// The picked items still in Photos, each to be copied in by the `StagingLane` (MEMNG-952).
    /// An item leaves this list in the same write that adds it to `files`, under its own id, so a
    /// copy is never added twice. Optional and absent on every manifest written before it, which
    /// is "nothing is left in Photos".
    public var staging: [StagingFile]?

    /// Set on an edit of a memo that already exists (MEMNG-954), and only there: such a job never
    /// sends a create. Absent on every manifest written before it, which is "a capture".
    public var memoEdit: MemoEdit?

    /// The items `staging` still holds; empty when it is absent.
    public var stagingFiles: [StagingFile] { staging ?? [] }

    /// Whether files are still arriving, from the editor or from Photos, so the create must wait
    /// for them.
    public var stillArriving: Bool { stagingLaunch != nil || !stagingFiles.isEmpty }

    /// Who the memo is meant to be visible to as the capture now stands (MEMNG-971): the owed
    /// edit's value when it carries one, else the create's — the same fallback the edit's request
    /// is built with (`OutboxRequests.patchMemo`). Nil is the account's default.
    public var intendedVisibility: String? { pendingEdit?.visibility ?? visibility }

    /// How many of the items picked for this capture have not reached it. Set when Post takes a
    /// capture with items still loading, one less for each that is appended; what is left when the
    /// capture is let go — a load that failed, a copy that failed, an append the queue refused, the
    /// time limit, a process that died first — never will, and the card says so rather than
    /// sending the memo a picture short in silence (MEMNG-951). The originals are still in Photos.
    /// Optional and absent on every manifest written before it, which is "nothing is missing".
    public var notArrived: Int?

    /// The person let THIS capture's files go over mobile data with "Use mobile data for this one"
    /// on its Transfers row: no video rule holds it (`mobileVideoWait`). It changes neither
    /// setting, and the mobile-data switch still decides as it always does — with that off, this
    /// capture waits for Wi-Fi like any other. Kept on the manifest, so a relaunch keeps it.
    /// Optional and absent on every manifest written before it, which is "not let go".
    public var videoOverMobileAllowed: Bool?

    /// The picked items that will never reach this capture: zero while they still may.
    public var missingItems: Int { stillArriving ? 0 : max(0, notArrived ?? 0) }

    /// A capture with nothing in it to send: no words, no files, no create ever sent, and no
    /// file still on its way — what a Post whose every picked item failed leaves behind. Its
    /// create would be an empty memo or a refusal, so the only thing it may become is removed
    /// (`Outbox.resubmit` refuses it; its row offers only Remove).
    public var hasNothingToSend: Bool {
        !stillArriving && files.isEmpty && !createMayHaveBeenSent
            && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the server may already hold this capture's memo: a create is on the wire, has been
    /// answered, or went out once and came back with no answer (a replay under the same key
    /// would return that memo). Removing such a capture here would not remove the memo, so the
    /// one decision that hangs on it — whether "Remove" may be offered — reads it from here.
    /// Conservative on purpose: a failed attempt with every file up counts, whatever failed.
    public var createMayHaveBeenSent: Bool {
        // An edit of an existing memo has no create: whether ITS change may have landed is
        // `editUnansweredSince`, which every caller of this asks beside it.
        guard memoEdit == nil else { return false }
        return state == .creating || resolvedMemoUID != nil
            || (attemptCount > 0 && files.allSatisfy(\.isComplete))
    }

    private enum CodingKeys: String, CodingKey {
        case id, idempotencyKey, content, visibility, capturedAt, files, binding, state
        case holdReason, waitReason, attemptCount, nextAttemptAt, lastError, cancelledAt
        case resolvedMemoUID, editKey, patchAttempt, pendingEdit
        // Every manifest already written spells it this way, and a rename that re-spelled it would
        // read as "no change is owed" on every capture a person is already carrying.
        case editUnansweredSince = "editSentAt"
        case transport
        case stagingLaunch
        case notArrived
        case staging
        case memoEdit
        case videoOverMobileAllowed
    }

    public init(
        id: UUID = UUID(),
        idempotencyKey: UUID = UUID(),
        content: String,
        visibility: String? = nil,
        capturedAt: Date,
        files: [OutboxFile],
        binding: AccountBinding,
        state: JobState = .waiting,
        holdReason: HoldReason? = nil,
        waitReason: WaitReason? = nil,
        attemptCount: Int = 0,
        nextAttemptAt: Date = .distantPast,
        lastError: String? = nil,
        cancelledAt: Date? = nil,
        resolvedMemoUID: String? = nil,
        editKey: String? = nil,
        patchAttempt: Int? = nil,
        pendingEdit: PendingEdit? = nil,
        editUnansweredSince: Date? = nil,
        transport: UploadTransport? = nil,
        stagingLaunch: UUID? = nil,
        notArrived: Int? = nil,
        staging: [StagingFile]? = nil,
        memoEdit: MemoEdit? = nil,
        videoOverMobileAllowed: Bool? = nil
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.content = content
        self.visibility = visibility
        self.capturedAt = capturedAt
        self.files = files
        self.binding = binding
        self.state = state
        self.holdReason = holdReason
        self.waitReason = waitReason
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.cancelledAt = cancelledAt
        self.resolvedMemoUID = resolvedMemoUID
        self.editKey = editKey
        self.patchAttempt = patchAttempt
        self.pendingEdit = pendingEdit
        self.editUnansweredSince = editUnansweredSince
        self.transport = transport
        self.stagingLaunch = stagingLaunch
        self.notArrived = notArrived
        self.staging = staging
        self.memoEdit = memoEdit
        self.videoOverMobileAllowed = videoOverMobileAllowed
    }

    /// The lane a capture is on. Nil is every row begun before the lane was recorded, and those
    /// were all begun on the chunk lane.
    public var lane: UploadTransport { transport ?? .chunk }

    /// This capture moved onto the whole lane, or nil when nothing in it was begun in chunks.
    ///
    /// The member queue has no chunk lane any more (MEMNG-546), so a row an older build began on it
    /// is written onto the whole lane where it is first read. A row says it was begun in chunks by
    /// naming that lane, or by naming none while a file already holds a session — the rule the
    /// first hand-off has always claimed by (`OutboxEngine.claimsWhole`). A row with no field and
    /// no session is NOT moved here: it has nothing to restart, its first hand-off claims it, and
    /// the share extension reads that missing field as "nobody has claimed this capture yet".
    ///
    /// Every file the server has not finished starts again from its first byte: its session is
    /// forgotten (one the server still holds expires on its own) and nothing it confirmed is
    /// carried over, because the whole lane sends a file in one task, never from an offset a chunk
    /// left. A file the server holds whole stays done — it is never sent twice.
    public func retiringChunkLane() -> UploadJob? {
        let begunInChunks =
            transport == .chunk || (transport == nil && files.contains { $0.uploadUID != nil })
        guard begunInChunks else { return nil }
        return with { job in
            job.transport = .whole
            for index in job.files.indices where !job.files[index].isComplete {
                job.files[index].uploadUID = nil
                job.files[index].bytesConfirmed = 0
                job.files[index].conflictResync = nil
            }
        }
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.byteSize } }

    public var confirmedBytes: Int64 {
        files.reduce(0) { $0 + Swift.min($1.bytesConfirmed, $1.byteSize) }
    }

    /// 0...1, and 1 for a note with no media — a text-only capture is not stuck at 0 %.
    public var fractionUploaded: Double {
        guard totalBytes > 0 else { return 1 }
        return Double(confirmedBytes) / Double(totalBytes)
    }

    public func file(_ id: UUID) -> OutboxFile? { files.first { $0.id == id } }

    /// The uids the memo is created with, in capture order.
    ///
    /// A picture staged for the edit is not one of them: it was picked after this create was first
    /// sent, and a replay that named it would be a different request under the same key.
    public var uploadUIDs: [String] {
        files.filter { $0.stagedForEdit != true }.compactMap(\.uploadUID)
    }
}

/// A picked item still in Photos: the capture names it by the library's own persisted identifier
/// (`PHAsset.localIdentifier`) until the `StagingLane` has copied it into the group container
/// (MEMNG-952).
public struct StagingFile: Codable, Sendable, Equatable, Identifiable {
    /// The id the copied file carries in `UploadJob.files`, fixed when the item was picked, so a
    /// copy made twice — by a run that died after its rename and the run after it — lands on ONE
    /// file under ONE id.
    public var id: UUID
    /// The library's persisted identifier for the item.
    public var assetIdentifier: String
    /// Set when the last staging pass could not read the item because Photos access is denied,
    /// limited to other items, or the item is gone from the library; cleared by a pass that can.
    /// Optional and absent until a pass has found that.
    public var needsPhotosAccess: Bool?

    public init(id: UUID = UUID(), assetIdentifier: String, needsPhotosAccess: Bool? = nil) {
        self.id = id
        self.assetIdentifier = assetIdentifier
        self.needsPhotosAccess = needsPhotosAccess
    }
}

public enum OutboxDefaults {
    /// What the server asks for today (`UPLOAD_CHUNK_SIZE`). Only ever a starting value: the size
    /// the session answers with wins, because the server is allowed to change its mind.
    public static let chunkSize = 5 * 1024 * 1024
    public static let appGroup = "group.live.discomarder.memosng"
}

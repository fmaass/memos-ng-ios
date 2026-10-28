# The Upload Moonshot — "Post and walk away"

**Horizon:** one month, 2 November → 29 November 2026, four weekly TestFlight builds and one App Store release.
**Assumption:** unlimited engineering hands, one household, one self-hosted server, one owner reviewing.
**Scope:** upload fidelity, end to end — from the moment a picture leaves somebody's hand on the phone
to the moment it is derived, visible and announced — on both repos (memos-ng server, memos-ng-ios app).
**Status:** proposal. Nothing here is ticketed or decided. Where it reverses something the code
decided on purpose, the reversal is named in § 9 and the owner decides; everywhere else the standing
rule applies (take the recommended option, record it, keep delivering).

The broader twelve-month moonshot lives in `docs/moonshot-household-memory.md`; this one is the
upload slice of it, cut to one month and written against the code as it stands on main `86e729f9`
(app) and `e9027b7` (server).

---

## 0. How to read this

Three complaints started this document:

1. *Share from Photos to memos, and the upload takes forever with no way to see whether it is
   happening at all.*
2. *Compose a memo with thirty photos and videos, and you cannot leave the screen and let it
   happen in the background. Cancel is the only way out.*
3. *You cannot set a memo's visibility while editing it; the only place is the long-press menu on
   the timeline.*

§ 1 traces each complaint to the exact lines that cause it — because two of the three are not what
they look like from the outside, and the fix for the wrong diagnosis is a month wasted. § 2 states
the moonshot in a sentence and § 3 the principles that do not bend. § 4 is the heart: six pillars,
each with the scene a family member lives, the mechanism behind it on both sides, the hard parts,
the invariants it carries, and the acceptance probe that proves it shipped on the real surface.
§ 5 lays the work on a four-week roadmap with named squads, weekly builds and a dependency spine.
§ 6 is the scoreboard, § 7 what we refuse to do, § 8 the risks with kill criteria, § 9 the owner's
decision points. Appendices hold the contract growth, the module map, the torture suite and the
existing tickets this absorbs.

"Unlimited dev resources" removes the throughput constraint and replaces it with another: one
owner, one gate, one set of family phones. So every pillar lands behind a flag as a weekly
TestFlight the household uses before it is finished, and every pillar is cut so that a squad can
run it in parallel with the others from day one.

---

## 1. Where we stand — the three complaints, traced to the code

### 1.1 "Share from Photos takes forever and you can't see it" — nothing uploads until the app opens

The share extension exists (`project.yml:235-237`, target `MemosShare`, app-extension, iOS 26) and
it works exactly as designed: it reads what was shared with `loadFileRepresentation(openInPlace:)`
(`Sources/MemosShare/SharedItemLoader.swift:8-9`), stages copies, and on Post writes a job into the
app-group outbox through `ShareIngest.commit` (`Sources/MemosShare/ShareRootView.swift:111-157`),
then calls `finish()`. It offers a visibility picker (`ShareRootView.swift:74-79`) and a spinner
that says "Reading what you shared…" (`:43-44`).

Then it stops. By design: *"The extension never sends anything itself. … It deliberately cannot
upload. The single-attach rule means one process owns the background session, and that process is
the app"* (`Packages/MemosShareKit/Sources/MemosShareKit/ShareIngest.swift:6-7`, `:22-25`;
`project.yml:232-234`). The bytes move when the app next drains the queue — on launch
(`Sources/MemosNG/MemosNGApp.swift:165`) or when a `BGAppRefreshTask` fires, which is requested
with `earliestBeginDate` fifteen minutes out (`MemosNGApp.swift:260-262`) and which iOS runs at its
own discretion, typically much later.

So the complaint is literally true. After "Post" in the share sheet, **zero bytes leave the phone
until somebody opens memos**. There is no progress to show because there is no transfer happening.
When the app does drain, the outbox tracks `bytesConfirmed` per file
(`Packages/MemosOutbox/Sources/MemosOutbox/UploadJob.swift`, `WholePlanner.swift`), but no view in
`MemosFeatures` or `MemosCore` reads it — the grep is zero outside the outbox package. The only
visible trace is the `Outbox` observable (`Outbox.swift:27-29`) feeding a resubmit button
(`TimelineView.swift:748`).

### 1.2 "Thirty photos and you can only cancel" — the sheet blocks on *import*, not on upload

The compose sheet does **not** wait for uploads. Post calls `enqueue`, the outbox persists the job
(`Packages/MemosOutbox/Sources/MemosOutbox/Outbox.swift:442-470`), the result is `.saved` and the
sheet dismisses (`ComposeView.swift:730-731`; `TimelineView.swift:806-826`). The upload then runs
in the app's one background `URLSession` (`UploadTaskSession.swift:12-40`: identifier
`live.discomarder.memosng.uploads`, `isDiscretionary = false`, `sessionSendsLaunchEvents = true`,
two files in flight, `WholePlanner.swift:33`).

What blocks is the step *before* Post. `PhotosPicker` hands over items lazily; the sheet loads each
one (`ComposeImports.swift:37`: `isImporting = awaitingPick || items.contains(where: \.isLoading)`),
and for a video "loading" means copying the full original out of the Photos library. While any item
is loading, Post is disabled (`ComposeView.swift:293-297`, `:338-341`) and Cancel is enabled
(`:335-337`). Thirty 4K clips is minutes of copying with a spinner in a pill and one live button.
That is the screen the complaint describes.

Two more facts shape the fix:

- **Editing a memo uploads in the foreground, outside the outbox.** `ComposeView.swift:438-440`:
  *"The files an edit picks go up in the FOREGROUND and the memo is patched with them directly
  (`TimelineStore.edit(attaching:)`), rather than through the outbox."* Add thirty pictures to an
  existing memo and the app must stay open until the last byte lands.
- **After Post, there is no view of the job.** The memo does not appear on the timeline until the
  server has it, so between Post and arrival the person sees nothing: no card, no ring, no count.

### 1.3 "No visibility when editing" — a deliberate omission on the client, nothing missing on the server

The compose sheet has a visibility menu (`ComposeView.swift:789-813`, submitted at `:720`). The
edit sheet hides it on purpose: *"An EDIT shows the date and the photo picker, and not the
visibility — who can see a memo is its own deliberate action"* (`ComposeView.swift:434-436`). The
one in-app path is the timeline long-press (`TimelineView.swift:478-485` → `:583-591` →
`TimelineStore.swift:1538` → `MemoActionStore.swift:193`). The server already accepts it:
`MemoPatch.visibility` (`Packages/MemosAPI/Sources/MemosAPI/openapi.json:2943`; server
`routers/memos.py:470`, applied in `services/memos.py:556-558`), owner-only (`routers/memos.py:1216`).
The web SPA's edit dialog has had the control all along (`frontend/src/components/MemoCard.vue:71-78`).

So the third complaint is a UI decision to reverse, not a feature to build — and the reversal
should keep the half of that decision that is right: widening (Just us → Public) is consequential
and deserves a beat; narrowing never does.

### 1.4 The systemic gaps underneath all three

These are the reasons the complaints will come back in another costume if only the three symptoms
are fixed:

| Gap | Where | Effect |
|---|---|---|
| A transient failure costs fifteen minutes | `RetrySchedule.swift:7-9`: base 15 min, cap 6 h, every failure class | A 429 or a dropped socket parks a file for a quarter of an hour; "takes forever" |
| A 413 parks a file forever | `OutboxRefusal.swift:62-63` → `JobState.held`, never retried (`UploadJob.swift:24-36`) | A 1.2 GB clip against `MAX_UPLOAD_MIB=1024` (`config.py:115`) silently never arrives |
| The server has no upload metrics | zero `Counter(`/`Histogram(`/`Gauge(` in `app/`; only `memosng_digest_*` | Nobody can see upload health from the outside either |
| Live events are a 1.5 s poll that closes when idle | `routers/assets.py:1208-1248`, `:1246-1247`; frames carry `data:` only, no `event:`/`id:`/`retry:` | Progress is coarse, reconnects are blind, memo events do not exist |
| Push fires only on attachment `ready`/`failed` | `worker.py:429-447` | "Your memo is live" is never said |
| Admission holds a stalled body's slot for 300 s | MEMNG-934; `UPLOAD_BODIES_PER_USER=3`, `PER_PROCESS=6` (`config.py:49-51`) | A phone that lost Wi-Fi mid-body locks its own retries out with 429s |
| Dedupe is late and narrow | sha256 computed at finalize (`services/uploads.py:1398`), matched only against the owner's **unlinked** rows (`:1400-1406`) | Re-sharing yesterday's photo uploads every byte again |
| The chunk lane still exists for legacy rows | `UploadJob.swift:315-316` default `.chunk`; MEMNG-672 / MEMNG-302 open against it | Two code paths, one of them with known races, both to be tested |
| No on-device probe of what Photos handed over | no `AVAssetExport`/`jpegData`/size cap in compose (grep returned nothing) | The app learns a file is too big from a 413, after the upload |

---

## 2. The moonshot in one sentence

**Anything you post to memos, from anywhere on the phone, is on its way within seconds of leaving
your hand, you can watch it land from the lock screen, nothing you tapped is ever lost, and
visibility is a dial you can turn wherever you are looking at the memo.**

The test of the sentence is a scene: on the train home, you select thirty clips from the day in
Photos, share them to memos with a caption and "Just us", lock the phone, and put it in your pocket.
The Dynamic Island shows a ring. The ring fills over the tunnel, pauses, resumes. When you take the
phone out at the door, the lock screen says *"Day at the lake · 30 of 30 · live"*, and the other
phone in the house has already shown the memo. Not one tap after "Post".

---

## 3. Principles that do not bend

Inherited from the household moonshot (`docs/moonshot-household-memory.md` § 3) and from
`CLAUDE.md`; the upload work adds four of its own.

1. **Originals are sacred.** The server receives the bytes Photos holds, never a re-encode. "Make
   it smaller so it uploads" is not an option; "resume it, dedupe it, wait for Wi-Fi" are.
2. **The contract is the product.** Every new server capability is an OpenAPI path first, generated
   into the client second; nothing is hand-written in `MemosAPI`.
3. **Private by architecture.** The extension still cannot read the token (`project.yml:246-254`);
   whatever it does with uploads it does with a grant the app minted for that one capture.
4. **The four invariants** (`CLAUDE.md` § Invariants): a store serializes its own mutations; every
   credential-scoped read is epoch-fenced; one-shot answers are deduplicated at the callback site;
   a refusal carries the epoch of the credential that earned it to the effect.
5. **Pilot first.** Four Friday TestFlights; each pillar reaches the family behind a flag before it
   is complete.
6. **The gate is the only build authority.** Every claim below ends in a `mac-gate SUMMARY … exit=0`.
7. **The main bar is frozen** (ADR-0008). Nothing in this document adds a tab, a badge or a button
   to the bottom bar. Transfers are reached from the timeline, the lock screen and the Dynamic Island.

The upload-specific four:

8. **The outbox is the only write path for media.** Share, compose, edit, camera: one queue, one
   planner, one set of tests. A second path (today: the foreground edit upload) is a second place to
   lose a file.
9. **Progress is a fact, not an animation.** Every number the person sees — bytes, count, minutes —
   derives from a confirmed server offset or a confirmed server state, never from a timer. A ring
   that moves while nothing is being received is a lie, and the lie is what "takes forever" feels like.
10. **Every byte is accounted for.** At any instant each queued file is in exactly one named state
    with a reason (`waiting for Wi-Fi`, `server busy, retrying in 8 s`, `too large for the server`,
    `signed out`), and that reason is the same string in the app, in the log and in the metric label.
11. **Waiting has a ceiling.** No retry schedule, admission slot, upload session or background wake
    is unbounded. Every wait has a number and the number is in a test.

---

## 4. The six pillars

Each pillar: **Scene** (what the family lives), **Mechanism** (server · iOS), **Hard parts**,
**Invariants** (which of the four it must prove), **Acceptance probe** (the real surface).

### Pillar 1 — Share and walk away: the extension starts the transfer

**Scene.** Select pictures in Photos, Share → memos, type a caption, pick "Just us", tap Post. The
sheet closes in under a second. Before it closes, the first bytes are already on the wire. Open
memos a minute later and the memo is there with its tiles filling in; or never open it, and it is
there anyway.

**Mechanism.**

*iOS.* The extension keeps writing the job to the app-group outbox exactly as today (commit order,
lease, account binding — `OutboxRepository.swift:205-212` all stay). Then, instead of returning, it
**creates upload sessions and starts the background tasks itself**:

- A background `URLSessionConfiguration` with a **per-capture identifier**
  (`live.discomarder.memosng.uploads.share.<jobUUID>`), `sharedContainerIdentifier` = the app
  group, files staged in the group container. This is the pattern Apple documents for extensions
  (App Extension Programming Guide, "Performing Uploads and Downloads"): the extension schedules
  background tasks, finishes, and when the tasks complete the system launches the containing app
  and calls `handleEventsForBackgroundURLSession` with the extension's session identifier; the app
  recreates a session with that identifier and receives the delegate events. The "single-attach"
  rule the current comment cites (`ShareIngest.swift:22-25`) holds **per identifier**, not per
  process, so one session per capture satisfies it without racing the app's main session.
- The `MemosOutbox` package grows a `SessionRegistry`: a manifest of every identifier that may hold
  tasks (the app's main one, plus one per in-flight shared capture), persisted in the group
  container. On any wake the app attaches to every identifier in the registry, reconciles tasks
  against job manifests (the existing `WholeReconciliation`), and retires identifiers whose capture
  has landed.
- The extension still has **no token**. Today the identity JSON in the group tells it who is signed
  in (`ShareRootView.swift:102-108`); the moonshot adds a **capture grant**: the app pre-mints a
  short-lived, upload-only bearer (scope `uploads:write`, 24 h, bound to the account epoch) and
  drops it in the group container alongside the identity JSON, rotating it on each foreground.
  The extension's tasks present the grant; memo creation itself still happens in the app with the
  real credential. If no grant is present or it has expired, the extension falls back to today's
  behaviour (enqueue only) and says so: *"Will upload when you open memos."*

*Server.* `POST /api/tokens/capture-grant` mints the grant (owner-scoped, revocable with the
session, listed under Manage Tokens as "Capture grant · phone"). `/api/uploads` and
`/api/uploads/{uid}` (PATCH, HEAD) accept it; nothing else does. The upload session records which
principal opened it, so a grant revoked mid-transfer refuses the next PATCH with a typed 401 the
outbox already maps to a hold (`OutboxRefusal.swift:56-66`).

**Hard parts.**

- The extension's process is killed shortly after `finish()`. Only tasks already handed to the
  background daemon survive. So the extension must *create the server upload sessions* (one small
  POST each, foreground, before `finish()`) and *hand the PATCH bodies to the background session*
  before it returns. For thirty files that is thirty session POSTs — § Pillar 4 adds a batch
  `POST /api/uploads/batch` so it is one.
- Memory: extensions get tens of megabytes. Staging thirty originals is copying, not loading, and
  `loadFileRepresentation(openInPlace:)` already avoids reading them (`SharedItemLoader.swift:59`).
- The device spike MEMNG-538 ("run the background-URLSession spike on the iPhone") was never run.
  It is the first thing the Extension squad does (day 1–2) and the kill criterion in § 8.

**Invariants.** Store serializes (the registry is written under the existing cross-process lease);
epoch-fenced (the grant carries the account epoch; a capture enqueued under epoch *n* is never
uploaded with grant *n+1*'s identity — `accountChanged` stays a refusal, `ShareIngest.swift:11-15`);
refusal-with-epoch (a 401 on the grant holds the job, it does not sign the app out — the grant is
not the session).

**Acceptance probe.** Share five photos from Photos with the memos app **force-quit**. Within ten
seconds, `SELECT upload_uid, bytes_received FROM uploads WHERE user_id = … ORDER BY created_at DESC
LIMIT 5` on the production database (through `bin/prod-sql.sh`) shows five rows with non-zero
`bytes_received`, and within two minutes the memo exists on the other household phone's timeline
without the first phone's app having been opened. Repeated with airplane mode toggled on for thirty
seconds mid-transfer: same end state, no duplicate memo (idempotency key, `OutboxWire.swift:87`).

### Pillar 2 — Transfers you can see: the Transfers sheet, Live Activity, Dynamic Island

**Scene.** Pull down on the timeline and a slim strip above the first card reads *"Uploading 12 of
30 · 1.4 GB left · about 6 min"*. Tap it: a sheet lists every job — the memo's first line, a row
per file with a ring, bytes, and the one-line reason when it is not moving (*"Waiting for Wi-Fi"*,
*"Server busy · retrying in 8 s"*, *"Too large for the server (1.2 GB > 1 GB)"*). Lock the phone:
the same numbers live on the lock screen and in the Dynamic Island. When the last file is derived,
the activity ends with *"Day at the lake · live"* and a tap opens the memo.

**Mechanism.**

*iOS.*
- `MemosOutbox` publishes a **`TransferLedger`**: an `@Observable`, main-actor projection of the
  job manifests — per job: memo preview, state, files; per file: `bytesConfirmed / size`, state,
  `reason`, `nextAttemptAt`. It is derived from exactly the facts the planner already keeps
  (`bytesConfirmed` after each confirmed `Upload-Offset` tail, `RetrySchedule`'s next date, the
  `OutboxRefusal` class) — principle 9, no timers. Rates and ETAs are a trailing window over
  confirmed bytes, shown only after two confirmations.
- `MemosFeatures` gets `TransfersStrip` (the pull-down strip above the timeline's first card — not
  in the bar, ADR-0008) and `TransfersSheet`. The strip appears only while a job exists and
  disappears thirty seconds after the last one lands. Each failed row has one action that names the
  fix (*Retry now*, *Use mobile data for this one*, *Sign in*, *Remove*).
- **Live Activity.** A new `MemosActivity` widget-extension target hosts the ActivityKit UI (lock
  screen banner, Dynamic Island compact/minimal/expanded). The app starts the activity when the
  ledger has its first job and updates it from the background session delegate (so the ring moves
  while the phone is locked, because the delegate runs in the relaunched app). The activity's
  content state is the ledger's summary struct — one source of truth for the strip, the sheet and
  the island.
- **Push-to-start for shared captures.** A capture started by the extension (Pillar 1) has no app
  running to start the activity. The app registers its push-to-start token with the server once
  (`POST /api/devices/live-activity-token`); when the server sees the first byte of a grant-opened
  upload session it sends the APNs push-to-start for that job, and per-job update pushes on every
  state change. On the fallback path (no APNs key configured on the server) the activity starts on
  the app's next wake, which the background session guarantees within the transfer anyway.
- **Local notification** on job completion when the app is not frontmost: *"Day at the lake is
  live"*, deep link to the memo; and on a terminal failure with the reason and the one action.

*Server.* An `apns` service (token-based auth, `.p8` key via `APNS_KEY`, `APNS_KEY_ID`,
`APNS_TEAM_ID`; no-op when unset, like `send_to_user` today, `services/push.py:41-43`), a
`live_activity_tokens` table, and a job-state fan-out from the upload router and the worker's
terminal path (`worker.py:429-447` already has the hook for web push; the Live Activity update is
the second consumer of the same event). Live Activity updates carry
`{job: uid, files_done, files_total, bytes_done, bytes_total, state, reason}`.

**Hard parts.**

- Honest ETAs over a two-file-in-flight budget with variable cellular throughput. Rule: no ETA under
  two confirmations or above twelve hours; show "paused" instead.
- Activity lifetime: Live Activities end after eight hours. A job that waits for Wi-Fi overnight
  ends the activity with "paused · waiting for Wi-Fi" and restarts it when bytes move again.
- The strip must never shift the timeline's content when it appears mid-scroll; it is part of the
  refreshable header, not an inserted row.

**Invariants.** The ledger is a projection and never a second store (store serializes); every
displayed state is read from a manifest written by the planner, and a state the planner left is
never resurrected by a late delegate callback (epoch-fenced on the job's generation);
`didCompleteWithError` and `didReceive response` are the two callbacks for one answer — the
existing one-answer claim pattern applies.

**Acceptance probe.** Thirty files (ten 4K clips of ~400 MB, twenty HEIC) posted from compose; the
phone locked. A screen recording of the lock screen over the full transfer shows the ring and the
count only ever increasing, the count reaching 30/30 within 90 s of the last `bytes_received = size`
row on the server, and the Live Activity ending on "live" within 60 s of the attachment rows all
reading `status = ready`. Airplane mode for sixty seconds in the middle: the activity reads
"paused · no connection" within five seconds of the loss, and resumes within ten seconds of the
return, with `bytes_received` on the server continuing from its held offset, not from zero.

### Pillar 3 — Compose that never holds you: staging in the outbox, optimistic memo card, edits through the queue

**Scene.** Tap the camera-roll pill, pick thirty items, keep typing while the pill counts them in,
tap Post the instant you are done writing. The sheet closes. The memo is already at the top of the
timeline with thirty shimmering tiles; they turn into thumbnails one by one as the uploads land and
the server derives them. Add twenty more to an older memo from its edit sheet: same thing, you leave
and the tiles fill in behind you.

**Mechanism.**

*iOS.*
- **Post is enabled while items are still loading.** `canSave` drops the `isImporting` term. The
  job manifest gains a **`staging` state per file** holding the `PhotosPickerItem`'s identifier (a
  persisted `PHAsset.localIdentifier`, obtained with the limited-library access the picker already
  grants) and the loading moves into the outbox: a new **`StagingLane`** in `MemosOutbox` copies
  each item from Photos into the group container (`loadFileRepresentation`, then rename — the same
  staging the extension does), transitions the file to `staged`, and the `WholePlanner` picks it up.
  Staging runs under a `BGProcessingTask` when the app is backgrounded (minutes-long,
  `requiresNetworkConnectivity = false`) and on the main app's lifetime when it is not.
- **The optimistic card.** `TimelineStore` learns to show *pending memos*: for each outbox job
  without a server uid it inserts a `PendingMemo` card at the top with the caption, the date, the
  tags, and one placeholder tile per staged file — carrying the ledger's ring. On `createMemo`
  success the card is swapped for the real `MemoOut` in place (same identity key, so no jump), and
  tiles continue to show `processing` until the SSE says `ready`. Every edit action on a pending
  card is either allowed on the job (caption, visibility, remove a file) or disabled with the
  reason — never silently ignored.
- **Edits go through the outbox.** `TimelineStore.edit(attaching:)` stops uploading in the
  foreground. Adding files to an existing memo becomes an **`EditJob`** with the server-side
  `edit_key` (`routers/memos.py:500`) as its idempotency key; the job's terminal action is
  `PATCH /api/memos/{uid}` with `upload_uids`. The old foreground path is deleted, not kept behind
  a flag (principle 8).
- The **chunk lane is retired** (ADR-0007 decision 5, MEMNG-546): legacy `.chunk` rows are migrated
  on first read to whole jobs with `bytesConfirmed = 0`, and `ChunkMath`, `BackgroundChunkScheduler`
  and the chunk PATCH path are deleted. MEMNG-672 and MEMNG-302 close as "lane removed".

*Server.* Nothing new is required for the optimistic card. `MemoPatch.upload_uids` already exists
(`routers/memos.py:477`); `edit_key` already exists. One addition: `MemoOut` gains
`attachments[].status` on every list path (it is on `AttachmentOut`, `routers/uploads.py:93-113`,
and must be on the timeline projection too), so a freshly created memo renders its own processing
state without a second fetch.

**Hard parts.**

- Photos access from the outbox lane: the picker's grant is per-item and tied to the
  `PhotosPickerItem`; persisting it means either (a) `PHPickerResult.assetIdentifier` with
  `photoLibrary: .shared()` (requires the user to grant library access once — a one-time prompt we
  accept), or (b) copying the items out *before* Post as today but not blocking Post on it. The
  moonshot does (a) with (b) as the fallback when access is denied: Post stays enabled, the files
  already loaded go, the rest show *"Allow Photos access to send the rest"* in the Transfers sheet.
- Cancel semantics on a pending card: "Remove" on a job whose first file is already on the server
  must delete the upload session on the server (`DELETE /api/uploads/{uid}` — new) so no orphan
  reaches finalize.
- Date and tags edits racing with the job's `createMemo`: the job manifest is the single owner
  until the server uid exists; the edit sheet writes to the manifest, not to the API, while pending.

**Invariants.** The edit job's `edit_key` makes a retried PATCH safe (store serializes, join);
a `createMemo` response arriving after the person removed the pending card does not resurrect it
(the job is `withdrawn` in `withdrawal.json`, `OutboxRepository.swift:236`, and the response is
dropped against the job's generation); the `PHPicker` can answer with a file *and* an error for one
item — one answer wins at the callback.

**Acceptance probe.** Thirty items picked, Post tapped within two seconds of the picker closing
(screen recording timestamps). The sheet is gone within one second; the pending card is on the
timeline with thirty placeholders; the app is backgrounded for the rest. Server: thirty
`attachments` rows reach `ready`; the memo's `attachment` count is thirty; `SELECT count(*) FROM
uploads WHERE memo_id IS NULL AND user_id = … AND created_at > now() - interval '1 hour'` is zero
after the sweep. Edit path: add five clips to a memo from last week, leave the sheet, kill the app;
five more `ready` rows under that memo within ten minutes.

### Pillar 4 — Fidelity on the wire: seconds-scale retry, resume, dedupe by hash, size truth, Wi-Fi policy

**Scene.** The Wi-Fi drops as you walk out of the house; the transfer pauses at 61 % of a clip and
continues from 61 % on cellular, or waits politely until the next Wi-Fi if you told it large videos
should. The server hiccups for three seconds; the retry is four seconds later, not fifteen minutes.
You share a photo you already shared in May; it is on the server before the sheet closes, zero
bytes sent. You share a 1.6 GB clip; the sheet tells you *before* uploading that the server's limit
is 1 GB (or, after § 9 (b), the server takes it).

**Mechanism.**

*iOS (`MemosOutbox`).*
- **Resume from offset is finished.** The offset protocol is already live on the server
  (`HEAD /api/uploads/{uid}` → `Upload-Offset`, PATCH with `Upload-Offset`, 409 on a gap —
  `routers/uploads.py:174-298`) and the request shapes exist on the client
  (`OutboxRequests.swift:44-86`). What is missing is the planner behaviour from plan 4144's I-phases:
  on any interruption, HEAD first, then PATCH the tail from the confirmed offset, never the whole
  file again (MEMNG-633's "stalls at 7 % re-sending the whole video").
- **Retry classes replace the one schedule.** `RetrySchedule` (`RetrySchedule.swift:7-9`) becomes
  three: *transient* (socket drop, 408, 5xx, 429 with `Retry-After`): honour `Retry-After`, else
  2 s → 4 → 8 → 32 → 60 s, cap one minute; *connectivity* (`NWPathMonitor` says no path, or the
  policy says Wi-Fi only and the path is cellular): no timer at all, resume on the path event;
  *hold* (401 on the grant, 413, account change): no timer, resume on the named fix. `held` rows
  gain a `reason` enum and a `fixAction` so the Transfers sheet can offer the one right button.
- **Size truth before the first byte.** The planner reads the server's limits once per session
  (`GET /api/uploads/limits` → `max_bytes`, `wifi_recommended_above_bytes`) and marks a file
  `tooLarge` at staging time, with the number in the reason. The compose sheet shows it on the tile
  (a small "1.6 GB > 1 GB" caption) before Post, so the person can drop it or keep it for the day
  the limit rises.
- **Dedupe by hash, before upload.** Staging computes a streaming SHA-256 (CryptoKit, ~1–2 GB/s on
  A17+, so a 400 MB clip is well under a second) and the upload session request carries it. The
  server answers `bytes_received = size` immediately when it already holds those bytes for this
  owner (Pillar 4 server side); the planner skips the PATCH and goes straight to finalize.
- **Network policy with truthful copy.** A setting *"Send videos over mobile data: Always / Only
  under 200 MB / Never"* (default: only under 200 MB). The reason string is the real one:
  *"Waiting for Wi-Fi (video over 200 MB)"*, never "Waiting to try again" (MEMNG-657).
- **Upload budget becomes adaptive** within the server's admission: two in flight by default
  (`UploadBudget`, `WholePlanner.swift:33`), one when the last three attempts hit 429, three on
  Wi-Fi with no 429 in the last minute. The server's per-user cap is the ceiling.

*Server (memos-ng).*
- `POST /api/uploads` takes an optional `sha256`. Dedupe moves from finalize to session creation
  and widens to **all of the owner's attachments**, linked or not (`services/uploads.py:1400-1406`
  today matches unlinked rows only): a hit creates the upload session already complete
  (`bytes_received = size`, backed by a hard link to the existing original under `DATA_ROOT`), and
  finalize creates a new attachment row that **shares the original's file and copies its
  renditions and blurhash** (no second derive). The sha256 index already exists on `Attachment`.
- `POST /api/uploads/batch` creates up to fifty sessions in one request (for the extension and the
  thirty-item compose), returning the same `UploadOut` per entry, including the dedupe short-circuit.
- `GET /api/uploads/limits` publishes `max_bytes`, the recommended Wi-Fi threshold and the
  per-user admission (`UPLOAD_BODIES_PER_USER`) so the client's budget is not a guess.
- `DELETE /api/uploads/{uid}` withdraws a session (Pillar 3's "Remove").
- **Admission that releases on stall** (MEMNG-934): a PATCH body that receives no bytes for 30 s
  gives up its slot; the client's HEAD-then-tail resume makes that safe. Limits raised (MEMNG-648):
  `UPLOAD_BODIES_PER_USER=4`, `PER_PROCESS=8`, with the worker's CPU budget unchanged (derives are
  queued, not inline). A Traefik transport with a response-header timeout above the slow derive
  path (MEMNG-655) and an explicit request-body cap of `MAX_UPLOAD_MIB + 1` in the deployed stack
  (the cap lives in the infra repo; verified by a live oversized PATCH returning 413 from Traefik,
  not a reset).
- `MAX_UPLOAD_MIB` → owner decision § 9 (b); the recommended value is 4096 with the disk admission
  check extended to `size` at session creation (refuse with 507 and a reason when free space under
  `DATA_ROOT` is below `size + 10 %`).

**Hard parts.**

- Resume across a *grant* change (Pillar 1): the session was opened by the grant, the tail is
  presented by the app's real credential after relaunch. The session records the owner, not the
  token; any credential of that owner may continue it. The epoch rule still holds at the client:
  the job's manifest carries the account epoch it was enqueued under.
- Dedupe by hash and "originals are sacred" are compatible only if the *bytes* match. Photos can
  hand over a different representation of the same asset (edited vs. original, HEIC vs. JPEG
  export). Hash matching never loses anything: a mismatch is just an upload.
- Hard-linking originals means a memo delete must not unlink a file another attachment shares. The
  reclaim path (`services/reclaim.py:138`) gains a reference count by sha256.

**Invariants.** Two overlapping retries of one file are one PATCH (the file's slot in the planner
is the guard, as `UploadBudget` already does); a stale 429 answer arriving after the budget was
raised does not lower it again (judged against the attempt generation); the `Retry-After` answer
and the task's completion are one answer; a 401 on the tail classifies with the epoch the tail
presented, on `OutboxRepository`, before any hop (`scripts/refusal-sites-rule.sh` pins the entry
points — the new lanes register with it).

**Acceptance probe.** The torture suite (Appendix C) rows T1–T6, each a device run with a screen
recording and a server-side read-back:
- T1 Wi-Fi off at 60 % of a 400 MB clip, on again 30 s later → `bytes_received` on the server
  never decreases; total bytes on the wire (Traefik access log) ≤ 1.05 × file size.
- T2 Server returns 429 for 20 s (toggle `UPLOAD_BODIES_PER_USER=0` live) → every retry inside
  the `Retry-After` window ± 1 s; the file completes within 30 s of the toggle back.
- T3 Re-share a photo from May → upload session row with `bytes_received = size` and zero PATCH
  rows in the access log; new attachment row with the May row's sha256; renditions present with no
  new `media_jobs` row.
- T4 A 1.6 GB clip → with the limit at 1 GB: the compose tile says so before Post and the
  Transfers row says so after; with the limit raised: it lands, `status = ready`, the slow lane
  transcode completes under `SLOW_TRANSCODE_TIMEOUT_S`.

### Pillar 5 — A server that tells the truth: upload metrics, a real event stream, memo events, pushes that say "live"

**Scene.** The server tells every client what it knows, as it learns it. The other phone in the
house sees the new memo appear without pulling to refresh. The web SPA shows a tile going from
"uploading 40 %" to "processing" to a thumbnail. Grafana shows upload bytes per minute, failures by
reason and the queue depth of both worker lanes, so an "it takes forever" has a chart behind it.

**Mechanism.**

- **`/api/events` becomes a real SSE stream.** Frames carry `event:`, `id:` and a `retry:` hint
  (the client parser already handles all three, `SSEParser.swift:39-44`, `:134-136`; the server
  emits none, `routers/assets.py:1204-1205`). The 1.5 s poll (`:1211`) and the close-when-idle
  (`:1246-1247`) are replaced by Postgres `LISTEN/NOTIFY` on three channels — `upload_progress`,
  `attachment_status`, `memo_changed` — with a 25 s keepalive comment and `Last-Event-ID` replay
  from a 5-minute ring. Event types: `upload.progress {upload_uid, bytes_received, size}` (coalesced
  to at most one per upload per second), `attachment.status` (today's payload), `memo.created`,
  `memo.updated {uid, fields}`, `memo.deleted`, `memo.visibility {uid, visibility}`.
- **The upload router and finalize emit.** Each committed PATCH tail notifies `upload_progress`;
  finalize notifies `attachment_status`; memo create/patch/delete notify `memo_changed` with the
  visibility-filtered recipients (a PROTECTED memo is announced to household members, a PRIVATE one
  to its owner only — the same predicate as `services/memos.py:87`).
- **The iOS `MediaEventClient`** (`MediaEventClient.swift:134`) consumes the new types: the
  timeline inserts and patches memos from `memo.*` events (no pull-to-refresh needed for the second
  phone), the Transfers ledger takes `upload.progress` as a second, server-side confirmation of the
  offset (it already has the client-side one), and pending tiles flip on `attachment.status`.
- **Pushes.** `_notify_terminal` (`worker.py:429-447`) is generalized into `notify(user, event)`
  with three consumers: web push (existing), APNs Live Activity update (Pillar 2), and a new
  **memo-live push** — one notification per memo (not per file) when the last attachment of a
  freshly created memo reaches `ready`: *"Day at the lake is live"*. Household members get it for
  PROTECTED and PUBLIC memos if they opted in (*Settings → Tell me when someone posts*).
- **Metrics** (Prometheus, `prometheus_client`, registered beside the instrumentator in
  `app/main.py:136`): `memosng_upload_bytes_total{principal}`, `memosng_upload_sessions_total{result}`
  (`completed|deduped|expired|withdrawn|rejected_size`), `memosng_upload_patch_seconds` (histogram),
  `memosng_upload_admission_rejections_total{scope}`, `memosng_upload_sessions_open`,
  `memosng_media_jobs_queued{lane}`, `memosng_media_job_seconds{lane,kind}`,
  `memosng_media_jobs_failed_total{lane,reason}`, `memosng_events_subscribers`. One Grafana
  dashboard, "Uploads", with the four questions on it: are bytes arriving, are sessions completing,
  is admission refusing, is the worker keeping up.
- **Orphan truth.** A sweep for finalized attachments never linked to a memo (today: only the
  manual `scripts/reconcile_orphan_attachments.py`): rows older than 24 h with `memo_id IS NULL`
  and no open upload session are reported in the metric and reclaimed after 72 h. The ADR-0007
  "completed-but-undelivered race" open point closes by construction: the client's `createMemo`
  retries with its idempotency key for as long as the attachments exist, and the attachments exist
  for 72 h.

**Hard parts.**

- `LISTEN/NOTIFY` through SQLAlchemy async needs a dedicated connection per app process, outside
  the pool; the stream handler fans out in-process. Two uvicorn workers mean two listeners, which
  is fine — each serves its own subscribers.
- Payload size: NOTIFY payloads are capped at 8000 bytes; events carry ids and the client fetches.
- Visibility-filtered fan-out must be computed at emit time with the memo's visibility *at that
  instant*; a later visibility change is its own event. A `memo.visibility` narrowing to PRIVATE is
  delivered to the household as `memo.deleted` (they can no longer see it), which is exactly what
  the timeline should do.

**Invariants.** The stream is per-credential and the client fences it on the session generation
(already: `TimelineView.swift:654-658` gates on scene phase; the generation fence comes from the
media-fetch precedent); a `memo.updated` that arrives for a memo the person is editing locally does
not overwrite the editor's unsaved text (the edit sheet owns its draft until Save; the timeline
card updates underneath).

**Acceptance probe.** Two phones. Phone A posts a memo with three photos; phone B's timeline, in
the foreground, shows the card within three seconds of `memo.created` in the server log and its
tiles flip to thumbnails without any touch. `curl -N /api/events` with a real PAT shows `event:`,
`id:` and `retry:` lines and a keepalive comment every 25 s. `/metrics` shows
`memosng_upload_bytes_total` increasing by the file size ± 1 %. The "Uploads" Grafana dashboard
renders all four panels from the live Prometheus.

### Pillar 6 — Visibility wherever you look at the memo

**Scene.** Open the edit sheet of a memo: the same Public / Just us / Private menu the compose sheet
has sits in the meta row. Change it to Just us and save: done. Change it from Just us to Public: a
one-line confirmation names what that means (*"Everyone with the link can see it"*) and then it is
done. The viewer's Info sheet shows the current visibility as a tappable chip. A pending memo in the
Transfers sheet can have its visibility changed before it lands. Your default for new memos is a
setting in the app, the same one the server uses.

**Mechanism.**

- `ComposeView` shows `VisibilityMenu` (`ComposeView.swift:789-813`) in edit mode too; the comment
  at `:434-436` is rewritten to say what the new rule is: *narrowing is immediate; widening asks
  once*. The PATCH carries `visibility` (`MemoPatch.visibility`, `openapi.json:2943`) only when it
  changed; `TimelineStore.edit` and `MemoActionStore.setVisibility` (`MemoActionStore.swift:193`)
  share one `VisibilityChange` type so the widening confirmation lives in exactly one place and the
  long-press path uses it too.
- The viewer's Info sheet (`MediaInfoSheet.swift`) gains a visibility chip for the memo the picture
  belongs to, owner-only (the server refuses others, `routers/memos.py:1216`), with the same type.
- The pending card and the Transfers sheet edit the job manifest's visibility until `createMemo`
  runs.
- The share sheet keeps its picker (`ShareRootView.swift:74-79`); its "Account default" option
  reads the same default the app now exposes under *Settings → Default visibility*, backed by the
  server's `user.default_visibility` (`models.py:113-114`) through a new `PATCH /api/me`.
- `memo.visibility` events (Pillar 5) keep every other screen honest: a Library view that starts on
  Public (owner rule 2026-10-26, MEMNG-933) drops a picture the moment its memo narrows.

**Hard parts.** None technical. The one design question — whether widening deserves a beat — is
answered above and goes to the owner in § 9 (c) because it reverses a documented decision.

**Invariants.** Two taps on the chip in quick succession are one PATCH (the `MemoActionStore` work
gate precedent); a `MemoOut` returned by a stale edit does not revert a visibility set by the
long-press path a second later (the store compares `updated_at`, not arrival order).

**Acceptance probe.** Edit a memo, set Just us, save: `SELECT visibility FROM memos WHERE uid = …`
reads `PROTECTED` and the other household phone still shows it; set Private: the other phone's
timeline drops it within three seconds (event-driven, no refresh). Widen Just us → Public: the
confirmation appears once; the row reads `PUBLIC`.

---

## 5. The roadmap: four weeks, six squads, four Friday builds

### The dependency spine

```
Week 1                Week 2                  Week 3                   Week 4
──────────────────────────────────────────────────────────────────────────────────────
Spike: extension      Extension starts        Capture grant +          Soak on family phones
bg-session (538) ───► tasks (P1) ───────────► push-to-start LA ──────► torture suite T1–T12
                                              (P1+P2)                  release 2.7.0
TransferLedger +      Live Activity local     Live Activity pushed
strip + sheet (P2) ─► (P2) ─────────────────► from server (P2)
                                                                       │
Post-while-importing  StagingLane + BGTask    Edit via outbox,         │
+ optimistic card ──► (P3) ─────────────────► chunk lane deleted (P3)  │
(P3)                                                                   │
Retry classes +       Resume-from-offset      Dedupe end-to-end,       │
limits endpoint ────► finished + batch ─────► Wi-Fi policy, 4 GB (P4)  │
(P4)                  sessions (P4)                                    │
Metrics + 934/648/    LISTEN/NOTIFY stream    memo.* events on iOS,    │
655 fixes (P5) ─────► + event types (P5) ───► memo-live push (P5)      │
Visibility on edit    Info-sheet chip +       Default-visibility       │
(P6) ✔ ships Fri 1    pending-card edit (P6)  setting (P6)             ▼
```

Every arrow is a merged, gated slice; nothing in week *n+1* starts on an unmerged week *n* branch.
Squads run in parallel from day one because the week-1 items are independent: the only hard
dependencies are P1→P2 (push-to-start needs the grant) and P3→P4 (staging needs the hash and the
limits), both inside one week.

### Week 1 — "See it" (2–6 Nov) · TestFlight 2.7.0 (74), Friday 6 Nov

The week where every complaint gets its first visible answer without touching the risky parts.

- **Extension squad.** Run MEMNG-538 on a real iPhone: an extension-created background session with
  a per-capture identifier, `sharedContainerIdentifier`, one 300 MB PATCH, extension finished;
  prove the app is launched with the identifier and receives the delegate events after a force quit.
  Written up as a one-page spike report with the device log attached. Go/no-go for P1 by Tuesday.
- **Transfers squad.** `TransferLedger` on the existing `bytesConfirmed` facts; `TransfersStrip`
  and `TransfersSheet` behind `transfers.sheet`; per-file reason strings for the states that exist
  today (`backoff`, `held`, `uploading`, `done`). The family sees uploads for the first time.
- **Compose squad.** Post enabled during import: the loaded files go, the loading ones are copied
  by a detached task that the sheet's dismissal does not cancel (the interim before `StagingLane`),
  and the pending card appears on the timeline with the ring. Flag `compose.pending-card`.
- **Wire squad.** Retry classes (transient / connectivity / hold) with `NWPathMonitor`;
  `GET /api/uploads/limits` on the server and `tooLarge` at staging on the client; `held` gains
  `reason` and `fixAction`. MEMNG-657's wording fix falls out.
- **Server squad.** MEMNG-934 (slot release on stall), MEMNG-648 (limits), MEMNG-655 (Traefik
  transport) deployed through `/safe-deploy` as 2.7.0 of memos-ng; Prometheus upload and media
  metrics; the "Uploads" Grafana dashboard. `sha256` accepted on `POST /api/uploads` (dedupe still
  at finalize this week).
- **Visibility squad.** P6's edit-sheet menu with the widening confirmation; the shared
  `VisibilityChange` type; the Info-sheet chip. **Ships complete on Friday.**
- **Gate squad** (all month). Second simulator slot on mars for the torture suite; the suite's
  harness (Appendix C) runs T7–T12 (simulator-able rows) nightly from Monday of week 2.

*Demo, Friday:* share from Photos → open memos → the strip and the sheet show the files landing
with real bytes; edit a memo's visibility; a 429 storm on the server recovers in seconds.

### Week 2 — "Walk away" (9–13 Nov) · TestFlight 2.7.0 (75), Friday 13 Nov

- **Extension.** P1 for real: session registry in `MemosOutbox`, extension creates sessions and
  hands PATCH bodies to its background session, app attaches to every registered identifier on
  wake, reconciliation extended. Still using the app's identity JSON plus a **temporary** path: the
  extension gets the upload-only grant minted by the app on each foreground (server side lands
  this week, `POST /api/tokens/capture-grant`, listed under Manage Tokens).
- **Transfers.** `MemosActivity` widget extension; Live Activity started and updated locally from
  the background session delegate; local "memo is live" notification. Dynamic Island compact view.
- **Compose.** `StagingLane` with persisted asset identifiers and `BGProcessingTask`; the one-time
  Photos access prompt with the denied-path fallback; `DELETE /api/uploads/{uid}` wired to "Remove".
- **Wire.** Resume-from-offset finished (HEAD, then the tail, never the whole file);
  `POST /api/uploads/batch` on both sides; adaptive budget within the server's published admission.
- **Server.** `/api/events` on `LISTEN/NOTIFY` with `event:`/`id:`/`retry:`, keepalive, replay ring;
  `upload.progress` and `memo.*` event types emitted; the web SPA consumes `upload.progress`.
- **Visibility.** Pending-card and Transfers-sheet visibility edits on the manifest.

*Demo, Friday:* thirty clips shared from Photos with the app force-quit; phone locked; Dynamic
Island ring; memo on the other phone before the first phone is unlocked.

### Week 3 — "Everywhere" (16–20 Nov) · TestFlight 2.7.0 (76), Friday 20 Nov

- **Extension + Transfers.** APNs service on the server; push-to-start and update pushes for
  grant-opened captures; activity restarts after the eight-hour ceiling; "paused" states.
- **Compose.** Edits through the outbox (`EditJob`, `edit_key`); the foreground edit upload
  deleted; chunk lane deleted with the legacy-row migration; MEMNG-672 / MEMNG-302 closed.
- **Wire.** Dedupe end-to-end (hash at staging, session created complete, finalize by hard link
  with rendition copy, reference-counted reclaim); the Wi-Fi policy setting; `MAX_UPLOAD_MIB` per
  § 9 (b) with the disk-admission check at session creation and the Traefik body cap verified live.
- **Server.** Memo-live push (one per memo); household opt-in; finalized-but-unlinked orphan sweep
  with its metric; `attachments[].status` on the timeline projection.
- **Visibility.** Default-visibility setting backed by `PATCH /api/me`; share sheet reads it.

*Demo, Friday:* the lake-day scene from § 2, start to finish, filmed. Re-share May's photo: zero
bytes. Pull the Wi-Fi mid-clip: resumes at the held offset.

### Week 4 — "Prove it" (23–27 Nov) · TestFlight 2.7.0 (77), release 2.7.0, Friday 27 Nov

- Monday–Wednesday: the full torture suite on two household phones (T1–T12), each row with a screen
  recording, the server read-back and the Traefik byte count, published as clip pages the owner
  reviews but never has to wait on (clips rule, 2026-10-23).
- Flags default on; the chunk-lane and foreground-edit code paths confirmed absent from the build
  (a grep rule in the gate: `scripts/no-chunk-lane-rule.sh`, 0 hits with a positive control).
- Thursday: fixes from the soak only; no new behaviour after Wednesday noon.
- Friday: App Store release 2.7.0 with first-person release notes through `/outgoing-text`;
  memos-ng 2.7.x tagged and deployed the same day; the ADRs in § 9 recorded as accepted or rejected.

### Squads and staffing

| Squad | Owns | Repos | Headcount (unlimited, but this many can actually work in parallel) |
|---|---|---|---|
| Extension | P1: registry, grant, extension sessions, reconciliation | iOS + server (grant) | 2 iOS, 1 server |
| Transfers | P2: ledger, strip, sheet, Live Activity, notifications | iOS + server (APNs) | 2 iOS, 1 server |
| Compose | P3: staging lane, pending card, edit job, chunk-lane removal | iOS | 3 iOS |
| Wire | P4: retry classes, resume, dedupe, limits, policy, batch | iOS + server | 2 iOS, 2 server |
| Server | P5: events, pushes, metrics, admission, sweeps, deploys | server | 3 server, 1 infra |
| Visibility | P6 | iOS + server (`/api/me`) | 1 iOS |
| Gate | torture harness, second simulator slot, nightly runs, clip pages | infra | 2 |

Seventeen people on the keyboard; one owner. The owner's load is bounded on purpose: one Friday
build to use, one set of clip pages to glance at, and the five decisions in § 9, three of which can
be taken on Monday of week 1.

---

## 6. The scoreboard

Measured on the household's phones against the production server, each with the probe that
produces it. Today's values come from the mechanisms cited in § 1; where no measurement exists the
cell says so.

| # | Measure | Today | Target | Probe |
|---|---|---|---|---|
| 1 | Seconds from share-sheet Post to the first byte received, app closed | ∞ until the app is opened (`ShareIngest.swift:6-7`) | ≤ 5 s | Pillar 1 probe |
| 2 | Seconds from compose Post to the sheet being gone, 30 items | minutes (import gate, `ComposeView.swift:293-297`) | ≤ 1 s | Pillar 3 probe |
| 3 | Thirty-item post (≈ 8 GB) to all `ready`, phone locked, home Wi-Fi | not measured | ≤ 25 min, zero taps | Pillar 2 probe |
| 4 | Retry latency after a transient failure | 15 min (`RetrySchedule.swift:7`) | ≤ 8 s, `Retry-After` honoured ± 1 s | T2 |
| 5 | Bytes re-sent after an interruption at 60 % | up to 100 % (MEMNG-633) | ≤ 5 % | T1 |
| 6 | Bytes sent to re-share an already-uploaded photo | 100 % | 0 | T3 |
| 7 | Files parked forever by a 413 | all of them (`held` never retried) | 0; each has a reason and a fix | T4 |
| 8 | Captures lost across the torture suite | unknown | 0 | T1–T12 |
| 9 | Progress accuracy (shown bytes vs. server `bytes_received`) | no progress shown | within one PATCH tail (≤ 5 MiB) | Pillar 2 probe |
| 10 | Second phone sees a new memo without refresh | never (no memo events) | ≤ 3 s | Pillar 5 probe |
| 11 | Places visibility can be set in the app | 2 (compose, long-press) | 6 (+ edit, Info sheet, pending card, Transfers) | Pillar 6 probe |
| 12 | Upload health visible in Grafana | no metrics | four panels live | Pillar 5 probe |
| 13 | Upload code paths for media | 3 (whole, chunk, foreground edit) | 1 | gate rule, week 4 |

---

## 7. What we will not do

- **No re-encode on the phone.** Not HEIC→JPEG, not a 1080p "phone copy" to make uploads faster.
  The server has the slow lane for that; the phone sends what Photos holds.
- **No tus, no IETF resumable-upload draft, no sidecar.** ADR-0007 rejected them with reasons that
  still hold; the offset protocol that exists is enough once the client finishes it.
- **No second upload path.** The foreground edit upload and the chunk lane are deleted, not
  deprecated.
- **No change to the main bar.** The Transfers strip sits in the timeline header; the sheet is a
  sheet; the island and the lock screen are the system's.
- **No new persistence framework.** The outbox's atomic JSON manifests in the app group stay; the
  ledger is a projection of them.
- **No progress by timer, ever.** If a number cannot be derived from a confirmed offset or a server
  state, the UI says "paused" or shows a count without a ring.
- **No Combine, no XCTest, no hand-written client methods, no unfenced identity read** — the
  doctrine stays.
- **No multi-account uploads from the extension.** A capture is bound to the account that was signed
  in when it was composed; a change refuses, as today.

---

## 8. Risks and kill criteria

| Risk | Signal | Kill criterion | Fallback |
|---|---|---|---|
| The extension-owned background session does not survive the extension's exit on device, or the app is not launched for its identifier | MEMNG-538 spike, day 1–2 | No successful 300 MB transfer with the app force-quit by Tuesday 3 Nov | P1 ships as "enqueue + app launched by a silent push": the server, told of the enqueue by a tiny foreground POST from the extension, sends a background push that wakes the app to drain. Scoreboard row 1 becomes ≤ 60 s instead of ≤ 5 s |
| ActivityKit push-to-start is unreliable for a capture the app never saw | Week 3 device runs | < 90 % of grant-opened captures show an activity within 30 s | Activity starts on the app's next wake (the background session wakes it within the transfer) |
| APNs key handling on the server is a new secret class | Week 2 review | — | No-op when unset, exactly like VAPID today; Live Activity falls back to local updates |
| `LISTEN/NOTIFY` under two uvicorn workers plus the worker container | Week 2 load test (200 subscribers, 50 uploads) | p95 event latency > 2 s or a dropped frame in replay | Keep the poll at 500 ms with `event:`/`id:`/`retry:` added — the client gains everything except latency |
| Hard-linked originals and the reclaim path | Week 3 rehearsal on a copy of production data | Any original unlinked while a second attachment references it | Dedupe creates a *copy* instead of a hard link (disk cost, zero risk) |
| Raising `MAX_UPLOAD_MIB` floods the slow lane | `memosng_media_jobs_queued{lane="slow"}` | Queue depth > 20 for an hour on a normal day | Keep the limit; size truth in the UI still lands |
| Photos library access prompt is declined by a household member | Week 2 build | — | The denied path keeps Post enabled; the un-loaded files say so in Transfers; nothing is lost |
| The month's merge volume exceeds the gate's throughput (one lane per branch, merkur + mars) | Lane pane, from week 1 | Two consecutive Fridays miss the build | Week 4 becomes soak-only earlier; P2's server push and P4's dedupe are the first to slip, because their fallbacks are complete products |

---

## 9. Owner decision points

Every other choice in this document takes the recommended option under the standing rule. These
five reverse something decided on purpose, or spend something only the owner can spend.

| # | Decision | Today | Recommended | Why it is the owner's |
|---|---|---|---|---|
| (a) | The share extension starts upload tasks itself, with a per-capture session identifier and an upload-only grant | "The extension never sends anything itself" (`ShareIngest.swift:6-7`; `project.yml:232-234`), a documented design rule | **Yes**, after the week-1 spike proves it on device | It reverses a written rule and widens what a process without the token can do (uploads only, revocable) |
| (b) | Raise `MAX_UPLOAD_MIB` from 1024 | `config.py:115`; ADR-0007 open point | **4096**, with disk admission at session creation | It changes the server's exposure to disk pressure and the slow lane's load |
| (c) | Visibility on the edit sheet | Deliberately omitted (`ComposeView.swift:434-436`) | **Yes**, narrowing immediate, widening confirmed once | It reverses a documented UI decision |
| (d) | APNs on the server (a `.p8` key in the stack's secrets) for Live Activity pushes and the memo-live notification | No APNs; web push via VAPID only | **Yes**, no-op when unset | A new secret class in production |
| (e) | Dedupe by hash across the owner's whole library, with shared originals on disk | Finalize-time dedupe against unlinked rows only | **Yes**, hard link + reference-counted reclaim; copy if the rehearsal shows any risk | It changes what a memo delete may remove from `DATA_ROOT` — the destructive-data row of the autonomy table |

**Decided 2026-10-27 by the owner, all five on the recommended option:** (a) yes, gated on the
week-1 device spike; (b) 4096 with disk admission; (c) yes, widening asks once; (d) yes; (e) hard
link with reference-counted reclaim, after the rehearsal, copy as the fallback. Scheduling: the
tickets are filed now; week 1's visibility-on-edit story and the MEMNG-538 device spike start by
hand in the week of 27 October; the rest waits for lane n from 2 November, which lifts the
26 October memos pause from that date.

Recorded, once decided, as ADR-0009 (extension-started uploads and the capture grant), ADR-0010
(upload fidelity: retry classes, resume, dedupe, size truth) and an amendment to ADR-0007 that keeps
its "no resumable protocol" while naming the offset-tail resume it already allows. The ADR-0008
number stays with the frozen main bar; plan 4144's "ADR-0008, proposed" label is corrected to
"amendment to ADR-0007".

---

## Appendix A — Contract growth (additive paths, all generated into `MemosAPI`)

| Path | Purpose | Pillar |
|---|---|---|
| `POST /api/uploads` + `sha256` (optional) | dedupe at session creation; `bytes_received = size` on a hit | 4 |
| `POST /api/uploads/batch` | up to 50 sessions in one request | 1, 4 |
| `GET /api/uploads/limits` | `max_bytes`, `wifi_recommended_above_bytes`, `bodies_per_user` | 4 |
| `DELETE /api/uploads/{uid}` | withdraw a session; no orphan reaches finalize | 3 |
| `GET /api/uploads/{uid}` | `bytes_received`, `size`, `state`, `principal` — the server-side truth for the ledger | 2 |
| `POST /api/tokens/capture-grant` · `DELETE …/{id}` | upload-only grant for the extension, 24 h, listed under Manage Tokens | 1 |
| `POST /api/devices/live-activity-token` · `DELETE` | push-to-start token registration | 2 |
| `GET /api/events` | `event:` / `id:` / `retry:`; types `upload.progress`, `attachment.status`, `memo.created`, `memo.updated`, `memo.deleted`, `memo.visibility`; `Last-Event-ID` replay | 5 |
| `PATCH /api/me` | `default_visibility`, `notify_on_household_posts` | 6, 5 |
| `MemoOut.attachments[].status` on list paths | pending tiles render without a second fetch | 3 |
| `/metrics` | the nine `memosng_upload_*` / `memosng_media_*` / `memosng_events_*` families | 5 |

Every path is synced into the app from one tagged memos-ng commit by `scripts/sync-openapi.sh`,
per the contract rule in `CLAUDE.md`; a release tag per week (2.7.0 … 2.7.3).

## Appendix B — Module map (iOS)

```
MemosNG (app)            composition; attaches every registered background session on wake
MemosShare (.appex)      + UploadStarter: creates sessions (batch), hands PATCH bodies to its own
                           background session, registers the identifier, finishes
MemosActivity (.appex)   NEW widget extension: Live Activity UI (lock screen, Dynamic Island)
MemosShareKit            ShareIngest + the capture-grant reader (no keychain, unchanged entitlement)
MemosOutbox              + SessionRegistry, StagingLane (PHAsset identifiers → group container),
                           EditJob, RetryClasses (transient / connectivity / hold), TransferLedger,
                           hash at staging; − ChunkMath, BackgroundChunkScheduler, chunk PATCH
MemosCore                MediaEventClient consumes memo.* and upload.progress; TimelineStore gains
                           PendingMemo; MemoActionStore + TimelineStore share VisibilityChange
MemosFeatures            TransfersStrip, TransfersSheet, pending card, edit-sheet VisibilityMenu,
                           Info-sheet chip, Settings rows (default visibility, mobile-data policy,
                           household notifications)
MemosAPI                 regenerated from the week's memos-ng tag; nothing hand-written
```

The dependency rule holds: nothing new imports Features; `MemosActivity` depends on `MemosOutbox`
only (the ledger's summary struct is its content state).

## Appendix C — The torture suite

Each row is a named test id the gate can run (`--only-testing`) where it is simulator-able, and a
device script with a screen recording where it is not. "Pass" is always a server-side read-back.

| Id | Scenario | Pass condition | Where |
|---|---|---|---|
| T1 | Wi-Fi lost at 60 % of a 400 MB clip, back after 30 s | `bytes_received` monotonic; wire bytes ≤ 1.05 × size | device |
| T2 | Server 429 for 20 s mid-transfer | retries inside `Retry-After` ± 1 s; completes ≤ 30 s after | device + sim |
| T3 | Re-share a photo already in the library | 0 PATCH rows; new attachment shares the sha256; no new media job | device |
| T4 | A file above the limit | reason shown before Post and in Transfers; nothing parked without a fix action | sim |
| T5 | Force-quit the app during a 30-file job | all 30 `ready`; one memo; no duplicates | device |
| T6 | Share with the app force-quit, then never open it | memo exists on the other phone | device |
| T7 | Sign out mid-transfer | job `held · signed in as someone else / signed out`; nothing uploaded under the new identity; the hold is released by signing back in as the same account | sim |
| T8 | Switch accounts mid-transfer | `accountChanged` refusal; the old account's job stays held, never re-bound | sim |
| T9 | Remove a pending memo whose first file is already on the server | upload sessions withdrawn; orphan count unchanged after the sweep | sim |
| T10 | Two overlapping retries of one file | exactly one PATCH on the wire (stub transport) | sim |
| T11 | A stale 401 arrives after a successful re-sign-in | the session survives; the job resumes | sim |
| T12 | 48 h backgrounded with a job waiting for Wi-Fi | the job is intact on day 3 and lands on the first Wi-Fi | device |

## Appendix D — Existing tickets this absorbs

| Ticket | State today | Lands in |
|---|---|---|
| MEMNG-538 background-URLSession device spike | Open | Week 1, Extension squad (go/no-go) |
| MEMNG-546 whole-file uploads, chunk lane removed | Open | Week 3, Compose squad |
| MEMNG-672 / MEMNG-302 chunk-lane races | Open, design-first / owner-blocked | Closed by lane removal, week 3 |
| MEMNG-633 stalls at 7 % re-sending the whole video | Verification | Week 2, resume-from-offset |
| MEMNG-934 stalled body holds its slot 300 s | Open | Week 1, Server squad |
| MEMNG-648 raise admission limits | Open | Week 1, Server squad |
| MEMNG-655 Traefik transport timeout | Open | Week 1, Server + infra |
| MEMNG-657 "Waiting to try again" wording | Open | Week 1, retry classes |
| MEMNG-656 retry a keyed create once after a 5xx | Open | Week 1, retry classes |
| MEMNG-650 expired-link reissue loses a row | Open | Week 2, events (the list is patched by events, not re-read) |
| MEMNG-489 cancel a stalled upload back into the editor | Verification | Week 2, pending card + Remove |
| MEMNG-647 whole-file pilot checklist as outbox tests | Verification | Week 4, torture suite |
| MEMNG-290 / 291 / 293 orphan sweep vs. extension enqueue | Verification | Week 2 (registry under the same lease) |
| MEMNG-855 Set visibility (retitled away) | Delivered | Pillar 6 re-opens the intent as a new story |
| Plan 4144 request budget + upload resilience (I1–I4, C1) | Draft | Pillar 4, weeks 1–3 |

Filed as one Epic ("Upload moonshot 2.7") with six Stories (one per pillar) and the torture suite
as a seventh, each Story on a weekly milestone, per the backlog-align hierarchy.

# The memos-ng Moonshot — "The Household Memory"

**Horizon:** 12 months, November 2026 → October 2027
**Assumption:** unlimited engineering hands, the same one household, the same self-hosted server.
**Status:** proposal, not a plan. Nothing in here is ticketed, gated or decided. Where it collides with
a decision the owner already made, the collision is named in § 9 and the owner decides.

---

## 0. How to read this

A moonshot is not a backlog. It is a description of a product that does not exist yet, written
concretely enough that a team could start on Monday and know what "done" looks like in twelve
months. So this document does three things:

1. It states where the product stands today, from the repositories as they are (§ 1).
2. It describes the product twelve months out as eleven pillars, each with the scenes a family
   would actually live, the server and iOS work behind them, the hard parts, and the acceptance
   probe that proves it shipped (§ 4).
3. It lays that work on a quarter-by-quarter roadmap with named squads, demo days and kill
   criteria (§ 5–8).

"Unlimited dev resources" removes the usual constraint, so a different one takes its place: there
is exactly one household, one server, one owner reviewing everything. Throughput of hands stops
mattering; **throughput of trustworthy pilots** becomes the limit. Every pillar below is therefore
built to land as a weekly TestFlight the family can use, behind a flag, before it is finished.

---

## 1. Where we stand (the baseline, from the code)

What exists today, so the moonshot is measured against reality rather than against a blank page.

**The product.** memos-ng is a self-hosted, phone-first family photo and memo app: markdown
memos with tags and media on a timeline, plus the photo-library features that grew around them.
The users are one household. It runs as two containers from one image (app + worker) and a
Postgres 17, behind Authelia SSO, on the family's own hardware.

**The server (memos-ng).** Python 3.13, FastAPI, SQLAlchemy 2 async, Alembic. Vue 3.5 + PrimeVue
4 + Tailwind 4 SPA with MapLibre and PMTiles. Visibility is a three-level enum (PRIVATE,
PROTECTED, PUBLIC; the app calls PROTECTED "Just us"). Tags on memos and, since 2.4.0, on
pictures (favorites). Collections of kind trip (tag + date span) and album (hand-picked), with
covers. Location columns and a `/api/map/*` surface cut from Protomaps. A daily photo digest
e-mail with its own tables, runner, renderer and metrics. Uploads are whole-file over
`/api/uploads`; tus was removed in 1.11.0. The worker drains `media_jobs` with
`FOR UPDATE SKIP LOCKED` in a fast lane (thumbnails, posters) and a slow lane (ffmpeg H.264),
with a thermal guard. Renditions and blurhashes are stored; delivery is through HMAC-signed,
short-lived, DB-free URLs over a local filesystem under `DATA_ROOT`. Search is Postgres
`tsvector`. Export exists (`/api/export`, a 4096 px photobook rendition). Web Push via VAPID.
Prometheus metrics. 64 OpenAPI paths. No CI; a local gate.

**The iOS app (memos-ng-ios).** SwiftUI, Swift 6 strict concurrency, iOS 26, iPhone 16 and up.
Four packages in a strict dependency line (Features → Core → API) plus an outbox package and a
share extension. Four tabs: Timeline, Library, Collections, Places. Compose with camera, a media
viewer with video, a Photos-style Library (day, month mosaic, year jump), trips and albums, a
MapKit Places map on Apple's basemap, a favorites heart, a heatmap date jump, Settings with
Manage tokens, a What's New sheet. Sign-in through SFSafariViewController and a custom scheme;
PAT in the Keychain. Uploads are one whole-file background URLSession task per media file, no
resumption (ADR-0007). A per-(server, user) timeline read cache; a durable capture outbox; no
offline editing. Only derived tiers are ever drawn; an original is fetched only on an explicit
Save or Share. The build authority is a Mac gate reached over ssh, with mutation-tested
warnings-as-errors, pinned dependencies, test-count baselines and a TestFlight cut script.

**What the docs already park.** Voice notes and transcription (deferred to the backlog in the
parity roadmap). A Places playback timeline (code exists, not drawn; the owner shelved it on
2026-09-18). Set-visibility from the app (MEMNG-855). Push, offline editing, widgets, watchOS and
iPad are listed as out of v1 even though push and outbox code now exist. Accessibility is
explicitly out of scope (owner, 2026-09-20). The main bottom bar is frozen as built on 2.2.1 (41)
(ADR-0008). Store submission is an open phase.

**What is genuinely strong.** The media pipeline, the signed-URL delivery path, the visibility
model, the typed OpenAPI contract with a generated Swift client, the outbox, the gate. These are
foundations, and the moonshot leans on every one of them rather than replacing them.

---

## 2. The moonshot in one sentence

> **In twelve months memos-ng is the household's memory: everything the family photographs,
> films, says and writes is kept at full fidelity on hardware the family owns, is understood by
> intelligence that never leaves the house, and comes back as stories on every screen in the
> home.**

Three promises sit under that sentence. Each pillar in § 4 serves at least one.

| Promise | What it means | What it rules out |
|---|---|---|
| **Nothing is lost** | Originals verbatim and bit-checked forever; every word, voice note, caption and location kept; a complete export that renders with no server. | Lossy "originals", a vendor format, a library that only works while the app runs. |
| **Nothing leaves the house** | Faces, speech, embeddings and search all computed on the phone or on the family's own server. No third-party AI API in the default path. | Cloud ML, telemetry, an account with anyone but the household. |
| **It comes back to you** | The library tells its own stories: this day, this trip, this person, this year; on the phone, the TV, the wall, the printed page. | A grid you scroll and forget. |

---

## 3. Principles that do not bend

These are the constraints every pillar is designed inside. They are not new; most are already
true of the codebase. The moonshot makes them explicit so an eleven-squad effort does not erode
them.

1. **Originals are sacred and never displayed.** The bytes that arrive are the bytes kept. Every
   screen draws a derived tier. The only way to get an original is an explicit Save or Share.
2. **The contract is the product.** Every capability is a typed OpenAPI path first; both the SPA
   and the generated Swift client consume the same contract. Never a hand-written client method.
3. **Private by architecture, not by policy.** Visibility, circles, signed URLs and on-device
   inference are enforced in code paths, not in settings a bug can flip.
4. **The store serializes its own mutations; every identity-scoped read is epoch-fenced; a one-shot
   answer is deduplicated at the callback site; a refusal carries its epoch to the effect.** The
   four invariants from the iOS CLAUDE.md apply to every new store, lane and package.
5. **Pilot first.** A thin, flagged, usable slice in the family's hands beats a finished feature
   nobody has held. Weekly TestFlight, every pillar, from month one.
6. **The gate is the only build authority.** More hands means more gates, not fewer checks. Any
   pillar that cannot be mutation-tested, baseline-counted and device-run does not merge.
7. **Family-scale, forever.** Design for one household of a few people and a few hundred thousand
   assets over decades. Never for a million tenants. The right trade-offs follow from that.
8. **Open on the way out.** Every table has an export; every export renders without memos-ng.

---

## 4. The eleven pillars

Each pillar follows the same shape: the dream, the scenes, the server work, the iOS work, the
hard parts, what we keep from today, and the acceptance probe that proves it shipped. The probes
are deliberately on the real surface (a rendered view, a database row, a printed object), never a
log line.

### Pillar 1 — Understanding: the library knows who, where, what and when

**The dream.** You can ask the library anything a family member could answer by flipping through
it: "the kids at the lake, summer 2025", "every picture with grandma's handwriting", "that video
where she said 'again'". The answers come from models that run on the phone and on the home
server, never from a cloud API.

**Scenes.**
- At the search field you type "lake" and get the lake pictures, with or without a tag, because
  the image embedding knows what a lake looks like.
- You tap a face in the viewer; the app offers "This is Lena" once, and from then on every picture
  of Lena is one tap away, including the ones from 2019 nobody tagged.
- A photo of a hand-written recipe card is searchable by its words.
- A voice memo recorded at the playground is transcribed on the phone and searchable before it
  has even uploaded.
- The Timeline shows a weather glyph and the place name on each day header, derived from the
  capture metadata, never typed.

**Server work.**
- `pgvector` with HNSW indexes: one `asset_embeddings` table keyed by asset uid and model id
  (image embedding, text embedding of caption/OCR/transcript), so a model upgrade is a new row set
  and a backfill, never a migration of meaning.
- A worker lane `understand` next to `fast` and `slow`: image embedding (an open CLIP-family
  model such as MobileCLIP or SigLIP in ONNX), OCR, scene and object tags, face detection and
  embedding. All run on the family's own server; a GPU is optional, not required.
- Server-side speech-to-text (whisper.cpp-class) for uploads from devices that could not transcribe
  on-device.
- `people` and `person_faces` tables: a face cluster becomes a person only when a human names it.
  Unnamed clusters are never surfaced beyond "suggested". People are household-private by
  default; a person record never leaves the house in any export unless the exporter says so.
- A hybrid search endpoint: `tsvector` for words, vector similarity for meaning, re-ranked
  together, with the same filters the current search takes (tag, visibility, date, mine,
  pictureTag) so the SPA and the app keep their existing query shape.
- Reverse geocoding and weather-at-capture resolved from the family's own offline datasets
  (the Protomaps cut already exists; a gazetteer and a historical weather extract are the same
  shape of vendored asset).

**iOS work.**
- An on-device inference package `MemosSense` (Core → Sense, Features consumes it): Vision for
  face rectangles and feature prints, VisionKit text recognition, the iOS 26 SpeechAnalyzer for
  transcription, Core ML with a converted MobileCLIP for image and text embeddings. Everything
  runs in the outbox lane before upload, so understanding ships with the bytes.
- A people sheet in the viewer, a People section in Library, and "Who is this?" suggestions
  gated behind a per-household flag.
- Natural-language search in the Library search field, with the top hits explained ("matched:
  caption · scene: beach").
- Foundation Models (the on-device Apple LLM in iOS 26) to turn a raw query into the structured
  filter the API already understands, so "Lena at the lake last summer" becomes
  `person=lena scene=lake date=2025-06..2025-09` without any text leaving the phone.

**Hard parts.**
- Face clustering is the one feature that can be wrong in a way a family notices. Precision over
  recall, always; a merge needs a human; a split is one tap.
- Model versioning: the embedding space changes when the model changes. The `model_id` column and
  a side-by-side backfill is the whole answer, and it has to be designed in from the first row.
- Battery: on-device inference lives in the outbox's processing lane with the same thermal
  discipline the worker has, and never runs on a hot device.

**We keep.** The `tsvector` search, every existing filter, the signed-URL delivery, the media
lanes.

**Acceptance probe.** On the family's real library: a free-text query with no tag match returns the
intended picture in the top five on at least 9 of 10 scripted queries; the people view for a named
person shows a stranger in fewer than 1 in 200 results; a voice memo recorded in airplane mode is
searchable by its words before the device reconnects.

### Pillar 2 — Stories: the library retells itself

**The dream.** memos-ng stops being a grid and starts being a book. Trips become chapters with a
first page. Every morning there is a "This day" page. At the end of a year there is a year book,
drafted by the library, edited by the family, and printed.

**Scenes.**
- The daily digest e-mail becomes a "This day" story in the app, on the TV screensaver and in a
  Lock Screen widget: the same day across years, with the best three pictures chosen by sharpness,
  faces and the family's own favorites.
- A trip is detected from GPS and time: a tight cluster of captures 300 km from home over four
  days becomes a suggested trip with a route, a map, the daily highlights and the memos written
  during it. One tap accepts it as a collection.
- The year book: a draft 60-page layout for 2026, chapters by trip and month, covers chosen by
  the existing cover logic, captions from memos, a places spread, a people spread. Edit on iPad
  or the SPA, order a printed copy from the app, and the PDF is also in the archive export.
- A short highlight reel for a trip: the best clips and pictures, cut to a length, rendered on
  the phone with AVFoundation, shareable at the 2048 share tier.

**Server work.**
- A `stories` resource: a story is a typed document (chapters, spreads, captions, picks)
  referencing asset uids, with a renderer to HTML (the digest renderer grows into it), to PDF
  (the photobook path already produces print renditions) and to the TV.
- Trip detection as a worker job over the location columns, with the detector's parameters
  stored per household so the family can tune what counts as "away".
- A "best shot" scorer in the `understand` lane: sharpness, exposure, faces present, eyes open,
  duplicates collapsed. Stored as a score column, never as a hidden decision.
- The photobook export grows from a rendition into an orderable product: a print-service
  adapter (one vendor behind an interface) with proofs, pricing and a read-back of the order
  state.

**iOS work.**
- A Stories tab is NOT added: the main bar is frozen (ADR-0008). Stories live inside
  Collections (a trip is already a collection) and at the top of Timeline as "This day".
- A story editor sheet: reorder spreads, swap a pick, edit a caption, choose a cover; every edit
  is a typed PATCH on the story document.
- The highlight-reel renderer using AVMutableComposition on device.
- WidgetKit "This day" (small, medium, Lock Screen) and a Live Activity for a reel render.

**Hard parts.**
- Taste. Automatic picks must be good enough to keep and easy enough to override that nobody
  resents them. The pick is always shown with its reason.
- The print vendor is the first third party in the loop. It only ever sees the print renditions
  the family explicitly orders, never the library.

**We keep.** The digest tables and renderer, collections and covers, the photobook rendition.

**Acceptance probe.** A printed year book for 2026 is on the table by the end of month ten, ordered
from the app, and the family changed fewer than 20 % of its auto-picked spreads before ordering.

### Pillar 3 — Capture everything: voice, words, milestones, scans, the camera roll

**The dream.** Whatever a family makes on a phone ends up in the library without a decision:
pictures, video, Live Photos, ProRAW, spatial captures, screenshots that matter, voice notes, a
sentence a child said, a scanned drawing, a growth milestone.

**Scenes.**
- You hold the capture button; it records a voice memo, transcribes it on the device and files
  it under today with the transcript as the memo text.
- "Quote" is a memo kind: who said it, what, when. The year book has a quotes spread.
- A scanned drawing from the fridge goes through VisionKit's document camera and is kept as a
  flat, deskewed image with the original frame.
- The app can take over the Photos library: a one-time import of everything, then a continuous
  watch that imports new captures (with the family's choice of what counts), deduplicated by
  perceptual hash against what is already in the library.
- Live Photos, HDR gain maps, ProRAW and spatial video are kept whole; the derived tiers render
  them correctly (the HDR poster tone-map already exists).

**Server work.**
- Memo kinds: `note`, `voice`, `quote`, `milestone`, `scan`. One table, one `kind` column, typed
  payloads in the contract. The timeline renders each kind with its own card.
- Perceptual hashes (pHash + dHash) in the `understand` lane; a `near_duplicates` relation; the
  import endpoint can answer "do you already have this?" before any bytes are sent.
- Sidecar preservation: Live Photo pairs, RAW + JPEG pairs, gain-map metadata, spatial MV-HEVC
  all kept as one logical asset with multiple files, which the sibling-metadata work already
  started.
- A `milestones` resource (person, kind, date, memo) for the baby-and-child use the household
  already lives.

**iOS work.**
- Capture kinds in Compose: a hold-to-record voice control, Quote, Scan (VisionKit), Milestone.
- A PhotoKit importer: a full-library backfill with resumable progress, then a change-observer
  that enqueues new assets into the existing outbox. Everything goes through the outbox so the
  upload invariants hold.
- The Photos "Shared with You" and share-sheet paths already exist; the importer adds a
  "Keep in memos" shortcut on any Photos item through App Intents.

**Hard parts.**
- Deduplication must never delete. It only groups. A near-duplicate group is shown, the family
  decides.
- The importer's first run on a 50 000-item camera roll must survive a week of backgrounding.
  BGProcessingTask plus the outbox's own durability is the design; the probe is a cold run.

**We keep.** The outbox, the share extension, the whole-file background upload.

**Acceptance probe.** A fresh phone with 30 000 Photos items imports to the library in the
background without the app in the foreground for more than a minute at a time, with zero
duplicates created on a second run.

### Pillar 4 — Local-first: the whole library on the phone, edits that never conflict

**The dream.** The phone holds the whole library's metadata and enough derived tiers to browse
all of it on a plane. Every edit (tag, caption, favorite, visibility, album membership) is made
locally, instantly, and synchronizes when a connection exists. Two phones editing the same memo
do not fight.

**Scenes.**
- On a flight you tag three hundred pictures of a trip, write captions, build an album. On
  landing the server has it all, in order, with nothing lost and nothing duplicated.
- Two parents fix the same caption on two phones; the later word wins per field, and both see the
  same thing within seconds of reconnecting.
- Year, month and day in Library open instantly for the whole archive, scrolled at 120 Hz with no
  network.

**Server work.**
- A change log: every mutation on memos, assets, tags, collections and stories appends a row to
  `changes` with a monotonic server sequence; `/api/sync` streams rows since a cursor and accepts a
  batch of client operations with per-field last-writer-wins and a server-assigned sequence. SSE
  `/api/events` already exists and becomes the wake-up signal.
- Idempotent writes keyed by a client operation id, so a retry after a timeout cannot double a
  tag or an album membership.
- Resumable uploads return, this time native: `Content-Range` PATCH on `/api/uploads/{uid}` and
  `HEAD` for the offset. ADR-0007 chose whole-file retries because tus was the wrong shape;
  this is the moonshot's one deliberate reversal and goes to the owner (§ 9).

**iOS work.**
- A `MemosStore` package: SQLite through GRDB, holding the mirrored tables plus an outgoing
  operation queue. The outbox becomes one lane of this store.
- Every store in Features that reads over the network today reads the local database instead;
  the network becomes a background sync actor. This is the largest single refactor in the
  moonshot and is done one tab at a time behind a flag, Library first.
- A tier cache policy per asset: "keep offline" per collection or per year, with disk budgets
  and the existing signed-URL expiry respected (a cached tier is a cached file, not a cached URL).

**Hard parts.**
- Per-field LWW is enough for a household and avoids a CRDT library; the moment shared text
  editing is wanted (Pillar 5 comments), that decision is revisited with a real need in hand.
- Migration: the mirror is built from the existing endpoints first, then switched to the change
  log. Both paths run in parallel for a quarter with a reconciliation check in the gate.

**We keep.** The outbox, the read cache idea (generalized), SSE, the signed-URL media cache.

**Acceptance probe.** Airplane mode for 24 hours with 500 edits across tags, captions, favorites
and two new albums; on reconnect, a server-side diff of the change log against the device's
operation queue shows exactly 500 applied, 0 duplicated, 0 lost, and the SPA shows the same.

### Pillar 5 — Everyone in the house: people, circles, guests, reactions

**The dream.** The library is shared the way a family shares a living room. Each person has an
identity; who can see what is expressed as circles instead of three fixed levels; grandparents
and friends get their own windows without accounts; the family reacts and comments; a party
guest can drop pictures in through a link.

**Scenes.**
- Circles: `household`, `grandparents`, `just-us` (the two adults), `kids` (what the kids may
  browse on the TV). A memo or album belongs to circles. The three-level enum maps onto three
  default circles so nothing existing changes meaning.
- Grandma opens a link on her iPad, sees "Lena's week" as a living album that updates itself,
  with no account, no app, no password; the link is a circle membership token with an expiry.
- A birthday party: a QR code on the table; guests scan it and drop their pictures into the
  party album from their own phones through the web, into a holding area the family approves.
- Reactions and short comments on a memo, visible to the circle it belongs to; kids' accounts
  can react, not delete.
- "Just us" pictures still live only in their trip or album (owner rule, 2026-10-26): circles do
  not change where things live, only who can see them.

**Server work.**
- `circles`, `circle_members` (user or guest token), `audience` on memos, assets and collections
  as a set of circle ids. Visibility becomes a derived property for the compat paths.
- Guest access: a `guest_tokens` table, scoped to one circle, expiring, revocable, with its own
  signed-URL audience so a leaked link can be cut without rotating anything else.
- A drop endpoint: unauthenticated, token-scoped, quarantined uploads into a `drops` holding area;
  nothing enters the library until a household member accepts it.
- `reactions` and `comments` tables, SSE fan-out for live updates.
- Kids' accounts as a role with no delete and no export.

**iOS work.**
- A circle picker wherever visibility is set today; the "Set visibility" deferral (MEMNG-855)
  becomes this.
- Reactions on the viewer and timeline cards; a comments sheet.
- A "Share a window" flow that mints a guest link with a QR code, a chosen circle and an expiry,
  and reads it back from the server before showing it.

**Hard parts.**
- Every identity-scoped read is epoch-fenced (invariant 2). A guest token revoked mid-session
  must stop rendering on the next fetch, never resurrect a list.
- The SPA is the guest surface, so its guest mode is a product in itself: read-only, no account
  UI, no leakage of household structure.

**We keep.** The three visibility levels as default circles, Authelia for household identities,
PATs, the native login lane.

**Acceptance probe.** A grandparent link opened on a device that has never seen memos-ng shows a
living album, updates within 10 seconds of a new picture joining its circle, and shows nothing
within 10 seconds of the link being revoked; a drop from a guest phone appears in the holding
area and in the album only after acceptance.

### Pillar 6 — Every screen in the house: TV, Mac, iPad, watch, Vision Pro, wall

**The dream.** The library is wherever the family looks: the TV screensaver, the Mac menu bar,
an iPad on the kitchen counter, a watch face, a Vision Pro immersive view, an e-ink frame on the
wall. One codebase, many screens.

**Scenes.**
- tvOS: the screensaver is "This day" and the last trip; the Siri Remote browses years; a trip
  plays as a slideshow with its map.
- iPad: the year book editor, with drag and drop across spreads and a pencil for captions.
- macOS (native SwiftUI, not Catalyst): the full app plus the archive tools (fixity reports,
  export), and a menu-bar "This day".
- watchOS: a complication with today's story; "Quote" capture by voice on the wrist.
- visionOS: spatial photos and videos from an iPhone 16 Pro open in their full depth; panoramas
  wrap the room; the Places globe floats on the table.
- Wall: a Home Assistant integration serves a frame endpoint; an e-ink display on the hallway
  wall shows one picture a day, chosen by the story engine.
- Widgets, Lock Screen, App Intents, Siri and Spotlight: "Hey Siri, show me pictures of Lena
  at the lake" opens the app on the result; memos are Spotlight-indexed on device.

**Server work.**
- A `frame` endpoint: given a circle token and a size, returns today's chosen picture at that
  size, cache-headed for a device that polls once an hour.
- tvOS, macOS and visionOS all consume the same contract; the only server work is making sure
  the signed URLs and tiers cover the sizes those screens need (4K tiers for TV and Vision Pro,
  MV-HEVC passthrough).
- A Home Assistant custom component in the memos-ng repo, released alongside.

**iOS work (really: Apple-platform work).**
- Features already keeps the platform-specific code thin; the moonshot adds `MemosTV`,
  `MemosMac`, `MemosWatch`, `MemosVision` targets consuming Core, with Features split so view
  models are shared and views are per platform where they must be.
- iPad is the same app with size classes and the editor.
- App Intents for search, capture and "Keep in memos"; WidgetKit timelines backed by the local
  store (Pillar 4); Spotlight indexing from the local store.

**Hard parts.**
- The gate. Every target is a new scheme, a new simulator slot, a new test-count baseline and a
  new place for a warning to hide. The gate must grow before the targets do (Pillar 11).
- The main bar is frozen on iPhone. The other platforms have their own navigation and the
  freeze does not extend to them; this is stated so nobody treats tvOS as a bar change.

**We keep.** The whole Features/Core/API stack; the Places map; the frozen iPhone bar.

**Acceptance probe.** The same trip, opened on iPhone, iPad, Mac, TV and Vision Pro, shows the
same pictures in the same order with the same captions, from the same server, with no
platform-specific API path; the hallway frame shows a new picture every morning for 30 days
without intervention.

### Pillar 7 — Video as a first-class citizen

**The dream.** Video is no longer a poster with a play button. It scrubs instantly, streams at
the right quality for the screen and the connection, keeps its audio, and gets cut into
highlights without leaving the app.

**Scenes.**
- A four-minute 4K clip scrubs with frame-accurate thumbnails before a byte of the main stream
  has loaded.
- On cellular the viewer plays 720p; on the TV it plays 4K HEVC; both come from one ladder.
- Trim a clip to the ten good seconds, keep the original untouched, and the trimmed version is a
  derived asset with provenance pointing at its source.
- A Live Photo plays its three seconds on long-press, as in Photos, with its sound.

**Server work.**
- The slow lane grows an HLS ladder: CMAF fMP4 segments, 360p–1080p H.264 plus HEVC up to 4K,
  AAC audio, with the existing thermal guard and a per-asset priority (recent first).
- Scrub sprite sheets and a WebVTT thumbnail track per asset.
- Derived assets: a trim is a new asset row with `derived_from`, rendered by the worker, keeping
  the original immutable.
- Signed URLs extend to HLS playlists and segments (one signature over the asset, segments
  served under it).

**iOS work.**
- AVPlayer with HLS and the thumbnail track; a scrub bar with the sprite sheet.
- A trim sheet on the viewer that submits a trim job and shows the derived clip when ready.
- Live Photo playback in the viewer and in Library tiles on long-press.

**Hard parts.**
- Storage. A ladder for every video multiplies disk use. The policy is lazy: a ladder is cut on
  first play request and kept with an LRU, except for the tiers the story engine picks.
- The video cover patch in flight today (MEMNG-914) is the seam this pillar starts from.

**We keep.** The H.264 slow lane, posters, the HDR tone-map, the viewer's video layer.

**Acceptance probe.** A 4K clip uploaded from the phone is scrubbable in the viewer within two
minutes of upload on the home network; the TV plays it at 4K; cellular plays it at 720p; the
original file's checksum is unchanged in the archive.

### Pillar 8 — Forever: archival fidelity, provenance and the way out

**The dream.** This library outlives the software, the server and possibly the people who built
it. Every original is content-addressed and checked on a schedule; there are three copies on two
media with one off-site; every asset carries provenance; the whole thing exports to a folder
that renders in a browser with no server; and a documented path hands it on.

**Scenes.**
- A nightly fixity scrub reads every original, compares its BLAKE3 against the manifest and
  reports in the app's Settings: "412 311 files, 0 mismatches, last full pass Tuesday".
- A disk fails; the off-site copy restores it; the scrub confirms.
- "Export everything" produces a folder: originals by year, a `manifest.json`, a static HTML
  index with the timeline, trips, albums, people and places, all viewable offline on any
  computer for the next thirty years.
- Every picture taken in the app carries a C2PA manifest signed by the household's key: this
  came from this phone, on this date, edited by nobody.
- A "digital legacy" page in Settings names who gets the keys and the export, and how.

**Server work.**
- Content-addressed storage: originals stored under their BLAKE3, with the memo-folder layout
  kept as a view (hard links or a manifest) so nothing existing breaks.
- A `fixity` worker job over the whole store, with a `fixity_runs` table and metrics.
- Off-site replication through a maintained tool (restic or kopia, never a hand-rolled copier),
  driven by the worker, with restore rehearsed in the gate monthly.
- The static export: a renderer that writes the HTML index, with the same markdown pipeline
  the digest uses, and every derived tier it needs so the folder is self-contained.
- C2PA signing with `c2pa-rs` for app captures; verification shown in the viewer's info sheet.
- Format strategy: originals never transcoded; derived tiers move to AVIF or JPEG XL when every
  target platform decodes them, decided per tier by a table in the repo, not by a flag.

**iOS work.**
- An Archive section in Settings: fixity status, copies, last restore rehearsal, export
  progress, legacy page.
- C2PA signing at capture in the outbox lane, with the household key in the Secure Enclave.
- The info sheet (the deferred MEMNG-869 work) shows provenance.

**Hard parts.**
- Restore is the feature; backup is the side effect. The monthly rehearsal restores a random
  sample to a scratch location and compares checksums, in the gate, with the result on the
  Settings page.
- The export is only honest if it is tested by opening it on a machine with no memos-ng. That
  test is scripted.

**We keep.** `DATA_ROOT`, the memo-folder layout as a view, the existing export endpoints.

**Acceptance probe.** Pull a drive; restore from off-site; the scrub reports 0 mismatches. Open
the static export on a laptop with no network and browse a trip, a person and a place.

### Pillar 9 — Place and time as a canvas

**The dream.** Places becomes a way to travel through the library, not a map with pins. Routes
of trips, a globe of years, a place page for the lake house with every visit, and time as a
scrubber across all of it.

**Scenes.**
- The globe: spin it, and each trip is an arc; tap an arc and you are in that trip.
- The lake house has a place page: every visit, by year, with the people who were there and the
  weather that week.
- A trip's route is drawn from the pictures' GPS plus, with permission, the phone's own
  significant-location history imported at trip creation, so the drive is a line and not a dot.
- Time as a scrubber: drag across a year and watch the map fill. This is the playback timeline
  the owner shelved in 2026-09-18, re-proposed with a full year's data behind it (§ 9).

**Server work.**
- `places` as first-class rows (a named cluster of coordinates with a radius), with the
  gazetteer-derived default names from Pillar 1; `place_visits` derived by the worker.
- Route storage per trip: a simplified polyline from the captures, optionally enriched by a
  device-imported track.
- Map markers grow a time dimension in the existing `/api/map/markers` so the scrubber is one
  query shape.

**iOS work.**
- MapKit with a globe at low zoom; trip arcs as overlays; place pages as a Collections kind.
- The scrubber on the Places tab, flagged, as the first pilot of the re-proposed timeline.

**Hard parts.**
- Location privacy inside the house is not an issue; outside it is. Place names and routes
  never leave in a guest circle unless the album explicitly includes the map.

**We keep.** The MapKit Places map, the Apple basemap on iOS, the Protomaps cut for the SPA.

**Acceptance probe.** A trip created from last summer's pictures shows a route that a family member
agrees is the drive they took, and the place page for home shows every year since the first
upload.

### Pillar 10 — Platform: the library as a thing agents and tools can use

**The dream.** memos-ng is the household's memory API. An assistant can answer from it; the
home's automations can act on it; the family's own scripts can read it; and all of that stays
inside the house.

**Scenes.**
- An MCP server ships in the memos-ng image: an agent on the family's own machines can search,
  read a memo, list a trip, pick pictures for a story draft, and never write without a scoped
  token.
- "Ask the library" in the SPA and the app: a chat that answers from the library with citations
  to the pictures, powered by Apple's on-device model on the phone and by a local model on the
  server. A cloud model is a per-household opt-in, off by default, and the library's content is
  never sent, only the structured results.
- Webhooks: a new picture in the `party` album triggers the hallway frame to show it; a new
  milestone posts to the family chat.
- A versioned, documented public contract with a deprecation policy, because the agents will
  depend on it.

**Server work.**
- `/api/v2` is NOT created; the existing contract is versioned by the shared API major (the
  owner's version policy) and grows additively. An OpenAPI diff check in the gate fails on a
  breaking change.
- An MCP server (one process, same image) exposing read tools and scoped write tools over the
  PAT model, with every call logged to an `audit` table.
- Webhooks: `subscriptions` with signed deliveries and retries, built on the SSE event stream.
- A local LLM adapter interface with one maintained backend behind it; the chat answers are
  always grounded in search results with asset uids, never free generation.

**iOS work.**
- "Ask the library" as a sheet from the search field, using Foundation Models for the planning
  step and the API for the facts.
- Shortcuts actions that mirror the MCP tools, so the family's automations work from the phone
  without an agent.

**Hard parts.**
- Scoped writes. An agent must never be able to delete or change visibility; those are
  household-member actions. The PAT scopes grow to express that.

**We keep.** PATs, SSE, the OpenAPI-first contract, the shared API major.

**Acceptance probe.** An agent, given only a read PAT, answers "where were we on 14 May 2026?"
with the right place and three pictures, and its attempt to set visibility is refused and logged.

### Pillar 11 — The engineering moonshot: a gate that scales to eleven squads

**The dream.** More hands do not mean a slower gate or a looser bar. The gate grows into a device
farm, every pillar has a performance budget it cannot exceed, and the whole system is exercised
by chaos and fuzzing before the family ever sees a regression.

**Scenes.**
- A merge runs on three Macs in parallel, against four simulator slots and two real phones, and
  reports one summary line with `exit=0`.
- Library scrolls a 300 000-asset library at 120 Hz on an iPhone 16; the gate measures it, and a
  frame-time regression of 10 % fails the merge.
- The server runs under a nightly chaos job: a killed worker mid-ladder, a full disk, a Postgres
  failover, a corrupted original; every one of them ends in a defined state and a metric.
- The OpenAPI contract is fuzzed; every endpoint survives malformed input with a typed error.

**Server work.**
- CI arrives: the local gate becomes a job that runs on the family's own runner, with the same
  scripts. Coverage is measured but the bar is mutation score, as it is on iOS.
- Perf budgets as tests: p95 latency per endpoint on a replayed real-traffic sample, with a
  stored baseline and a fail on regression.
- Chaos jobs on the dev stack, nightly, with a report page.
- Fuzzing of the contract with a schema-driven generator in the gate.

**iOS work.**
- Device-farm gate: the existing lane framework grows from two Macs to as many as are plugged in,
  with real devices via `xcodebuild -destination` and the existing admission helper owning the
  slots.
- Scroll and launch performance tests in the gate with stored baselines; `os_signpost` in the
  stores; an in-app perf overlay behind a flag.
- Snapshot tests of every populated view in light and dark, on the device scope (iPhone 16 and
  up), with a reviewed baseline.

**Hard parts.**
- The gate is already the bottleneck with one squad. With eleven, the lane framework's locks,
  disk admission and simulator slots are the critical path. This pillar starts in week one and
  nothing else merges at scale until it has landed.

**We keep.** Every gate rule, the mutation-tested warnings canary, pins, baselines, the lanes.

**Acceptance probe.** Eleven concurrent merges in one day, each with a full green gate summary,
with the median gate time no worse than today's single-lane time.

---

## 5. The roadmap: four quarters, eleven squads, four demo days

The roadmap is organized so that **every quarter ends with something the family uses**, and so
that the two foundation pillars (local-first and the gate) land before the pillars that depend on
them. Dates are quarters of the moonshot year, starting November 2026.

### The dependency spine

```
Q1  Gate at scale (P11) ──┐
    Change log + sync (P4) ──┼──► Q2 everything on the phone reads the local store
    Content-addressed store + fixity (P8) ──┘
    Embedding index + understand lane (P1)
    Circles data model (P5)

Q2  People, OCR, speech (P1) ──► Stories picks (P2) ──► Q3 year book
    HLS ladder (P7) ──► Q3 TV and Vision Pro
    Guest links + drops (P5)
    Capture kinds + importer (P3)
    tvOS + iPad (P6)

Q3  Year book + print (P2)        macOS, watchOS, visionOS, frame (P6)
    Trips auto-detect + routes (P9)  Static export + off-site + C2PA (P8)
    Comments + reactions (P5)        Trim + reels (P7)

Q4  MCP + Ask the library + webhooks (P10)
    Globe + scrubber (P9)            Chaos, fuzz, perf budgets everywhere (P11)
    The 2026 book printed. The year retold on the TV. The scoreboard.
```

### Quarter 1 — Foundations (Nov 2026 – Jan 2027): "nothing visible, everything possible"

| Squad | Delivers | Pilot in the family's hands |
|---|---|---|
| Gate | Lane framework on N Macs, real-device slots, perf baselines, OpenAPI diff check, server CI on a home runner | Faster TestFlight cadence: twice a week |
| Sync | `changes` log, `/api/sync`, idempotent writes, `MemosStore` (GRDB) behind a flag for Library | Library offline on a plane, read-only |
| Archive | Content-addressed originals as a view over the existing layout, BLAKE3 manifest, nightly fixity, Settings → Archive page | "412 311 files, 0 mismatches" visible in Settings |
| Sense | `pgvector`, `understand` lane with image embeddings, hybrid search endpoint, on-device MobileCLIP in the outbox | Free-text search finds "lake" with no tag |
| People & circles | Circles tables mapping the three visibility levels 1:1, circle picker in the app (closes the Set-visibility deferral) | Set visibility from the phone |
| Video | HLS ladder behind a flag, sprite sheets, signed playlist URLs | Scrubbing in the viewer for new uploads |
| Platforms | tvOS skeleton: sign-in, "This day" screensaver, year browse | The TV shows this day |
| Stories | Best-shot scorer, "This day" in Timeline and a widget | A Lock Screen widget of this day across years |
| Capture | Voice memos with on-device transcription; memo kinds in the contract | Hold to record a voice note |
| Places | `places` rows + gazetteer names on day headers | Day headers say where |
| Platform & agents | PAT scopes, audit table, webhooks skeleton | none yet |

**Demo day 1 (end of January):** the Library opens offline on a plane; a search for "snow" finds
snow; the TV shows this day; Settings says every original is intact.

### Quarter 2 — Understanding and sharing (Feb – Apr 2027): "the library knows us"

| Squad | Delivers | Pilot |
|---|---|---|
| Sense | Face clusters on device, People in Library, "Who is this?", OCR, server speech-to-text, Foundation Models query planner | "Lena at the lake last summer" works |
| Sync | Every tab reads `MemosStore`; writes go through the operation queue; resumable uploads (owner decision) | 24 hours of airplane edits, nothing lost |
| People & circles | Guest links with QR, living albums on the SPA guest surface, drops with a holding area | Grandma's window; the party QR |
| Stories | Trip auto-detection, story documents, the story editor sheet, a highlight reel on device | A suggested trip with a route |
| Capture | Quote, Scan, Milestone kinds; the PhotoKit importer with dedupe groups | The camera roll backfilled, no duplicates |
| Video | Lazy ladder policy, Live Photo playback, 4K tiers | Live Photos move |
| Platforms | iPad layout; App Intents + Siri + Spotlight; Live Activity for uploads | "Hey Siri, show me pictures of Lena" |
| Archive | Off-site replication through a maintained tool; monthly restore rehearsal in the gate | Settings shows the last restore |
| Gate | Snapshot tests light/dark on every populated view; scroll-perf tests with baselines | none visible; everything safer |
| Places | Routes from captures; place pages | The lake house page |
| Platform & agents | Webhooks live; local LLM adapter | The frame updates when a picture joins `party` |

**Demo day 2 (end of April):** a grandparent opens a link and sees a living album; a search by
person and place works with no tags; the camera roll is in; a suggested trip shows the drive.

### Quarter 3 — Stories and every screen (May – Jul 2027): "it comes back to you"

| Squad | Delivers | Pilot |
|---|---|---|
| Stories | The year-book draft for 2026, iPad editor, print-service adapter with proofs and order read-back | The proof PDF of the 2026 book |
| Platforms | macOS native, watchOS complication + voice quote, visionOS spatial and panoramas, Home Assistant component + e-ink frame | The wall shows a picture a day |
| Video | Trim as a derived asset; highlight reels server-side for the TV | A ten-second trimmed clip |
| People & circles | Comments and reactions with SSE fan-out; kids' accounts | A heart and a word under a picture |
| Archive | Static export (self-contained folder), C2PA signing at capture, provenance in the info sheet | Open the export on a laptop |
| Places | Globe with trip arcs; device track import at trip creation | Spin the globe |
| Sense | Model-version backfill drill (swap the embedding model, no downtime) | none visible |
| Sync | Reconciliation check in the gate retired once parity holds for a quarter | none visible |
| Gate | Chaos jobs nightly on the dev stack; contract fuzzing | none visible |
| Capture | Sidecar preservation audit: Live, RAW+JPEG, gain maps, spatial; HDR tiers everywhere | A ProRAW shot looks right on the TV |
| Platform & agents | MCP server in the image, read tools, scoped writes | An agent lists a trip |

**Demo day 3 (end of July):** the 2026 year book is ordered from the app; the same trip plays on
iPhone, iPad, Mac, TV and Vision Pro; the hallway frame has shown a new picture every morning for
a month.

### Quarter 4 — Platform, polish and proof (Aug – Oct 2027): "ask the library"

| Squad | Delivers | Pilot |
|---|---|---|
| Platform & agents | "Ask the library" on the phone and the SPA with citations; Shortcuts mirroring the MCP tools; contract deprecation policy | "Where were we on 14 May?" |
| Places | The time scrubber (owner decision) | Drag a year across the map |
| Gate | Perf budgets on every endpoint and every view; eleven concurrent merges proven | The scoreboard |
| Stories | The year retold on the TV by the story engine: chapters, people, places, quotes | The living-room premiere |
| All squads | Flag retirement: every flag either becomes default or is deleted with its code; docs, ADRs, the architecture doctrine ratified | A clean tree |
| Archive | Digital-legacy page and runbook | A sealed envelope |

**Demo day 4 (end of October):** the printed 2026 book is on the table; the 2027 year plays on
the TV; an agent answers from the library; the fixity report says zero; the export opens offline.

---

## 6. Squads and staffing

With unlimited hands the shape still has to be small enough to review. Eleven squads of five to
seven, one per pillar, plus three cross-cutting groups:

| Squad | Owns | Platform surface |
|---|---|---|
| Sense | Pillar 1 | worker `understand` lane, `MemosSense` |
| Stories | Pillar 2 | story documents, renderers, editor, print adapter |
| Capture | Pillar 3 | memo kinds, importer, sidecars |
| Sync | Pillar 4 | change log, `MemosStore`, uploads |
| People & circles | Pillar 5 | circles, guests, drops, reactions, SPA guest mode |
| Platforms | Pillar 6 | tvOS, iPadOS, macOS, watchOS, visionOS, frame, intents |
| Video | Pillar 7 | ladder, scrub, trim, reels |
| Archive | Pillar 8 | content addressing, fixity, off-site, export, C2PA |
| Places | Pillar 9 | places, routes, globe, scrubber |
| Platform & agents | Pillar 10 | MCP, webhooks, LLM adapter, contract policy |
| Gate | Pillar 11 | lanes, device farm, CI, perf, chaos, fuzz |
| Design | every pillar | the visual language across six platforms, the frozen bar's siblings |
| Contract | every pillar | OpenAPI review, the generated client, the SPA parity |
| Release | every pillar | the twice-weekly TestFlight, the server deploys, the flags ledger |

Rules of engagement, carried over from how this repo already works:

- Every squad works in its own worktree and ships through the same gate. No squad gets a private
  bar.
- Every merge has a cross-model review and a mutation proving its test. Rare-case findings become
  follow-up tickets; they never hold a feature's go-live (owner, 2026-10-20).
- Every pillar lands behind a per-household flag and is in the family's hands as a weekly pilot
  before it is complete. The flag ledger is a table in the repo, reviewed monthly; a flag older
  than a quarter is retired or justified.
- The owner reviews pilots, not pull requests. Review material is an artifact (clips, a page), and
  merges never wait on a yes (owner, 2026-10-23).

---

## 7. What we will not do

Saying no is most of the moonshot.

- **No cloud ML in the default path.** No face recognition, embedding or transcription leaves the
  house. A cloud model is a per-household opt-in for the chat planner only, with structured
  inputs.
- **No multi-tenancy.** One household per server, forever. The simplicity is the feature.
- **No social network.** Circles and guest windows are for sharing with people the family knows.
  No public profiles, no discovery, no feed of strangers.
- **No lossy originals, no transcoded originals, no "optimized storage".** Disk is cheap; the
  bytes are sacred.
- **No new tab on iPhone.** The main bar is frozen (ADR-0008). Stories and People live inside the
  tabs that exist.
- **No accessibility programme** (owner, 2026-09-20). The platform defaults are kept and nothing
  is actively broken, but no squad is staffed for it.
- **No hand-written client methods, no second contract.** Everything generates from one
  `openapi.json` synced from one tagged memos-ng commit.
- **No vendor lock on the way out.** Every third party (print, off-site storage, local LLM) sits
  behind an interface with one maintained implementation and a documented replacement path.

---

## 8. Risks and kill criteria

Each pillar has a point at which it is stopped rather than finished. These are written down now
so a stop is a decision, not a failure.

| Pillar | The risk | Kill criterion |
|---|---|---|
| Sense | Face clustering is wrong often enough that the family stops trusting it | Precision below 99.5 % on the family's library after Q2 → People stays "suggested only", search keeps embeddings |
| Stories | The auto-picks feel generic | More than 40 % of spreads changed before ordering → the book becomes a manual editor with picks as hints |
| Capture | The importer drains the battery or duplicates | A second run creates any duplicate → the importer stays manual-per-day |
| Sync | The mirror and the server disagree | Any reconciliation mismatch in the gate after Q2 → the tab goes back to network reads until fixed |
| People & circles | Guest surface leaks household structure | Any leak in the Q2 audit → guest links are paused |
| Platforms | The gate cannot carry six targets | Median gate time doubles → targets are serialized and visionOS/watchOS defer a quarter |
| Video | Disk use from ladders is unbounded | The LRU cannot hold under 20 % of `DATA_ROOT` → ladders cut only for story picks |
| Archive | Restore rehearsal fails | Any failed monthly restore is a P0 on the whole programme |
| Places | Routes are wrong | A family member cannot recognize the drive in 3 of 10 trips → routes become dots again |
| Platform & agents | An agent writes where it should not | Any unscoped write → MCP goes read-only until the scope model is redone |
| Gate | Eleven squads are slower than one | The single-lane time is not held → squads merge in a rota, fewer at once |

Programme-level risks:

- **The one reviewer.** The owner cannot review eleven pilots a week. Pilots are therefore
  batched into one weekly artifact page, and the owner's rule applies: take the recommended
  option, record it, keep delivering; the owner course-corrects later.
- **The one server.** Everything above runs on the same hardware. The Archive squad owns capacity
  planning from week one, and a second home server is in scope for Q2 if the `understand` lane
  and the ladder need it.
- **Scope gravity.** A moonshot invites everything. The eleven pillars are the whole scope; a
  twelfth needs a pillar to die first.

---

## 9. Owner decision points

Four places where the moonshot proposes to change a decision the owner already made. Each is a
proposal; the default is the owner's existing decision until the owner says otherwise.

| Decision | Existing | Moonshot proposes | Why |
|---|---|---|---|
| Resumable uploads | ADR-0007: whole-file retries, no resumption protocol | Native `Content-Range` resumption on the existing `/api/uploads` | The camera-roll importer (P3) and 4K video (P7) make a whole-file retry of a 2 GB file expensive; tus was the wrong shape, not the idea |
| Places timeline | Shelved 2026-09-18 | Re-proposed in Q4 as a time scrubber with routes and a full year of data behind it | The earlier version had no routes and little data; the moonshot's version is a different feature |
| The three visibility levels | PRIVATE / PROTECTED / PUBLIC; Just us only in a trip or album | Circles, with the three levels as default circles and the Just-us placement rule kept | Grandparents and guests need a fourth and fifth audience without a fourth enum value |
| The frozen main bar | ADR-0008, iPhone bar frozen as built | Kept exactly. Stated here only so nobody reads tvOS, iPad or macOS navigation as a bar change | The freeze is the owner's design decision |

Everything else in this document stays inside decisions already made: originals never displayed,
Share at the 2048 tier, iPhone 16 and up, the shared API major, no accessibility programme, go-live
first, TestFlight cuts autonomous on green gates.

---

## 10. The twelve-month scoreboard

The moonshot is done when every line below reads true on the real surface, in the family's
hands, in October 2027.

| # | Probe | Surface |
|---|---|---|
| 1 | 9 of 10 scripted free-text queries find the intended picture in the top five | Library search, real library |
| 2 | A named person's view shows a stranger in fewer than 1 in 200 results | People view |
| 3 | A voice memo recorded offline is searchable by its words before reconnecting | Search, airplane mode |
| 4 | The printed 2026 year book is on the table, ordered from the app | The table |
| 5 | A 30 000-item camera roll imports in the background with zero duplicates on a second run | Library, `near_duplicates` |
| 6 | 24 hours of airplane edits reconcile with 0 lost, 0 duplicated | `changes` log diff |
| 7 | A guest link shows a living album and goes dark within 10 s of revocation | A device that has never seen memos-ng |
| 8 | One trip, five platforms, same pictures, same order, same captions | iPhone, iPad, Mac, TV, Vision Pro |
| 9 | The wall frame shows a new picture every morning for 30 days | The hallway |
| 10 | A 4K clip scrubs within two minutes of upload; original checksum unchanged | Viewer, fixity manifest |
| 11 | Pull a drive, restore off-site, 0 mismatches; the static export browses offline | Settings → Archive, a laptop |
| 12 | A family member recognizes the drive in a detected trip's route | Places |
| 13 | A read-only agent answers "where were we on 14 May 2026?" and its write is refused and logged | MCP, `audit` |
| 14 | Eleven concurrent merges, every one with `mac-gate SUMMARY … exit=0`, median time held | The gate |
| 15 | Every flag retired or justified; the architecture doctrine ratified; the tree clean | The repos |

---

## Appendix A — Technology bets

Every bet names a maintained thing rather than a hand-rolled one (owner, 2026-10-07), and the
reason it is the right shape for one household.

| Area | Bet | Why this one |
|---|---|---|
| Vector search | `pgvector` with HNSW, in the existing Postgres | One database, one backup, one migration tool; family-scale never needs a separate vector store |
| Image/text embeddings | MobileCLIP (Apple, open) on device via Core ML; SigLIP or the same MobileCLIP in ONNX on the worker | The same embedding space on both ends so a phone-computed vector is a server vector |
| Faces | Vision feature prints on device; clustering on device; server stores embeddings only for cross-device consistency | Faces never need to be computed off the phone that took the picture |
| Speech | SpeechAnalyzer (iOS 26) on device; whisper.cpp-class on the worker for web uploads | Both run offline |
| Query planning | Apple Foundation Models (iOS 26) on device; a local model behind one adapter on the server | A cloud model only as opt-in, only for planning, never with content |
| Local store | SQLite via GRDB | Mature, Swift-native, migrations, FTS5 if ever needed; no SwiftData lock-in to a schema we cannot read |
| Sync | Server change log + per-field last-writer-wins + idempotent operation ids | Enough for a household; a CRDT library is a decision deferred until shared text editing exists |
| Video | ffmpeg CMAF/HLS ladder in the existing slow lane; AVPlayer | The lane, the thermal guard and the poster path already exist |
| Content addressing | BLAKE3 | Fast enough to scrub a terabyte nightly on home hardware |
| Off-site | restic or kopia | Maintained, encrypted, deduplicated, restore-tested by thousands of people |
| Provenance | C2PA via `c2pa-rs` | The open standard the camera vendors are converging on |
| Derived formats | AVIF now where every target decodes it; JPEG XL by table when it does | Tiers only; originals are never transcoded |
| Agents | MCP (one server process in the image) | The protocol the family's own agents already speak |
| Automation | Home Assistant custom component | The house already runs it |
| Platforms | SwiftUI on every Apple platform; shared Core, per-platform views where needed | One contract, one client, one store |
| CI | The existing gate scripts as jobs on a home runner | The gate is already the truth; CI just runs it unattended |

## Appendix B — Data model sketch (additive, all expand/contract)

```
asset_embeddings(asset_uid, model_id, kind[image|text], vector, created_at)        -- P1
people(uid, household_id, name, cover_asset_uid, created_at)                        -- P1
person_faces(person_uid?, asset_uid, bbox, embedding, model_id, confirmed_by?)      -- P1
asset_text(asset_uid, kind[ocr|transcript|caption], text, tsv, model_id)            -- P1
stories(uid, kind[this_day|trip|year|custom], document jsonb, state, created_at)    -- P2
story_renders(story_uid, target[html|pdf|tv], path, rendered_at)                    -- P2
print_orders(uid, story_uid, vendor_ref, state, proof_path, read_back_at)           -- P2
memos.kind[note|voice|quote|milestone|scan]                                         -- P3
near_duplicates(group_uid, asset_uid, phash, dhash)                                 -- P3
milestones(uid, person_uid, kind, date, memo_uid)                                   -- P3
changes(seq bigserial, entity, uid, field, value, op_id, actor, at)                 -- P4
uploads.offset, uploads.chunk_state                                                 -- P4 (owner)
circles(uid, name, kind[default|custom]); circle_members(circle_uid, user_id?, guest_token_uid?)  -- P5
audience(entity, uid, circle_uid)                                                   -- P5
guest_tokens(uid, circle_uid, expires_at, revoked_at, label)                        -- P5
drops(uid, guest_token_uid, asset_uid, state[held|accepted|rejected])               -- P5
reactions(memo_uid, user_id, emoji, at); comments(uid, memo_uid, user_id, text, at) -- P5
frame_devices(uid, circle_uid, size, last_served_at)                                -- P6
renditions.kind += hls_playlist|hls_segment|sprite|vtt                              -- P7
assets.derived_from, assets.derivation jsonb                                        -- P7
assets.blake3, fixity_runs(uid, started, finished, files, mismatches)               -- P8
provenance(asset_uid, c2pa_manifest, verified_at)                                   -- P8
places(uid, name, lat, lon, radius_m, source[gazetteer|user])                       -- P9
place_visits(place_uid, collection_uid?, date_from, date_to)                        -- P9
trip_routes(collection_uid, polyline, source[captures|device_track])                -- P9
pat_scopes(pat_uid, scope); audit(uid, actor, tool, args_hash, result, at)          -- P10
subscriptions(uid, event, url, secret, state); deliveries(sub_uid, event_id, state) -- P10
```

Every table is additive. Nothing existing is dropped during the moonshot year; contraction is a
separate, owner-gated phase after the scoreboard reads true.

## Appendix C — Contract growth (additive paths)

```
GET  /api/search?q=&mode=hybrid&person=&place=&scene=       P1
GET  /api/people  POST /api/people  PATCH /api/people/{uid}  P1
POST /api/people/{uid}/faces/confirm                         P1
GET  /api/stories  POST /api/stories  PATCH /api/stories/{uid}  P2
POST /api/stories/{uid}/render  POST /api/stories/{uid}/order   P2
GET  /api/stories/this-day                                   P2
POST /api/memos (kind)  GET /api/duplicates?phash=           P3
GET  /api/sync?since=  POST /api/sync                         P4
PATCH /api/uploads/{uid} (Content-Range)  HEAD /api/uploads/{uid}   P4 (owner)
GET/POST /api/circles  POST /api/circles/{uid}/guests        P5
POST /api/drops/{token}  GET /api/drops  POST /api/drops/{uid}/accept  P5
POST /api/memos/{uid}/reactions  /comments                   P5
GET  /api/frame?token=&w=&h=                                 P6
GET  /file/hls/{uid}/index.m3u8  POST /api/assets/{uid}/trim  P7
GET  /api/archive/fixity  POST /api/archive/export  GET /api/assets/{uid}/provenance  P8
GET  /api/places  GET /api/places/{uid}/visits  GET /api/collections/{uid}/route  P9
GET  /api/map/markers?from=&to=                              P9
MCP tools: search, memo.read, collection.list, story.draft (read)  P10
POST /api/subscriptions                                      P10
```

All inside the shared API major; the OpenAPI diff check in the gate refuses a breaking change.

---

*Written 2026-10-27 against memos-ng main and memos-ng-ios main 86e729f9. A proposal; the owner
decides what of it becomes a plan.*

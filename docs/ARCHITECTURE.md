# Reference iOS Architecture — doctrine v0 (proposed)

**Nothing here is ratified.** This is the v0 draft of the reference iOS architecture, mirrored
into the repository from the wiki page it was drafted on. It becomes v1 (accepted) only after the
app has actually shipped, revised from what shipped, and reviewed independently — every deviation
of the built app from this draft is listed then, with its reason. The deviations already known are
listed at the end of this file.

The reference is a **repo**, not a page: `CLAUDE.md` + this file carry the doctrine, and the wiki
mirrors it.

Platform facts below were researched on 2026-08-23.

## Stack

| Area | Choice | Why |
|------|--------|-----|
| Language mode | **Swift 6, strict concurrency ON**, declared explicitly in every target and package; Approachable Concurrency + MainActor default isolation on the app and Features layers | New Xcode app projects still default to the Swift 5 language mode. A reference opts in explicitly, on day one |
| Minimum OS | **iOS 26.0**, iPhone only | iOS 26 is on ~79 % of all iPhones / 86 % of the last four years of devices (Apple, 2026-06-07), and iOS 27 ships before this app does |
| Toolchain | **Xcode 26.6, pinned** | The shipping line is Swift 6.3. Xcode 27 forces Liquid Glass and ignores the compatibility key; the toolchain bump is its own change, not a side effect of one |
| Packages | Local SwiftPM packages under `Packages/`: `MemosAPI`, `MemosCore`, `MemosFeatures`; the app target only composes | Local feature packages are the uncontested part of current mainstream practice |
| Dependency injection | **SwiftUI environment** (`.environment`) | Apple's own guidance: `@Observable` models owned by `@State`, injected through the environment. No container, no singletons |
| State | One **`@Observable` store per feature** — `SessionStore`, `TimelineStore` | Community mainstream in 2026. No Combine |
| Networking | **swift-openapi-generator** over a vendored `openapi.json`; auth as a `BearerAuthMiddleware`; `ServerConfiguration` holds the base URL; `APIClientFactory` builds the client | The generator does not generate security schemes, so authentication is a middleware — one place that decides what credential a request carries. The generated `APIProtocol` is the seam tests substitute |
| Persistence | **No offline editing.** A durable capture outbox (MEMNG-100), and a timeline READ cache: one versioned `Codable` snapshot per (server base URL, user id) under `Library/Caches/<bundle id>/timeline/`, rewritten on every server-confirmed change of the plain timeline — the newest 200 rows of it — and deleted wherever the credential is | ADR-0002. A pure read cache is a snapshot the next successful load replaces whole — it is never authoritative and never a source of pagination cursors, so it needs neither a query engine nor a migration story. The rule that comes with it: the store graduates to GRDB the day offline EDITING enters scope |
| Auth | **PAT in the Keychain** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) in an access group the APP alone declares, `$(AppIdentifierPrefix)live.discomarder.memosng.credentials` | An app group identifier is itself a keychain access group, so a token in the shared group is a token the share extension can read. The app group carries the queue and the identity JSON; the token has a namespace of its own |
| Testing | **Swift Testing**; XCTest only for UI and performance tests | Default for new test targets since Xcode 16 |
| Formatting | **`swift format`** from the toolchain; the gate runs `swift format lint --strict --recursive .` | No SwiftLint |
| Rendering | **MarkdownUI** (GFM, task lists) — the only third-party dependency | Verified against this toolchain before adoption; see "Markdown parity" |
| Maps | **MapKit**, and only inside `MemosFeatures` — an `MKMapView` behind a representable, with MapKit's own clustering | The map is a screen, not a domain rule. `MemosCore`'s Places functions decide in plain degrees and import no MapKit, so what a tap opens is testable without one. What the basemap costs, and why no tile pipeline of this app's own ships: see "The basemap" |
| Gate | **`bin/mac-gate.sh`** | A Swift phase cannot be built on the Linux dev machine, so the Mac build host is the only build authority. See `CLAUDE.md` |

## Module boundaries

```
App target (composition only)
   └── MemosFeatures  →  MemosCore  →  MemosAPI
```

- **`MemosAPI`** — the generated client, `BearerAuthMiddleware`, `ServerConfiguration`,
  `APIClientFactory`, the typed `APIError`. Knows the wire format and nothing about the domain.
- **`MemosCore`** — domain models mapped from the generated types, the `@Observable` stores, the
  Keychain wrapper, the media-cache rules, and the Markdown layer ported from the SPA.
- **`MemosFeatures`** — screens: `TimelineView`, `MemoDetailView`, `SignInView`.

**Nothing imports Features.** Enforced by the manifests, checked mechanically by the gate.

**Places is the worked example of where that line falls.** Everything a tap decides is a pure
function of a value, so a test can hold what the screen presents without running a map:
`Packages/MemosCore/Sources/MemosCore/Places/` carries the domain model and its wire conversion
(`PlaceMarker.swift`, `PlaceMarker+Wire.swift`), the geometry — coordinate keys, grouping,
bounding box, the visible box and the antimeridian cases it brings (`PlaceGeo.swift`), the pin
specification and the add/repaint/drop diff a map is driven by (`PlaceClustering.swift`), the
displayed order and the slide a tapped photograph opens (`PlaceOrder.swift`), which of the four
states a read is in (`PlacesStatus.swift`), and the adapter that turns a marker into the
attachment the existing viewer already opens on (`PlaceAttachment.swift`). None of those files
imports MapKit; `PlaceGeo` states its sides as plain doubles for exactly that reason.
`Stores/PlacesStore.swift` is the one read: `GET /api/map/markers` takes no parameters, so it asks
one question, refuses a second ask while the first is out, and judges the answer against the
session handle that ISSUED the request.

`Packages/MemosFeatures/Sources/MemosFeatures/` holds the drawing: `PlacesView.swift` (the screen,
keyed on the signed-in subject), `PlacesMapView.swift` (the `UIViewRepresentable` around
`MKMapView`, its delegate, and the annotation objects the map keeps), `PlacePinView.swift` (the
`MKAnnotationView` a pin and a cluster share, UIKit all the way down) and
`PlacesPresentation.swift`, the seam between the two layers. The last three are also the only
production sources in the tree that import MapKit; the screen itself needs none of it.
`PlacesPresentation.swift` is where the seam's decisions are DEFINED and nowhere else — the
region-to-box conversion, which member lends a cluster its photograph, what a tap opens and how
close the camera may come — and the map view reaches for them by name rather than redefining any
of them. What the map view does decide is its own lifecycle: when a replaced map has to start its
annotations over, and that the first fit happens once. MapKit does not leave this package, but it
does not stop at its sources either: the Places tests import it too, because holding the seam to
a real `MKMapView` is the point of them.

## Concurrency

Swift 6 mode everywhere; `MemosAPI` and `MemosCore` build with `-warnings-as-errors`. `Sendable`
is keyed on crossing an ISOLATION boundary, not a package one — a type confined to the main actor
may be used from another package without it, and a type handed to a `nonisolated` layer or a task
needs it even inside one package. MainActor default isolation on the app and Features; the API
layer is `nonisolated`, because the transport calls its middleware off the main actor. Off-main
work is structured concurrency. No Combine.

## Sign-in

SSO runs in the ordinary web login, presented by the app itself in an `SFSafariViewController`
(`LoginBrowser`, driven by the `NativeLoginFlow` state machine and `SafariLoginPresenter`).
`ASWebAuthenticationSession` is BANNED: on a device it reported a missing domain association as
plain user-cancellation (`Code=1`), indistinguishable from someone closing the sheet.

The finished login comes back on the custom scheme `memosng://auth-callback`, and on this
internal-only-DNS estate that is the PERMANENT PRIMARY lane, not a fallback — Apple's CDN can
never fetch the AASA, so a universal link here is never associated and never opens the app. The
HTTPS lane (`NativeLoginReturn`) stays in the code as a self-activating enhancement: it would
start working the day a public split-horizon AASA stub is served, with nothing to change here.

A callback is never taken from `initialLoadDidRedirectTo:` — iOS strips the query from that URL,
so the code is not on it. That delegate is log-only.

## Errors and auth failures

- The API layer surfaces a typed **`APIError`** — never an untyped `Error` at a package boundary.
- **`401` → signed out.** There is no refresh lifecycle to fall back on: the token IS the
  credential. There is no silent retry, because retrying a revoked token only produces a spinner.
- Sign-out revokes the presenting token (`POST /api/auth/native/logout`) and wipes the stored
  credential only once the server has said it is dead — a 204, or a 401 meaning it already was.
  **A failed revoke KEEPS the credential** and reports `revokeFailed`: a device that believes it
  is signed out while a live token sits in whatever took it is the worse of the two states.
  Discarding it anyway is a deliberate choice made on the screen (`signOutWithoutRevoking`).
  A 401 to the revoke means "already dead" only when it names the credential this device is STILL
  holding. A renewal landing while the revoke is on the wire makes the server refuse it because the
  token it named is gone — and the successor is live, was never revoked, and is valid for up to a
  year in whatever holds it. That case reports `revokeFailed(.unauthorized)` and KEEPS the
  credential; the screen offers the sign-out again, which then revokes the token this device is
  actually holding. Same rule as the line above, applied to the one refusal that looks like
  permission to wipe (MEMNG-270).
- A stored credential is **re-validated at launch**, not trusted, and removed when the server
  rejects it.

## Media cache

Derived media is served through HMAC-signed URLs with an expiry. A cached response therefore may
not outlive the signature that authorised it: `SignedMediaURL` parses `exp` out of the URL, bounds
the cache lifetime by whichever of `exp` and the server's `max-age` is shorter, and bypasses the
cache entirely once the signature has expired. Asserted in a Core test, not assumed.

## The basemap

The map under the Places pins is Apple's, drawn by MapKit. The consequence is stated rather than
implied: the viewport's tile requests go to Apple, and what a reader pans over is known to Apple as
a viewport. Nothing else about the household's photographs is: the marker coordinates, the
thumbnails on the pins and the memo content behind them are fetched only from the household's own
server, over the same signed-URL media path everything else uses. The app fetches, caches and
serves no map tiles of its own, and the self-hosted basemap the web client draws is deliberately
not consumed here — a second tile pipeline on a phone buys a privacy property this app already has
for the photographs and pays for it in cache, battery and a renderer nobody maintains.

## Markdown parity

**The SPA renderer is the contract**, not a Swift re-interpretation of GFM: raw HTML renders as
literal text, a single newline is a line break, bare URLs and e-mail addresses become links, GFM
task lists / tables / strikethrough are supported, a link is tappable only when its scheme is
`http`, `https` or `mailto`, images are dropped whole (alt text included), and tag-only lines are
stripped before rendering.

It is enforced by a committed projection fixture asserted on both sides. memos-ng renders a corpus
through the real SPA renderer and commits the block projection defined in
`docs/markdown-parity.schema.md`; this repo vendors that file next to `openapi.json` from the same
commit, and a Swift Testing suite renders each case's carried input **through the renderer the app
ships** — `MemoMarkdownSource.prepare` into `MarkdownContent`, the parse `Markdown(_:)` performs —
and asserts the same projection. A renderer that flattens a list, loses a task's state or keeps a
`javascript:` link tappable cannot pass, and neither can a MarkdownUI release that changes what it
parses.

A link is held to the scheme rule in every spelling CommonMark gives it. markdown-it validates a
link reference definition where it is defined and refuses to register an unsafe one; cmark-gfm
does not, so `prepare` neutralises the definition instead, which leaves the same thing on screen
as the SPA shows and leaves every reference that named the label as text.

The block parse is load-bearing, not test-only scaffolding: it decides which source lines are
checkboxes (`taskCheckboxLines`, `toggleTask`), what the detail screen lists as tasks, and which
links `MemoMarkdownSource.prepare` neutralises before MarkdownUI ever sees them.

## Outgoing text

App Store text, review notes, release notes and any public README are first-person singular, carry
no AI attribution, leak nothing internal, and make only claims that are literally true.

## Starting a new iOS project from this reference

1. Clone; rename the bundle id and the scheme.
2. Point `scripts/sync-openapi.sh` at the new backend and re-run it; re-record the source commit.
3. Delete `MemosFeatures` — the screens are the app-specific part.
4. Keep the `MemosCore` / `MemosAPI` shape: bearer middleware, `ServerConfiguration`,
   `APIClientFactory`, the Keychain wrapper, the `@Observable` store pattern, the typed `APIError`
   and the 401-signs-out rule.
5. Keep the tooling: `bin/mac-gate.sh`, `.swift-format`, and the `CLAUDE.md` rules.

## Not in this reference

TCA (capable, but a household reference should be the mainstream answer a future contributor
recognises without a framework tutorial); Combine; singletons for dependency injection;
storyboards or a UIKit-first UI; SwiftLint. Also out of scope for v1: push notifications, offline
editing, widgets, App Intents, watchOS, macOS and iPad layout.

Custom URL-scheme auth callbacks were on that list and are not any more. On an internal-only-DNS
estate the custom scheme is the sign-in lane, permanently — see **Sign-in** above.

The Places **playback timeline** is not shipped, and the list above would not say so on its own,
because the code for it is in the tree:
`Packages/MemosCore/Sources/MemosCore/Places/PlaceTimeline.swift` holds the month histogram, the
playhead reducer and the playhead's effect on the marker set, with
`PlaceTimelineTests` asserting all of it. Nothing draws it — no other Swift file names
`PlaceTimeline`, `PlaceHistogram`, `PlaceBucket`, `PlaybackSpeed` or `TimelineMode` — so the
shipped map is a map without a scrubber. Tested pure rules waiting for a screen, not a feature
somebody removed the last call to.

## Known deviations of the built skeleton from this draft

Recorded here rather than quietly absorbed, for the review that turns v0 into v1.

1. **Keychain access group.** The draft named an app-group access group, and for one release that
   is what shipped — which was wrong twice over. An app group identifier IS a keychain access
   group on iOS, so the share extension could read the token it needed no part of; and a query
   that names no group at all matches every group the app can see, which is how a delete meant for
   the old namespace took the only credential with it. The token now lives in
   `$(AppIdentifierPrefix)live.discomarder.memosng.credentials`, declared by the app target alone,
   with the app group and the pre-entitlement `<team>.<bundle>` group emptied into it on read.
   Every query names its group. What the simulator cannot prove — that the extension is actually
   refused — is a device ceremony; the gate checks the generated entitlement files instead.

   **The app group remains a namespace the extension can name.** It is the legacy migration
   SOURCE, and the share extension holds the app-group entitlement because it needs that
   container for the outbox files and the identity JSON — on iOS that entitlement carries
   keychain access with it. No entitlement change can take that away while the extension needs
   the container. What protects the token is not reachability but two other things: no current
   build WRITES there, and a device that still has a token there has it moved out lazily
   (`CredentialVault` migrates on read, `restore()` before anything else touches the credential).

   Two things have to go right for the legacy copy to be gone, and the second is not guaranteed
   by the first. The move must be PROVEN — an `add` the home namespace accepted and a read-back
   that returned the value. Until it is, nothing is deleted at all, deliberately, because deleting
   on an unproven move can destroy the only copy on the device: an `add` the home namespace
   refuses, a read-back that throws, and a read-back that answers nil each leave the token exactly
   where it is and answer with it. Then the delete must actually succeed. It is ATTEMPTED on every
   read that resolves the home value, not once — `tidy` is the last thing such a read does — and a
   delete the keychain refuses is logged and attempted again on the next such read. So the copy
   disappears when a `remove` succeeds: normally at the first successful migration, later on a
   device whose keychain keeps refusing, and never on one that stops reading first. This is not a
   bounded window; it is a residual that ends when a delete lands and not before.

   One interval is uncoverable from this side entirely: between the extension being upgraded and
   the host app's first launch, only the app can move the token and the app has not run. A
   host-side sweep cannot cover a period in which the host does not execute. Closing all of it
   would mean a NEW app group for the extension and leaving the old one app-only — a bigger
   change than this round, and one that trades this residual for a second migration of the queue
   and identity files. Accepted, recorded, not forgotten.
2. **`MemosCore` and `MemosAPI` declare macOS as well as iOS.** Not because the app runs there,
   but because SwiftPM is the only way to build those two targets with `-warnings-as-errors`, and
   SwiftPM builds for the host. The Features layer stays iOS-only.
3. **`MemosCore` links `OpenAPIRuntime` directly.** The generated request types ARE OpenAPIRuntime
   types, and the default arguments Core inlines when it builds one are defined in that module.
   The layering rule is unchanged; this is a link-time fact, not a new direction of dependency.
4. **The vendored `openapi.json` is copied verbatim, and what the generator cannot express is
   excluded rather than rewritten.** The sync writes the file byte for byte as memos-ng emits it,
   so its provenance is one `git show` away; nothing here transforms the contract. memos-ng has
   written nullable scalars as OAS 3.1 type arrays since 433a3fe, which the generator handles, so
   the normalisation step that used to run here is gone. What it never covered is a nullable
   `$ref` — `anyOf: [{$ref: X}, {"type": "null"}]` — which this generator version skips with a
   warning that fails nothing, leaving a property silently absent. Where that idiom appears on a
   surface the app does not read, the operations that reach it are left out of
   `openapi-generator-config.yaml`'s inclusion filter, so no half-generated type exists to be
   trusted; `scripts/openapi-coverage-rule.sh` holds that list to the document so nothing else
   drops out with it. The real fix belongs in memos-ng's schema output, and a local transform is
   not a substitute for it.
5. **The test bundles are Xcode targets, not SwiftPM test targets.** An XcodeGen scheme's test
   action cannot reference a package's test targets. The bundle names and the requirement that
   `xcodebuild test` runs all three are unchanged.
6. **Parity is asserted against the shipped renderer's own parse, plus rendered measurements.**
   `MarkdownContent(_:).renderHTML()` is projected, because it comes from the same block model
   `Markdown(_:)` renders; the theme is held by measuring rendered views (body size, soft breaks)
   and by reading pixels back (a link is painted in the accent). Two things that parse cannot
   answer are asserted elsewhere and named where they are: cmark's HTML renderer applies its own
   safe mode, which blanks an unsafe `href` and omits raw HTML where the view keeps both — so the
   raw-HTML case is held against the block model in MemosCoreTests, and link liveness is read out
   of the rendered pixels.

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
| Persistence | **No offline writes.** No read cache in v1 | Offline editing and sync are out of scope; a cache is a later decision, not a foundation one |
| Auth | **PAT in the Keychain** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, default keychain), pasted in v1 | The access group and the browser-brokered login arrive with the entitlements that make them possible |
| Testing | **Swift Testing**; XCTest only for UI and performance tests | Default for new test targets since Xcode 16 |
| Formatting | **`swift format`** from the toolchain; the gate runs `swift format lint --strict --recursive .` | No SwiftLint |
| Rendering | **MarkdownUI** (GFM, task lists) — the only third-party dependency | Verified against this toolchain before adoption; see "Markdown parity" |
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

## Concurrency

Swift 6 mode everywhere; `MemosAPI` and `MemosCore` build with `-warnings-as-errors`. Every type
crossing a package boundary is `Sendable`. MainActor default isolation on the app and Features;
the API layer is `nonisolated`, because the transport calls its middleware off the main actor.
Off-main work is structured concurrency. No Combine.

## Errors and auth failures

- The API layer surfaces a typed **`APIError`** — never an untyped `Error` at a package boundary.
- **`401` → signed out.** There is no refresh lifecycle to fall back on: the token IS the
  credential. There is no silent retry, because retrying a revoked token only produces a spinner.
- Sign-out revokes the presenting token (`POST /api/auth/native/logout`) and **wipes the stored
  credential even if that call failed** — a device that believes it is signed out while still
  holding a live token is the worse of the two states.
- A stored credential is **re-validated at launch**, not trusted, and removed when the server
  rejects it.

## Media cache

Derived media is served through HMAC-signed URLs with an expiry. A cached response therefore may
not outlive the signature that authorised it: `SignedMediaURL` parses `exp` out of the URL, bounds
the cache lifetime by whichever of `exp` and the server's `max-age` is shorter, and bypasses the
cache entirely once the signature has expired. Asserted in a Core test, not assumed.

## Markdown parity

**The SPA renderer is the contract**, not a Swift re-interpretation of GFM: raw HTML renders as
literal text, a single newline is a line break, bare URLs and e-mail addresses become links, GFM
task lists / tables / strikethrough are supported, a link is tappable only when its scheme is
`http`, `https` or `mailto`, images are dropped whole (alt text included), and tag-only lines are
stripped before rendering.

It is enforced by a committed projection fixture asserted on both sides. memos-ng renders a corpus
through the real SPA renderer and commits the block projection defined in
`docs/markdown-parity.schema.md`; this repo vendors that file next to `openapi.json` from the same
commit, and a Swift Testing suite renders each case's carried input and asserts the same
projection. A renderer that flattens a list, loses a task's state or keeps a `javascript:` link
tappable cannot pass.

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
storyboards or a UIKit-first UI; custom URL-scheme auth callbacks; SwiftLint. Also out of scope for
v1: push notifications, offline editing, widgets, App Intents, watchOS, macOS and iPad layout.

## Known deviations of the built skeleton from this draft

Recorded here rather than quietly absorbed, for the review that turns v0 into v1.

1. **Keychain access group.** The draft named an app-group access group. The skeleton uses the
   DEFAULT keychain with the access-group parameter present but unset: setting
   `kSecAttrAccessGroup` without the App Groups and Keychain Sharing entitlements fails every call
   with `errSecMissingEntitlement`, and those entitlements arrive with the Apple Developer Program
   in a later phase.
2. **`MemosCore` and `MemosAPI` declare macOS as well as iOS.** Not because the app runs there,
   but because SwiftPM is the only way to build those two targets with `-warnings-as-errors`, and
   SwiftPM builds for the host. The Features layer stays iOS-only.
3. **`MemosCore` links `OpenAPIRuntime` directly.** The generated request types ARE OpenAPIRuntime
   types, and the default arguments Core inlines when it builds one are defined in that module.
   The layering rule is unchanged; this is a link-time fact, not a new direction of dependency.
4. **The vendored `openapi.json` is normalised during the sync.** FastAPI's
   `anyOf: [X, {"type": "null"}]` is rewritten to an OAS 3.1 type array, because the generator
   otherwise drops every nullable property without failing. The rewrite is lossless and its
   counts are recorded in `OPENAPI_SOURCE`; the real fix belongs in memos-ng's schema output.
5. **The test bundles are Xcode targets, not SwiftPM test targets.** An XcodeGen scheme's test
   action cannot reference a package's test targets. The bundle names and the requirement that
   `xcodebuild test` runs all three are unchanged.
6. **Parity is asserted at the block-model layer, not by inspecting MarkdownUI's output.**
   MarkdownUI renders a view, which cannot be projected. The model the suite pins is the same one
   the app uses to decide task rows and link safety, and MarkdownUI renders the source that model
   prepared — but a divergence inside MarkdownUI's own inline rendering would not be caught here.

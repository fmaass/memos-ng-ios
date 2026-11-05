# Full-gate step chain

Moved verbatim from CLAUDE.md § The gate is the only build authority on 2026-10-16.
Two references in the moved text say "below" and point at text that no longer follows them:
the dependency-pin check is CLAUDE.md § Dependency pins, and the host slot is
`docs/gate/run-admission.md`.

It refuses (exit 2) if the tree has no HEAD or if its remote target resolves outside
`~/build/memos-ng-ios/gate/`, mirrors the worktree with `rsync --delete`, and runs, fail-fast:
`bin/generate.sh` (which also asserts the version keys in the generated project) → the
entitlement greps (the app declares EXACTLY ONE keychain access group, the credentials one,
read by index because the first entry is the default an unqualified add lands in; the app group
is deliberately absent from `keychain-access-groups` — a raw `group.…` entry can never match the
profile's `TEAMID.*` pattern and breaks device signing, and the app's keychain access to it rides
on the application-groups entitlement instead; the share extension declares no keychain group;
both declare the app group as a positive control; and `scripts/applinks-rule.sh`, which reads both
files as text, XML comments removed first, and requires the app's applinks set to be exactly
`applinks:trip.discomarder.live` and its `?mode=developer` twin, both as direct entries of the
associated-domains array (a nested array is not the list) and no other applinks host at any depth
(MEMNG-1177, MEMNG-1178), and the share extension to claim no applinks host at all, with the
app group in both files and the associated-domains key in the app's as its positive control,
MEMNG-1084) → `swift format lint --strict --recursive .` → the dependency-pin
check (below) → `xcodebuild build-for-testing` on the generic simulator destination, outside the
host slot (`bin/mac-gate.sh:1752`) → `xcodebuild test-without-building` of all five test bundles on
this run's private device, inside the host slot (`:1765`, `:1776`; the slot is below) → a read-back
of the BUILT app and .appex, its build settings queried on the same generic destination (each one's `PrivacyInfo.xcprivacy`, held per bundle to exactly its declared required-reason
codes by `scripts/privacy-manifest-verdict.py`, its version keys and its export-compliance answer) →
a rebuild of every package with its warnings fatal, each against the tracked `Package.resolved`
copied beside its manifest and refused any version that file does not name, so a fresh upstream
tag cannot reach this step alone (`swift build -warnings-as-errors` for the four that declare
macOS; MemosFeatures through `xcodebuild` for the simulator, where the fatality comes from its own
manifest) → the dependency-rule greps → the incarnation-order rule
(`scripts/incarnation-order-rule.sh`: in `SessionStore.swift` each of `park`, `establish`,
`failSignIn`, `persist`, `putBack` and `wipeCredential` calls `endIncarnation(` before its first
write of `client` or `credential` — a sender off the main actor checks the incarnation, never the
handle — with every pinned site found once and the functions writing the handle being exactly that
set as the control) → the share-link rule
(`scripts/sharelink-rule.sh`: the literal `ShareLink` appears in no file under
`Packages/MemosFeatures`, with `import SwiftUI` under its sources as the control) → the
text-selection rule (`scripts/textselection-rule.sh`: the literal `textSelection` appears in no
file matching `Packages/MemosFeatures/Sources/MemosFeatures/Settings/ManageTokens*.swift`, so the
Copy button — which hands over a pasteboard item that expires — is the one way a minted token's
plaintext leaves the screen, with the exact path `…/Settings/ManageTokensScreen.swift` naming
`copySecret` as the control; memo text keeps its selection, it is not a credential) → the
token-screen button rule (`scripts/managetokens-buttonstyle-rule.sh`: the word-bounded literal
`Button` appears nowhere in `…/Settings/ManageTokensScreen.swift`, because a card there is one
List row and a default-styled control in it is pressed by a tap anywhere in that row, with
`CardButton(` at least six times outside any comment in the same file as the control and one uncommented
`.buttonStyle(.borderless)` line in `Design/CardButton.swift` as a hint that is not a fence) → the
picture-list forwarding rule (`scripts/picturelist-forwarding-rule.sh`: in each of `TimelineView.swift`
and `MemoDetailView.swift` the literal `listing: submission.pictures` appears on exactly one
uncommented line — neither save call site can be reached from a test, both being private functions
behind a sheet that never presents — with the `attaching:` forwarding beside it as the control) → the
no-foreground-edit-upload rule (`scripts/no-foreground-edit-upload-rule.sh`, MEMNG-954: files added to
an existing memo go through the outbox edit job, so the deleted foreground uploader's two names appear
in no Swift file under `Packages/` or `Sources/`, comments included, with `func enqueueEdit(` in
`Outbox.swift`, the `memoEdit` field on `UploadJob` and `enqueueEdit(` in `TimelineStore.swift` as the
controls; its selftest is `tests/gate/no-foreground-edit-upload-rule-test.sh`) → the
main-bar freeze rule (`scripts/mainbar-freeze-rule.sh`, the executable half of ADR-0008: outside
comments `LeadingMainBar(` is constructed on exactly one line of the Features sources and that line
is in `Dock.swift`, no line ends in the bare name (a construction split across lines), `Dock.swift`
hides the system tab bar and pins its minimise behaviour to `.never`, every line naming `.tabBar`
also says `.hidden` (so a modifier split across lines cannot show it), `tabViewBottomAccessory`, `role: .search` and `BarStyle` appear nowhere and
`placement: .bottomBar` not in `MediaLibraryView.swift`, `LeadingMainBar.swift` keeps the whole
declaration lines of `leadingInset` 21, `height` 62 and the `pillTravel` spring (response 0.35,
damping ratio 0.7), and the one-bar, edge-fade, leading 6 and 7, bubble 1–3 and fold-film render
tests and DockModeTests' fold table keep their exact `@Test("…")` lines — so a rename, a deletion
or a trait such as `.disabled` fails it — while neither test file carries a `.disabled` or
`.enabled(if:` trait anywhere and the `@Suite` line the render tests' extension belongs to, in
`MediaImageLoaderTests.swift`, is pinned whole, with the type declared once in `LeadingMainBar.swift`, at
least two `safeAreaBar(edge: .bottom)` lines and each test file's `@Test(` count as the controls;
its own test, `tests/gate/mainbar-freeze-rule-test.sh`, is a selftest every run names) → the
generated-surface rule (`scripts/openapi-coverage-rule.sh`: every operationId in the vendored
document is either named in the generator config's inclusion list or is one of the named
exclusions, with the operation count it read as the control) → the release-notes rule
(`scripts/release-notes-rule.sh`, step `notes`: the first `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` key lines of `project.yml` head exactly one `## <version> (<build>)`
section, outside code fences, of `Packages/MemosFeatures/Sources/MemosFeatures/Resources/ReleaseNotes.md`
— the one file the TestFlight cut sends and the What's new screen shows — with the count of
sections read as the control; its selftest `tests/gate/release-notes-rule-test.sh` is one every run
names) → the

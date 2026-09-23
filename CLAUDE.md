# memos-ng-ios

Native SwiftUI client for memos-ng, and the reference iOS project new iOS apps are cloned from.
The architecture and its reasoning live in `docs/ARCHITECTURE.md` (doctrine v0, proposed). The
rules below are the executable part — the ones a change can break.

## The gate is the only build authority

Swift cannot be built on the Linux machine this repo is developed on. Every build, test, lint and
dependency check runs on the Mac build host through one script:

    MAC_GATE_HOST=merkur.local bin/mac-gate.sh

It refuses (exit 2) if the tree has no HEAD or if its remote target resolves outside
`~/build/memos-ng-ios/gate/`, mirrors the worktree with `rsync --delete`, and runs, fail-fast:
`bin/generate.sh` (which also asserts the version keys in the generated project) → the
entitlement greps (the app declares EXACTLY ONE keychain access group, the credentials one,
read by index because the first entry is the default an unqualified add lands in; the app group
is deliberately absent from `keychain-access-groups` — a raw `group.…` entry can never match the
profile's `TEAMID.*` pattern and breaks device signing, and the app's keychain access to it rides
on the application-groups entitlement instead; the share extension declares no keychain group;
both declare the app group as a positive control) → `swift format lint --strict --recursive .` → the dependency-pin
check (below) → `xcodebuild test` (all five test bundles) → a read-back of the BUILT app and
.appex (each one's `PrivacyInfo.xcprivacy`, its version keys and its export-compliance answer) →
a rebuild of every package with its warnings fatal, each against the tracked `Package.resolved`
copied beside its manifest and refused any version that file does not name, so a fresh upstream
tag cannot reach this step alone (`swift build -warnings-as-errors` for the four that declare
macOS; MemosFeatures through `xcodebuild` for the simulator, where the fatality comes from its own
manifest) → the dependency-rule greps → the share-link rule
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
generated-surface rule (`scripts/openapi-coverage-rule.sh`: every operationId in the vendored
document is either named in the generator config's inclusion list or is one of the named
exclusions, with the operation count it read as the control) → the
per-bundle test-count check, which asks two questions: whether every bundle EXECUTED at least one
case, and whether each bundle's executed count is still at or above the row
`tests/gate/testcount-baseline.tsv` records for it (`bundle<TAB>count`, one row per bundle, no
header; the arithmetic is `scripts/testcount-verdict.sh`). A count below its row fails the step
naming the bundle, the baseline and the observed count. Equal or above passes, and a rise never
asks for the baseline to be touched. The baseline must name exactly the bundles the run wanted,
neither short of one nor naming one more, so a run whose bundle list differs from the tracked
baseline fails at testcount, and that is intended: the full gate's verdict is only valid over the
default bundle list, and adding or removing a bundle re-records the baseline in the same change. A
baseline that is absent, unreadable or malformed fails too — a count nobody recorded is not a zero.
What the comparison catches is the loss of a test that RAN: it does not catch the deletion of a
test that was skipped, nor a reduction that stays inside headroom accumulated since the baseline
was last recorded — and because the baseline is re-recorded from a branch's final tree before it
merges, headroom at a merge is zero. Every run that obtained the counts writes them to
`.gate-artifacts/testcount-baseline.tsv` before any of them is judged, so a deliberate reduction is
recorded with `cp .gate-artifacts/testcount-baseline.tsv tests/gate/testcount-baseline.tsv` and
never by hand. A candidate at that path was put there by the run you are reading — pass or fail —
through its validated copyback and nothing else: the run's first act, before it reads its
arguments or refuses anything, removes any candidate at that path; the copyback first discards
every staging folder present, which at that point can only be one an earlier run abandoned,
because the lane lock serialises runs of a branch (a shared explicit `MAC_GATE_ARTIFACTS` across
branches is outside that promise), and then lands in `.gate-artifacts/incoming-<run token>/`, never
at that path; and
`scripts/testcount-candidate-owner.sh` promotes the candidate only when it came back beside this
run's token in `run-token`, the stamp the build host writes on the same chain that clears its
artifacts folder. So a run that never obtained counts — no result bundle, a failing `xcresulttool`,
JSON it cannot parse or walk — exits non-zero and leaves no candidate, and neither does a step that
an earlier failing step skipped, nor a run interrupted before the promotion. A run that refused
before it began names, in its refusal, any file it could not clear. The documented path is
`<repo root>/.gate-artifacts/testcount-baseline.tsv` or `$MAC_GATE_ARTIFACTS/testcount-baseline.tsv`;
a run that can resolve neither has no such path and clears none — it cannot identify its
destination, which says nothing about a candidate elsewhere on disk.
Changing that tracked file is a reviewed act that an audit of the change has to see and justify — a
reduction is named in the change that makes it, with the tests it retired — and no mechanism in the
gate accepts or rejects a baseline change on its own. It ends with one summary line of every step's exit code and
returns the first non-zero one. The `.xcresult` and any screenshots come back to
`MAC_GATE_ARTIFACTS` (default `.gate-artifacts/`, gitignored).

Two steps run before any of that, on the machine you are working from. The classifier test
(`tests/gate/fastpath-classify-test.sh`) checks the gate's own docs-only classifier against
throwaway repositories it builds itself — it is the gate's integrity check and runs on every gate.
Then the change set is classified: what this branch changed against `origin/main` (merge-base,
renames not followed, so a rename is judged by both of its names) plus everything staged, edited or
untracked in the working tree. When every one of those paths is documentation or repository
metadata — `docs/`, any `.md`, `.gitignore`, `.gitattributes`, `.editorconfig`, `CODEOWNERS`,
`LICENSE` — and none of them is a symbolic link, the gate reports `PASS (fast path: docs-only)`,
names every changed path and the base it measured from, and copies nothing to the build host.
Anything else meets the full gate: `project.yml`, every manifest, xcconfig, entitlement and plist,
every source file, this script and its own tests. The release-version check runs on both paths, so
a version bump can never take the fast path. Every run writes what it classified to
`.gate-artifacts/classification.txt`, fast path or not. `bin/mac-gate.sh --classify-only` prints
that classification and stops, without needing a build host.

Iteration uses the quick mode and the merge verdict is the full gate: `bin/mac-gate.sh --quick
[--bundle <name>|--only-testing <id>]` runs the selftests, the release-version check, the
classification, the same lane lock and load gate, then rsyncs and — on the lane's private
simulator, reusing its DerivedData — lints, generates, compiles for testing and runs the named
bundle or suite (every bundle with `--quick` alone), skipping the package rebuilds, the canary, the
pins and the entitlement, dependency-rule, share-link, text-selection and token-screen button
greps and the generated-surface rule. The
lint is the same `swift format lint --strict --recursive .` the full gate runs, it comes first, and
a lint error stops the run there: generate, build and tests are not invoked and the exit is the
lint's own code. It prints its own
`MAC_GATE_QUICK: lint=<rc> build=<rc> tests=<rc> | exit=<rc>` and is never a verdict, because only
the full gate writes `mac-gate SUMMARY`.

Each branch has its own lane on the build host — `~/build/memos-ng-ios/gate/<branch>` for the
mirror and `~/build/memos-ng-ios/work/<branch>` for its DerivedData — and runs of one branch are
serialised by a lock on that lane: a second live run says who holds it and stops (exit 3). The
tree's retention policy is two lock-aware sweeps that a full run reaches, each subject to its own
preconditions (the docs-only fast path reaches neither). Before anything is copied, and only after a successful pruned fetch with
the standard refspec, unlocked lanes older than 24 hours whose branch exists neither locally nor
on origin are reaped, the current lane always protected, with each reaped lane's size and the
data volume's free space logged before and after. After the mirror is in place, when the root
volume has less than 15G free, unlocked sibling trees go oldest-stamped first — gate lanes, then
work lanes — until 20G is free or nothing unlocked remains, each removed path and the free space
afterwards logged. The reaper and the shared lock predicate live in `scripts/reap-gate-lanes.sh`
and are exercised by `tests/gate/reap-lanes-test.sh`; the pressure sweep lives in
`bin/mac-gate.sh` beside it, its thresholds not under test. So a lane is eligible once its branch
is absent from both inventories, it is unlocked, and both of its directories are older than 24
hours by their modification time — an already-old lane qualifies the moment its branch goes —
and it disappears on the next full run whose fetch was accepted: an opportunity, not a deadline.

A task is not done until that summary line reads `| exit=0`. Never cite a piped or filtered
summary — the exit code is the verdict.

The gate keeps its own complete log of every run at
`MAC_GATE_ARTIFACTS/mac-gate-<branch>-<run token>.log` and names that path on the line before its
verdict, so two runs — two branches, or two runs of the same branch — can never write the same
file. Any redirect of a gate's output by a caller uses a path unique to the branch and the run
too, never a generic name in a shared directory: that is how one run's evidence gets truncated
mid-write by another's (`tests/gate/concurrent-log-test.sh` holds the gate to its half of it).

**Git is the only medium between the two machines.** The gate directory is a mirror, never a
checkout, and it is never opened in Xcode. A hands-on clone on the Mac lives at
`~/projects/memos-ng-ios`, is never an rsync target, and nothing writes there.

## The dependency rule

    App target (composition only)
       └── MemosFeatures  →  MemosCore  →  MemosAPI

Nothing imports Features. The rule is enforced by the package manifests and checked mechanically
by the gate, with a positive control in the same run:

    grep -n "MemosCore\|MemosFeatures" Packages/MemosAPI/Package.swift      → 0 hits
    grep -n "MemosFeatures"            Packages/MemosCore/Package.swift     → 0 hits
    grep -n "MemosCore"                Packages/MemosFeatures/Package.swift → ≥ 1 (control)

Because that check is a literal text grep, a manifest may not name a layer above it **even inside
a comment**. A check a comment can defeat is not a check.

## Concurrency

Swift 6 language mode and complete strict concurrency in every target and every package, declared
explicitly (`swiftLanguageModes: [.v6]`, `SWIFT_VERSION 6.0` + `SWIFT_STRICT_CONCURRENCY complete`).
MainActor default isolation on the app and the Features layer; the API layer stays `nonisolated`,
because its middleware is called off the main actor by the transport. `Sendable` is keyed on
crossing an ISOLATION boundary, not a package one: a type that stays confined to the main actor may
be used across packages without it. No Combine — Observation and structured concurrency cover it.

Every package builds with its warnings fatal; a warning is a defect. Four of them take
`-warnings-as-errors` from the gate's command line. MemosFeatures cannot: SwiftPM has no iOS
destination for it, and every way of asking `xcodebuild` for that setting also reaches the
dependencies, so a warning in MarkdownUI or OpenAPIKit would fail the gate. It declares
`.treatAllWarnings(as: .error)` on its own target instead. Dropping that line does not fail
anything — the build still succeeds, the warnings simply stop being fatal — and neither the
manifest text nor the build log can be trusted to say otherwise, because a source file can print
whatever a reader looks for. So the gate proves it by mutation: it builds the target as it stands,
then builds it AGAIN with a throwaway file holding nothing but warnings, and requires that second
build to fail. A canary that survives is the failure. The verdict is two exit codes read by
`scripts/warnings-canary-verdict.sh` (fed pairs by `tests/gate/warnings-canary-test.sh`); both
build logs come back as `.gate-artifacts/MemosFeatures-warnings-build.log` and
`.gate-artifacts/MemosFeatures-canary-build.log`. The manifest grep survives as an early hint.

## Invariants every change carries

Paste this block verbatim into every implementation brief and review-gate prompt for this
repo. Each line was bought by external review re-catching the same class on multiple
slices in one session (2026-08-28, session-32 postmortem); the gate must not be the only
memory of them.

- **A store serializes its own mutations.** A disabled button is never the guard: two
  overlapping invocations of the same operation must be one request on the wire (join or
  refuse — state which), and a state the operation left must not be resurrectable by a
  response that outlived it. Precedents: the edit-key slot, renewal joining,
  ManageTokensStore's work gate.
- **Every credential- or identity-scoped read is epoch-fenced.** A response is judged
  against the identity/generation that ISSUED its request, never the current one: a stale
  401 must not end a renewed session, a stale file must not be handed over, a stale list
  must not repopulate a forgotten state. Precedents: PresentedCredential epochs, the
  session-generation download fence, the media fetch generation.
- **A one-shot answer is deduplicated at the callback site, synchronously.** When a
  framework can answer through more than one callback (success + terminal-failure pairs),
  exactly one delivery wins, claimed BEFORE any actor hop — hop ordering is not guaranteed.
  Precedent: PhotoDelegate's oneAnswer claim.
- **A refusal carries the epoch of the credential that earned it, all the way to the
  effect.** Classifying a 401 where the answer arrives and acting on it hops later is the
  same defect written twice: the decision is taken about an instant that has passed. So the
  401 becomes ONE typed value — `CredentialRefusal` for the generated-client and download
  lanes, `OutboxRefusal` for the outbox — carrying which generation the request PRESENTED,
  and the ONE decision rule is asked synchronously on the isolation that performs the
  effect: the main actor for a sign-out or a wipe, `OutboxRepository` for a hold, with
  nothing awaited between the question and the write. Never re-derive it per site, and never
  hand a Bool across a hop. Enforced by `scripts/refusal-sites-rule.sh` — rule 1 (the
  literal, a hint) and rule 2 (pinned entry points and call counts, the fence).

## Tests

Swift Testing (`import Testing`), never XCTest for new tests. Every new or changed function gets a
test, and a test must fail when the behaviour breaks.

- **Mock the generated `APIProtocol`'s transport, never the store.** The stores ARE the unit under
  test; substituting them proves nothing. `StubTransport` in MemosCoreTests hands the real
  generated client a scripted transport, so the request the store builds, the middleware that
  attaches the token and the decoding are all exercised.
- The Markdown layer is held to `Packages/MemosAPI/Sources/MemosAPI/Fixtures/markdown-parity.json`,
  vendored from memos-ng. Every case carries its own Markdown input; the suite renders it and
  asserts the committed projection. Do not edit that file by hand — re-run `scripts/sync-openapi.sh`.
- Pure functions ported from the SPA (`stripTagOnlyLines`, `isTagOnlyLine`, `toggleTask`,
  `taskCheckboxLines`) carry the SAME vectors as their vitest specs. If one changes, both sides
  change together or the port is broken.

## The generated client

`Packages/MemosAPI` generates its client from a vendored `openapi.json` at build time. Both it and
the parity fixture are synced from ONE memos-ng commit:

    MEMOS_NG_REPO=/path/to/memos-ng scripts/sync-openapi.sh <40-char-sha>

The commit, its subject and the files it wrote are recorded in `Packages/MemosAPI/OPENAPI_SOURCE`.
Never hand-write a client method: if something will not generate, fix the contract.

The sync vendors `openapi.json` VERBATIM: the committed file is byte-for-byte
`git show <sha>:openapi.json` in memos-ng, so provenance is checkable with one command. Keep it
that way — memos-ng emits OAS 3.1 nullable type arrays (`type: ["string", "null"]`) natively, so
no rewrite is needed. It was not always so: swift-openapi-generator silently DROPS a property
written as `anyOf: [X, {"type": "null"}]`, `MemoList.nextCursor` included, which is why a
`scripts/normalize-openapi.py` step canonicalised the idiom until memos-ng 433a3fe. If nullable
properties ever vanish from the generated types again, fix the contract in memos-ng rather than
reintroducing a transform here.

If a test bundle needs `OpenAPIRuntime` or `HTTPTypes` directly, it is declared twice — in
`project.yml` and in the package manifest. Keep the versions in step; SwiftPM resolves one graph
and refuses a conflict.

## Project file

`MemosNG.xcodeproj` is generated by XcodeGen from `project.yml` and is NOT committed. Edit
`project.yml`; run `bin/generate.sh` after cloning (it stubs the per-machine `signing.local.yml` —
see `signing.local.yml.example` for device signing). Never commit a `DEVELOPMENT_TEAM`, a
provisioning profile, or a token. A default server host is a different thing and IS committed
(`SignInView.swift`) — it is a convenience for the household's one server, prefilled into an
editable field, never a trust anchor: nothing is authorised because the address was the default.

## Dependency pins

`Package.resolved` at the repo root is the whole resolved dependency graph, and it is committed.
SwiftPM reads that file from inside the project
(`MemosNG.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`), which is generated and therefore
absent from a clone, so `bin/generate.sh` copies the tracked file in before anything resolves.
Pinning the direct dependencies in `project.yml` with `exactVersion` would not be the same thing:
eight of the thirteen packages the app links are transitive and named in no manifest in this
repo, so their versions would still float.

The gate's `pins` step resolves against the restored file and compares what came back with what is
tracked, package by package: the version, the exact commit, and the repository it came from. SwiftPM rewrites that file whenever a pin
cannot satisfy the manifests, so a mismatch IS drift — a dependency added, a requirement bumped
past its pin, a hand edit — and the step fails with a `PINS FAIL:` line naming every package that
moved. `xcodebuild test` then runs with `-onlyUsePackageVersionsFromResolvedFile`, so the build
itself cannot resolve its way to a version the file does not name.

After a deliberate dependency change the pins are re-recorded, not hand-edited: every run leaves
what it resolved in `.gate-artifacts/Package.resolved`, so `cp .gate-artifacts/Package.resolved
Package.resolved` and commit that.

## Outgoing text

Anything that leaves this repo under my name — App Store listing text, release notes, a public
README, an issue or a PR body — is first-person **singular**, carries **no AI attribution** (no
"Generated with…", no `Co-authored-by`, no bot sign-off), and leaks nothing internal (no ticket
keys, no internal hostnames, no estate paths). Verification claims must be literally true.

## BookStack Page Registry

Writes to known pages resolve BY ID from here; name-search is discovery only.

- Book: book:3153 (memos-ng-ios — Features)
- Charter: page:3158
- Documentation Backlog: none — work is tracked in windshift workspace `MEMNG`
- Lessons Learned: page:3281
- Feature — Places: page:3855
- Session Reviews chapter: chapter:3155
- Decisions chapter: chapter:3154 (ADR-0001: page:3157; ADR-0004: page:3936 — the app versions inside
  the shared API major)
- Handover — search-renovation (WP-10 nightly package, 2026-09-23): page:3938 (chapter:3155); playbook
  in the memos-ng book: page:3937
- Register / Roadmap: none — implementation plans are pages in the book (page:3186, page:3274),
  each filed as a windshift Epic

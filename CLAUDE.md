# memos-ng-ios

Native SwiftUI client for memos-ng, and the reference iOS project new iOS apps are cloned from.
The architecture and its reasoning live in `docs/ARCHITECTURE.md` (doctrine v0, proposed). The
rules below are the executable part — the ones a change can break.

## The gate is the only build authority

Swift cannot be built on the Linux machine this repo is developed on. Every build, test, lint and
dependency check runs on the Mac build host through one script:

    MAC_GATE_HOST=merkur.local bin/mac-gate.sh

Inside the pfadfinder-lane container the gate takes the estate lock itself (never wrap it in an
outer `flock` on that file) and names the build host by the ssh alias `merkur`:

    `env MAC_GATE_ESTATE_LOCK=/home/fabian/projects/worktrees/.wp13-gate.lock MAC_GATE_HOST=merkur bin/mac-gate.sh`

Docs-only change sets take a fast path; every run writes what it classified to
`.gate-artifacts/classification.txt`, fast path or not. `bin/mac-gate.sh --classify-only` prints
that classification and stops, without needing a build host.

Iteration uses the quick mode and the merge verdict is the full gate: `bin/mac-gate.sh --quick
[--bundle <name>|--only-testing <id>]`; its `MAC_GATE_QUICK:` line is never a verdict, because
only the full gate writes `mac-gate SUMMARY`.

A task is not done until that summary line reads `| exit=0`. Never cite a piped or filtered
summary — the exit code is the verdict.

**Git is the only medium between the two machines.** The gate directory is a mirror, never a
checkout, and it is never opened in Xcode. A hands-on clone on the Mac lives at
`~/projects/memos-ng-ios`, is never an rsync target, and nothing writes there. The lane's TestFlight
cut (`bin/testflight-cut.sh`) pushes commits to `~/build/memos-ng-ios/release/repo.git` (create-only
`refs/cuts/*`) and builds in `release/work` — the only other write path to the Mac.

Everything else about the gate is read on demand: before running, changing or diagnosing it, read
the file that governs the topic. Each holds its lines moved verbatim from this section.

- `docs/gate/host-routing.md` — the container's estate lock, `MAC_GATE_HOST=auto` host pick and
  the per-worktree run lock (MEMNG-824).
- `docs/gate/pipeline.md` — the full gate's fail-fast step chain and every `scripts/*-rule.sh` it runs.
- `docs/gate/testcount-baseline.md` — the per-bundle test-count check, its baseline and candidate
  copyback, the summary line and the returned artifacts.
- `docs/gate/preflight-and-fastpath.md` — the local lint before the estate lock (MEMNG-807), the
  classifier selftest and the docs-only fast path.
- `docs/gate/quick-mode-and-mutants.md` — `--quick`, `--iterations` and the `--mutants` realness
  loop (MEMNG-825) with its fence.
- `docs/gate/lane-retention.md` — per-branch lanes, the lane lock (exit 3) and the reap and pressure sweeps.
- `docs/gate/run-admission.md` — disk admission, the host-wide simulator slot, its recovery states
  and the vendored admission helper.
- `docs/gate/mount-guard.md` — the build-root mount guard (MEMNG-602): host profiles, pending marker, recovery.
- `docs/gate/run-logs.md` — per-run logs, the private script copy and the estate ledger's durable log copies.

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
the parity fixture are synced from ONE memos-ng commit, and that commit must carry exactly one
`v<major>.*` release tag of the app's own major (`MARKETING_VERSION` in `project.yml`) — the script
refuses an untagged commit and a tag of another major:

    MEMOS_NG_REPO=/path/to/memos-ng scripts/sync-openapi.sh <40-char-sha-of-a-v<major>.*-tag>

The commit, its tag, its subject and the files it wrote are recorded in
`Packages/MemosAPI/OPENAPI_SOURCE`, and the tag and its major in the generated
`VendoredRelease.swift`, which the sign-in handshake compares with the server's `/health`.
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
- Feature — Manage tokens: page:4334
- Session Reviews chapter: chapter:3155
- Decisions chapter: chapter:3154 (ADR-0001: page:3157; ADR-0004: page:3936 — the app versions inside
  the shared API major; ADR-0005: page:3995 — superseded by ADR-0006; ADR-0006: page:4036 — superseded by ADR-0007;
  ADR-0007: page:4044 — proposed: background uploads without resumption — one whole-file background
  URLSession upload task per media file over the existing /api/uploads, retried whole on failure, no
  resumable-upload protocol on either side; memos-ng removed its tus 1.0 router as 1.11.0, plan page 4043
  in the memos-ng book; ADR-0008: page:4248 — accepted 2026-10-06: the main bottom bar is the app's own
  Liquid Glass capsule hosted once over the tab view, frozen as built on 2.2.1 (41); a change to it needs
  the owner's explicit ask and simulator screen recordings before any build)
- Playbook — background uploads, native resumable (2026-09-24): page:4030 (chapter:3155; S1 handover
  page:4031)
- Handover — search-renovation (WP-10 nightly package, 2026-09-23): page:3938 (chapter:3155); playbook
  in the memos-ng book: page:3937
- Register / Roadmap: none — implementation plans are pages in the book (page:3186, page:3274),
  each filed as a windshift Epic

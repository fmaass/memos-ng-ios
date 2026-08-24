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
entitlement greps (the app declares the credential keychain group first and the app group
second, read by index; the share extension declares no keychain group; both declare the app
group as a positive control) → `swift format lint --strict --recursive .` → `xcodebuild test`
(all five test bundles) → a read-back of the BUILT app and .appex (each one's
`PrivacyInfo.xcprivacy`, its version keys and its export-compliance answer) →
`swift build -warnings-as-errors` for MemosAPI and MemosCore → the dependency-rule greps → a
per-bundle test-count check. It ends with one summary line of every step's exit code and
returns the first non-zero one. The `.xcresult` and any screenshots come back to
`MAC_GATE_ARTIFACTS` (default `.gate-artifacts/`, gitignored).

A task is not done until that summary line reads `| exit=0`. Never cite a piped or filtered
summary — the exit code is the verdict.

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
because its middleware is called off the main actor by the transport. Every type crossing a package
boundary is `Sendable`. No Combine — Observation and structured concurrency cover it.

MemosAPI and MemosCore build with `-warnings-as-errors`; a warning there is a defect.

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
provisioning profile, a server URL default, or a token.

## Outgoing text

Anything that leaves this repo under my name — App Store listing text, release notes, a public
README, an issue or a PR body — is first-person **singular**, carries **no AI attribution** (no
"Generated with…", no `Co-authored-by`, no bot sign-off), and leaks nothing internal (no ticket
keys, no internal hostnames, no estate paths). Verification claims must be literally true.

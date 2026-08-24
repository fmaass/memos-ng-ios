# memos-ng-ios

Native SwiftUI client for [memos-ng](https://github.com/fmaass/memos-ng), and the reference iOS
project I build new iOS apps from. It talks to a memos-ng server over its REST API with a personal
access token stored in the Keychain.

Status: foundation. Sign in, read the timeline, read a memo. Writing, sharing and notifications
come later. The architecture and its reasoning are in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md);
the click-path for getting a build to my own devices over TestFlight is in
[`docs/TESTFLIGHT.md`](docs/TESTFLIGHT.md).

## Building

The Xcode project is generated, not committed:

    brew install xcodegen
    bin/generate.sh
    open MemosNG.xcodeproj

Requires Xcode 26.6 and the iOS 26 simulator runtime. The three local packages under `Packages/`
resolve on first build; `MemosAPI` generates its client from the vendored `openapi.json` as part of
that build, so the first one takes a while.

## The gate

Every build, test and lint runs on a Mac build host, driven from wherever you are working:

    MAC_GATE_HOST=<ssh-alias> bin/mac-gate.sh

It mirrors the working tree to a disposable directory on that host and runs, in order and
fail-fast: `bin/generate.sh` (xcodegen), `swift format lint --strict --recursive .`, `xcodebuild test`
(three test bundles), `swift build -warnings-as-errors` for `MemosAPI` and `MemosCore`, the
dependency-rule check, and a per-bundle test-count check. It prints one summary line of every
step's exit code and returns the first non-zero one; the result bundle and any screenshots are
copied back to `.gate-artifacts/`.

The gate directory on the build host is a mirror, never a checkout. Git is the only medium between
the two machines.

## Syncing the contract

`openapi.json` and the Markdown parity fixture are vendored from ONE memos-ng commit, so the client
and the renderer are always tested against the same server:

    MEMOS_NG_REPO=/path/to/memos-ng scripts/sync-openapi.sh <40-char-sha>

That writes `Packages/MemosAPI/Sources/MemosAPI/openapi.json`, the parity fixture beside it, and
`docs/markdown-parity.schema.md`, and records the commit plus what the sync did in
`Packages/MemosAPI/OPENAPI_SOURCE`. Never edit any of those by hand.

## Signing in

Create a personal access token in the memos web app, then paste it with your server address into
the sign-in screen. The token is validated against `GET /api/auth/user` before it is stored, and a
`401` anywhere signs the app out.

DEBUG builds only: if `MEMOS_SERVER` and `MEMOS_PAT` are both set in the environment at launch, the
app signs in with them. That exists so a simulator with no keyboard can be driven for acceptance
runs; release builds contain no code path that reads a credential from the environment.

## Running on a device

Simulator builds need nothing. For a physical iPhone: add your Apple ID in Xcode → Settings →
Accounts (free personal team is fine, re-signs weekly), copy `signing.local.yml.example` over
`signing.local.yml` (replacing the generated stub), fill in the team id, run `bin/generate.sh`, pick
your device. Never set
signing in the Xcode UI — the project file is generated and your click would be wiped.

# memos-ng-ios

Native SwiftUI client for memos-ng, and the reference iOS project new iOS apps are cloned from.
The architecture and its reasoning live in `docs/ARCHITECTURE.md` (doctrine v0, proposed). The
rules below are the executable part — the ones a change can break.

## The gate is the only build authority

Swift cannot be built on the Linux machine this repo is developed on. Every build, test, lint and
dependency check runs on the Mac build host through one script:

    MAC_GATE_HOST=merkur.local bin/mac-gate.sh

Inside the pfadfinder-lane container the same gate takes the jupiter-local estate lock ITSELF —
`MAC_GATE_ESTATE_LOCK` names the lock file that is the estate-wide exclusion for Mac gates (this
script's own lock is per branch and serialises nothing across repos), and the run then stamps
`lock_requested`/`lock_acquired` into its log and its row in `worktrees/gate-runs.tsv`. Never wrap
that command in an outer `flock` on the same file as well: the gate would wait on itself forever.
It names the build host by the ssh alias `merkur`, the only name the container's key is bound to
(`merkur.local` does not authenticate there):

    `env MAC_GATE_ESTATE_LOCK=/home/fabian/projects/worktrees/.wp13-gate.lock MAC_GATE_HOST=merkur bin/mac-gate.sh`

**The gate can pick the build host itself (MEMNG-824).** `MAC_GATE_HOST=auto` with the per-host lock
map `MAC_GATE_ESTATE_LOCKS=merkur=/home/fabian/projects/worktrees/.wp13-gate.lock,mars=/home/fabian/projects/worktrees/.mars-gate.lock`
(preference order, names limited to the mount guard's profiles) tries each host's lock with
`flock -n` in map order and takes the first that is free AND answers `ssh -o BatchMode=yes -o
ConnectTimeout=10 <host> true` under `timeout 30`. With every host busy it probes the busy ones and
waits, blocking, on the host named by `<artifacts>/lane-host` (written by every run that reaches
the remote step: `<host> <branch> <UTC> <run token>`; read only for this branch and under 24 h
old), else on the first answering host in map order; a host that stops answering during that wait
is let go and the choice is made again. No answering host, `auto` without the map, or a name the
gate does not know refuses with exit 15 before any lock. The choice is one `route       :
host=<h> reason=<…> worktree_wait=<s>s pid=<n> token=<t>` line in the run log, `host=<name>` sits
on `mac-gate SUMMARY:` and `MAC_GATE_QUICK:` just before `locallint=`, and the run ledger's rows
carry it as a 13th field (`host`; the 13-name header is written only into a new or empty ledger,
so an older ledger keeps its 12-name header above mixed 12/13-field rows). An explicit host with
`MAC_GATE_ESTATE_LOCK` behaves as before; an explicit host with only the map takes its own entry.
Every run that builds or tests — explicit or `auto` — also holds the worktree's run lock,
`<artifacts>/.run.lock` (a kernel `flock` on descriptor 7, taken after the local lint and before the
estate lock, released only when the run's process exits), so two runs of one worktree never
overlap on two hosts over one artifacts directory; it carries one informational `pid= token=
host=` line and needs no reclaim. Every line that closes descriptor 9 for a child or a subshell
closes 7 too, the router's own `exec 9>&-` lines excepted; `tests/gate/host-routing-test.sh`, a
named selftest, holds all of it. `bin/testflight-cut.sh` does not take `auto`: keep its explicit
host and lock.

It refuses (exit 2) if the tree has no HEAD or if its remote target resolves outside
`~/build/memos-ng-ios/gate/`, mirrors the worktree with `rsync --delete`, and runs, fail-fast:
`bin/generate.sh` (which also asserts the version keys in the generated project) → the
entitlement greps (the app declares EXACTLY ONE keychain access group, the credentials one,
read by index because the first entry is the default an unqualified add lands in; the app group
is deliberately absent from `keychain-access-groups` — a raw `group.…` entry can never match the
profile's `TEAMID.*` pattern and breaks device signing, and the app's keychain access to it rides
on the application-groups entitlement instead; the share extension declares no keychain group;
both declare the app group as a positive control) → `swift format lint --strict --recursive .` → the dependency-pin
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
arguments or refuses anything, removes any candidate at that path — with one exception: a run the
local lint refused never took the estate lock that serialises that removal against a run of the
same worktree still promoting its own, so it leaves any earlier candidate in place, which is why a
candidate beside a `locallint=1` run is never that run's (a run the `--mutants` check refused is
the same case: it lints nothing, takes no lock and clears nothing); the copyback first discards
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

Three steps run before any of that, on the machine you are working from. The first is the local
lint (`scripts/local-lint.sh`, MEMNG-807): the same `swift format lint --strict --recursive .` over
the caller's repository root, in the bootstrap, before the estate lock is even requested and so
before the lane lock — a formatting error used to wait out the whole queue only to fail the build
host's first step. It takes a native `swift format` on PATH first, then the docker image
`swift:6.3` when it is already on the machine (`docker run --rm --pull never --network none -v
<tree>:/src:ro`, never pulled); every one of its calls, the version probes included, is bounded by
`timeout -k 10`, which sends KILL ten seconds after a TERM that was ignored; either must report
the build host's major, and neither is ever asked to rewrite. A failure refuses the run there with
the lint's own exit code, 1: no estate lock taken, no ssh, no test-count candidate cleared, the
lint's lines and its verdict in the run log, `locallint=1` on the summary (or the quick line) and
`mode=refused` in the run ledger. No such tool — the pfadfinder-lane
container has neither — falls through to the build host's lint alone and says why in the log, as
does a tool that ended without a verdict (any code but 0 or 1); the field is then `locallint=-`.
Both lines carry `locallint=` just before `| exit=`; the quick line's `lint=` is still the build
host's. A run's output is what it was plus the bootstrap's start notice (`mac-gate: linting …
before the estate lock is requested`), the `--- step: locallint ---` heading with the lint's
lines, its verdict and status lines, and the build host's version line. It runs on the docs-only
fast path too (a clean tree lints in about a minute), and never
on `--help`, `--classify-only` or a run without `MAC_GATE_HOST`. Its verdict line,
`MAC_GATE_LOCALLINT rc=… local=… version=… mac=…`, names the local swift-format and the build
host's as pinned in the script (6.3.0, read 2026-10-13); the build host's own lint step prints
`MAC_GATE_SWIFTFORMAT version=…`, so one run log holds both for comparison. An implementer that
cannot build can still lint, with the docker form from the worktree root — `docker run --rm -v
"$PWD":/src:ro -w /src swift:6.3 swift format lint --strict --recursive .` — so no review round
reaches the Mac with a formatting error. Its selftests are `tests/gate/local-lint-test.sh` (the
helper against fake tools, and the real image where it is present) and
`tests/gate/local-lint-refusal-path-test.sh` (the refusal before the estate lock, while another
process holds it); both are named selftests. The second step is the classifier test
(`tests/gate/fastpath-classify-test.sh`), which checks the gate's own docs-only classifier against
throwaway repositories it builds itself — it is the gate's integrity check and runs on every gate.
Then the change set is classified: what this branch changed against `origin/main` (merge-base,
renames not followed, so a rename is judged by both of its names) plus everything staged, edited or
untracked in the working tree. When every one of those paths is documentation or repository
metadata — `docs/`, any `.md`, `.gitignore`, `.gitattributes`, `.editorconfig`, `CODEOWNERS`,
`LICENSE` — and none of them is a symbolic link, the gate reports `PASS (fast path: docs-only)`,
names every changed path and the base it measured from, and copies nothing to the build host.
Anything else meets the full gate: `project.yml`, every manifest, xcconfig, entitlement and plist,
every source file, this script and its own tests. A package's bundled resource
(`Packages/*/Sources/*/Resources/*`) is never docs-only, whatever its extension, so a change to the
release notes alone meets the full gate and its `notes` step. The release-version check runs on both paths, so
a version bump can never take the fast path. Every run writes what it classified to
`.gate-artifacts/classification.txt`, fast path or not. `bin/mac-gate.sh --classify-only` prints
that classification and stops, without needing a build host.

Iteration uses the quick mode and the merge verdict is the full gate: `bin/mac-gate.sh --quick
[--bundle <name>|--only-testing <id>]` runs the selftests, the release-version check, the
classification, the same lane lock and run admission, then rsyncs and — reusing the lane's
DerivedData — lints, generates, compiles for testing on the generic destination and runs the named
bundle or suite on a private device of its own inside the host slot (`bin/mac-gate.sh:2380`, `:2394`) (every bundle with `--quick` alone), skipping the package rebuilds, the canary, the
pins and the entitlement, dependency-rule, share-link, text-selection and token-screen button
greps and the generated-surface rule. The
lint is the same `swift format lint --strict --recursive .` the full gate runs, it comes first, and
a lint error stops the run there: generate, build and tests are not invoked and the exit is the
lint's own code. `--iterations <N>` (1 to 1000, refused without `--only-testing`) repeats that one
scope with `-test-iterations N -run-tests-until-failure`, fails when any run fails or the result
bundle shows a case run fewer than N times, and adds `iterations=N` to the quick line.
`--quick --only-testing <id> --mutants <dir>` is the way to run the realness loop (MEMNG-825): `<dir>`
holds 1 to 4 numbered unified diffs (`NN-<name>.patch`), each a mutant the named scope must catch.
`scripts/mutants-check.sh`, evaluated by the bootstrap before the estate lock is requested, refuses
with exit 2 a patch that does not apply (`patch -p1 --dry-run` on a scratch copy), creates, deletes,
renames or re-modes a file, names an untracked path, a path outside the tree, one not in canonical
form (an empty segment, as in `a//b`, which git resolves to the same file as `a/b`) or one under a
`Tests` directory, holds the heredoc terminator's prefix, or touches a file another patch touches, and a
fifth patch; the bytes it judged are frozen at that moment, so an edit to `<dir>` while the run
queues reaches nothing. `--bundle` and `--iterations` are refused beside it. Inside ONE estate-lock
hold and ONE simulator span the build host writes the patches outside the mirror, copies the
touched files aside and hashes them, runs the clean scope (it must pass; a failing clean run keeps
its code and runs no mutant), then per mutant applies it, rebuilds incrementally, runs the scope
with evidence of its own (`MemosNG-quick-mutant-NN.xcresult`, `quick-test-NN.log`,
`mutant-NN-build.log`) and restores the files from the copy, touched, each compared byte for byte
with the copy afterwards — a file that does not compare equal is removed from the mirror, the batch
stops and is unsound, and the mutant stays marked applied; the give-back the remote traps run
restores an applied mutant too. A file that can be neither put back nor removed is written into
the lane's fence, a `<branch>%mutant-fence` file in the gate root (`/` escaped as `%2F`; no branch
can carry a `%`, so no lane can sit there) that no sweep of the lane's directories removes, because rsync's size-and-mtime check could skip the leftover: every later run
of that lane checks the fence after its rsync and before it builds, refuses one it cannot read
whole, clears a file only once it is verified (absent, its bytes no longer the leftover's, or
removed by an earlier fenced run so that rsync had to write it), and otherwise removes it and
refuses with exit 18 and `MAC_GATE_MUTANT_FENCE REFUSE` lines naming the file and the fence; the
fence is never deleted by hand. Then it rebuilds, runs the clean scope again and compares hashes
and listings: any difference is `MAC_GATE_BATCH_UNSOUND`. One `MAC_GATE_MUTANT <name>
caught|SURVIVED|BROKEN|INCONCLUSIVE tests_rc=<rc>` line per mutant (caught = it built, the scope failed
and the result bundle shows a failed case); the quick line carries `mutants=<caught>/<total>`; a
mutant not caught is named on a `MAC_GATE_MUTANT_SURVIVOR` line and the exit is 17. A batch writes
one ledger row (mode `quick`) and no test-count candidate. Its selftest, `tests/gate/mutants-test.sh`,
is one every run names. It prints its own
`MAC_GATE_QUICK: lint=<rc> build=<rc> tests=<rc> locallint=<rc|-> | exit=<rc>` and is never a verdict, because only
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
and are exercised by `tests/gate/reap-lanes-test.sh`; the pressure sweep is `gate_pressure_sweep` in
the same file (`scripts/reap-gate-lanes.sh:37`), called by the build host's script
(`bin/mac-gate.sh:1237`) and by the admission's disk reading (`:1112`), its thresholds not under test. So a lane is eligible once its branch
is absent from both inventories, it is unlocked, and both of its directories are older than 24
hours by their modification time — an already-old lane qualifies the moment its branch goes —
and it disappears on the next full run whose fetch was accepted: an opportunity, not a deadline. A full
run whose build-host steps failed and that reaches its remote summary also tries to remove its own
`warnings/` rebuild trees there, never through a path that is not its own physical path (a run
interrupted on the way does not), keeping its DerivedData (`gate_drop_failed_rebuilds`, same file and test); a run that
passed keeps them for the next incremental build.

**One simulator phase at a time on the build host, admitted by condition.** Before anything is
copied, run admission (`bin/mac-gate.sh:1129`, `scripts/gate-admission.sh:636`) requires the host's
free space plus this lane's own trees to cover a run's peak (12 GiB) and a 3 GiB reserve, polling
every 60 s up to a 6 h ceiling; it refuses with exit 12 at the ceiling and 13 after three
consecutive polls it could not measure. The 12 GiB is a provisional allowance rounded up from a measurement:
one cold-lane full gate on 2026-09-27 (`MAC_GATE_HOST=merkur.local bin/mac-gate.sh` at 6d6bf81),
sampled every ~16 s with `df -Pk /` and `du -sk` of the lane's trees and its simulator device —
9.4G the largest sampled sum, 11.2G the recorded bound, though the record's own parts do not add
up to them and its raw samples were not kept (the detail is the comment above
`GATE_ADMISSION_NEED_KB` in `bin/mac-gate.sh`). The old load gate is gone, and with it the «proceeding
anyway» after its wait: an unmeasured reading is a refusal, never an admission. The simulator span
is the host-wide slot `~/build/.gate-slots/sim`, shared by every repo's gate: a run claims it by
rename(2) (`scripts/gate-admission.sh:378`) just before it creates its device and releases it just
after that device's deletion is confirmed (`bin/mac-gate.sh:1288`, `:1438`, `:1447`). The wait
(`scripts/gate-admission.sh:511`) holds until the slot is free AND free space ≥ 8 GiB, memory free
≥ 20 %, load ≤ 24 and no booted device named `gate-*`, `mac-gate-iphone-*` or `mac-gate-ipad-*`
other than the holder's; each wait logs who holds the slot and which term failed, and the ceiling
refuses with exit 11 (12 when free space is the only failing term). Swap in use is on every wait
line (`swap_used=`) and is never a term: the host idles at about 6 GiB of swap held by long-lived
desktop applications, so a swap bound would hold every run to its ceiling. A
holder is recovered only when its pid is gone, no process of its process group lives, and its
devices are confirmed deleted under the reap mutex, the holder's token re-checked twice
(`:248`, `:464`); a live holder is never taken, and one whose pid is gone but whose group lives is
logged `ORPHAN-HOLDER` and waited for. The run's own release comes before the build host's summary,
checked (`scripts/gate-admission.sh:433`); the EXIT, INT, TERM and HUP traps repeat it
(`bin/mac-gate.sh:1277-1280`) and a PIPE trap moves output to a file so a dropped ssh still ends
in that release (`:1283`). Its handler writes one line into that file at once
(`scripts/gate-admission.sh:679`): bash 3.2 keeps a failed write's bytes buffered, and every later
`$(…)` would carry them into its value — the release then misread its own token and kept the slot
(2026-09-30). A run whose ssh went away before it claimed the slot stops waiting with `slot=14`
(`:526`), rather than testing, hours later, for a controller that is gone. Two residuals are stated, not
closed: it detects a broken output connection, not a dead controller, so an orphaned ssh client
that keeps draining output is not caught; and a drop is noticed only at the remote's next write,
so a waiter can claim the slot before its first failed write (the `slot-claimed` line, `:405`).
Neither can make two holders or release live work. A release that cannot confirm the run's processes and devices gone keeps
the slot, marked `state=cleanup-failed`, and reports `simrelease=1`; the next waiter's recovery
retries it. Two states need a human, and the log line names the step: `REAP-DEAD`
(`scripts/gate-admission.sh:476`) — a recoverer died holding the reap mutex, so recovery stays
blocked until its pid is confirmed gone and `ssh merkur rm -rf ~/build/.gate-slots/reap` clears it;
`DEVICE-STUCK` (`:299`, `:317`) — three deletes could not remove the run's device (or a shared one
will not shut down), the slot stays fenced, and once nothing of that run is alive the one udid the
line names is deleted with `xcrun simctl delete <udid>` — never a fleet-wide `simctl` operation.
Every slot event is a `GATE_SLOT <utc> token=<run token>` line on the build host — `slot-claimed`,
`device-created udid=…`, `device-deletion-confirmed udid=…`, `slot-released`. `MAC_GATE_SIMULATOR`
names an existing shared device instead: the run claims the slot all the same, creates and deletes
nothing, and its release shuts that device down and confirms it (`bin/mac-gate.sh:1288-1306`). The
claim writes that device's UDID into the record it renames into place, and a claim without a valid
one is never attempted (`scripts/gate-admission.sh:378`); a shared record that names no device is
fenced by cleanup and recovery alike, never released (`:322`). Devices are read from `simctl list
devices -j`, unavailable runtimes included, and any record without a UDID, a state or a name makes
the whole reading unmeasured, never «none left» (`:170`); the run admission's disk reading on the
build host goes through the same checked readers, since no pipefail reaches `ssh bash -s` (`:130`).
The summary line carries `admit=`, `slot=` and `simrelease=` as exit codes (`bin/mac-gate.sh:1131`,
`:2543-2544`), and `slot_wait=` (seconds waited) and `disk=` (GiB free at admission) as
information (`:1132`, `:2547`); `slot=-` means the build host's script never reported its slot. The
helper is vendored byte-identical by the other iOS repos: `scripts/GATE_ADMISSION_SOURCE` records
the reference commit and its sha256, and `tests/gate/admission-test.sh`, one of the selftests every
run needs (`bin/mac-gate.sh:689`), checks that sha and every case above against fake readers.

**The build root must be the build host's own image (MEMNG-602).** A full or quick run's first contact
with the build host is the `--- step: mount ---`, after the classification and before the
preflight's first write: it pipes `scripts/gate-mount-guard.sh` from the run's private copy (it is
one of `GATE_RUN_HELPERS`) to `ssh bash -s` and asks `gate_mount_guard report memos-ng-ios/gate
memos-ng-ios/work`, under `timeout 30`. The guard first picks its profile by a PAIR read on the host — its
`LocalHostName` (`scutil --get LocalHostName`, lower-cased) and its hardware `IOPlatformUUID` (`ioreg`,
read once and reused for the marker check) — and each profile is a block of literals naming both
halves of its pair: `merkur` on `ABED54FD-4031-53B1-9951-E8FF4DE51F69` — volume UUID
`EE4304C8-021C-489D-B57B-6D846E76B1CF`, bundle `/Volumes/lexosaurus/caches/merkur_build.sparsebundle`,
sentinel `.NOT-MOUNTED-merkur_build`, agent `live.discomarder.merkur-build-image`; `mars` on
`639B86D9-17FA-5EBE-8A66-530B948476BE` — volume UUID `4FBC8F45-0C6B-45C4-AF86-411A2B7B2789`, bundle
`/Volumes/flexosaurus/caches/mars_build.sparsebundle`, sentinel `.NOT-MOUNTED-mars_build`, agent
`live.discomarder.mars-build-image`; both rooted at `/Users/fabian/build`. Any mismatch — an unknown name, a
known name on the other host's or unknown hardware (a host renamed to the other's name), either
read failing, timing out, empty or malformed — is `MOUNT REFUSE no mount profile for host <name>
(<hardware UUID or unmeasured: …>)` with `mountguard=enforced marker=not-read`, rc 16, in either
mode: no marker is read and no pending state is ever reported for a host without a profile, so a
renamed host fails closed and never selects the other's. A third host needs a code change. The verdict line names the host it chose (`MOUNT OK host=<host> uuid=… dev=…`,
`MOUNT REFUSE host=<host> …`). The guard then reads the volume at `~/build` — the recorded
UUID, apfs, mounted exactly there with ownership, attached from the one sparse bundle, a mount
boundary below `$HOME`, the unmounted directory's sentinel hidden — and this repo's two subtrees on
it, read-only. Its refusal is `mount=16` and the run ends there with exit 16 (`mode=refused` in the
run ledger): nothing was written on the host, no lock taken, no slot claimed, no device created,
and no further ssh is made — a signal during the step's ssh included, because the device give-back
stays off until the step has accepted the answer. The whole answer is judged: exit 0 and exactly two
lines, `MOUNT OK|REFUSE …` then `mountguard=<state> marker=<one of the guard's marker states>`,
agreeing, with a `pending:` state only beside `marker=valid`; anything else — a missing helper, a
failed or timed-out ssh, an extra line, stderr noise — is a refusal too, its answer quoted in the log.
While a valid pending marker `~/.config/build-mount-guard/pending` on the host (this host's
`IOPlatformUUID`, a window of at most 72 h, `now < expires`) exists, a refusal is reported instead:
`mount=0` with `mountguard=pending:REFUSE` on the summary; otherwise the summary carries
`mountguard=enforced` (or `pending:OK`). Renewing the marker needs the orchestrator's approval and a
second renewal the owner's. After the image comes unmounted, recovery is manual: `launchctl
kickstart -k gui/501/<the host's agent label>`, which the refusal line names. No environment
variable moves the root, the UUID, the bundle path or the label on either host — only the readers,
`scutil` included, are replaceable, for the tests. One LaunchAgent program,
`scripts/merkur/build-image-mount.sh`, serves both hosts through the same profile (the bundle's
volume and its log derived from it), each host's agent defined by
`scripts/<host>/live.discomarder.<host>-build-image.plist` and held by
`tests/gate/build-image-mount-test.sh`. The remote free-space line after
the sweep reads the target's volume, never `/`. `tests/gate/mount-guard-test.sh` holds the guard and
`tests/gate/mount-refusal-path-test.sh` the gate's refusal path; both are named selftests.

A task is not done until that summary line reads `| exit=0`. Never cite a piped or filtered
summary — the exit code is the verdict.

The gate keeps its own complete log of every run at
`MAC_GATE_ARTIFACTS/mac-gate-<branch>-<run token>.log` and names that path two lines before its
verdict, so two runs — two branches, or two runs of the same branch — can never write the same
file. The line between them is `script      : sha256 <hex>`, the text of `bin/mac-gate.sh` the run
executed: a run copies the script, and the helpers it hands to the build host or runs at the end
(`scripts/reap-gate-lanes.sh`, `gate-work-dir.sh`, `gate-root-refusal.sh`,
`testcount-candidate-owner.sh`, taken from the caller's repository), into a private directory under
`$TMPDIR` at start and execs the copy, so an edit to the tree while a run is under way cannot change
what it runs (`tests/gate/private-copy-test.sh` edits the script and a helper mid-run). The
selftests under `tests/gate/` and the tree mirrored to the build host are still read from the tree. Any redirect of a gate's output by a caller uses a path unique to the branch and the run
too, never a generic name in a shared directory: that is how one run's evidence gets truncated
mid-write by another's (`tests/gate/concurrent-log-test.sh` holds the gate to its half of it).
A worktree's `.gate-artifacts/` goes with the worktree at merge-closeout, so the run's row in the
estate ledger (`MAC_GATE_RUNS_LEDGER`, default `/home/fabian/projects/worktrees/gate-runs.tsv`)
names a durable copy instead: on its way out, after everything else it writes, the run copies its
complete log, byte for byte, to `MAC_GATE_RUNS_LOGS` (default `gate-logs/` beside the ledger) as
`memos-ng-ios-<branch>-<run token>.log`, fast path included. A copy that cannot be made keeps the
row on the local log behind one `LEDGER-LOG-KEPT-LOCAL <why>` line and never changes the run's exit
code (`tests/gate/estate-ledger-test.sh`, case 22).

**Git is the only medium between the two machines.** The gate directory is a mirror, never a
checkout, and it is never opened in Xcode. A hands-on clone on the Mac lives at
`~/projects/memos-ng-ios`, is never an rsync target, and nothing writes there. The lane's TestFlight
cut (`bin/testflight-cut.sh`) pushes commits to `~/build/memos-ng-ios/release/repo.git` (create-only
`refs/cuts/*`) and builds in `release/work` — the only other write path to the Mac.

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

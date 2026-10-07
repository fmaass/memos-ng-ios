# Getting this app onto my phone through TestFlight

Everything the repository can decide has been decided. What is left is the half that only a
signed-in human can do: agreements, an app record, an internal tester group, and one Xcode Cloud
workflow — the first three of those are done.

As observed in App Store Connect on 2026-08-25, the record holds version `0.1.0` builds 1, 2, 3 and
4, and build 4 is distributed to the `household` group with two invites. All four were archived in
Xcode on the build Mac and uploaded by hand. Part 2 is the part that has never been exercised: no
Xcode Cloud workflow exists yet.

Steps marked **[me only]** cannot be automated from here — they need a browser session in App
Store Connect or a signed-in Xcode. Everything else is already committed.

This is for **internal TestFlight distribution only**. Nothing here submits the app to the App
Store, and no step below starts a review.

---

## What the repository already declares

Do not re-derive these while answering App Store Connect's questions — read them off this list, so
the answers on the website and the answers inside the bundle say the same thing.

| Thing | Value |
| --- | --- |
| App bundle identifier | `live.discomarder.memosng` |
| Share-extension bundle identifier | `live.discomarder.memosng.share` |
| App group | `group.live.discomarder.memosng` |
| Associated domain | `memos.discomarder.live` (webcredentials) |
| Version (`CFBundleShortVersionString`) | `MARKETING_VERSION` in `project.yml`, per [`RELEASING.md`](RELEASING.md) |
| Build number (`CFBundleVersion`) | `CURRENT_PROJECT_VERSION` in `project.yml` — an Xcode Cloud build numbers its own |
| Export compliance | `ITSAppUsesNonExemptEncryption = false`, already in both bundles |
| Data collected | none |
| Tracking | none, and no tracking domains |
| Required-reason APIs declared | file timestamps (`C617.1`) and user defaults (`CA92.1`, `1C8F.1`), in both bundles |

The privacy manifests are `Support/MemosNG/PrivacyInfo.xcprivacy` and
`Support/MemosShare/PrivacyInfo.xcprivacy`. They declare the same two required-reason API
categories, for different code in each bundle:

- `NSPrivacyAccessedAPICategoryFileTimestamp`, reason `C617.1` — a timestamp read off a file in a
  container the reason covers: the bundle's own, or the app group's. The app reads the
  modification date of a picked file it has just copied into its temporary directory; the
  extension reads the modification date of a shared file it has just staged there. Both, through
  the outbox code linked into each of them, also read the creation date of an outbox manifest,
  which lives in the app group container. The app alone has a second location for that queue: it
  falls back to its own Application Support directory when the group cannot be reached, which
  `C617.1` covers as the app's own container. The extension has no fallback — it refuses to post
  rather than write a capture nothing would drain.
- `NSPrivacyAccessedAPICategoryUserDefaults`, reasons `CA92.1` and `1C8F.1` — `CA92.1` for the
  process's own defaults and `1C8F.1` for the app group's suite. The app keeps the appearance
  choice, the library's sort direction and the media fetch generation in its own defaults and the
  outbox's mobile-data choice in the group's; the extension carries only that last one, because
  the outbox is linked into it as well. Each manifest's own comment names the file behind every
  reason.

Nothing else in either bundle touches a required-reason API: nothing reads volume capacity,
nothing asks for system uptime, and nothing enumerates keyboards. The gate reads both shipping
bundles back and fails if a manifest is missing, does not parse, claims tracking, lists a tracking
domain or a collected data type, or declares file-timestamp reasons other than exactly `C617.1` or
user-defaults reasons other than exactly `CA92.1` and `1C8F.1`, per bundle, naming the bundle and
the difference (`scripts/privacy-manifest-verdict.py`, exercised by
`tests/gate/privacy-manifest-test.sh`). It prints any other declared category but holds none to a
value, and the answers on the website still come off the manifests themselves, not off the gate's
log.

---

## Part 1 — App Store Connect, before the first build

### 1. Accept the agreements **[me only]**

App Store Connect → **Business**. The Account Holder has to have signed the current Apple Developer
Program License Agreement before an app can be added to the account; a pending agreement is the
usual reason the next step refuses.

### 2. Register the identifiers **[me only]**

The app is not a plain single-target app: it embeds a share extension, the two share an app group,
and the app claims an associated domain. Those capabilities must exist on the identifier before a
distribution build can be signed, or the archive fails at signing with no useful message.

On the Apple Developer website → **Certificates, Identifiers & Profiles** → **Identifiers**:

1. Add an **App Group**: `group.live.discomarder.memosng`.
2. Add an **App ID** for `live.discomarder.memosng`, and enable **App Groups** (selecting the group
   above) and **Associated Domains** on it.
3. Add an **App ID** for `live.discomarder.memosng.share`, and enable **App Groups** on it
   (selecting the same group). The extension needs no other capability — it holds no credential.

Xcode can create some of this on demand when it signs, but doing it here first means the first
cloud build does not fail on it.

### 3. Create the app record **[me only]**

App Store Connect → **Apps** → **+** (top left) → **New App**. The dialog wants:

- **Platforms**: iOS.
- **Name**: `memosng`. App names are unique across the whole App Store, TestFlight-only apps
  included — if it is taken, pick another and note it; the name here does not have to match
  `CFBundleDisplayName`, which is what shows under the icon on the phone.
- **Primary Language**: whatever the interface is written in — English (U.S.).
- **Bundle ID**: pick `live.discomarder.memosng` from the menu. It must be exactly that, or the
  uploaded build will not attach to this record.
- **SKU**: any private string; `memosng-ios` does.
- **User Access**: Full Access.

Click **Create**. The record appears with the status *Prepare for Submission*, which is where it
stays — nothing below submits it.

### 4. Privacy policy URL **[me only]**

App Store Connect → the app → sidebar **App Privacy** → **Privacy Policy URL** (the field moved
here from App Information — as executed 2026-08-24, App Information no longer carries it):

    https://memos.discomarder.live/privacy

The page is live. The field is required for an App Store submission and for external TestFlight
testing; App Store Connect did not enforce it for the internal-only group, but it is filled so the
question never arises.

### 5. App Privacy **[me only]**

App Store Connect → the app → sidebar **App Privacy** → **Get Started**.

Answer **No** to the question about whether data is collected from this app. That is the answer
that matches the two privacy manifests, and it is true — memo text and media go to my own server and
nowhere else, there is no analytics SDK, no crash reporter and no advertising identifier. Then
**Publish** and confirm.

Apple documents this section as a requirement for distributing on the App Store rather than for
TestFlight, but the answers have to match the bundles either way, so it is two clicks now instead of
a contradiction later.

### 6. The internal tester group **[me only]**

App Store Connect → the app → **TestFlight** tab → in the sidebar, the **+** next to **Internal
Testing** → name it `household` → **Create**.

Then, with the group selected, **Invite Testers** on the right, tick each person, **Add**.

Two constraints that decide who can be in it:

- An internal tester must already be a **user on the App Store Connect team** with the role Account
  Holder, Admin, App Manager, Developer or Marketing. Someone who is not on the team is added first
  under **Users and Access** — by Apple Account email — and only then appears in this list.
- Up to 100 internal testers per group, and each build stays testable for 90 days.

Internal testing needs **no Beta App Review**, which is the whole reason for staying internal.

**Enable automatic distribution** comes PRE-CHECKED in the create dialog, and the dialog warns the
choice is permanent — it cannot be changed after the group exists. Untick it BEFORE clicking
Create (as executed 2026-08-24: `household` was created with it off). With it off, every build is
added to the group by hand from the group's **Builds** tab — that manual add IS the distribution
step, and it is the same motion Xcode Cloud builds need regardless of the checkbox.

One role note from practice: **Customer Support has no TestFlight privilege** — a tester who only
needs TestFlight still gets at least the Marketing role under Users and Access.

---

## Part 2 — Xcode Cloud

### 7. Create the workflow **[me only]**

All of this happens **in Xcode on the build Mac**; there is no web path into it. Until a workflow
exists, App Store Connect's **Xcode Cloud** tab — both on the app and under **Users and Access** —
is a marketing page reading *"Create a workflow in Xcode to get started."* beside an **Open Xcode**
link, and `/ci/workflows/new` and `/ci/settings` fall back to that same page (observed 2026-08-25).
The promise of editing workflows and launching builds from the web holds only after onboarding.

In Xcode, with the project open (generate it first with `bin/generate.sh` — the `.xcodeproj` is not
committed):

That regeneration is load-bearing for the dependencies, not just for the project file:
`bin/generate.sh` restores the committed `Package.resolved` into the regenerated project, so an
archive taken after it links the same dependency graph the gate tested. Run it before every
archive. If **File ▸ Packages ▸ Update to Latest Package Versions** is ever used, the pins have
moved — re-record them from the project
(`cp MemosNG.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved Package.resolved`),
run the gate, and archive only once it is green. Never archive straight from an updated project.

1. **Report navigator** → the **Cloud** button → **Get Started**.
2. **Select a Product**: `MemosNG` → **Next**. If I am on more than one Apple Developer Program
   team, pick the team the app is going to be distributed from.
3. Xcode proposes a first workflow: build on every change to the default branch and on pull requests
   against it, latest macOS and Xcode, **archive** action, email on completion. Click **Edit
   Workflow** → **Start Conditions**, keep **Branch Changes** on `main` and delete **Pull Request
   Changes** — a build per pull request is noise for a one-person repository.
4. **Grant Access to Your Source Code** → **Grant Access**, then the GitHub authorisation. This
   authorises the Xcode Cloud GitHub App for the repository, which is an account-level action.
   Then **Next**, **Complete**.
5. Branch `main` → **Start Build**.

The first run is where the permissions land: authorising Xcode Cloud against the Git host, and
letting it use the Apple Developer team for signing. Both are one-time.

### 8. Add the TestFlight post-action **[me only]**

Apple's own guidance is to add the TestFlight distribution as a refinement after the first
successful build, not during setup. So once a build has gone green: edit the workflow → **Post
Actions** → add **TestFlight (Internal Testing Only)** → select the `household` group.

Distribution to internal testers is a post-action on the archive; there is no review queue in front
of it.

### 8b. Headless release with fastlane — the working path (2026-08-26)

Xcode Cloud (steps 7–8) still needs a one-time Xcode-GUI onboarding that has not happened. Until
then — and as the primary path — a release runs **entirely over SSH from the orchestrator**, no
GUI, no Mac login password:

    ssh merkur.local
    cd ~/projects/memos-ng-ios && git pull && ./bin/generate.sh
    set -a; source ~/.config/memosng-ci.env; set +a
    export PATH=/opt/homebrew/bin:$PATH DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fastlane beta

- **Auth** is an App Store Connect API key (`~/.appstoreconnect/private_keys/AuthKey_<id>.p8`, a
  team key with App Manager access) — no Apple ID, no 2FA.
- **Signing** runs in a dedicated `memosng-ci` keychain so `codesign` never needs the GUI login
  keychain, which is unreachable over SSH (`errSecInternalComponent`). The Distribution cert and
  its private key live in that keychain and in `fastlane/certs` (both git-ignored).
- **The IPA is assembled by hand.** Xcode 26.6's `-exportArchive` fails with an opaque
  `Copy failed` (the app copies fine with `ditto`), so `fastlane beta` archives with
  `skip_package_ipa`, zips the already-distribution-signed `.app` into `Payload/`, and uploads
  that via `upload_to_testflight`.
- **Distribution happens through the group attach, not by magic.** `household` was created with
  `hasAccessToAllBuilds` off and Apple's API refuses to enable it afterwards, so a processed build
  is INVISIBLE to testers until it is attached to the group. `fastlane beta` therefore waits for
  processing and performs the attach itself (never re-add `skip_waiting_for_build_processing` --
  it exits before the build exists in ASC and the attach silently never runs; and keep
  `submit_beta_review: false` -- the default posts an external-testing review submission that
  fails on this app and kills the lane between processing and the attach). There is still no
  review queue and no per-tester step; the export-compliance key in `project.yml` keeps the
  compliance prompt away.
- **The lane proves the attach instead of assuming it.** `upload_to_testflight` exits 0 on its own
  success, which is not the same thing as the household being able to see the build — 1.0.2 (8) and
  1.0.3 (9) were both found processed-but-unattached by hand, days later. So `fastlane beta` ends
  with an App Store Connect read-back, also runnable on its own as
  `fastlane verify_attach version:<marketing> build:<n>`, asserting three separate things: the
  build's `processingState` is `VALID`; the `household` group itself lists the build (the group
  side of the relationship — that is the direction a tester's TestFlight reads); and its
  `buildBetaDetail.internalBuildState` is `IN_BETA_TESTING`, polling for up to 5 minutes while it
  is still the transient `READY_FOR_BETA_TESTING`. Anything else fails the lane and names the state
  it saw. The verdict is a pure function in `fastlane/lib/asc_readback.rb` so each of those
  assertions is unit-tested without talking to Apple:
  `ruby -Ifastlane/lib fastlane/test/asc_readback_test.rb`.
- **The "What to Test" text comes from a tracked file.** `fastlane/TESTFLIGHT_NOTES.md` holds one
  `## <marketing> (<build>)` section per build, newest first, and `fastlane beta` passes the
  section matching the numbers read off the archive as `upload_to_testflight`'s `changelog:`. The
  lane asks for it right after the archive, before the dSYM copy and the upload, and refuses when
  the section is missing, empty, duplicated or longer than TestFlight's 4000 characters — a blank
  changelog is the defect this closes, so it is never the fallback. So the section has to be on the
  checkout before `fastlane beta` runs, one line per point (TestFlight shows plain text), in the
  first person singular and with no ticket keys or internal host names: testers read it. Check it
  before archiving with `fastlane testflight_notes version:<marketing> build:<n>`, which prints the
  text `beta` would send and uploads nothing. The derivation is `fastlane/lib/release_notes.rb`,
  tested by `ruby -Ifastlane/lib fastlane/test/release_notes_test.rb`.
- **The cut's guards are one tested module.** `fastlane/lib/cut_guard.rb` takes every decision that
  keeps a cut from building the wrong commit or spending a number twice — provenance, the claim,
  the archive's pair against the claimed pair, and `prove_unused`'s "prove only on no such build" —
  and `archive_ipa`, `prove_unused` and `beta` call it as their first statement, handing it the
  archive and the upload as callables it reaches only after every check has passed. Its refusal
  ends in `CUT-GUARD-VERDICT=<verdict>`. Tested, with each refusal shown to stop before the archive
  and the upload: `ruby -Ifastlane/lib fastlane/test/cut_guard_test.rb` (minitest; on a machine
  without Ruby, a throwaway `micromamba create -p <scratch>/ruby -c conda-forge ruby` provides one).

Secrets live only on merkur: `~/.config/memosng-ci.env` (0600, holds the key id / issuer / `.p8`
path / CI keychain password) and the `.p8` itself (0600). Nothing signing-related is committed.

**Crash symbols.** `fastlane beta` copies the archive's `dSYMs/` to the NAS the moment the archive
exists, into `janus:/memos-ng-ios/dSYMs/<marketing>-<build>/` (`/Users/Shared/nas/janus/…` as merkur
sees it), and prints every bundle's `dwarfdump --uuid` line. Off-host on purpose: `build/` is reaped
for disk and merkur's disk is a single point of failure. `/Volumes/lexosaurus` is the fallback and
announces itself with a loud `WARN`; when neither store is reachable the lane FAILS rather than
skipping, because a silent skip is how **builds 7, 8 and 9 shipped with no preserved symbols at
all** — nothing copied them and nothing complained, so their crash reports could never be
symbolicated. 7 was recovered afterwards from a surviving local archive; 8 and 9 are gone for good.
Standalone: `fastlane preserve_dsyms archive:<path> [version:<v> build:<n>]`, where the numbers
default to what the archive's own `Info.plist` carries.

### 8c. Lane cut — `bin/testflight-cut.sh` (2026-10-07)

A work-package lane cuts its milestone's TestFlight build itself, from its own Linux clone, with
no orchestrator session and without touching the hands-on clone on the Mac. Both variables are
required on both commands (neither has a default; `env … bin/mac-gate.sh` exports nothing back):

    env MAC_GATE_HOST=merkur MAC_GATE_ESTATE_LOCK=/home/fabian/projects/worktrees/.wp13-gate.lock bin/testflight-cut.sh --archive-only
    env MAC_GATE_HOST=merkur MAC_GATE_ESTATE_LOCK=/home/fabian/projects/worktrees/.wp13-gate.lock bin/testflight-cut.sh

- **Preconditions (local).** A clean tree whose HEAD equals `origin/main` after a fetch. `--sha
  <40-hex>` replaces that with "HEAD is this sha" — it authorises the checked-out commit, it never
  selects another. Every refusal ends `state=REFUSED(<reason>) … | exit=2` with nothing pushed.
- **Paths on the Mac.** `/Users/fabian/build/memos-ng-ios/release/repo.git` — a bare repo that
  takes each commit as the create-only ref `refs/cuts/<sha>` (its `update` hook refuses a rewrite
  or a delete of `refs/cuts/*`; `receive.denyDeletes`); `release/work` — the release checkout the
  commit is checked out in, detached, and regenerated (`bin/generate.sh`). Nothing else on the Mac
  is written, and the hands-on clone `~/projects/memos-ng-ios` is never read or written.
- **What runs there** (`bin/testflight-cut-remote.sh`, one ssh call): fetch and detached checkout,
  HEAD = sha and a clean tree, the 3 GiB floor on the volume holding `release/work`, the version
  pair read from that commit's `project.yml`, `~/.config/memosng-ci.env` sourced silently, then
  `fastlane prove_unused version:<v> build:<b>` → `fastlane beta expected_sha:<sha>` →
  `fastlane verify_attach version:<v> build:<b>`. A `prove_unused` refusal ends the run before
  anything is archived: `state=REFUSED(build-number-spent) … | exit=20` only when the lane's
  verdict is `spent` (the number is claimed already, or App Store Connect holds it), and
  `state=REFUSED(unused-unproven) … | exit=21` for any other failure (App Store Connect could not
  be read, no such app, the markers' lock) — the number may still be free; nothing was proved. `--archive-only` runs `fastlane archive_ipa expected_sha:<sha>` alone:
  no proof, no claim, no upload — the dry run every first cut of a new setup starts with.
- **Provenance.** `archive_ipa` and `beta` both run `CutGuard.provenance!` first whenever they are
  given `expected_sha:` — the release checkout must be clean and at exactly that commit. The
  owner's train (`scripts/release/cut-*`) passes no sha and is not affected.
- **One build number, one upload, across both trains.** `fastlane prove_unused` (used by this cut
  and by `cut-0-unused.sh`) writes `~/.memosng-cut/unused-<v>-<b>` only on App Store Connect's
  "no such build", and `fastlane beta` claims it first thing — after provenance, before any
  archive — by renaming it to `spent-<v>-<b>-<utc>`, refusing with `no unspent proof` without one.
  Both go through `scripts/release/cut-markers.sh`, whose one lock (`flock` on
  `~/.memosng-cut/.lock`, Homebrew's `/opt/homebrew/bin/flock` on the Mac) makes a claim landing
  between a proof's query and its write win: the write refuses. A spent number is never proved
  again by any script; a failed upload's number is released only by the owner removing its
  `spent-*` marker by hand. A `fastlane beta` run by hand therefore needs `fastlane prove_unused`
  for the same pair first.
- **The three locks, outermost first.** (1) The estate gate lock `MAC_GATE_ESTATE_LOCK`, taken on
  the Linux side before the push and released after the Mac half has reported (logged
  `cut lock: waited <s> s`, ceiling `MEMOS_CUT_LOCK_WAIT_S`, default 21600 s). When the ssh leg
  ends with ssh's 255 or without the Mac half's report line, the Mac may still be cutting: the lock
  stays held until D + G + skew (see **Timing**), logged `cut lock: holding until <utc> (remote
  outcome unknown)`, and the run ends `state=UNKNOWN(ssh-lost)` with ssh's code (1 for 0). Nothing
  asks the Mac again; read `release/work`'s state and App Store Connect before cutting again. A cut, every
  lane's gate, another lane's cut and a build-root cutover window exclude each other. The cut
  runs no gate, so this is not a lock wrapped around one. (2) The release checkout's own lock
  `release/.cut.lock`, taken on the Mac inside the budget. (3) The estate-wide release lock
  `~/.release-lock`, taken by the Fastfile itself around signing and the archive, shared with the
  other apps' pipelines. The markers' lock is separate and held for milliseconds only.
- **Budget.** `MEMOS_CUT_TIMEOUT_MIN` (default 120) bounds the Mac half, its lock wait included;
  past it the cut's process group is stopped and the run reports `TIMEOUT` (the Mac half's own
  `stage=budget` report; a release-checkout lock still held at the deadline reports `stage=lock`,
  `LOCK-TIMEOUT`). 120 is a placeholder
  until the first `--archive-only` run is timed; that measurement goes here.
- **Timing.** ONE absolute deadline, `D` = the start of the ssh leg + the budget (UTC epoch
  seconds), is computed on the Linux side and passed to the Mac half, so a late start (script
  delivery, a slow login) shortens the cut instead of moving its end. The constants live in one
  place, the top of `bin/testflight-cut.sh`, and travel to the Mac half as arguments:

  | constant | value | meaning |
  |---|---|---|
  | `CUT_MIN_WINDOW_S` | 300 s | the Mac half refuses to start (`REMOTE-REFUSED`, exit 3) unless more than this is left before `D`: checkout, generate and the proof alone take minutes |
  | `CUT_STOP_GRACE_S` | 60 s | the cut's process group gets TERM at `D` and KILL at `D` + 60 |
  | `CUT_REAP_S` | 10 s | the killed group is waited for until `D` + 70 at most; `G` = 70 s |
  | `CUT_CLOCK_SKEW_S` | 120 s | both hosts are NTP-synced; the most their clocks may disagree |
  | (polling) | ≤ 1 s | the wrapper notices `D` within one 0.5 s poll and reaps in 0.2 s steps; the TERM is dated `D` itself, so polling never moves the KILL or the reap's end, and the rest fits inside the skew allowance |

  The wrapper checks `D` once more after it holds the checkout lock and before it launches
  anything: past `D` it launches nothing and reports `stage=expired`, exit 76,
  `state=REFUSED(deadline-passed)`. A signal to the wrapper never moves the stop past `D`.
  Everything of the cut is gone by `D + G` on the Mac's clock, so after an unknown outcome the
  estate lock is held until `D + G + skew` = `D` + 190 s on this host's. The outer `timeout` around
  the ssh leg is a backstop only and ends 60 s after that. `MEMOS_CUT_TEST_TIMING="<budget_s>
  <grace_s> <reap_s> <skew_s> <min_window_s>"` replaces all five for the selftest only; a real cut
  never sets it.
- **The last line is the verdict:**

      testflight-cut SUMMARY: version=<v> build=<n> sha=<40> state=<state> group=<group> | exit=<rc>

  `state` is `VALID` (uploaded, and the read-back found it valid, attached to the group and in
  testing), `archive-only`, `FAILED`, `TIMEOUT`, `LOCK-TIMEOUT` (the release checkout's lock),
  `ESTATE-LOCK-TIMEOUT`, `REMOTE-REFUSED`, `REFUSED(deadline-passed)`, `PUSH-FAILED`, `NO-REPORT` (exit 0 without the report of
  a finished lane), `UNKNOWN(ssh-lost)` or `REFUSED(<reason>)`. Only `| exit=0` with `VALID` (or `archive-only` for the dry run) is a cut.
- **Tests.** `tests/gate/testflight-cut-test.sh` (a named gate selftest: the local half on real
  git repositories with a fake ssh that probes the estate lock, the Mac half's body against a
  throwaway release root, and the Fastfile's wiring: each lane's first statement hands it to
  `CutGuard`), `fastlane/test/cut_guard_test.rb` (the guards themselves), `fastlane/test/cut_wrapper_test.rb` (the Mac
  half's real lock-and-deadline wrapper, read out of the script and run: `ruby
  fastlane/test/cut_wrapper_test.rb`), `tests/gate/cut-markers-test.sh` (the proof
  and claim, the replayed race, two concurrent claims, the lock ceiling) and
  `tests/gate/cut-scripts-test.sh` (the owner's train).

---

## Part 3 — the build number

A local archive needs the number bumped by hand; an Xcode Cloud build does not. Both halves are
written down because this is the thing most likely to look wrong.

Which numbers to set, when they move and what the gate enforces is [`RELEASING.md`](RELEASING.md)'s
job — the semver scheme, the build counter, the annotated tag. Read the numbers there and in
`project.yml`, never off this page. What is left here is how App Store Connect and Xcode Cloud
consume the number: a local archive is uploaded under exactly the value in `project.yml`, and App
Store Connect refuses a number it already holds — an upload spends its number whether or not the
build is ever distributed.

Verified from Apple's documentation:

- Xcode Cloud assigns each build its own build number, starting at `1` and increasing by one per
  build, and the next value can be changed in App Store Connect → the app → **Xcode Cloud** tab →
  **Settings** → **Build Number** (Admin or App Manager only). That pane does not exist before the
  product is onboarded from Xcode: until then the tab is the marketing page described in step 7
  (observed 2026-08-25).
- That number is exposed to custom build scripts as `CI_BUILD_NUMBER` — "The number of the current
  build, for example, `42`" — alongside the rest of the `CI_*` environment.
- Custom build scripts live in a `ci_scripts` directory beside the project, named
  `ci_post_clone.sh`, `ci_pre_xcodebuild.sh` and `ci_post_xcodebuild.sh`.

Not verified: Apple's documentation, on the pages I read, does not state in so many words that
Xcode Cloud stamps `CFBundleVersion` in the archive from its own build number. The circumstantial
case is strong — the "next build number" setting exists to avoid *version collisions*, which only
occur if the number reaches App Store Connect — and that is the behaviour developers report. But I
have not confirmed it against a document or a build.

So `CURRENT_PROJECT_VERSION` is only load-bearing for an archive made **locally**, in Xcode. Under
Xcode Cloud the value is expected to be ignored in favour of the assigned build number, which is
why nothing here depends on it being right. The durable fix, if a duplicate build number is ever
rejected there, is still a `ci_scripts/ci_pre_xcodebuild.sh` that writes `$CI_BUILD_NUMBER` into the
version before `xcodebuild` runs, so that no hand edit is needed at all.

---

## Part 4 — what a tester sees

1. The build appears under **TestFlight** → the `household` group, after processing.
2. Export compliance is not asked: both bundles answer it already.
3. Each tester gets an email, installs Apple's **TestFlight** app, accepts, and installs from there.
4. Signing in is the normal sign-in against `https://memos.discomarder.live` — but the **first**
   attempt fails. Nothing in the app touches the network before it, so iOS raises the **Local
   Network** prompt on the sign-in's own exchange call, possibly just as the sign-on sheet closes,
   and denies that connection whatever the answer is: the error reads *"The Internet connection
   appears to be offline."*
5. Allow **Local Network** (if the prompt was missed: Settings → Apps → memosng → Local Network),
   then tap **Sign in** again. That attempt completes. The permission is needed because the server
   resolves to a private address on the household network.

---

## Before starting any of this

Run the gate. It is what proves the bundles carry what this document claims they carry:

    MAC_GATE_HOST=<the Mac build host> bin/mac-gate.sh

The `bundle` step opens the built `.app` and the embedded `.appex` and checks each one's
`PrivacyInfo.xcprivacy`, version keys and export-compliance answer. A summary line ending in
`| exit=0` is the only green.

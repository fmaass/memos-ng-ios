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
| Required-reason API declared | file timestamps, reason `C617.1`, in both bundles |

The privacy manifests are `Support/MemosNG/PrivacyInfo.xcprivacy` and
`Support/MemosShare/PrivacyInfo.xcprivacy`. Each declares one required-reason API category —
`NSPrivacyAccessedAPICategoryFileTimestamp` with reason `C617.1` — because both the picker path and
the share path read the modification date of a file they have just copied into their own container.
Nothing else in the app touches a required-reason API: there is no `UserDefaults` anywhere, nothing
reads volume capacity, nothing asks for system uptime, and nothing enumerates keyboards. The gate
reads both shipping bundles back and fails if either manifest is missing or says something else.

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

Secrets live only on merkur: `~/.config/memosng-ci.env` (0600, holds the key id / issuer / `.p8`
path / CI keychain password) and the `.p8` itself (0600). Nothing signing-related is committed.

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

# Getting this app onto my phone through TestFlight

Everything the repository can decide has been decided. What is left is the half that only a
signed-in human can do: agreements, an app record, an internal tester group, and one Xcode Cloud
workflow. That is roughly ten minutes of clicking, once.

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
| Version (`CFBundleShortVersionString`) | `0.1.0` |
| Build number (`CFBundleVersion`) | `1` in the repo — Xcode Cloud numbers its own builds |
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

App Store Connect → the app → **App Information** → **Privacy Policy URL**:

    https://memos.discomarder.live/privacy

That page is being built alongside this. The field is required for an App Store submission and for
external TestFlight testing; I have not confirmed whether App Store Connect enforces it for an
internal-only group, so fill it in and the question does not arise.

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

Leave **Enable automatic distribution** off, or at least do not rely on it: builds that come from
Xcode Cloud must be added to a group by hand regardless of that checkbox.

---

## Part 2 — Xcode Cloud

### 7. Create the workflow **[me only]**

In Xcode, with the project open (generate it first with `bin/generate.sh` — the `.xcodeproj` is not
committed):

1. **Report navigator** → the **Cloud** button → **Get Started**.
2. **Select a Product**: `MemosNG`. If I am on more than one Apple Developer Program team, pick the
   team the app is going to be distributed from.
3. Xcode proposes a first workflow: build on every change to the default branch and on pull requests
   against it, latest macOS and Xcode, **archive** action, email on completion. Click **Edit
   Workflow** and narrow the start condition to the default branch — a build per pull request is
   noise for a one-person repository.
4. **Grant Access to Your Source Code** → **Grant Access**, then follow the Git host's
   authorisation, **Next**, **Complete**.
5. Pick the branch and **Start Build**.

The first run is where the permissions land: authorising Xcode Cloud against the Git host, and
letting it use the Apple Developer team for signing. Both are one-time.

### 8. Add the TestFlight post-action **[me only]**

Apple's own guidance is to add the TestFlight distribution as a refinement after the first
successful build, not during setup. So once a build has gone green: edit the workflow → **Post
Actions** → add **TestFlight (Internal Testing Only)** → select the `household` group.

Distribution to internal testers is a post-action on the archive; there is no review queue in front
of it.

---

## Part 3 — the build number

Nothing needs doing here. It is written down because it is the thing most likely to look wrong.

Verified from Apple's documentation:

- Xcode Cloud assigns each build its own build number, starting at `1` and increasing by one per
  build, and the next value can be changed in App Store Connect → the app → **Xcode Cloud** tab →
  **Settings** → **Build Number** (Admin or App Manager only).
- That number is exposed to custom build scripts as `CI_BUILD_NUMBER` — "The number of the current
  build, for example, `42`" — alongside the rest of the `CI_*` environment.
- Custom build scripts live in a `ci_scripts` directory beside the project, named
  `ci_post_clone.sh`, `ci_pre_xcodebuild.sh` and `ci_post_xcodebuild.sh`.

Not verified: Apple's documentation, on the pages I read, does not state in so many words that
Xcode Cloud stamps `CFBundleVersion` in the archive from its own build number. The circumstantial
case is strong — the "next build number" setting exists to avoid *version collisions*, which only
occur if the number reaches App Store Connect — and that is the behaviour developers report. But I
have not confirmed it against a document or a build.

So: `CURRENT_PROJECT_VERSION` stays `1` in `project.yml` and is not bumped by hand. If a TestFlight
upload is ever rejected for a duplicate build number, the fix is a `ci_scripts/ci_pre_xcodebuild.sh`
that writes `$CI_BUILD_NUMBER` into the version before `xcodebuild` runs — not an edit to the
repository's `1`.

`MARKETING_VERSION` is `0.1.0` on both targets and is bumped deliberately, by hand, when there is
something to call a new version.

---

## Part 4 — what the first tester sees

1. The build appears under **TestFlight** → the `household` group, after processing.
2. Export compliance is not asked: both bundles answer it already.
3. Each tester gets an email, installs Apple's **TestFlight** app, accepts, and installs from there.
4. On first launch the app asks for **Local Network** access — the server resolves to a private
   address on the household network, and iOS will silently fail every request until that is allowed.
5. Signing in is the normal sign-in against `https://memos.discomarder.live`.

---

## Before starting any of this

Run the gate. It is what proves the bundles carry what this document claims they carry:

    MAC_GATE_HOST=<the Mac build host> bin/mac-gate.sh

The `bundle` step opens the built `.app` and the embedded `.appex` and checks each one's
`PrivacyInfo.xcprivacy`, version keys and export-compliance answer. A summary line ending in
`| exit=0` is the only green.

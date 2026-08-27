# Releasing MemosNG

Version authority mirrors the backend's: the numbers live in `project.yml` (`MARKETING_VERSION`
+ `CURRENT_PROJECT_VERSION`, identical on BOTH targets — the extension carries the app's build
number), the generated project inherits them, and the gate enforces agreement.

## The scheme

- **MARKETING_VERSION** is semver. Patch for fixes, minor for features, major for a break in
  what the household relies on. `1.0.0` is the first release the household verified working
  (2026-08-25); everything before it shipped as `0.1.0` builds 1–4.
- **CURRENT_PROJECT_VERSION** increments by exactly one for EVERY archive that is uploaded,
  monotonically forever — never reset per version train, never reused. App Store Connect
  consumes a build number on upload whatever happens afterwards.
- Every marketing release gets an **annotated tag** `v<MARKETING_VERSION>` on the exact commit
  the shipped archive was built from, with an annotation naming the build number and what the
  release is. Tag AFTER the build is verified on a device, not at upload.

## The ritual

1. Bump the numbers in `project.yml` on the release branch (build +1 always; marketing per the
   scheme). The gate refuses numbers that do not advance past the latest `v*` tag.
2. Merge; on merkur: `git pull && ./bin/generate.sh`, then Any iOS Device → Product → Archive →
   Distribute → Upload. Auto-distribution is off: attach the build to the `household` group in
   App Store Connect (or let the observed auto-attach do it, but verify).
   The headless path for this step is `fastlane beta` ([`TESTFLIGHT.md`](TESTFLIGHT.md) §8b): it
   preserves the archive's dSYMs to `janus:/memos-ng-ios/dSYMs/<marketing>-<build>/` before
   anything reaps `build/`, and it ends by reading App Store Connect back to prove the build is
   attached to the `household` group — so "uploaded" cannot be mistaken for "the household can see
   it". Both are verifiable on their own afterwards with `fastlane verify_attach version:<v>
   build:<n>` and `fastlane preserve_dsyms archive:<path>`.
3. Verify on a device — sign-in included on a fresh install.
4. Tag: `git tag -a v<version> -m "<version> (build <n>): <one line on what shipped>"` on the
   merged commit, `git push origin v<version>`.

The gate's version step reads the latest `v*` tag and fails when `MARKETING_VERSION` is below
the tagged version or `CURRENT_PROJECT_VERSION` is not strictly greater than the tagged build —
so a forgotten bump is caught before a wasted archive, and a spent number cannot ship twice.

# Build-root mount guard

Moved verbatim from CLAUDE.md § The gate is the only build authority on 2026-10-16.

**The build root must be the build host's own image (MEMNG-602).** A full or quick run's first contact
with the build host is the `--- step: mount ---`, after the classification and before the
preflight's first write: it pipes `scripts/gate-mount-guard.sh` from the run's private copy (it is
one of `GATE_RUN_HELPERS`) to `ssh bash -s` and asks `gate_mount_guard report memos-ng-ios/gate
memos-ng-ios/work CoreSimulator/Devices @devroot`, under `timeout 30`. The `@devroot` token (ARCH-1262)
adds term (f): `$HOME/Library/Developer/CoreSimulator/Devices` must be a symlink resolving to exactly
`<root>/CoreSimulator/Devices`, itself a proved subtree, else `MOUNT REFUSE host=<h> device root …`,
rc 16; the mount wrapper's inventory and both of its predicate calls carry the same. The guard first picks its profile by a PAIR read on the host — its
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

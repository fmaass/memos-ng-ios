# Run admission and the host-wide simulator slot

Moved verbatim from CLAUDE.md § The gate is the only build authority on 2026-10-16.

**One simulator phase at a time on the build host, admitted by condition.** Before anything is
copied, run admission (`bin/mac-gate.sh:1129`, `scripts/gate-admission.sh:786`) requires the host's
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
(`scripts/gate-admission.sh:646`) holds until the slot is free AND free space ≥ 8 GiB, memory free
≥ 20 %, load ≤ 24 and no booted device named `gate-*`, `mac-gate-iphone-*` or `mac-gate-ipad-*`
other than the holder's; each wait logs who holds the slot and which term failed, and the ceiling
refuses with exit 11 (12 when free space is the only failing term). Swap in use is on every wait
line (`swap_used=`) and is never a term: the host idles at about 6 GiB of swap held by long-lived
desktop applications, so a swap bound would hold every run to its ceiling. A
holder is recovered only when its pid is gone, no process of its process group lives, and its
devices are confirmed deleted under the reap mutex, the holder's token re-checked twice
(`:248`, `:466`); a live holder is never taken, and one whose pid is gone but whose group lives is
logged `ORPHAN-HOLDER` and waited for. The run's own release comes before the build host's summary,
checked (`scripts/gate-admission.sh:435`); the EXIT, INT, TERM and HUP traps repeat it
(`bin/mac-gate.sh:1277-1280`) and a PIPE trap moves output to a file so a dropped ssh still ends
in that release (`:1283`). Its handler writes one line into that file at once
(`scripts/gate-admission.sh:829`): bash 3.2 keeps a failed write's bytes buffered, and every later
`$(…)` would carry them into its value — the release then misread its own token and kept the slot
(2026-09-30). A run whose ssh went away before it claimed the slot stops waiting with `slot=14`
(`:661`), rather than testing, hours later, for a controller that is gone. Two residuals are stated, not
closed: it detects a broken output connection, not a dead controller, so an orphaned ssh client
that keeps draining output is not caught; and a drop is noticed only at the remote's next write,
so a waiter can claim the slot before its first failed write (the `slot-claimed` line, `:405`).
Neither can make two holders or release live work. A release that cannot confirm the run's processes and devices gone keeps
the slot, marked `state=cleanup-failed`, and reports `simrelease=1`; the next waiter's recovery
retries it. Two states need a human, and the log line names the step: `REAP-DEAD`
(`scripts/gate-admission.sh:507`) — a recoverer died holding the reap mutex, so recovery stays
blocked until its pid is confirmed gone and `ssh merkur rm -rf ~/build/.gate-slots/reap` clears it;
`DEVICE-STUCK` (`:299`, `:317`) — three deletes could not remove the run's device (or a shared one
will not shut down), the slot stays fenced, and once nothing of that run is alive the one udid the
line names is deleted with `xcrun simctl delete <udid>` — never a fleet-wide `simctl` operation.
One recovery state needs no human: `HOLDERLESS-DEVICE` (`scripts/gate-admission.sh:604`) — a
Booted gate device that no slot record names, left by a run cut off with its build host (2026-10-19:
one held its lane's next runs 2460 s and more on `unowned-gate-device=`). The hex suffix of a gate
device's name is the run token (`gate-<branch>-<token>`, `bin/mac-gate.sh:1060`), and nothing on the
host ties a token to a live process, so the run leaves a record of itself beside the slot,
`~/build/.gate-slots/run.<token>` — a copy of its slot record (pid, start time, process group, host,
device names) written when it names its device (`:532`) and kept past its release. The waiter
deletes that one udid under the reap mutex (`:568`) only when the name is `gate-*-<token>` carrying
the record's own token, the record names it and is not a shared hold's, its run is stale by the
holder judgment (`:248`), and — all read again under the mutex — the record is still stale, no slot
record names the device, and that udid is still Booted under that name; deletion is confirmed by
re-listing, and one that will not go is `DEVICE-STUCK` (`:620`). A device with no record, an
unreadable one or an unjudgeable run is unmeasured and left alone, as is a live or orphaned run's, a
shared device and every `mac-gate-iphone-*`/`mac-gate-ipad-*` device; such a device is still the
human step above. Admission drops a record once its run is stale and no device of its names is
listed (`:626`).
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

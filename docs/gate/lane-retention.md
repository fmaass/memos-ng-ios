# Build-host lanes and retention sweeps

Moved verbatim from CLAUDE.md § The gate is the only build authority on 2026-10-16.

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

# Run logs, private script copy and the estate ledger

Moved verbatim from CLAUDE.md § The gate is the only build authority on 2026-10-16.

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

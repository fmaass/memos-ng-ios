# Per-bundle test-count baseline

Moved verbatim from CLAUDE.md § The gate is the only build authority on 2026-10-16.

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

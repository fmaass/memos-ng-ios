# Quick mode, iterations and the mutants realness loop

Moved verbatim from CLAUDE.md § The gate is the only build authority on 2026-10-16.

Iteration uses the quick mode and the merge verdict is the full gate: `bin/mac-gate.sh --quick
[--bundle <name>|--only-testing <id>]` runs the selftests the change set owes (all of them when it
touches a path `config/gate-paths.txt` lists, else the classifier's alone — see
`docs/gate/preflight-and-fastpath.md`), the release-version check, the
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

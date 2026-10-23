# Local lint, classifier selftest and the docs-only fast path

Moved verbatim from CLAUDE.md § The gate is the only build authority on 2026-10-16.

Three steps run before any of that, on the machine you are working from. The first is the local
lint (`scripts/local-lint.sh`, MEMNG-807): the same `swift format lint --strict --recursive .` over
the caller's repository root, in the bootstrap, before the estate lock is even requested and so
before the lane lock — a formatting error used to wait out the whole queue only to fail the build
host's first step. It takes a native `swift format` on PATH first, then the docker image
`swift:6.3` when it is already on the machine (`docker run --rm --pull never --network none -v
<tree>:/src:ro`, never pulled); every one of its calls, the version probes included, is bounded by
`timeout -k 10`, which sends KILL ten seconds after a TERM that was ignored; either must report
the build host's major, and neither is ever asked to rewrite. A failure refuses the run there with
the lint's own exit code, 1: no estate lock taken, no ssh, no test-count candidate cleared, the
lint's lines and its verdict in the run log, `locallint=1` on the summary (or the quick line) and
`mode=refused` in the run ledger. No such tool — the pfadfinder-lane
container has neither — falls through to the build host's lint alone and says why in the log, as
does a tool that ended without a verdict (any code but 0 or 1); the field is then `locallint=-`.
Both lines carry `locallint=` just before `| exit=`; the quick line's `lint=` is still the build
host's. A run's output is what it was plus the bootstrap's start notice (`mac-gate: linting …
before the estate lock is requested`), the `--- step: locallint ---` heading with the lint's
lines, its verdict and status lines, and the build host's version line. It runs on the docs-only
fast path too (a clean tree lints in about a minute), and never
on `--help`, `--classify-only` or a run without `MAC_GATE_HOST`. Its verdict line,
`MAC_GATE_LOCALLINT rc=… local=… version=… mac=…`, names the local swift-format and the build
host's as pinned in the script (6.3.0, read 2026-10-13); the build host's own lint step prints
`MAC_GATE_SWIFTFORMAT version=…`, so one run log holds both for comparison. An implementer that
cannot build can still lint, with the docker form from the worktree root — `docker run --rm -v
"$PWD":/src:ro -w /src swift:6.3 swift format lint --strict --recursive .` — so no review round
reaches the Mac with a formatting error. Its selftests are `tests/gate/local-lint-test.sh` (the
helper against fake tools, and the real image where it is present) and
`tests/gate/local-lint-refusal-path-test.sh` (the refusal before the estate lock, while another
process holds it); both are named selftests. The second step is the classifier test
(`tests/gate/fastpath-classify-test.sh`), which checks the gate's own docs-only classifier against
throwaway repositories it builds itself — it is the gate's integrity check and runs on every gate.
The gate's other suites under `tests/gate/` check the gate's own machinery, so a run owes them only
when its change set touches it (MEMNG-892): `config/gate-paths.txt` lists that machinery, one glob
per line matched against the whole repository-relative path (`*` crosses `/`; `#` starts a comment),
and `gate_selftest_scope` in `bin/mac-gate.sh` reads only that file. It enumerates the change set on
its own — the branch's diff from the `origin/main` already on disk, every path any commit in that
range names (so a stale `origin/main` only enlarges the set: a branch that reverts a newer main's
gate change still names the script), the working tree's edits and the untracked files — rather than
borrowing the classifier's, and the classifier's suite,
which also holds the decision's cases, is never skipped; so a change to either cannot talk the gate
out of the suite that checks it. A run that touches no listed path logs one line,
`MAC_GATE_SELFTEST skipped: no path listed in config/gate-paths.txt changed — …`, and its summary
reads `selftest=skip`; a run that touches one logs `MAC_GATE_SELFTEST run: <path> matches <glob> in
config/gate-paths.txt` for every such path and runs them all. Every way of not knowing runs them
too, each with its reason on the `run:` line: `main` or `master`, no merge-base, a git command that
fails, an assume-unchanged or skip-worktree entry, a path git had to quote, and a config that cannot
be read or lists nothing. The named suites must exist and be executable on every run, skipping or
not, and `classification.txt` carries the decision on its `selftest:` line. A docs-only change set
normally lists no gate path, so its fast path runs the classifier's suite alone; the quick mode
takes the same decision as the full gate.
Then the change set is classified: what this branch changed against `origin/main` (merge-base,
renames not followed, so a rename is judged by both of its names) plus everything staged, edited or
untracked in the working tree. When every one of those paths is documentation or repository
metadata — `docs/`, any `.md`, `.gitignore`, `.gitattributes`, `.editorconfig`, `CODEOWNERS`,
`LICENSE` — and none of them is a symbolic link, the gate reports `PASS (fast path: docs-only)`,
names every changed path and the base it measured from, and copies nothing to the build host.
Anything else meets the full gate: `project.yml`, every manifest, xcconfig, entitlement and plist,
every source file, this script and its own tests. A package's bundled resource
(`Packages/*/Sources/*/Resources/*`) is never docs-only, whatever its extension, so a change to the
release notes alone meets the full gate and its `notes` step. The release-version check runs on both paths, so
a version bump can never take the fast path. Every run writes what it classified to
`.gate-artifacts/classification.txt`, fast path or not. `bin/mac-gate.sh --classify-only` prints
that classification and stops, without needing a build host.

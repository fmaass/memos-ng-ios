#!/usr/bin/env bash
#
# The gate's own integrity check: what `bin/mac-gate.sh --classify-only` calls a docs-only change.
#
# The fast path is the one place where the gate is allowed to say PASS without building anything,
# so the classifier that decides it is the one piece of the gate that cannot be checked by the
# gate's own build. It is checked here instead, against throwaway repositories this script builds:
# each case is a repository whose whole history and working tree exist to ask the classifier one
# question. A case that expects `full` is not decoration — every one of them is a way the fast
# path could have shipped an unbuilt change (a rename out of a source file, a symlink wearing a
# .md name, an edit sitting unstaged in the tree).
#
# Part 2 holds the decision of which of the gate's other suites a run owes (config/gate-paths.txt,
# MEMNG-892), as whole gate runs that reach the selftest step on stubs and stop at the fast path.
#
# Run it directly (`tests/gate/fastpath-classify-test.sh`) or let the gate run it: it is the
# gate's first step, on every run, fast path or not. MAC_GATE_SCRIPT points it at another copy of
# the gate (used to prove it red).
#
# Exit: 0 = every case classified as expected; 1 = at least one did not (the failures are named).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
GATE="${MAC_GATE_SCRIPT:-$repo_root/bin/mac-gate.sh}"
[ -x "$GATE" ] || { echo "FAIL: $GATE is not an executable file"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-fastpath-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

fails=0
cases=0
fastpath_seen=0

# A repository with an origin whose main holds the baseline the classifier measures against.
# Everything the classifier can look at is here: a docs tree, a couple of markdown files at the
# root, the version file, and source under both of the layouts this repo builds from.
new_repo() {
  local name="$1" work="$tmp/$1" origin="$tmp/$1.git"
  git init --quiet --bare "$origin" || return 1
  git init --quiet -b main "$work" || return 1
  git -C "$work" config user.email gate-test@example.invalid
  git -C "$work" config user.name "gate test"
  git -C "$work" config commit.gpgsign false
  git -C "$work" config core.hooksPath "$tmp/no-hooks"
  mkdir -p "$work/docs" "$work/Sources" "$work/Packages/MemosCore/Sources/MemosCore"
  printf 'a guide\n' > "$work/docs/guide.md"
  printf 'the readme\n' > "$work/README.md"
  printf 'MARKETING_VERSION: "1.0.0"\n' > "$work/project.yml"
  printf 'let app = 1\n' > "$work/Sources/App.swift"
  printf 'let old = 1\n' > "$work/Sources/Foo.swift"
  printf 'let core = 1\n' > "$work/Packages/MemosCore/Sources/MemosCore/Core.swift"
  git -C "$work" add -A >/dev/null || return 1
  git -C "$work" commit --quiet -m "baseline" || return 1
  git -C "$work" remote add origin "$origin"
  git -C "$work" push --quiet origin main || return 1
  printf '%s' "$work"
}

# The classifier is asked the way the gate asks it, from inside the repository under test and with
# no build host in the environment: a classification that needed a Mac to answer would not be a
# classification, it would be the gate.
classify() {
  local work="$1"
  local -a env_args=(-u MAC_GATE_HOST -u MAC_GATE_BRANCH)
  # A case that needs a git which fails puts a stub ahead of the real one; everything else runs
  # with the PATH this suite was started with.
  [ -z "$CLASSIFY_STUB_PATH" ] || env_args+=("PATH=$CLASSIFY_STUB_PATH:$PATH")
  OUT="$(cd "$work" && env "${env_args[@]}" "$GATE" --classify-only 2>&1)"
  RC=$?
}
CLASSIFY_STUB_PATH=""

# 0 = fast path, 10 = full gate. The exit code and the printed verdict have to agree: the gate
# reads the code, a human reads the line, and a disagreement between them is how a fast path
# gets taken for a reason nobody can see afterwards.
check() {
  local label="$1" expected="$2" work="$3"
  cases=$((cases + 1))
  classify "$work"
  local verdict="" expected_rc
  verdict="$(printf '%s\n' "$OUT" | sed -n 's/^CLASSIFY verdict=//p' | head -1)"
  case "$expected" in
    fastpath) expected_rc=0 ;;
    full) expected_rc=10 ;;
    *) echo "FAIL: the test asked for an unknown expectation '$expected'"; fails=$((fails + 1)); return ;;
  esac
  if [ "$RC" = "$expected_rc" ] && [ "$verdict" = "$expected" ]; then
    [ "$expected" != fastpath ] || fastpath_seen=1
    echo "ok   $label -> $expected"
  else
    fails=$((fails + 1))
    echo "FAIL $label: expected $expected (exit $expected_rc), got verdict='${verdict:-none}' exit=$RC"
    printf '%s\n' "$OUT" | sed 's/^/     | /'
  fi
}

# --- the cases ----------------------------------------------------------------------------------

# Documentation only, which is the whole point of the fast path.
w="$(new_repo docs-only)" || { echo "FAIL: cannot build the docs-only fixture"; exit 1; }
git -C "$w" checkout --quiet -b fix/docs
printf 'more guide\n' >> "$w/docs/guide.md"
printf 'more readme\n' >> "$w/README.md"
git -C "$w" commit --quiet -am "docs"
check "docs and a root markdown file" fastpath "$w"

# One Swift file in the same commit range is enough to owe a build.
w="$(new_repo docs-plus-swift)" || exit 1
git -C "$w" checkout --quiet -b fix/mixed
printf 'more guide\n' >> "$w/docs/guide.md"
printf 'let two = 2\n' >> "$w/Sources/App.swift"
git -C "$w" commit --quiet -am "docs and code"
check "docs plus one Swift file" full "$w"

# The per-bundle test-count baseline is data, not documentation: it decides whether the gate's
# testcount step passes, and a change to it alone must still be measured by a run that produces
# the counts it claims.
w="$(new_repo testcount-baseline)" || exit 1
git -C "$w" checkout --quiet -b fix/baseline
mkdir -p "$w/tests/gate"
printf 'MemosCoreTests\t1\n' > "$w/tests/gate/testcount-baseline.tsv"
git -C "$w" add -A >/dev/null
git -C "$w" commit --quiet -m "a test-count baseline"
check "the test-count baseline alone" full "$w"

# A bundled resource is not documentation, whatever its extension: the release notes are a .md
# the app ships and the What's new screen reads, and the gate's notes step holds them to the version
# (MEMNG-497). A change to that file alone must meet the full gate that runs the step.
w="$(new_repo bundled-markdown)" || exit 1
git -C "$w" checkout --quiet -b fix/notes
mkdir -p "$w/Packages/MemosFeatures/Sources/MemosFeatures/Resources"
printf '## 1.0.0 (1)\n\n- Notes.\n' \
  > "$w/Packages/MemosFeatures/Sources/MemosFeatures/Resources/ReleaseNotes.md"
git -C "$w" add -A >/dev/null
git -C "$w" commit --quiet -m "release notes"
check "a bundled resource .md alone" full "$w"

# The version file is the release-number authority; it never fast-paths.
w="$(new_repo project-yml)" || exit 1
git -C "$w" checkout --quiet -b fix/bump
printf 'CURRENT_PROJECT_VERSION: "6"\n' >> "$w/project.yml"
git -C "$w" commit --quiet -am "bump"
check "project.yml alone" full "$w"

# A markdown NAME over a source file: the allowlist reads names, so the mode has to be read too.
w="$(new_repo md-symlink)" || exit 1
git -C "$w" checkout --quiet -b fix/symlink
ln -s Sources/App.swift "$w/NOTES.md"
git -C "$w" add -A
git -C "$w" commit --quiet -m "a link that reads as documentation"
check "a .md symlink pointing at source" full "$w"

# A rename out of a source file removes Swift from the tree; with renames turned off both names
# are in the change set, and the old one is not allowlisted.
w="$(new_repo rename-swift-to-md)" || exit 1
git -C "$w" checkout --quiet -b fix/rename
git -C "$w" mv Sources/Foo.swift Foo.md
git -C "$w" commit --quiet -m "rename a source file to markdown"
check "Foo.swift renamed to Foo.md" full "$w"

# The gate builds the WORKING TREE, not the commits: an unstaged source edit is in the build.
w="$(new_repo dirty-tree)" || exit 1
git -C "$w" checkout --quiet -b fix/dirty
printf 'more guide\n' >> "$w/docs/guide.md"
git -C "$w" commit --quiet -am "docs"
printf 'let three = 3\n' >> "$w/Sources/App.swift"
check "a docs-only branch with an unstaged source edit" full "$w"

# Same, staged rather than unstaged.
w="$(new_repo dirty-tree-staged)" || exit 1
git -C "$w" checkout --quiet -b fix/staged
printf 'more guide\n' >> "$w/docs/guide.md"
git -C "$w" commit --quiet -am "docs"
printf 'let four = 4\n' >> "$w/Packages/MemosCore/Sources/MemosCore/Core.swift"
git -C "$w" add -A
check "a docs-only branch with a staged source edit" full "$w"

# main is measured against nothing here; it is where the full gate belongs.
w="$(new_repo on-main)" || exit 1
printf 'more guide\n' >> "$w/docs/guide.md"
git -C "$w" commit --quiet -am "docs on main"
check "the branch is main" full "$w"

# Nothing to skip is not something to skip: an empty change set gets the full gate.
w="$(new_repo empty-diff)" || exit 1
git -C "$w" checkout --quiet -b fix/empty
check "no change against origin/main" full "$w"

# An enumeration that FAILS must not read as an enumeration that found nothing. Here the branch
# carries a Swift file and the working tree an untracked markdown file, and `git diff` refuses: a
# classifier that ignores the failure sees only the markdown and calls it documentation.
w="$(new_repo enumeration-fails)" || exit 1
git -C "$w" checkout --quiet -b fix/enumeration
printf 'let five = 5\n' >> "$w/Sources/App.swift"
git -C "$w" commit --quiet -am "a source change the stub will hide"
printf 'notes\n' > "$w/NOTES.md"
stub="$tmp/stub-bin"
mkdir -p "$stub"
real_git="$(command -v git)"
{
  printf '#!/usr/bin/env bash\n'
  printf 'for a in "$@"; do\n'
  printf '  [ "$a" = diff ] || continue\n'
  printf '  echo "stub git: refusing to enumerate" >&2\n'
  printf '  exit 1\n'
  printf 'done\n'
  printf 'exec %s "$@"\n' "$real_git"
} > "$stub/git"
chmod +x "$stub/git"
CLASSIFY_STUB_PATH="$stub"
check "an enumeration command that fails" full "$w"
CLASSIFY_STUB_PATH=""

# A gitlink wears a name like any other. `.gitmodules` would meet the full gate on its own, but a
# submodule pointer added straight to the index does not go through one.
w="$(new_repo gitlink)" || exit 1
git -C "$w" checkout --quiet -b fix/gitlink
gitlink_sha="$(git -C "$w" rev-parse HEAD)"
git -C "$w" update-index --add --cacheinfo "160000,$gitlink_sha,Sources/X.md"
git -C "$w" commit --quiet -m "a submodule pointer that reads as documentation"
check "a gitlink named Sources/X.md" full "$w"

# skip-worktree and assume-unchanged tell git to stop looking at a file. What the gate copies to
# the build host is the file on disk, so a change git has been told to ignore is a change that
# would be built and never classified.
w="$(new_repo skip-worktree)" || exit 1
git -C "$w" checkout --quiet -b fix/skipped
printf 'more guide\n' >> "$w/docs/guide.md"
git -C "$w" commit --quiet -am "docs"
git -C "$w" update-index --skip-worktree Sources/App.swift
printf 'let six = 6\n' >> "$w/Sources/App.swift"
check "an index entry marked skip-worktree" full "$w"

# --- part 2: which of the gate's own suites a run owes (MEMNG-892) ---------------------------------
# The gate's suites check the gate's machinery, so a run owes them when its change set touches that
# machinery: a path config/gate-paths.txt lists. A run that touches none of them skips them and
# says so on one line naming that file; this suite (the classifier's) is the exception and runs on
# every run, so a change to the decision can never talk the gate out of the suite that checks it —
# which is why the decision's cases live HERE and not in a suite the decision could skip.
#
# Each case is a whole gate run, not --classify-only, because the claim is about the selftest step
# itself: what it ran, what it logged and what the summary says. The change sets are documentation,
# so every run that classifies takes the fast path and none of them needs a build host; ssh and
# rsync are stubs that refuse, so a run that went further than that fails instead of reaching out.
# The fixture's suites are stubs that say they ran.

unset MAC_GATE_ESTATE_LOCK MAC_GATE_ESTATE_LOCKS MAC_GATE_ESTATE_LOCK_STAMPS MAC_GATE_SIMULATOR
export MAC_GATE_RUNS_LEDGER="$tmp/gate-runs.tsv"

scope_stub_bin="$tmp/scope-stub-bin"
mkdir -p "$scope_stub_bin"
printf '#!/bin/sh\necho "stub ssh: no build host in this suite" >&2\nexit 255\n' > "$scope_stub_bin/ssh"
printf '#!/bin/sh\necho "stub rsync: no build host in this suite" >&2\nexit 255\n' > "$scope_stub_bin/rsync"
chmod +x "$scope_stub_bin/ssh" "$scope_stub_bin/rsync"

SCOPE_NAMED="$(sed -n 's/^for selftest_name in \(.*\); do$/\1/p' "$GATE")"
SCOPE_CONFIG_REL="config/gate-paths.txt"
SCOPE_SKIP_LINE="MAC_GATE_SELFTEST skipped: no path listed in $SCOPE_CONFIG_REL changed"

# A repository the whole gate can run in up to its fast path: the named suites (and one unnamed one)
# as stubs, the helpers the steps before the fast path call, and a config listing the machinery.
# $2 = "noconfig" leaves the config out; "emptyconfig" writes one that lists nothing; $3 = a named
# suite to leave out of main.
scope_repo() {
  local name="$1" config="${2:-}" omit="${3:-}" work="$tmp/$1" origin="$tmp/$1.git" stub
  git init --quiet --bare "$origin" || return 1
  git init --quiet -b main "$work" || return 1
  git -C "$work" config user.email gate-test@example.invalid
  git -C "$work" config user.name "gate test"
  git -C "$work" config commit.gpgsign false
  git -C "$work" config core.hooksPath "$tmp/no-hooks"
  mkdir -p "$work/docs/scripts" "$work/Sources" "$work/tests/gate" "$work/scripts" "$work/config"
  printf 'a guide\n' > "$work/docs/guide.md"
  printf 'notes\n' > "$work/docs/scripts/notes.md"
  printf 'the scripts\n' > "$work/scripts/README.md"
  printf 'let app = 1\n' > "$work/Sources/App.swift"
  printf '.gate-artifacts/\n' > "$work/.gitignore"
  {
    printf 'targets:\n'
    printf '  MemosNG:\n'
    printf '    settings:\n'
    printf '      MARKETING_VERSION: "9.9.9"\n'
    printf '      CURRENT_PROJECT_VERSION: "999"\n'
  } > "$work/project.yml"
  for stub in $SCOPE_NAMED extra-scope-test.sh; do
    [ "$stub" != "$omit" ] || continue
    if [ "$stub" = fastpath-classify-test.sh ]; then
      printf '#!/bin/sh\necho "%s stub ran"\nexit "${SCOPE_CLASSIFIER_RC:-0}"\n' "$stub" > "$work/tests/gate/$stub"
    else
      printf '#!/bin/sh\necho "%s stub ran"\nexit 0\n' "$stub" > "$work/tests/gate/$stub"
    fi
    chmod +x "$work/tests/gate/$stub"
  done
  printf 'gate_lane_is_unlocked() { return 0; }\n' > "$work/scripts/reap-gate-lanes.sh"
  cp "$repo_root/scripts/gate-admission.sh" "$work/scripts/gate-admission.sh" || return 1
  cp "$repo_root/scripts/release-version-rule.sh" "$work/scripts/release-version-rule.sh" || return 1
  cp "$repo_root/scripts/gate-mount-guard.sh" "$work/scripts/gate-mount-guard.sh" || return 1
  case "$config" in
    noconfig) : ;;
    emptyconfig) printf '# lists nothing\n\n' > "$work/$SCOPE_CONFIG_REL" ;;
    *)
      # A commented-out docs/* is not a pattern, so a change under docs/ must still skip; and the
      # scripts/* line carries padding and a trailing comment, either of which, kept, would make
      # it a pattern that matches nothing.
      {
        printf '# the gate machinery\n'
        printf '# docs/*\n'
        printf 'bin/mac-gate.sh\n'
        printf '  scripts/*  # the helpers\n'
        printf 'tests/gate/*-test.sh\n'
        printf '%s\n' "$SCOPE_CONFIG_REL"
      } > "$work/$SCOPE_CONFIG_REL" ;;
  esac
  git -C "$work" add -A >/dev/null || return 1
  git -C "$work" commit --quiet -m "baseline" || return 1
  git -C "$work" remote add origin "$origin"
  git -C "$work" push --quiet origin main || return 1
  printf '%s' "$work"
}

# One whole gate run in $1. OUT, RC and LOGTEXT (the run log, read back) are what a case reads.
scope_run() {
  local work="$1"
  local -a env_args=(-u MAC_GATE_BRANCH "PATH=$scope_stub_bin:${SCOPE_GIT_STUB:+$SCOPE_GIT_STUB:}$PATH"
    MAC_GATE_HOST=stub-host "MAC_GATE_ARTIFACTS=$work/.gate-artifacts"
    "SCOPE_CLASSIFIER_RC=${SCOPE_CLASSIFIER_RC:-0}")
  OUT="$(cd "$work" && env "${env_args[@]}" "$GATE" 2>&1)"
  RC=$?
  local log_path
  log_path="$(printf '%s\n' "$OUT" | sed -n 's/^run log     : //p' | tail -1)"
  LOGTEXT=""
  [ -n "$log_path" ] && [ -r "$log_path" ] && LOGTEXT="$(cat "$log_path")"
}
SCOPE_GIT_STUB=""
SCOPE_CLASSIFIER_RC=0

scope_has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
scope_ok() { cases=$((cases + 1)); echo "ok   $1"; }
scope_bad() {
  cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $1"
  printf '%s\n' "$OUT" | sed 's/^/     | /'
}

if [ "$(printf '%s\n' $SCOPE_NAMED | wc -l | tr -d ' ')" -ge 2 ] && printf ' %s ' $SCOPE_NAMED | grep -q ' fastpath-classify-test\.sh '; then
  scope_ok "scope: the gate's named suite list was read and names this suite (control)"
else
  cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL scope: no named suite list could be read from $GATE: [$SCOPE_NAMED]"
fi

# (a) Nothing listed changed: the run skips every suite but this one, logs the skip with the
# config's path, and the summary says skip rather than a 0 that reads as "they passed". The change
# set holds docs/scripts/notes.md, which a pattern that is not anchored at the root (scripts/*
# matched anywhere) would take for a gate path, and the config holds `# docs/*` as a comment.
w="$(scope_repo scope-skip)" || { echo "FAIL: cannot build the scope-skip fixture"; exit 1; }
git -C "$w" checkout --quiet -b fix/scope-skip
printf 'more guide\n' >> "$w/docs/guide.md"
printf 'more notes\n' >> "$w/docs/scripts/notes.md"
git -C "$w" commit --quiet -am "docs"
scope_run "$w"
if [ "$RC" -eq 0 ] && scope_has "$SCOPE_SKIP_LINE" \
   && printf '%s\n' "$LOGTEXT" | grep -qF -- "$SCOPE_SKIP_LINE" \
   && scope_has "fastpath-classify-test.sh stub ran" \
   && ! scope_has "mount-guard-test.sh stub ran" && ! scope_has "extra-scope-test.sh stub ran" \
   && printf '%s\n' "$OUT" | grep -Eq '^mac-gate SUMMARY: selftest=skip classify=0 .*\| exit=0$' \
   && grep -q '^selftest: skip' "$w/.gate-artifacts/classification.txt" 2>/dev/null; then
  scope_ok "scope: a change set touching no listed path skips the suites, logs '$SCOPE_SKIP_LINE', runs the classifier's, and the summary says selftest=skip"
else
  scope_bad "scope: a change set touching no listed path did not skip as specified (exit $RC)"
fi

# (b) A listed path changed (scripts/README.md, under `  scripts/*  # the helpers` — the padding and
# the comment are not the pattern):
# every suite runs, and the line names the path and the pattern that owed them.
w="$(scope_repo scope-run)" || exit 1
git -C "$w" checkout --quiet -b fix/scope-run
printf 'more\n' >> "$w/scripts/README.md"
git -C "$w" commit --quiet -am "a note beside the gate's scripts"
scope_run "$w"
if [ "$RC" -eq 0 ] && scope_has "MAC_GATE_SELFTEST run: scripts/README.md matches scripts/* in $SCOPE_CONFIG_REL" \
   && ! scope_has "MAC_GATE_SELFTEST skipped" \
   && scope_has "fastpath-classify-test.sh stub ran" && scope_has "mount-guard-test.sh stub ran" \
   && scope_has "extra-scope-test.sh stub ran" \
   && printf '%s\n' "$OUT" | grep -Eq '^mac-gate SUMMARY: selftest=0 classify=0 .*\| exit=0$'; then
  scope_ok "scope: a change set touching a listed path runs every suite and names the path that owed them"
else
  scope_bad "scope: a change set touching a listed path did not run the suites as specified (exit $RC)"
fi

# (c) The listed path is untracked, in the working tree: it is copied to the build host like any
# committed change, so it owes the suites too.
w="$(scope_repo scope-untracked)" || exit 1
git -C "$w" checkout --quiet -b fix/scope-untracked
printf 'more guide\n' >> "$w/docs/guide.md"
git -C "$w" commit --quiet -am "docs"
printf 'new\n' > "$w/scripts/NEW.md"
scope_run "$w"
if scope_has "MAC_GATE_SELFTEST run: scripts/NEW.md matches scripts/* in $SCOPE_CONFIG_REL" \
   && scope_has "mount-guard-test.sh stub ran"; then
  scope_ok "scope: an untracked file under a listed path runs the suites"
else
  scope_bad "scope: an untracked file under a listed path did not run the suites (exit $RC)"
fi

# (d) main is not a change set, so nothing can be shown untouched: the safe side, every suite. The
# run then owes the full gate, which the refusing ssh stub ends; only the selftest step is read.
w="$(scope_repo scope-main)" || exit 1
printf 'more guide\n' >> "$w/docs/guide.md"
git -C "$w" commit --quiet -am "docs on main"
scope_run "$w"
if scope_has "MAC_GATE_SELFTEST run: the branch is main" && scope_has "mount-guard-test.sh stub ran" \
   && ! scope_has "MAC_GATE_SELFTEST skipped"; then
  scope_ok "scope: a run on main runs every suite"
else
  scope_bad "scope: a run on main did not run every suite (exit $RC)"
fi

# (e) No config, and a config that lists nothing: neither can show that nothing listed changed.
w="$(scope_repo scope-noconfig noconfig)" || exit 1
git -C "$w" checkout --quiet -b fix/scope-noconfig
printf 'more guide\n' >> "$w/docs/guide.md"
git -C "$w" commit --quiet -am "docs"
scope_run "$w"
if [ "$RC" -eq 0 ] && scope_has "MAC_GATE_SELFTEST run: $SCOPE_CONFIG_REL cannot be read" \
   && scope_has "mount-guard-test.sh stub ran"; then
  scope_ok "scope: a missing config runs every suite"
else
  scope_bad "scope: a missing config did not run every suite (exit $RC)"
fi
w="$(scope_repo scope-emptyconfig emptyconfig)" || exit 1
git -C "$w" checkout --quiet -b fix/scope-emptyconfig
printf 'more guide\n' >> "$w/docs/guide.md"
git -C "$w" commit --quiet -am "docs"
scope_run "$w"
if [ "$RC" -eq 0 ] && scope_has "MAC_GATE_SELFTEST run: $SCOPE_CONFIG_REL lists no path" \
   && scope_has "mount-guard-test.sh stub ran"; then
  scope_ok "scope: a config that lists nothing runs every suite"
else
  scope_bad "scope: a config that lists nothing did not run every suite (exit $RC)"
fi

# (f) An enumeration that fails is not one that found nothing: a git whose diff refuses must not
# turn into a skip.
w="$(scope_repo scope-gitfails)" || exit 1
git -C "$w" checkout --quiet -b fix/scope-gitfails
printf 'more\n' >> "$w/scripts/README.md"
git -C "$w" commit --quiet -am "a gate-path change the stub will hide"
SCOPE_GIT_STUB="$tmp/stub-bin"
scope_run "$w"
SCOPE_GIT_STUB=""
if scope_has "MAC_GATE_SELFTEST run: the change set could not be enumerated" \
   && scope_has "mount-guard-test.sh stub ran" && ! scope_has "MAC_GATE_SELFTEST skipped"; then
  scope_ok "scope: a git that fails to enumerate runs every suite"
else
  scope_bad "scope: a git that fails to enumerate did not run every suite (exit $RC)"
fi

# (g) The skip never hides this suite's own verdict: the classifier's suite failing in a run that
# skips the rest fails the step and the run.
w="$(scope_repo scope-classifier-red)" || exit 1
git -C "$w" checkout --quiet -b fix/scope-classifier-red
printf 'more guide\n' >> "$w/docs/guide.md"
git -C "$w" commit --quiet -am "docs"
SCOPE_CLASSIFIER_RC=1
scope_run "$w"
SCOPE_CLASSIFIER_RC=0
if [ "$RC" -eq 1 ] && scope_has "$SCOPE_SKIP_LINE" && scope_has "fastpath-classify-test.sh stub ran" \
   && printf '%s\n' "$OUT" | grep -Eq '^mac-gate SUMMARY: selftest=1 .*\| exit=1$'; then
  scope_ok "scope: the classifier's suite failing in a skipping run fails the run (selftest=1)"
else
  scope_bad "scope: the classifier's suite failing in a skipping run did not fail it (exit $RC)"
fi

# (h) A named suite that is missing is a failure on every run, skipping or not: the integrity check
# is not the suites' to skip. Here main never had mutants-test.sh, so the change set (docs) does
# not touch it.
w="$(scope_repo scope-missing-named "" mutants-test.sh)" || exit 1
git -C "$w" checkout --quiet -b fix/scope-missing-named
printf 'more guide\n' >> "$w/docs/guide.md"
git -C "$w" commit --quiet -am "docs"
scope_run "$w"
if [ "$RC" -ne 0 ] && scope_has "mutants-test.sh is missing or not executable" && scope_has "$SCOPE_SKIP_LINE"; then
  scope_ok "scope: a missing named suite fails a skipping run"
else
  scope_bad "scope: a missing named suite did not fail a skipping run (exit $RC)"
fi

# (j) A stale origin/main must not hide a gate change. The local origin/main is A; upstream main has
# moved to B, which changed scripts/README.md; the branch is based on B and puts that file back to
# A's text. Measured as a tree diff from A, the file never changed; measured against the real main
# B, the branch changes gate machinery. Both B's commit and the revert are in A..HEAD and both name
# the file, so the decision reads the paths every commit in that range names, not only the tree.
w="$(scope_repo scope-stale-base)" || exit 1
stale_a="$(git -C "$w" rev-parse HEAD)"
printf 'upstream edit\n' >> "$w/scripts/README.md"
git -C "$w" commit --quiet -am "upstream: a gate-path change on main (B)"
git -C "$w" push --quiet origin main || exit 1
git -C "$w" update-ref refs/remotes/origin/main "$stale_a"
git -C "$w" checkout --quiet -b fix/scope-stale-base
git -C "$w" show "$stale_a:scripts/README.md" > "$w/scripts/README.md"
printf 'more guide\n' >> "$w/docs/guide.md"
git -C "$w" commit --quiet -am "put the script back to A's text, and a docs change"
scope_run "$w"
if scope_has "MAC_GATE_SELFTEST run: scripts/README.md matches scripts/* in $SCOPE_CONFIG_REL" \
   && scope_has "mount-guard-test.sh stub ran" && ! scope_has "MAC_GATE_SELFTEST skipped"; then
  scope_ok "scope: a branch reverting an upstream gate change, measured from a stale origin/main, runs the suites"
else
  scope_bad "scope: a branch reverting an upstream gate change, measured from a stale origin/main, did not run the suites (exit $RC)"
fi

# (i) The config is listed in itself: a change to it is a change to what the gate treats as its
# own, and runs the suites.
w="$(scope_repo scope-config-edit)" || exit 1
git -C "$w" checkout --quiet -b fix/scope-config-edit
printf 'docs/*\n' >> "$w/$SCOPE_CONFIG_REL"
git -C "$w" commit --quiet -am "list docs too"
scope_run "$w"
if scope_has "MAC_GATE_SELFTEST run: $SCOPE_CONFIG_REL matches $SCOPE_CONFIG_REL in $SCOPE_CONFIG_REL" \
   && scope_has "mount-guard-test.sh stub ran"; then
  scope_ok "scope: a change to the config itself runs the suites"
else
  scope_bad "scope: a change to the config itself did not run the suites (exit $RC)"
fi

# The repository's own config is read the way the gate reads it, and lists the gate itself and
# this suite: a config that had stopped naming them would let a change to the decision skip
# everything but this suite.
real_cfg="$repo_root/$SCOPE_CONFIG_REL"
if [ -r "$real_cfg" ] \
   && grep -qx 'bin/mac-gate.sh' "$real_cfg" && grep -qx "$SCOPE_CONFIG_REL" "$real_cfg" \
   && grep -Eqx 'tests/gate/\*(-test\.sh)?' "$real_cfg"; then
  scope_ok "scope: $SCOPE_CONFIG_REL lists bin/mac-gate.sh, itself and the gate's suites"
else
  cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL scope: $real_cfg is missing or does not list bin/mac-gate.sh, itself and tests/gate's suites"
fi

# --- verdict --------------------------------------------------------------------------------------
# The positive control on the suite: a run where every case came back `full` would pass a
# classifier that had simply stopped saying fastpath, which is not the thing under test.
if [ "$fastpath_seen" -ne 1 ]; then
  echo "FAIL: no case reached the fast path — the suite proves nothing about a classifier that never takes it"
  fails=$((fails + 1))
fi

echo "gate fastpath classifier: $((cases - fails)) of $cases cases as expected"
[ "$fails" -eq 0 ] || { echo "FASTPATH-TEST FAIL: $fails case(s) misclassified"; exit 1; }
echo "FASTPATH-TEST ok"

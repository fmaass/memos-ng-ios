#!/usr/bin/env bash
#
# mac-gate.sh — the build authority for this repo.
#
# Swift cannot be built on the Linux machine this repo is developed on, so every build, test,
# lint and dependency check runs on a Mac build host. This script is the ONLY sanctioned way to
# get there: it mirrors the working tree into a disposable gate directory on that host, runs the
# ordered checks, streams their output, copies the result bundle back, and returns the remote
# exit code unmasked.
#
# The ordered checks are: the gate's own classifier test, generate the project, lint, test, rebuild
# every package with warnings as errors, check the dependency rule, the share-link rule, the
# text-selection rule, the refusal-sites rule and the openapi-coverage rule, read the SHIPPING
# bundles back, and count the tests that actually ran.
#
# A change set of documentation and repository metadata only takes a FAST PATH. What the branch
# changed against origin/main (merge-base, renames not followed, so a rename is judged by both of
# its names) plus everything staged, edited or untracked in the working tree is classified against
# the allowlist in gate_path_is_metadata() below: docs/, any .md, .gitignore, .gitattributes,
# .editorconfig, CODEOWNERS, LICENSE. When every changed path is on it and none of them is a
# symbolic link, the gate reports "PASS (fast path: docs-only)" naming each path and the base it
# measured from, and copies nothing to the build host. Everything else — project.yml, any manifest,
# any source file, this script, the tests — meets the full gate, so a version bump can never skip
# the release-number check. What still runs on the fast path is what is local and cheap: the
# classifier's own test suite (tests/gate/fastpath-classify-test.sh, the gate's integrity check,
# which runs on EVERY gate) and the release-version authority check. The remote steps are skipped
# whole, `pins` included: it needs a generated project and a package resolution on the build host,
# which is the copy the fast path exists to avoid, and it reads Package.resolved — a file no
# docs-only change set can contain. Files git IGNORES are outside this classification by design:
# they never reach main, and the full gate builds whatever is on disk regardless.
#
# Git is the only medium of exchange between the two machines. The gate directory is a mirror,
# never a checkout: it is rsync'd with --delete, it is never opened in Xcode, and a developer's
# own clone on the build host is never a target (the containment check below enforces that).
#
# Usage:
#   MAC_GATE_HOST=<ssh-alias> bin/mac-gate.sh
#   MAC_GATE_HOST=<ssh-alias> bin/mac-gate.sh --quick [--bundle <name> | --only-testing <id>]
#                                     the ITERATION loop, never a verdict: lint, then compile for
#                                     testing on this branch's warm lane and run the named scope on
#                                     it. A lint error stops the run before anything is built.
#                                     --bundle names one of the gate's test bundles;
#                                     --only-testing takes an xcodebuild identifier
#                                     (Bundle, Bundle/Suite or Bundle/Suite/test). Neither means
#                                     anything without --quick, and only one of them at a time.
#                                     With --quick alone every bundle runs.
#   bin/mac-gate.sh --classify-only   print how this branch's change set classifies, and stop.
#                                     Needs no build host. Exit 0 = the docs-only fast path
#                                     applies, 10 = the full gate is owed.
#   bin/mac-gate.sh --help            print this usage.
#
# What the quick mode SKIPS is the whole difference: the package rebuilds with warnings fatal, the
# warnings canary, the pin check, the entitlement, dependency-rule, share-link, text-selection,
# refusal-sites and openapi-coverage rules, the
# shipping-bundle read-back and the per-bundle test count. What it keeps is everything that makes
# a run safe to start: the selftests, the release-version check, the classification, this branch's
# lane lock, the load gate and the private simulator — and the lint, which costs seconds and which
# the full gate would fail on anyway. It prints one line of its own,
# MAC_GATE_QUICK: lint=<rc> build=<rc> tests=<rc> | exit=<rc>, which is deliberately NOT the gate's
# summary line — a quick run can never be read, or pasted, as a verdict. The verdict is the full
# gate.
# It reuses the lane's DerivedData, which is why it is quick and why it takes the same lock: the
# tree it compiles into is the tree a full run of this branch would rsync --delete.
#
# Two gates for two branches can run at the same time. They must not share a simulator: the
# device holds ONE installation per bundle id, so a second branch installing over the first
# leaves an app whose frameworks belong to the other branch — dyld "Symbol not found" at launch
# and a red gate that says nothing about the code under test (observed 2026-08-24, three
# concurrent gates, two false reds). So by default this script gives each run its own device:
# created on the build host before the build, named for the branch and the local process, and
# deleted again on every exit path (see the trap in the remote script).
#
# Environment:
#   MAC_GATE_HOST        (required) ssh alias/host of the Mac build host
#   MAC_GATE_BRANCH      override the branch that names the gate directory (default: current)
#   MAC_GATE_SIMULATOR   run on this EXISTING, shared device by name instead of a private one.
#                        Only for reproducing a device-specific failure — it gives up the
#                        isolation above, so two runs set to the same name can cross-install.
#   MAC_GATE_DEVICE_TYPE device type identifier for the private device
#                        (e.g. com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro). Default:
#                        chosen on the build host from the newest installed iOS runtime.
#   MAC_GATE_ARTIFACTS   local directory for the copied-back .xcresult/screenshots and for this
#                        run's own log, mac-gate-<branch>-<run token>.log — one file per run, so
#                        two runs cannot write over each other and a caller's redirect cannot
#                        truncate either (default: <repo>/.gate-artifacts)
#   MAC_GATE_TEST_BUNDLES  ADDITIONAL test bundles that must each run >= 1 test. The bundles
#                        below are always enforced and cannot be removed by setting this — an
#                        override that could shrink the list would let a suite stop being built
#                        without the gate noticing. Adding one is not a verdict either: the
#                        tracked test-count baseline must name exactly the bundles a run wanted,
#                        so a run with a different list fails at testcount by design, until the
#                        baseline is re-recorded from a run that wanted the same list.
#
# Two gates for the SAME branch are a different matter: they share the gate directory, the work
# directory, the DerivedData and the result bundle, so the second one's `rsync --delete` rewrites
# the tree the first is building and the verdict belongs to neither. Those runs are serialised by
# a lock on the branch's gate directory, taken before anything is copied. The loser does not
# wait: it says who holds the lock and stops.
#
# Before copying, a successful pruned origin fetch with the standard fetch refspec lets the
# build host reclaim unlocked gate/work lanes older than 24 hours and absent from both local
# and origin heads. Current lanes are protected. Reaping logs directory sizes and the data
# volume's free space before and after; a failed fetch or non-standard refspec skips it.
#
# Exit codes: 2 = refusal (unsafe or unusable inputs, nothing was copied or run);
#             3 = another run of this branch holds the gate lock (nothing was copied or run);
#             4 = the lock this run held was reaped while the run was starting, and the build host
#                 half stopped before touching anything;
#            10 = --classify-only only: this change set owes the full gate (0 there means the
#                 fast path applies);
#             otherwise the exit code of the first failing step.

set -uo pipefail

GATE_ROOT_REMOTE='$HOME/build/memos-ng-ios/gate'
# Empty means "create a private device for this run" — the default. A name here is the opt-out.
SIMULATOR="${MAC_GATE_SIMULATOR:-}"
DEVICE_TYPE="${MAC_GATE_DEVICE_TYPE:-}"
# Always enforced. MAC_GATE_TEST_BUNDLES may only ADD to this list.
MANDATORY_TEST_BUNDLES="MemosAPITests MemosCoreTests MemosOutboxTests MemosFeaturesTests MemosShareKitTests"
TEST_BUNDLES="$MANDATORY_TEST_BUNDLES"
for extra in ${MAC_GATE_TEST_BUNDLES:-}; do
  case " $TEST_BUNDLES " in
    *" $extra "*) ;;
    *) TEST_BUNDLES="$TEST_BUNDLES $extra" ;;
  esac
done

die_refuse() {
  printf 'mac-gate: REFUSED: %s\n' "$1" >&2
  exit 2
}

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

# --classify-only answers one question — does this change set owe a build — and it has to be
# answerable without a Mac: it is what the gate's own test suite drives, and a classification that
# needed the build host would be the gate rather than a decision about it.
CLASSIFY_ONLY=0
QUICK=0
QUICK_BUNDLE=""
QUICK_ONLY_TESTING=""
# A while/shift loop rather than `for arg`, because two of these take a value. The value is
# checked where it is read: a flag whose argument is missing would otherwise swallow the NEXT
# flag, and `--quick --bundle --only-testing X` would run a scope nobody asked for.
while [ $# -gt 0 ]; do
  case "$1" in
    --classify-only) CLASSIFY_ONLY=1 ;;
    --quick) QUICK=1 ;;
    --bundle)
      case "${2:-}" in
        ""|-*) die_refuse "--bundle needs a test bundle name (one of: $TEST_BUNDLES)" ;;
      esac
      QUICK_BUNDLE="$2"; shift ;;
    --only-testing)
      case "${2:-}" in
        ""|-*) die_refuse "--only-testing needs an xcodebuild test identifier (Bundle, Bundle/Suite or Bundle/Suite/test)" ;;
      esac
      QUICK_ONLY_TESTING="$2"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die_refuse "unknown argument: $(printf '%q' "$1") (see --help)" ;;
  esac
  shift
done

# The combinations, refused here rather than half-honoured later. A scope is a thing only the
# quick mode has; the full gate runs every bundle and always will, so a scope beside it is an
# instruction this script cannot carry out, not a preference it can ignore.
if [ -n "$QUICK_BUNDLE" ] && [ -n "$QUICK_ONLY_TESTING" ]; then
  die_refuse "--bundle and --only-testing are two ways to name one scope; pass one of them"
fi
if [ "$QUICK" -eq 0 ] && { [ -n "$QUICK_BUNDLE" ] || [ -n "$QUICK_ONLY_TESTING" ]; }; then
  die_refuse "--bundle and --only-testing only mean something with --quick; the full gate runs every bundle"
fi
if [ "$QUICK" -eq 1 ] && [ "$CLASSIFY_ONLY" -eq 1 ]; then
  die_refuse "--quick and --classify-only ask for different things: one builds and tests, the other only says whether a build is owed"
fi
if [ -n "$QUICK_BUNDLE" ]; then
  # Whitespace first, and then a whole-word comparison. The bundle list is one space-separated
  # string, so a substring test against it accepts a value that spans two names — "MemosAPITests
  # MemosCoreTests" is inside " $TEST_BUNDLES " and names no bundle at all — and a trailing space
  # turns a good name into one xcodebuild would read as an identifier that matches nothing.
  case "$QUICK_BUNDLE" in
    *[[:space:]]*)
      die_refuse "--bundle names ONE test bundle, and $(printf '%q' "$QUICK_BUNDLE") contains whitespace (one of: $TEST_BUNDLES)" ;;
  esac
  quick_bundle_known=0
  for known_bundle in $TEST_BUNDLES; do
    [ "$QUICK_BUNDLE" != "$known_bundle" ] || quick_bundle_known=1
  done
  [ "$quick_bundle_known" -eq 1 ] \
    || die_refuse "--bundle $QUICK_BUNDLE: not one of the test bundles this gate builds ($TEST_BUNDLES)"
fi

# Single-quote escaping for values interpolated into a script sent to the build host, so a branch
# name can never become remote shell syntax.
esc() { printf "%s" "$1" | sed "s/'/'\\\\''/g"; }

# --- inputs -----------------------------------------------------------------------------------
host="${MAC_GATE_HOST:-}"
[ -n "$host" ] || [ "$CLASSIFY_ONLY" -eq 1 ] \
  || die_refuse "MAC_GATE_HOST is not set (ssh alias of the Mac build host)"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die_refuse "not inside a git working tree"
cd "$repo_root" || die_refuse "cannot enter $repo_root"

# (1) refuse unless the local tree has a HEAD — an empty repo has nothing reviewable to build,
#     and the provenance header below would be a lie.
head_sha="$(git rev-parse --verify HEAD 2>/dev/null)" \
  || die_refuse "the working tree has no HEAD commit (nothing to build from)"

branch="${MAC_GATE_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}"
[ -n "$branch" ] || die_refuse "cannot determine the branch name"
[ "$branch" != "HEAD" ] || die_refuse "detached HEAD: set MAC_GATE_BRANCH to name the gate directory"

# The branch names a directory that `rsync --delete` will empty, and it reaches the build host
# inside a script. So it is validated HERE, before anything is sent or run: an unvalidated value
# could carry a newline and append a line of its own to the build host's reply, naming a target
# outside the gate root for rsync to delete.
case "$branch" in
  *[!A-Za-z0-9._/-]*)
    die_refuse "branch name may only contain A-Z a-z 0-9 . _ - / (got: $(printf '%q' "$branch"))" ;;
esac
case "/$branch/" in
  */../*) die_refuse "branch name may not contain a '..' segment: $branch" ;;
esac
case "$branch" in
  /*) die_refuse "branch name may not be absolute: $branch" ;;
esac


# --- what a change set is, and whether it owes a build ------------------------------------------
# The one verdict this gate reaches without building anything. It is a decision about what reaches
# the build host, so it is taken from what WOULD reach it: the commits this branch adds to
# origin/main and everything the working tree holds on top of them — rsync copies the tree, not
# the history.
CLASSIFY_VERDICT=""
CLASSIFY_BASE="-"
CLASSIFY_REASON=""
CLASSIFY_PATHS=""
ORIGIN_FETCHED=0

# The allowlist, by NAME. Conservative on purpose: it names what cannot change a build, and
# everything it does not name meets the full gate — project.yml (where the release numbers live),
# every Package.swift and Package.resolved, xcconfig, entitlements and plist files, this script,
# the tests, and anything under Packages/, Sources/ or an App directory. LICENSE is spelled out
# rather than globbed, because a LICENSE* glob would also read LICENSEChecker.swift as metadata.
gate_path_is_metadata() {
  local path="$1" base="${1##*/}"
  case "$path" in
    docs/*) return 0 ;;
    *.md) return 0 ;;
  esac
  case "$base" in
    .gitignore|.gitattributes|.editorconfig|CODEOWNERS) return 0 ;;
    LICENSE|LICENCE|LICENSE.txt|LICENCE.txt|LICENSE.md|LICENCE.md) return 0 ;;
  esac
  return 1
}

gate_classify() {
  CLASSIFY_VERDICT=full
  CLASSIFY_BASE="-"
  CLASSIFY_REASON=""
  CLASSIFY_PATHS=""

  # Fetched first: the base is only as honest as the ref it is read from, and a stale origin/main
  # would make an old change set look small. A fetch that cannot reach the remote is not fatal —
  # it falls back to the ref on disk and says so — but a base that cannot be resolved at all owes
  # the full gate, because then nothing is known about what changed.
  local fetch_note=""
  # Pruning makes deleted branches disappear from the local inventory used by the lane reaper.
  if git fetch --quiet --prune origin 2>/dev/null; then
    ORIGIN_FETCHED=1
  else
    fetch_note=" (origin could not be fetched — the origin/main already on disk was used)"
  fi
  # main needs the inventory too, even though it has no change set to classify.
  case "$branch" in
    main|master)
      CLASSIFY_REASON="the branch is $branch, which is not a change set measured against origin/main${fetch_note}"
      return 0 ;;
  esac
  local base
  base="$(git merge-base origin/main HEAD 2>/dev/null)" || base=""
  if [ -z "$base" ]; then
    CLASSIFY_REASON="the merge-base with origin/main cannot be resolved${fetch_note}"
    return 0
  fi
  CLASSIFY_BASE="$base"

  # Three sources, because three different things end up on the build host: what the branch
  # committed (--no-renames, so a rename is BOTH names and the source file that left is judged
  # too), what is staged or edited in the working tree, and what is untracked but not ignored.
  #
  # Each one is checked, because a git that FAILS prints nothing and nothing reads exactly like "no
  # source file changed" — which is how a broken enumeration becomes a fast path. `local` is
  # declared apart from every assignment below on purpose: `local x="$(cmd)"` returns local's own
  # status, not the command's, and would swallow the very failure this guards against.
  local branch_paths tree_paths untracked_paths index_tags
  branch_paths="$(git diff --name-only --no-renames "$base...HEAD" 2>/dev/null)" || {
    CLASSIFY_REASON="the commits on this branch could not be enumerated (git diff $base...HEAD failed)"
    return 0
  }
  tree_paths="$(git diff --name-only --no-renames HEAD 2>/dev/null)" || {
    CLASSIFY_REASON="the working tree could not be enumerated (git diff HEAD failed)"
    return 0
  }
  untracked_paths="$(git ls-files --others --exclude-standard 2>/dev/null)" || {
    CLASSIFY_REASON="the untracked files could not be enumerated (git ls-files --others failed)"
    return 0
  }
  # An entry git has been told to stop looking at — assume-unchanged (a lowercase tag) or
  # skip-worktree (S) — is a file neither diff above will mention and rsync will copy regardless.
  index_tags="$(git ls-files -v 2>/dev/null)" || {
    CLASSIFY_REASON="the index could not be read (git ls-files -v failed)"
    return 0
  }
  if printf '%s\n' "$index_tags" | grep -qE '^[a-zS] '; then
    CLASSIFY_REASON="the index carries assume-unchanged or skip-worktree entries, so a change to one of them would be built without ever being classified"
    return 0
  fi

  local paths
  paths="$(printf '%s\n%s\n%s\n' "$branch_paths" "$tree_paths" "$untracked_paths" \
    | sed '/^$/d' | sort -u)"
  if [ -z "$paths" ]; then
    CLASSIFY_REASON="nothing changed against origin/main${fetch_note}"
    return 0
  fi
  CLASSIFY_PATHS="$paths"

  local path entry mode
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    # A path git had to quote carries a character this loop reads one way and the shell another;
    # it is never allowlisted, whatever its name looks like.
    case "$path" in
      '"'*)
        CLASSIFY_REASON="the change set holds a path git could not print literally ($path)"
        return 0 ;;
    esac
    if ! gate_path_is_metadata "$path"; then
      CLASSIFY_REASON="$path is neither documentation nor repository metadata"
      return 0
    fi
    # A name is not a file. Only an ORDINARY file may be passed unbuilt: 120000 is a symbolic link
    # whose name says nothing about what it points at, 160000 is a submodule pointer that carries
    # a whole tree behind a documentation-shaped name, and any other mode is something this gate
    # has never been shown. Read in the index, in HEAD and on disk, because the change set spans
    # all three, and a read that fails is not a read that found an ordinary file.
    entry="$(git ls-files -s -- "$path" 2>/dev/null)" || {
      CLASSIFY_REASON="the index entry for $path could not be read"
      return 0
    }
    mode="$(printf '%s\n' "$entry" | awk 'NR==1 {print $1}')"
    if [ -n "$mode" ] && [ "$mode" != 100644 ] && [ "$mode" != 100755 ]; then
      CLASSIFY_REASON="$path is not an ordinary file in the index (mode $mode)"
      return 0
    fi
    entry="$(git ls-tree -r --full-tree HEAD -- "$path" 2>/dev/null)" || {
      CLASSIFY_REASON="the HEAD entry for $path could not be read"
      return 0
    }
    mode="$(printf '%s\n' "$entry" | awk 'NR==1 {print $1}')"
    if [ -n "$mode" ] && [ "$mode" != 100644 ] && [ "$mode" != 100755 ]; then
      CLASSIFY_REASON="$path is not an ordinary file in HEAD (mode $mode)"
      return 0
    fi
    if [ -L "$path" ]; then
      CLASSIFY_REASON="$path is a symbolic link on disk, so its name says nothing about what would be built"
      return 0
    fi
  done <<< "$paths"

  CLASSIFY_VERDICT=fastpath
  CLASSIFY_REASON="every changed path is documentation or repository metadata${fetch_note}"
  return 0
}

# --- this run's own log ---------------------------------------------------------------------------
# The gate keeps its whole output itself, at a path no other run can have produced: the artifacts
# directory, the branch, and this run's token. A caller may redirect stdout wherever it likes and
# none of it can reach this file — which is the point. Two agents once pointed two runs at one
# generic name in a shared scratch directory; the second `>` truncated the first run's evidence
# while it was still being written, the reader watching that file was left with nothing, and the
# run had to be started again (2026-09-09). So two runs of the SAME branch write two files, and
# every exit path names the one it wrote on the line before its verdict.
branch_slug="$(printf '%s' "$branch" | tr '/' '-' | tr -c 'A-Za-z0-9._-' '-')"
branch_slug="${branch_slug:0:40}"
# A token, because a pid is not proof of identity to the far side: the remote half of this run has
# to be able to ask "is the lock in that directory still MINE", and a reap replaces the directory
# with one that carries somebody else's token. The log is named for it for the same reason the lock
# carries it — one run, one name, and a re-run of a branch never lands on the file its predecessor
# is still writing.
RUN_TOKEN="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
[ -n "$RUN_TOKEN" ] || RUN_TOKEN="$$-$(date -u +%s)"
artifacts="${MAC_GATE_ARTIFACTS:-$repo_root/.gate-artifacts}"
log="$artifacts/mac-gate-$branch_slug-$RUN_TOKEN.log"
# Opened where the run wants it rather than on the way past, because the default artifacts
# directory is INSIDE the tree the classifier reads: a log created before the classification would
# be an untracked path in the change set it is classifying.
open_run_log() {
  mkdir -p "$artifacts" || die_refuse "cannot create the artifacts directory $artifacts"
  : > "$log" || die_refuse "cannot write $log"
}
say() { printf '%s\n' "$*" | tee -a "$log"; }

if [ "$CLASSIFY_ONLY" -eq 1 ]; then
  gate_classify
  # Opened after the classification, never before it: see open_run_log.
  open_run_log
  {
    printf 'CLASSIFY verdict=%s\n' "$CLASSIFY_VERDICT"
    printf 'CLASSIFY base=%s\n' "$CLASSIFY_BASE"
    printf 'CLASSIFY reason=%s\n' "$CLASSIFY_REASON"
    if [ -n "$CLASSIFY_PATHS" ]; then
      printf '%s\n' "$CLASSIFY_PATHS" | sed 's/^/CLASSIFY path /'
    fi
    printf 'CLASSIFY log=%s\n' "$log"
  } | tee -a "$log"
  [ "$CLASSIFY_VERDICT" = fastpath ] && exit 0
  exit 10
fi

# The private device is named here, where the branch and this process are known: the branch so a
# stray device says which run left it behind, the pid so two runs of the SAME branch (a re-run
# started before the first one let go) still cannot land on one device. It reuses the branch slug
# the run log is named from, which is already reduced to the character set the branch validation
# above allows, minus '/', and cut short enough to stay a readable name in `simctl list`.
DEVICE_NAME="gate-${branch_slug}-$$"

# Who this run is, for the gate lock below. The host is in it because the pid alone is only
# meaningful to the machine that issued it, and the lock is read by whoever comes next; the token
# is the one this run's log is named for.
LOCK_DIR=""
LOCK_OWNER="host=$(hostname -s) pid=$$ at $(date -u +%Y-%m-%dT%H:%M:%SZ) token=$RUN_TOKEN"

open_run_log

# The build host deletes the device when the remote script ends, however it ends. That covers a
# failing step and a refusal — it does NOT cover this script being interrupted: a remote shell
# whose ssh client has gone away is not signalled, it runs on until a write to the dead
# connection kills it, and a shell killed that way runs no trap (measured 2026-08-24: after the
# local ssh was killed the device was still there). So the device is claimed from this side too,
# by a name only this run can have produced. Deleting a name that is already gone is a no-op, so
# the two claims cannot fight; the message below is printed only when this side found something
# still standing.
remove_gate_device() {
  [ -z "$SIMULATOR" ] || return 0   # a device this run did not create is not this run's to delete
  [ -n "${DEVICE_NAME:-}" ] || return 0
  local name; name="$(esc "$DEVICE_NAME")"
  timeout 90 ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
    "export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH
     export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
     xcrun simctl shutdown '$name' >/dev/null 2>&1
     xcrun simctl delete '$name' >/dev/null 2>&1" \
    && say "simulator   : removed the leftover device $DEVICE_NAME from the build host"
  return 0
}
# The lock goes back the same way the device does, and for the same reason: every exit path,
# including the interrupted one. It is removed only while this run still owns it — a lock taken
# over by a later run after this one was killed is that run's, not this one's to drop.
release_gate_lock() {
  [ -n "${LOCK_DIR:-}" ] || return 0
  local dir="$LOCK_DIR"
  # Cleared first: a signal arm and the EXIT trap both reach here.
  LOCK_DIR=""
  {
    printf "lock='%s'\n" "$(esc "$dir")"
    printf "owner='%s'\n" "$(esc "$LOCK_OWNER")"
    cat <<'REL_EOF'
[ -d "$lock" ] || exit 0
if [ "$(cat "$lock/owner" 2>/dev/null)" = "$owner" ]; then rm -rf "$lock"; fi
REL_EOF
  } | timeout 90 ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'bash -s' >/dev/null 2>&1
  return 0
}

die_locked() {
  printf 'mac-gate: REFUSED: %s\n' "$1" >&2
  printf 'mac-gate: REFUSED: %s\n' "$1" >> "$log" 2>/dev/null
  # A quick run that never got the lock built nothing, so it reports nothing built — but it still
  # reports, on its own line, because that line is what the caller reads.
  [ "${QUICK:-0}" -eq 0 ] \
    || printf 'MAC_GATE_QUICK: lint=- build=- tests=- | exit=3\n' | tee -a "$log"
  exit 3
}

trap 'remove_gate_device; release_gate_lock' EXIT
trap 'remove_gate_device; release_gate_lock; exit 130' INT
trap 'remove_gate_device; release_gate_lock; exit 143' TERM
trap 'remove_gate_device; release_gate_lock; exit 129' HUP

# --- (5) provenance ---------------------------------------------------------------------------
{
  printf '=== mac-gate %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'host        : %s\n' "$host"
  printf 'repo        : %s\n' "$repo_root"
  printf 'branch      : %s\n' "$branch"
  printf 'HEAD        : %s\n' "$head_sha"
  printf 'HEAD subject: %s\n' "$(git log -1 --pretty=%s)"
  if [ -n "$SIMULATOR" ]; then
    printf 'simulator   : %s (MAC_GATE_SIMULATOR — shared device, no per-run isolation)\n' "$SIMULATOR"
  else
    printf 'simulator   : %s (created on the build host for this run, deleted on exit)\n' "$DEVICE_NAME"
  fi
  printf -- '--- git status --porcelain (full) ---\n'
  git status --porcelain
  printf -- '--- git diff --stat (working tree vs HEAD) ---\n'
  git diff --stat HEAD
  printf -- '--- end provenance ---\n'
} 2>&1 | tee -a "$log"

# --- step bookkeeping -------------------------------------------------------------------------
declare -a STEP_NAMES=() STEP_RCS=()
first_fail=0
record() {
  STEP_NAMES+=("$1"); STEP_RCS+=("$2")
  if [ "$2" -ne 0 ] && [ "$first_fail" -eq 0 ]; then first_fail="$2"; fi
}
summary_and_exit() {
  local line="mac-gate SUMMARY:" i
  for i in "${!STEP_NAMES[@]}"; do line="$line ${STEP_NAMES[$i]}=${STEP_RCS[$i]}"; done
  line="$line | exit=$first_fail"
  say "run log     : $log"
  say "$line"
  exit "$first_fail"
}
# The quick mode's line is a different sentence on purpose. `mac-gate SUMMARY: … | exit=0` is the
# one thing in this repo that means "this change may merge", and a run that skipped the pins, the
# warnings rebuilds and the shipping-bundle read-back must not be able to produce it — not by
# accident, and not by a copy-paste out of a terminal. So the quick mode says what it did (the
# lint, the build and the tests it ran) under a name of its own, and never reaches summary_and_exit.
# A dash means "never got that far": the build host was never asked, or it stopped before saying.
QUICK_LINT_RC="-"
QUICK_BUILD_RC="-"
QUICK_TESTS_RC="-"
quick_summary_and_exit() {
  say "run log     : $log"
  say "MAC_GATE_QUICK: lint=$QUICK_LINT_RC build=$QUICK_BUILD_RC tests=$QUICK_TESTS_RC | exit=$first_fail"
  say "quick       : NOT a verdict — the merge verdict is a full run of this gate"
  exit "$first_fail"
}
end_run() {
  if [ "$QUICK" -eq 1 ]; then quick_summary_and_exit; fi
  summary_and_exit
}

# --- the gate's own integrity check --------------------------------------------------------------
# The classifier decides whether anything gets built at all, which makes it the one part of this
# gate that no build can check. Its suite runs HERE, on every run, fast path or not: a fast path
# taken by a classifier nobody checked is a gate that passes what it never read.
say "--- step: selftest ---"
selftest_rc=0
# NAMED, not counted. A suite that is deleted or loses its execute bit takes its whole subject with
# it, and a step that runs "whatever is in tests/gate" would report selftest=0 for an empty
# directory. These three must be there.
for selftest_name in fastpath-classify-test.sh warnings-canary-test.sh testcount-test.sh; do
  selftest_script="$repo_root/tests/gate/$selftest_name"
  if [ -x "$selftest_script" ]; then
    "$selftest_script" 2>&1 | tee -a "$log"
    [ "${PIPESTATUS[0]}" -eq 0 ] || selftest_rc="${PIPESTATUS[0]}"
  else
    say "the gate's own test $selftest_script is missing or not executable"
    selftest_rc=1
  fi
done
# And anything else that ships beside them, so a new suite is never silently ignored.
for selftest_script in "$repo_root"/tests/gate/*-test.sh; do
  case "${selftest_script##*/}" in
    fastpath-classify-test.sh|warnings-canary-test.sh|testcount-test.sh) continue ;;
  esac
  [ -x "$selftest_script" ] || continue
  "$selftest_script" 2>&1 | tee -a "$log"
  [ "${PIPESTATUS[0]}" -eq 0 ] || selftest_rc="${PIPESTATUS[0]}"
done
record selftest "$selftest_rc"
[ "$first_fail" -eq 0 ] || end_run

# --- release-version authority ------------------------------------------------------------------
# Runs HERE, on the controller, because the tags live in this checkout and the mirrored tree on
# the build host carries no .git. The latest v* tag records what shipped (its annotation names
# the build: "X.Y.Z (build N): ..."); the numbers in project.yml must ADVANCE past it — the
# marketing version never below the tagged one, the build strictly greater always. A forgotten
# bump is caught before a wasted archive; a spent build number cannot ship twice. No v* tag yet
# is the bootstrap case and passes with a named line. Ritual: docs/RELEASING.md.
version_at_least() { # $1 >= $2, dotted numerics
  # Split on OWN lines: an IFS set in the same `local` statement does not govern that
  # statement's word-splitting, and the perturbation run caught the strings comparing whole.
  local IFS=. i
  local -a a b
  read -r -a a <<< "$1"
  read -r -a b <<< "$2"
  for i in 0 1 2; do
    [ "${a[$i]:-0}" -gt "${b[$i]:-0}" ] && return 0
    [ "${a[$i]:-0}" -lt "${b[$i]:-0}" ] && return 1
  done
  return 0
}
release_tag="$(git -C "$repo_root" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
if [ -n "$release_tag" ]; then
  tagged_version="${release_tag#v}"
  tagged_build="$(git -C "$repo_root" tag -l "$release_tag" --format='%(contents:subject)' \
    | sed -n 's/.*build \([0-9][0-9]*\).*/\1/p')"
  yml_version="$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' "$repo_root/project.yml" | head -1)"
  yml_build="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' "$repo_root/project.yml" | head -1)"
  [ -n "$yml_version" ] && [ -n "$yml_build" ] \
    || die_refuse "release check: could not read version keys from project.yml"
  if ! version_at_least "$yml_version" "$tagged_version"; then
    die_refuse "release check: MARKETING_VERSION $yml_version is below the shipped tag $release_tag"
  fi
  if [ -n "$tagged_build" ] && [ "$yml_build" -le "$tagged_build" ]; then
    die_refuse "release check: build $yml_build does not advance past the shipped build $tagged_build ($release_tag)"
  fi
  say "release     : $yml_version (build $yml_build) advances past $release_tag (build ${tagged_build:-?})"
else
  say "release     : no v* tag yet — bootstrap, nothing to advance past"
fi

# --- the change set, and the fast path -----------------------------------------------------------
# Classified on every run, fast path or not, and written into the artifacts next to the log: the
# evidence has to say what the gate decided to look at, or a PASS cannot be read afterwards.
say "--- step: classify ---"
gate_classify
{
  printf 'gate classification %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'branch  : %s\n' "$branch"
  printf 'HEAD    : %s\n' "$head_sha"
  printf 'base    : %s (merge-base with origin/main)\n' "$CLASSIFY_BASE"
  printf 'verdict : %s\n' "$CLASSIFY_VERDICT"
  printf 'reason  : %s\n' "$CLASSIFY_REASON"
  printf 'changed paths:\n'
  if [ -n "$CLASSIFY_PATHS" ]; then
    printf '%s\n' "$CLASSIFY_PATHS" | sed 's/^/  /'
  else
    printf '  (none)\n'
  fi
} > "$artifacts/classification.txt"
say "classify    : $CLASSIFY_VERDICT — $CLASSIFY_REASON"
say "classify    : base $CLASSIFY_BASE (merge-base with origin/main)"
if [ -n "$CLASSIFY_PATHS" ]; then
  while IFS= read -r classified_path; do
    say "classify    : changed $classified_path"
  done <<< "$CLASSIFY_PATHS"
else
  say "classify    : changed nothing"
fi
say "classify    : written to $artifacts/classification.txt"
record classify 0

if [ "$CLASSIFY_VERDICT" = fastpath ] && [ "$QUICK" -eq 0 ]; then
  # No device was ever created and no lock was ever taken, so nothing is owed back to the build
  # host; cleared here so the exit trap does not ssh over there to delete a device that was
  # only ever a name.
  DEVICE_NAME=""
  say "mac-gate PASS (fast path: docs-only) — base $CLASSIFY_BASE — changed: $(printf '%s' "$CLASSIFY_PATHS" | tr '\n' ' ')"
  say "fast path   : nothing was copied to a build host — $CLASSIFY_REASON"
  printf 'verdict : PASS (fast path: docs-only)\n' >> "$artifacts/classification.txt"
  summary_and_exit
fi
# The fast path answers "does this change set owe a build". A quick run is not asking that: it is
# an explicit request to compile and test, and the change set it is asked about is usually one the
# author is in the middle of writing. So it goes to the build host regardless — and, because it is
# not a verdict, skipping it would have saved nothing anyone could merge on.
if [ "$CLASSIFY_VERDICT" = fastpath ]; then
  say "classify    : docs-only, but --quick was asked for a build rather than for a verdict — continuing"
fi

# --- (2) resolve the remote target and refuse anything outside the gate root -------------------
# Resolved on the build host, where the path actually exists: lexically (so a `..` in the branch
# name cannot escape) AND physically (so a symlink planted in the gate root cannot either).
surviving_branches=""
reap_skip_reason="origin fetch failed; local refs may be incomplete"
origin_fetch_refspec="$(git config --get-all remote.origin.fetch)" || origin_fetch_refspec=""
if [ "$origin_fetch_refspec" != '+refs/heads/*:refs/remotes/origin/*' ]; then
  ORIGIN_FETCHED=0
  reap_skip_reason="non-standard fetch refspec"
  say "GATE_REAP skipped: $reap_skip_reason"
fi
if [ "$ORIGIN_FETCHED" -eq 1 ]; then
  surviving_refs="$(git for-each-ref refs/heads refs/remotes/origin --format='%(refname)')" \
    || die_refuse "cannot enumerate local and origin branches for lane reaping"
  surviving_branches="$(printf '%s\n' "$surviving_refs" \
    | sed -e '/^refs\/remotes\/origin\/HEAD$/d' -e 's#^refs/heads/##' -e t \
      -e 's#^refs/remotes/origin/##' | sort -u)"
fi
preflight_out="$(
  {
    printf "branch='%s'\n" "$(esc "$branch")"
    printf "lock_owner='%s'\n" "$(esc "$LOCK_OWNER")"
    printf "origin_fetched='%s'\n" "$(esc "$ORIGIN_FETCHED")"
    printf "reap_skip_reason='%s'\n" "$(esc "$reap_skip_reason")"
    printf "surviving_branches='%s'\n" "$(esc "$surviving_branches")"
    cat "$repo_root/scripts/reap-gate-lanes.sh"
    cat "$repo_root/scripts/gate-work-dir.sh"
    cat <<'PRE_EOF'
set -uo pipefail
gate_root_raw="$HOME/build/memos-ng-ios/gate"
mkdir -p "$gate_root_raw" || { echo "REFUSE cannot create the gate root"; exit 2; }
gate_root="$(cd "$gate_root_raw" && pwd -P)" || { echo "REFUSE cannot resolve the gate root"; exit 2; }
target_raw="$gate_root/$branch"
# lexical normalisation of . and .. without touching the filesystem
target="$(printf '%s' "$target_raw" | awk -F/ '{
  n = 0
  for (i = 1; i <= NF; i++) {
    if ($i == "." || $i == "") continue
    else if ($i == "..") { if (n > 0) n-- }
    else { n++; a[n] = $i }
  }
  s = ""
  for (i = 1; i <= n; i++) s = s "/" a[i]
  if (s == "") s = "/"
  print s
}')"
[ -n "$target" ] || { echo "REFUSE empty target path"; exit 2; }
[ "$target" != "$gate_root" ] || { echo "REFUSE target is the gate root itself"; exit 2; }
case "$target/" in
  "$gate_root"/*) ;;
  *) echo "REFUSE target $target resolves outside the gate root $gate_root"; exit 2 ;;
esac
case "$target/" in
  */projects/*) echo "REFUSE target $target is inside a projects checkout"; exit 2 ;;
esac
if [ -e "$target" ]; then
  phys="$(cd "$target" 2>/dev/null && pwd -P)" || { echo "REFUSE target exists but is not a directory"; exit 2; }
  case "$phys/" in
    "$gate_root"/*) ;;
    *) echo "REFUSE target symlinks to $phys, outside the gate root $gate_root"; exit 2 ;;
  esac
  if [ -e "$target/.git" ]; then
    echo "REFUSE target $target is a git checkout; the gate directory is a mirror, never a checkout"
    exit 2
  fi
fi
echo "GATE_REAP data volume before:"
df -h "$gate_root" | sed 's/^/GATE_REAP /' || exit 2
if [ "$origin_fetched" -eq 1 ]; then
  survivors_file="$(mktemp "${TMPDIR:-/tmp}/gate-survivors-XXXXXX")" || exit 2
  trap 'rm -f "$survivors_file"' EXIT
  printf '%s\n' "$surviving_branches" > "$survivors_file" || exit 2
  # The work root comes off the resolved gate root, the same sibling the build half will use: a
  # symlinked ~/build or ~/build/memos-ng-ios (the likely answer to a full disk) would otherwise
  # leave the two halves reaping different trees. Resolved, because the reaper compares physical
  # paths and refuses a symlinked root — a work tree moved onto another volume is ordinary here.
  work_root="$(gate_work_root_resolved "$gate_root")" || exit 2
  reap_gate_lanes "$gate_root" "$work_root" "$branch" "$survivors_file" || exit 2
else
  echo "GATE_REAP skipped: $reap_skip_reason"
fi
echo "GATE_REAP data volume after:"
df -h "$gate_root" | sed 's/^/GATE_REAP /' || exit 2
mkdir -p "$target" || { echo "REFUSE cannot create $target"; exit 2; }
# The lock is a directory, because mkdir is the one atomic "claim it or find it claimed" this
# host has in every shell it runs: /bin/bash here is 3.2 and has no flock. It is taken now,
# before a single byte is rsync'd, since the copy is what a concurrent same-branch run destroys.
lock="$target.lock"
if mkdir "$lock" 2>/dev/null; then
  printf '%s\n' "$lock_owner" > "$lock/owner" 2>/dev/null
  # Read back, because the claim is only as good as what the next run will find in there.
  lock_back="$(cat "$lock/owner" 2>/dev/null)"
  if [ "$lock_back" = "$lock_owner" ]; then
    echo "LOCK ACQUIRED"
  else
    echo "LOCK MISMATCH $lock_back"
  fi
else
  echo "LOCK HELD $(cat "$lock/owner" 2>/dev/null | tr -d '\n')"
fi
echo "LOCKDIR $lock"
echo "GATE_ROOT $gate_root"
echo "TARGET $target"
PRE_EOF
  } | ssh -o BatchMode=yes "$host" 'bash -s' 2>&1
)"
preflight_rc=$?
printf '%s\n' "$preflight_out" | tee -a "$log" >/dev/null
while IFS= read -r preflight_line; do
  case "$preflight_line" in GATE_REAP*) say "$preflight_line" ;; esac
done <<< "$preflight_out"
if [ "$preflight_rc" -ne 0 ]; then
  printf '%s\n' "$preflight_out" >&2
  exit 2
fi
# The build host's reply is re-checked here rather than trusted. Exactly one of each line, the
# root has to look like a path, and the target has to be the one this script would have computed.
gate_root="$(printf '%s\n' "$preflight_out" | sed -n 's/^GATE_ROOT //p')"
target="$(printf '%s\n' "$preflight_out" | sed -n 's/^TARGET //p')"
[ -n "$gate_root" ] || die_refuse "the build host did not return a gate root"
[ -n "$target" ] || die_refuse "the build host did not return a gate target"
[ "$(printf '%s\n' "$gate_root" | wc -l)" -eq 1 ] || die_refuse "more than one gate root returned"
[ "$(printf '%s\n' "$target" | wc -l)" -eq 1 ] || die_refuse "more than one gate target returned"
case "$gate_root" in
  /*) ;;
  *) die_refuse "the gate root is not an absolute path: $(printf '%q' "$gate_root")" ;;
esac
case "$gate_root" in
  *[!A-Za-z0-9._/-]*) die_refuse "the gate root contains unexpected characters" ;;
esac
expected_target="$gate_root/$branch"
[ "$target" = "$expected_target" ] \
  || die_refuse "the build host returned $target, not the expected $expected_target"
[ "$target" != "$gate_root" ] || die_refuse "the target is the gate root itself"
case "$target/" in
  "$gate_root"/*) ;;
  *) die_refuse "target $target is outside the gate root $gate_root" ;;
esac
case "/$target/" in
  */../*) die_refuse "target $target contains a '..' segment" ;;
esac
case "$target/" in
  */projects/*) die_refuse "target $target is inside a projects checkout" ;;
esac
say "gate target : $host:$target"

# --- (2b) the gate lock -------------------------------------------------------------------------
# The build host either handed this run the lock or named who holds it. A live holder is a
# refusal, not a wait: two runs of one branch cannot be ordered by patience, and a gate that sits
# silent for ten minutes reads as a hang. A holder that is gone is reaped once, out loud.
lockdir="$(printf '%s\n' "$preflight_out" | sed -n 's/^LOCKDIR //p')"
[ -n "$lockdir" ] || die_refuse "the build host did not return a gate lock path"
[ "$(printf '%s\n' "$lockdir" | wc -l)" -eq 1 ] || die_refuse "more than one gate lock path returned"
[ "$lockdir" = "$target.lock" ] \
  || die_refuse "the build host returned the lock $lockdir, not the expected $target.lock"

if printf '%s\n' "$preflight_out" | grep -q '^LOCK MISMATCH'; then
  die_locked "the gate lock of $branch was written but reads back as somebody else's: $(printf '%s\n' "$preflight_out" | sed -n 's/^LOCK MISMATCH //p')"
elif printf '%s\n' "$preflight_out" | grep -q '^LOCK ACQUIRED$'; then
  LOCK_DIR="$lockdir"
  say "gate lock   : taken ($LOCK_OWNER)"
else
  holder="$(printf '%s\n' "$preflight_out" | sed -n 's/^LOCK HELD //p')"
  holder_host="$(printf '%s\n' "$holder" | sed -n 's/.*host=\([^ ]*\).*/\1/p')"
  holder_pid="$(printf '%s\n' "$holder" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')"
  # Only this machine's pids can be asked about; a lock from another machine is taken at its word.
  holder_alive=yes
  if [ -n "$holder_pid" ] && [ "$holder_host" = "$(hostname -s)" ] \
     && ! kill -0 "$holder_pid" 2>/dev/null; then
    holder_alive=no
  fi
  if [ "$holder_alive" = yes ]; then
    die_locked "another run of $branch holds the gate lock on $host (${holder:-owner unknown}) — nothing was copied. Wait for it to finish, or clear it with: ssh $host rm -rf '$lockdir'"
  fi

  # A dead controlling pid is only half the question. The tree this lock protects lives on the
  # BUILD HOST, and a remote script whose ssh client was killed is not signalled — it keeps
  # building until a write to the dead connection kills it. Reaping on the pid alone would hand
  # this run an rsync --delete over a tree an orphaned build is still reading. So the build host
  # is asked as well, and it has to answer twice: once about a control it can see (or its silence
  # about this branch proves nothing), once about this branch.
  branch_re="$(printf '%s' "$branch" | sed 's/[.[]/\\&/g')"
  probe_out="$(
    {
      printf "lock='%s'\n" "$(esc "$lockdir")"
      printf "branch_re='%s'\n" "$(esc "$branch_re")"
      cat <<'PROBE_EOF'
# The exact question: is the remote half of the run that took this lock still going? It writes
# its pid in here, and it is this host's pid, so this host can answer.
remote_pid="$(cat "$lock/remote-pid" 2>/dev/null | tr -d '[:space:]')"
remote_alive=0
if [ -n "$remote_pid" ] && kill -0 "$remote_pid" 2>/dev/null; then remote_alive=1; fi

# And the wider question, for an orphan that lost its note: anything at all still working inside
# this branch's gate or work tree. A search that finds nothing has to prove it can find
# something, so it starts a process carrying a path of exactly that shape and looks for it first.
control_dir="$HOME/build/memos-ng-ios/gate/PROBECONTROL-$$"
mkdir -p "$control_dir" && : > "$control_dir/live"
tail -f "$control_dir/live" >/dev/null 2>&1 &
control_pid=$!
sleep 1
control_hits="$(pgrep -f "memos-ng-ios/gate/PROBECONTROL-$$/live" | wc -l | tr -d ' ')"
live_hits="$(pgrep -f "memos-ng-ios/(gate|work)/$branch_re(/| |$)" | wc -l | tr -d ' ')"
kill "$control_pid" >/dev/null 2>&1
rm -rf "$control_dir"
echo "PROBE control=$control_hits live=$live_hits remote_pid=${remote_pid:-none} remote_alive=$remote_alive"
PROBE_EOF
    } | ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'bash -s' 2>&1
  )"
  probe_rc=$?
  control_hits="$(printf '%s\n' "$probe_out" | sed -n 's/.*control=\([0-9][0-9]*\).*/\1/p')"
  live_hits="$(printf '%s\n' "$probe_out" | sed -n 's/.*live=\([0-9][0-9]*\).*/\1/p')"
  remote_alive="$(printf '%s\n' "$probe_out" | sed -n 's/.*remote_alive=\([0-9]\).*/\1/p')"
  remote_pid="$(printf '%s\n' "$probe_out" | sed -n 's/.*remote_pid=\([^ ]*\).*/\1/p')"
  if [ "$probe_rc" -ne 0 ] || [ -z "$control_hits" ] || [ -z "$live_hits" ] || [ -z "$remote_alive" ]; then
    die_locked "could not ask $host whether a build of $branch is still running, so the lock stays where it is: ${probe_out:-no answer}"
  fi
  if [ "$control_hits" -lt 1 ]; then
    die_locked "the liveness probe on $host could not even see its own control process, so its silence about $branch proves nothing — the lock stays where it is"
  fi
  if [ "$remote_alive" -ne 0 ]; then
    die_locked "the run that took the lock on $branch lost its controlling shell (pid $holder_pid is gone here), but its build is still running on $host as pid $remote_pid — reaping now would rsync --delete the tree out from under it. Let it finish, or clear it with: ssh $host rm -rf '$lockdir'"
  fi
  if [ "$live_hits" -ne 0 ]; then
    die_locked "the lock of $branch names a pid that is gone, but $live_hits process(es) on $host are still working in that branch's gate/work tree — an orphaned build outlives the ssh client that started it, so the lock stays. Let it finish, or clear it with: ssh $host rm -rf '$lockdir'"
  fi

  # The reap itself is one rename, because two runs can reach this point together: mv is atomic,
  # so exactly one of them carries the old lock away and the other finds it gone. rm -rf followed
  # by mkdir is not — the second run's rm would delete the first run's fresh lock.
  takeover_out="$(
    {
      printf "lock='%s'\n" "$(esc "$lockdir")"
      printf "owner='%s'\n" "$(esc "$LOCK_OWNER")"
      printf "stamp='%s'\n" "$(esc "$$-$(date -u +%H%M%S)")"
      cat <<'TAKE_EOF'
aside="$lock.reaped-$stamp"
if mv "$lock" "$aside" 2>/dev/null; then
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$owner" > "$lock/owner"
    back="$(cat "$lock/owner" 2>/dev/null)"
    if [ "$back" = "$owner" ]; then
      rm -rf "$aside"
      echo TAKEOVER_OK
    else
      echo "TAKEOVER_LOST the lock reads back as: $back"
    fi
  else
    rm -rf "$aside"
    echo "TAKEOVER_LOST another run claimed it: $(cat "$lock/owner" 2>/dev/null | tr -d '\n')"
  fi
else
  echo "TAKEOVER_LOST another run reaped it first"
fi
TAKE_EOF
    } | ssh -o BatchMode=yes "$host" 'bash -s' 2>&1
  )"
  case "$takeover_out" in
    *TAKEOVER_OK*)
      LOCK_DIR="$lockdir"
      say "gate lock   : reaped a stale lock left by ${holder:-an unknown run} — pid $holder_pid is gone and no build of $branch is running on $host — and took it" ;;
    *)
      die_locked "the stale lock of $branch was claimed by another run first: $takeover_out" ;;
  esac
fi


# --- (3) mirror the worktree ------------------------------------------------------------------
# --- load gate ----------------------------------------------------------------------------------
# The branch lock orders runs of ONE branch; nothing ordered runs of five. Five concurrent
# xcodebuilds drove the host's one-minute load past nine hundred, at which point the network
# stack starved and a live gate died mid-run on "no route to host". So a run holds its branch
# lock but does not START while the host is drowning: above roughly three times the core count
# it waits, out loud, and takes its turn when the load drains. A pure read — no slot state to
# leak, no stale slot to reap.

LOAD_LIMIT="${MAC_GATE_LOAD_LIMIT:-24}"
load_waited=0
while : ; do
  host_load="$(timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
    'sysctl -n vm.loadavg' 2>/dev/null | awk '{printf "%d", $2}')"
  [ -n "$host_load" ] || { say "load gate   : host unreadable, proceeding"; break; }
  if [ "$host_load" -le "$LOAD_LIMIT" ]; then
    [ "$load_waited" -eq 0 ] || say "load gate   : load $host_load, proceeding after ${load_waited}m"
    break
  fi
  load_waited=$((load_waited + 1))
  [ "$load_waited" -le 45 ] || { say "load gate   : still $host_load after 45m — proceeding anyway"; break; }
  [ $((load_waited % 5)) -ne 1 ] || say "load gate   : host load $host_load > $LOAD_LIMIT, waiting"
  sleep 60
done

say "--- step: rsync ---"
rsync -a --delete \
  --exclude '.git' --exclude 'signing.local.yml' \
  --exclude '.build' \
  --exclude 'DerivedData' \
  --exclude '*.xcodeproj' \
  --exclude '*.xcresult' \
  --exclude '.gate-artifacts' \
  -e ssh \
  "$repo_root"/ "$host:$target/" 2>&1 | tee -a "$log"
record rsync "${PIPESTATUS[0]}"
[ "$first_fail" -eq 0 ] || end_run

# --- (4) the ordered, fail-fast checks on the build host --------------------------------------
say "--- step: remote ---"
{
  printf "GATE_TARGET='%s'\n" "$(esc "$target")"
  printf "GATE_ROOT='%s'\n" "$(esc "$gate_root")"
  printf "GATE_SIMULATOR='%s'\n" "$(esc "$SIMULATOR")"
  printf "GATE_DEVICE_NAME='%s'\n" "$(esc "$DEVICE_NAME")"
  printf "GATE_DEVICE_TYPE='%s'\n" "$(esc "$DEVICE_TYPE")"
  printf "GATE_RUN_TOKEN='%s'\n" "$(esc "$RUN_TOKEN")"
  printf "GATE_TEST_BUNDLES='%s'\n" "$(esc "$TEST_BUNDLES")"
  printf "GATE_BRANCH='%s'\n" "$(esc "$branch")"
  printf "GATE_QUICK='%s'\n" "$(esc "$QUICK")"
  printf "GATE_QUICK_BUNDLE='%s'\n" "$(esc "$QUICK_BUNDLE")"
  printf "GATE_QUICK_ONLY_TESTING='%s'\n" "$(esc "$QUICK_ONLY_TESTING")"
  cat "$repo_root/scripts/reap-gate-lanes.sh"
  cat "$repo_root/scripts/gate-work-dir.sh"
  cat <<'REMOTE_EOF'
set -uo pipefail

# The first thing this shell does, before a directory is entered or a byte is removed: check that
# the lock this run was given is still this run's. A controller can be killed between the copy and
# this line, and the lock it left behind can be judged stale and reaped in that moment — in which
# case another run now owns the tree, and the only correct move here is to stop having touched
# nothing. What remains is the few milliseconds between ssh handing this script to bash and this
# check: in that window this shell has mutated nothing, so a reap there costs the reaper nothing
# and costs this run only the run itself.
GATE_LOCK="$GATE_TARGET.lock"
gate_lock_owner="$(cat "$GATE_LOCK/owner" 2>/dev/null)"
case "$gate_lock_owner" in
  *"token=$GATE_RUN_TOKEN"*) ;;
  *)
    echo "remote: the gate lock of this run was taken over while it was starting" \
         "(the lock now reads: ${gate_lock_owner:-gone}) — stopping, nothing was touched"
    exit 4 ;;
esac
# Only now, and only into a lock that answered with this run's token: the note that says a build
# is running on this host, which is what tells the next run not to reap while it is.
printf '%s\n' "$$" > "$GATE_LOCK/remote-pid" 2>/dev/null

export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
# xcode-select still points at the Command Line Tools on this host, so the full Xcode is named
# explicitly rather than assumed.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

cd "$GATE_TARGET" || { echo "remote: cannot enter $GATE_TARGET"; exit 2; }
rm -rf .gate-artifacts && mkdir -p .gate-artifacts
XCRESULT="$GATE_TARGET/.gate-artifacts/MemosNG.xcresult"
# Build scratch lives OUTSIDE the mirrored tree. Inside it, `swift format lint --recursive .`
# would walk the dependency checkouts SwiftPM drops in DerivedData and lint other people's code;
# keeping it outside also lets the incremental build survive the next `rsync --delete`.
# It is the work/ sibling of the gate root the preflight resolved and this run was handed, never
# a rewritten substring of the gate path: ~/build/memos-ng-ios may resolve anywhere at all.
GATE_WORK="$(gate_work_dir "$GATE_ROOT" "$GATE_BRANCH")" \
  || { echo "remote: cannot derive a work directory"; exit 2; }
[ "$GATE_WORK" != "$GATE_TARGET" ] || { echo "remote: the work directory is the gate target"; exit 2; }
mkdir -p "$GATE_WORK" || { echo "remote: cannot create $GATE_WORK"; exit 2; }
DERIVED="$GATE_WORK/DerivedData"

# --- disk hygiene -------------------------------------------------------------------------------
# Per-branch trees are kept between runs for the incremental build, but a merged branch never
# gates again and nothing else reaps its ~3.6G — the host filled up five times in one day this
# way. So every run stamps its OWN trees (a directory's mtime only moves when direct children
# change, so DerivedData writes deep inside never refresh it — the touch is the bookkeeping),
# then sweeps sibling trees whose stamp is older than three days: still-active branches re-stamp
# far more often than that. Locks are NEVER sweep targets — they are owned by the runs that hold
# them and clean themselves up through the trap; deleting one from the side would strip a live
# run of its serialization.
HYGIENE_GATE_ROOT="${GATE_TARGET%/"$GATE_BRANCH"}"
HYGIENE_WORK_ROOT="${GATE_WORK%/"$GATE_BRANCH"}"
touch "$GATE_TARGET" "$GATE_WORK" 2>/dev/null
for hygiene_root in "${GATE_TARGET%/*/*}" "${GATE_WORK%/*/*}"; do
  find "$hygiene_root" -mindepth 2 -maxdepth 2 -type d -mtime +3 \
    ! -path "$GATE_TARGET" ! -path "$GATE_WORK" ! -name '*.lock*' 2>/dev/null \
    | while IFS= read -r stale; do
        case "$stale" in
          *.lock*) continue ;;
        esac
        gate_lane_is_unlocked "$HYGIENE_GATE_ROOT" "$HYGIENE_WORK_ROOT" "$stale" || continue
        rm -rf "$stale" && echo "GATE_HYGIENE swept stale tree $stale"
      done
done
# Age alone is not enough on a busy day: five concurrent branches at ~3G each filled the host
# to ENOSPC while every tree was hours old. Under PRESSURE the age rule yields — when free
# space is below 15G, the oldest-stamped sibling trees go, newest-stamped last, until 20G is
# free or nothing sweepable remains. Locked siblings may be waiting or building, so their
# trees must survive even under pressure; an unlocked sibling can rebuild its cache next run.
free_kb() { df -k / | awk 'NR==2 {print $4}'; }
# The 2026-09-05 mid-run ENOSPC needs more headroom for DerivedData and warnings rebuilds.
if [ "$(free_kb)" -lt 15728640 ]; then
  echo "GATE_HYGIENE pressure: under 15G free — reaping oldest sibling trees"
  for hygiene_root in "${GATE_TARGET%/*/*}" "${GATE_WORK%/*/*}"; do
    ls -1dtr "$hygiene_root"/*/* 2>/dev/null | while IFS= read -r victim; do
      [ -d "$victim" ] || continue
      case "$victim" in
        "$GATE_TARGET"|"$GATE_WORK"|*.lock*) continue ;;
      esac
      [ "$(free_kb)" -ge 20971520 ] && break
      gate_lane_is_unlocked "$HYGIENE_GATE_ROOT" "$HYGIENE_WORK_ROOT" "$victim" || continue
      rm -rf "$victim" && echo "GATE_HYGIENE pressure-swept $victim"
    done
  done
fi
disk_free="$(df -h / | awk 'NR==2 {print $4}')"
echo "GATE_HYGIENE disk free after sweep: $disk_free"
case "$disk_free" in
  *G*) : ;;
  *) echo "GATE_HYGIENE WARNING: free space is not in the gigabyte range ($disk_free) — a cold build needs ~4G" ;;
esac

# --- the simulator this run gets ----------------------------------------------------------------
# A simulator holds ONE installation per bundle id, so two branches building on the same device
# overwrite each other's app and the loser launches against the winner's frameworks — dyld
# "Symbol not found", a red gate, and nothing wrong with the code. Each run therefore gets a
# device of its own and gives it back. The trap is the giving back, and it has to hold on the
# paths nobody plans for: a failing step, a refusal, the SIGHUP this shell gets when the ssh
# connection goes away. An undeleted device is disk on a build host that has little to spare.
GATE_DEVICE_UDID=""
# The warnings check writes one file into the mirrored tree and takes it away again. It is named
# here, where the give-back below can reach it: a shell killed between writing it and deleting it
# would otherwise leave a source file the gate invented sitting in the tree for the next run to
# lint, build and rsync over.
GATE_CANARY_FILE=""
device_cleanup() {
  [ -n "$GATE_DEVICE_UDID" ] || return 0
  local udid="$GATE_DEVICE_UDID" attempt=1
  # Cleared first: a signal handler and the EXIT trap both reach here, and the second one in
  # must not try to delete a device the first one already took away.
  GATE_DEVICE_UDID=""
  while : ; do
    xcrun simctl shutdown "$udid" >/dev/null 2>&1
    if xcrun simctl delete "$udid" >/dev/null 2>&1; then
      echo "MAC_GATE_DEVICE deleted $udid"
      return 0
    fi
    [ "$attempt" -lt 5 ] || break
    attempt=$((attempt + 1))
    sleep 3
  done
  echo "MAC_GATE_DEVICE DELETE-FAILED $udid (delete by hand: xcrun simctl delete $udid)"
  return 1
}
# Everything this run took on the build host goes back together: the device, and the note in the
# lock that says a build is still running here. The note is removed only while it is still ours.
gate_give_back() {
  [ -z "${GATE_CANARY_FILE:-}" ] || rm -f "$GATE_CANARY_FILE"
  GATE_CANARY_FILE=""
  device_cleanup
  local rc=$?
  if [ -n "${GATE_LOCK:-}" ] && [ "$(cat "$GATE_LOCK/remote-pid" 2>/dev/null)" = "$$" ]; then
    rm -f "$GATE_LOCK/remote-pid"
  fi
  return $rc
}
trap 'gate_give_back' EXIT
trap 'gate_give_back; exit 130' INT
trap 'gate_give_back; exit 143' TERM
trap 'gate_give_back; exit 129' HUP

if [ -n "$GATE_SIMULATOR" ]; then
  GATE_DESTINATION="platform=iOS Simulator,name=$GATE_SIMULATOR"
  echo "MAC_GATE_DEVICE shared '$GATE_SIMULATOR' (MAC_GATE_SIMULATOR is set — no per-run isolation)"
else
  # Written out and then run, rather than fed to python on a pipe inside "$( … )": the build
  # host's /bin/bash is 3.2, and its command-substitution scanner reads a quoted here-document as
  # shell text — a stray parenthesis or quote inside the program becomes a syntax error before
  # anything runs. Every helper below is spelled this way for that reason.
  cat > "$GATE_WORK/choose-device.py" <<'PY'
import json, re, subprocess, sys

wanted = sys.argv[1].strip() if len(sys.argv) > 1 else ""

proc = subprocess.run(["xcrun", "simctl", "list", "runtimes", "-j"],
                      capture_output=True, text=True)
if proc.returncode != 0:
    sys.stderr.write(proc.stderr)
    sys.exit(1)

# A runtime's own supportedDeviceTypes is the only honest answer to "can this device type run
# this iOS": the device type list on its own says nothing about which runtimes accept it, and a
# create against a pair the host does not support fails after the gate has already started.
runtimes = [r for r in json.loads(proc.stdout).get("runtimes", [])
            if r.get("isAvailable") and "SimRuntime.iOS-" in r.get("identifier", "")]

def version(runtime):
    return tuple(int(part) for part in re.findall(r"\d+", runtime.get("version", "0")))

runtimes.sort(key=version, reverse=True)

def rank(name):
    # Newest generation first. Within a generation the Pro is preferred, and that is not taste:
    # the hosted-window accessibility probes in MemoEditWiringTests vend an empty tree on some
    # models (iPhone 17e, 2026-08-24) and pass on the Pro. Until that is fixed in the probe, the
    # gate picks the model the suite is known to pass on rather than whichever name sorts first.
    generation = re.match(r"iPhone (\d+)", name)
    if name.endswith(" Pro"):
        variant = 3
    elif name.endswith(" Pro Max"):
        variant = 2
    elif re.fullmatch(r"iPhone \d+", name):
        variant = 1
    else:
        variant = 0
    return (int(generation.group(1)) if generation else 0, variant)

for runtime in runtimes:
    devices = [d for d in runtime.get("supportedDeviceTypes", [])
               if d.get("name", "").startswith("iPhone")]
    if wanted:
        devices = [d for d in devices if d.get("identifier") == wanted]
    if not devices:
        continue
    best = max(devices, key=lambda device: rank(device["name"]))
    print("%s|%s|%s on %s" % (best["identifier"], runtime["identifier"], best["name"],
                              runtime.get("name", runtime["identifier"])))
    sys.exit(0)

sys.stderr.write("no iPhone device type%s is supported by any installed iOS runtime\n"
                 % ((" matching " + wanted) if wanted else ""))
sys.exit(1)
PY
  device_pick="$(/usr/bin/python3 "$GATE_WORK/choose-device.py" "$GATE_DEVICE_TYPE")"
  [ -n "$device_pick" ] || { echo "remote: cannot choose a simulator device type"; exit 2; }
  device_type="${device_pick%%|*}"
  device_rest="${device_pick#*|}"
  device_runtime="${device_rest%%|*}"
  device_label="${device_rest##*|}"
  GATE_DEVICE_UDID="$(xcrun simctl create "$GATE_DEVICE_NAME" "$device_type" "$device_runtime")"
  GATE_DEVICE_UDID="$(printf '%s' "$GATE_DEVICE_UDID" | tr -d '[:space:]')"
  case "$GATE_DEVICE_UDID" in
    [0-9A-Fa-f]*-*-*-*-*) ;;
    *)
      echo "remote: could not create the simulator $GATE_DEVICE_NAME ($device_label)"
      # Best effort by name: if a device WAS made and only its id came back unreadable, it still
      # has to go.
      xcrun simctl delete "$GATE_DEVICE_NAME" >/dev/null 2>&1
      GATE_DEVICE_UDID=""
      exit 2 ;;
  esac
  # Addressed by id, never by name: the name is the thing two runs could collide on.
  GATE_DESTINATION="platform=iOS Simulator,id=$GATE_DEVICE_UDID"
  echo "MAC_GATE_DEVICE created $GATE_DEVICE_NAME $GATE_DEVICE_UDID ($device_label)"
  # It is booted HERE, and waited for. xcodebuild boots a device it needs, but it does
  # not wait for the system inside to finish coming up, and a simulator that is still booting
  # vends an empty accessibility tree: the hosted-window probes in MemoEditWiringTests see no
  # labels at all and the suite fails for a reason that has nothing to do with the code
  # (measured 2026-08-24 on a newly created iPhone 17 Pro — "labels → []"). Nobody saw this while
  # the gate ran on a shared device, because that device had been up for days. A private device
  # is cold every time, so the wait belongs to the gate.
  xcrun simctl bootstatus "$GATE_DEVICE_UDID" -b || {
    echo "remote: the created simulator never finished booting"
    exit 2
  }

  # A factory-fresh simulator has accessibility switched OFF — com.apple.Accessibility has
  # neither AccessibilityEnabled nor ApplicationAccessibilityEnabled — and with those absent a
  # hosted UIWindow vends an EMPTY accessibility tree: MemoEditWiringTests reads back no labels
  # at all and fails on the device rather than on the code. The long-lived devices this gate used
  # to share had been switched on at some point, which is the only reason nobody saw it while
  # every run landed on the same device (found 2026-08-24 across two rounds; the model has
  # nothing to do with it).
  #
  # The write goes THROUGH the booted device. Writing the plist under the device's data directory
  # from this side looks like it worked — `defaults read` on that file returns 1 — and changes
  # nothing: the simulator does not read that file, `simctl spawn … defaults read` still answers
  # "does not exist", and the suite still fails. Measured on this host, three devices, one
  # suite: no keys -> fail, host-side file -> fail, spawn write -> pass.
  for a11y_key in AccessibilityEnabled ApplicationAccessibilityEnabled; do
    xcrun simctl spawn "$GATE_DEVICE_UDID" defaults write com.apple.Accessibility "$a11y_key" -bool true
  done
  # Read back from INSIDE the device, which is the only reader whose answer means anything here.
  for a11y_key in AccessibilityEnabled ApplicationAccessibilityEnabled; do
    a11y_value="$(xcrun simctl spawn "$GATE_DEVICE_UDID" defaults read com.apple.Accessibility "$a11y_key" 2>/dev/null | tr -d '[:space:]')"
    [ "$a11y_value" = "1" ] || {
      echo "remote: $a11y_key reads '${a11y_value:-unset}' inside $GATE_DEVICE_NAME —" \
           "hosted-window accessibility would vend an empty tree, so the gate stops here"
      exit 2
    }
  done
  echo "MAC_GATE_DEVICE accessibility on ($GATE_DEVICE_NAME: AccessibilityEnabled=1 ApplicationAccessibilityEnabled=1, read back inside the device)"
fi

# --- the version this gate expects --------------------------------------------------------------
# project.yml is where the version is written, so it is also where the checks below take their
# expectation from. A second copy in this script would be a copy to forget on the next bump, and
# forgetting it reads as a failed gate rather than as an out-of-date script.
cat > "$GATE_WORK/read-marketing-version.py" <<'PY'
import re, sys
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except OSError as error:
    sys.stderr.write("cannot read %s: %s\n" % (sys.argv[1], error))
    sys.exit(1)
values = set(re.findall(r'^[ \t]*MARKETING_VERSION:[ \t]*"?([^"\s#]+)"?[ \t]*(?:#.*)?$', text, re.M))
if not values:
    sys.stderr.write("project.yml declares no MARKETING_VERSION\n")
    sys.exit(1)
if len(values) != 1:
    sys.stderr.write("project.yml declares more than one MARKETING_VERSION: %s\n" % sorted(values))
    sys.exit(1)
print(values.pop())
PY
GATE_MARKETING_VERSION="$(/usr/bin/python3 "$GATE_WORK/read-marketing-version.py" project.yml)" \
  || GATE_MARKETING_VERSION=""

first_fail=0
summary=""
step() {
  local name="$1"; shift
  echo "::: $name :::"
  if [ "$first_fail" -ne 0 ]; then
    summary="$summary $name=skipped"
    echo "::: $name skipped (a previous step failed) :::"
    return
  fi
  "$@"
  local rc=$?
  summary="$summary $name=$rc"
  echo "MAC_GATE_STEP $name $rc"
  if [ "$rc" -ne 0 ] && [ "$first_fail" -eq 0 ]; then first_fail=$rc; fi
}

s_xcodegen() {
  [ -f project.yml ] || { echo "no project.yml in $GATE_TARGET — nothing to generate"; return 3; }
  bin/generate.sh --spec project.yml || return $?
  # The version pair has to move on BOTH targets together — an extension whose CFBundleVersion
  # differs from its host's cannot be installed, and a marketing version that differs between
  # them is a TestFlight build that says two things at once. Checked on the generated project,
  # here, because it costs nothing and the build that would surface it costs ten minutes.
  [ -n "$GATE_MARKETING_VERSION" ] || {
    echo "VERSION FAIL: project.yml does not name exactly one MARKETING_VERSION to expect"
    return 1
  }
  echo "--- version keys in the generated project (expected from project.yml: $GATE_MARKETING_VERSION) ---"
  /usr/bin/python3 - "$GATE_MARKETING_VERSION" <<'PY'
import re, sys

EXPECTED_MARKETING = sys.argv[1]
pbxproj = "MemosNG.xcodeproj/project.pbxproj"
try:
    text = open(pbxproj, encoding="utf-8").read()
except OSError as error:
    print("VERSION FAIL: cannot read %s: %s" % (pbxproj, error))
    sys.exit(1)

marketing = re.findall(r"MARKETING_VERSION = ([^;]+);", text)
current = re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", text)
print("MARKETING_VERSION values: %s" % (", ".join(marketing) or "(none)"))
print("CURRENT_PROJECT_VERSION values: %s" % (", ".join(current) or "(none)"))

rc = 0
# Two targets carry the pair, each with a Debug and a Release configuration.
if len(marketing) < 4:
    print("VERSION FAIL: expected at least 4 MARKETING_VERSION entries (app + extension, "
          "Debug + Release), found %d" % len(marketing))
    rc = 1
elif set(marketing) != {EXPECTED_MARKETING}:
    print("VERSION FAIL: MARKETING_VERSION is not %s everywhere" % EXPECTED_MARKETING)
    rc = 1
else:
    print("ok: every MARKETING_VERSION is %s" % EXPECTED_MARKETING)

if len(current) < 4:
    print("VERSION FAIL: expected at least 4 CURRENT_PROJECT_VERSION entries, found %d" % len(current))
    rc = 1
elif len(set(current)) != 1:
    print("VERSION FAIL: the two targets disagree on CURRENT_PROJECT_VERSION: %s" % set(current))
    rc = 1
else:
    print("ok: every CURRENT_PROJECT_VERSION is %s" % current[0])

# Positive control in the same read: a setting that must be there, so that a "not found" above
# means absent rather than a regex reading the wrong file.
if re.search(r"PRODUCT_BUNDLE_IDENTIFIER = live\.discomarder\.memosng;", text):
    print("ok (positive control): the app's bundle identifier is in the generated project")
else:
    print("VERSION FAIL: positive control missing — the generated project has no "
          "PRODUCT_BUNDLE_IDENTIFIER = live.discomarder.memosng")
    rc = 1

sys.exit(rc)
PY
}

s_format() { swift format lint --strict --recursive . ; }

s_entitlements() {
  # The privilege boundary this app rests on is not in the Swift: it is two generated plists. The
  # device token lives in a keychain access group the APP declares and the share extension does
  # not, and an app group identifier is itself a keychain access group — so an extension that
  # gained a keychain-access-groups entry, or a token left in the app group, would be readable by
  # the share sheet with nothing in the code to show for it. Checked on the GENERATED files rather
  # than on project.yml: the artefact is what ships.
  local rc=0 app="MemosNG.entitlements" ext="MemosShare.entitlements" f
  for f in "$app" "$ext"; do
    [ -f "$f" ] || { echo "ENTITLEMENT FAIL: $f was not generated"; return 1; }
    echo "--- $f"
    plutil -p "$f"
  done
  # Read by INDEX, because the order is the security property: the first entry of
  # keychain-access-groups is the default access group, and the app writes the token to whichever
  # group that is. A list whose first entry drifted to the app group would put every new token
  # where the share extension can read it.
  local first second
  first="$(plutil -extract keychain-access-groups.0 raw -o - "$app" 2>/dev/null)"
  second="$(plutil -extract keychain-access-groups.1 raw -o - "$app" 2>/dev/null)"
  if [ "$first" = '$(AppIdentifierPrefix)live.discomarder.memosng.credentials' ]; then
    echo "ENTITLEMENT ok: the credential group is FIRST, so it is the default access group"
  else
    echo "ENTITLEMENT FAIL: the first keychain access group is '$first'"; rc=1
  fi
  # A second entry is a defect twice over: iOS provisioning validates every entry against the
  # profile's `TEAMID.*` pattern (a raw `group.…` entry fails automatic signing on device
  # builds), and any extra group widens where an unqualified write could land. The app group's
  # keychain access rides on the application-groups entitlement, checked by the control below.
  if [ -z "$second" ]; then
    echo "ENTITLEMENT ok: keychain-access-groups has exactly one entry"
  else
    echo "ENTITLEMENT FAIL: unexpected second keychain access group '$second'"; rc=1
  fi
  if grep -q 'keychain-access-groups' "$ext"; then
    echo "ENTITLEMENT FAIL: $ext declares a keychain access group; the token would be readable"
    rc=1
  else
    echo "ENTITLEMENT ok: the share extension declares no keychain access group"
  fi
  # A grep that finds nothing proves nothing on its own: both targets DO carry the app group, so
  # this is the control that says the two greps above were run against real files.
  if grep -q 'group.live.discomarder.memosng' "$app" \
    && grep -q 'group.live.discomarder.memosng' "$ext"; then
    echo "ENTITLEMENT ok (positive control): both targets declare the app group"
  else
    echo "ENTITLEMENT FAIL: positive control missing — the app group is not in both files"; rc=1
  fi
  return $rc
}

s_pins() {
  # A rebuild that resolves different dependency versions than the last good build is a different
  # app, and nothing in a green test run would say so. SwiftPM keeps its resolved-versions file
  # INSIDE the project, which is generated and not committed — so the graph is tracked at the repo
  # root instead and bin/generate.sh copies it in. This step asks SwiftPM to resolve against it and
  # reads the file back: SwiftPM rewrites that file whenever the pins cannot satisfy the manifests
  # (a dependency added, a requirement bumped past its pin, a hand edit), so a difference here IS
  # the drift — caught before the build rather than at an archive.
  #
  # Pinning the five direct dependencies in project.yml instead would not have covered it: eight of
  # the thirteen packages the app links are transitive and named in no manifest in this repo, so
  # their versions would still float. Only the resolved graph pins the whole thing.
  local tracked="Package.resolved"
  local resolved="MemosNG.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  [ -f "$tracked" ] || { echo "PINS FAIL: $tracked is not in the tree"; return 1; }
  [ -f "$resolved" ] || {
    echo "PINS FAIL: bin/generate.sh did not put the pins in $resolved"
    return 1
  }
  xcodebuild -resolvePackageDependencies \
    -project MemosNG.xcodeproj \
    -scheme MemosNG \
    -derivedDataPath "$DERIVED"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "PINS FAIL: package resolution failed (xcodebuild -resolvePackageDependencies exit $rc)"
    return "$rc"
  fi
  # Copied back on every run, pass or fail: on a fail it is the file to adopt, and on a pass it is
  # the evidence of what the build actually resolved.
  cp "$resolved" .gate-artifacts/Package.resolved
  /usr/bin/python3 - "$tracked" "$resolved" <<'PY'
import glob, json, pathlib, re, sys

tracked_path, resolved_path = sys.argv[1], sys.argv[2]


def load(path):
    try:
        return json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError) as error:
        print("PINS FAIL: cannot read %s: %s" % (path, error))
        sys.exit(1)


def pins(document):
    # Everything that decides WHAT gets compiled: where the package comes from, which version, and
    # the exact commit. Deliberately not originHash — SwiftPM recomputes that on a re-resolve and
    # was observed returning a different value for an unchanged set of manifests (2026-08-25), so
    # a check that failed on it would go red for no reachable reason. `location` covers the case
    # originHash would have caught here: a dependency re-pointed at another repository.
    out = {}
    for pin in document.get("pins", []):
        state = pin.get("state", {})
        out[pin.get("identity", "?")] = (
            state.get("version") or state.get("branch") or "(revision only)",
            state.get("revision", ""),
            pin.get("location", ""),
        )
    return out


def identity(url):
    name = url.strip().strip('"').rstrip("/").rsplit("/", 1)[-1]
    if name.endswith(".git"):
        name = name[: -len(".git")]
    return name.lower()


tracked, resolved = load(tracked_path), load(resolved_path)
t, r = pins(tracked), pins(resolved)
rc = 0

# The control on the comparison below: two files that agreed because both were empty, or because
# the wrong pair was read, would still "match". So the dependencies this project DECLARES are read
# out of the two places that declare them and each one is looked up in what was resolved.
declared = set()
for path in ["project.yml", *sorted(glob.glob("Packages/*/Package.swift"))]:
    text = pathlib.Path(path).read_text(encoding="utf-8")
    for url in re.findall(r'\.package\(\s*url:\s*"([^"]+)"', text):
        declared.add(identity(url))
    for url in re.findall(r"^\s+url:\s*(https://\S+)\s*$", text, re.M):
        declared.add(identity(url))
if not declared:
    print("PINS FAIL: no remote dependency is declared in project.yml or Packages/*/Package.swift"
          " — the control below would pass on any file")
    rc = 1
missing = sorted(declared - set(r))
if missing:
    print("PINS FAIL: declared dependencies absent from the resolved graph: %s" % ", ".join(missing))
    rc = 1
elif declared:
    print("PINS ok (control): all %d declared remote dependencies are in the resolved graph: %s"
          % (len(declared), ", ".join("%s@%s" % (i, r[i][0]) for i in sorted(declared))))

added = sorted(set(r) - set(t))
removed = sorted(set(t) - set(r))
changed = sorted(i for i in set(t) & set(r) if t[i] != r[i])
if added or removed or changed:
    print("PINS FAIL: resolution does not match the tracked %s — this build would not use the "
          "versions this repo ships" % tracked_path)
    for i in changed:
        print("PINS FAIL:   %s: pinned %s (%s) from %s, resolved %s (%s) from %s"
              % (i, t[i][0], t[i][1][:12], t[i][2], r[i][0], r[i][1][:12], r[i][2]))
    for i in added:
        print("PINS FAIL:   %s: resolved at %s, pinned nowhere" % (i, r[i][0]))
    for i in removed:
        print("PINS FAIL:   %s: pinned at %s, no longer part of the graph" % (i, t[i][0]))
    rc = 1
elif tracked.get("version") != resolved.get("version"):
    print("PINS FAIL: the resolved-file format changed (version %s -> %s)"
          % (tracked.get("version"), resolved.get("version")))
    rc = 1
else:
    print("PINS ok: resolution reproduced all %d tracked pins, each at the same commit and from "
          "the same repository: %s"
          % (len(t), ", ".join("%s@%s" % (i, t[i][0]) for i in sorted(t))))

if rc:
    print("PINS FAIL: if this change is intended, re-record the pins from what was just resolved:")
    print("PINS FAIL:   cp .gate-artifacts/Package.resolved Package.resolved   # then commit it")
sys.exit(rc)
PY
}

s_xcodebuild() {
  # -onlyUsePackageVersionsFromResolvedFile is the second half of the pins step: that step proves
  # the tracked graph and the resolved graph agree, this makes the build itself unable to resolve
  # its way to anything else. Without it a build is always free to move a pin and say nothing.
  xcodebuild test \
    -scheme MemosNG \
    -destination "$GATE_DESTINATION" \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$XCRESULT" \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackagePluginValidation
}

s_bundlecheck() {
  # What ships is the BUNDLE, not the spec that produced it. XcodeGen can be given a resource and
  # still not put it where Apple looks, an INFOPLIST_KEY_ can land as the string "NO" where a
  # Boolean is read, and a deprecated key can survive a deletion in the wrong block — none of
  # which a green build says anything about. So the built product is opened and read.
  #
  # WHERE the product is is asked of xcodebuild rather than spelled out here: the configuration
  # and the product name are the project's to change, and a path written down in this script
  # would then point at nothing and read as a broken build instead of an out-of-date gate.
  local settings="$GATE_WORK/build-settings.json" app appex
  xcodebuild -showBuildSettings -json \
    -scheme MemosNG \
    -destination "$GATE_DESTINATION" \
    -derivedDataPath "$DERIVED" \
    -skipPackagePluginValidation > "$settings" 2>"$GATE_WORK/build-settings.err" || {
      echo "BUNDLE FAIL: xcodebuild -showBuildSettings failed"
      sed -n '1,20p' "$GATE_WORK/build-settings.err"
      return 1
    }
  cat > "$GATE_WORK/read-product-path.py" <<'PY'
import json, sys

path, target = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
# xcodebuild is free to print package-resolution chatter before the JSON, so the array is found
# rather than assumed to start at byte zero.
start = text.find("[")
if start < 0:
    sys.stderr.write("no JSON array in %s\n" % path)
    sys.exit(1)
try:
    entries, _ = json.JSONDecoder().raw_decode(text[start:])
except ValueError as error:
    sys.stderr.write("build settings do not parse: %s\n" % error)
    sys.exit(1)

for entry in entries:
    if entry.get("target") != target:
        continue
    settings = entry.get("buildSettings", {})
    build_dir = settings.get("TARGET_BUILD_DIR")
    product = settings.get("FULL_PRODUCT_NAME")
    if not build_dir or not product:
        sys.stderr.write("target %s declares no TARGET_BUILD_DIR/FULL_PRODUCT_NAME\n" % target)
        sys.exit(1)
    sys.stderr.write("product path from TARGET_BUILD_DIR + FULL_PRODUCT_NAME (%s / %s)\n"
                     % (build_dir, product))
    print(build_dir.rstrip("/") + "/" + product)
    sys.exit(0)

sys.stderr.write("no build settings for target %s (targets: %s)\n"
                 % (target, ", ".join(sorted(e.get("target", "?") for e in entries))))
sys.exit(1)
PY
  app="$(/usr/bin/python3 "$GATE_WORK/read-product-path.py" "$settings" MemosNG)" \
    || { echo "BUNDLE FAIL: cannot read the product path out of the build settings"; return 1; }
  [ -n "$app" ] || { echo "BUNDLE FAIL: empty product path"; return 1; }
  appex="$app/PlugIns/MemosShare.appex"
  echo "--- built product: $app"
  if [ ! -d "$app" ]; then
    echo "BUNDLE FAIL: no built app at $app"
    echo "    built products present:"
    ls -1 "$DERIVED/Build/Products" 2>&1 | sed 's/^/      /'
    return 1
  fi
  [ -d "$appex" ] || { echo "BUNDLE FAIL: no embedded extension at $appex"; return 1; }
  [ -n "$GATE_MARKETING_VERSION" ] || {
    echo "BUNDLE FAIL: project.yml does not name exactly one MARKETING_VERSION to expect"
    return 1
  }
  /usr/bin/python3 - "$app" "$appex" "$GATE_MARKETING_VERSION" <<'PY'
import plistlib, os, sys

app, appex = sys.argv[1], sys.argv[2]
# The expectation comes from project.yml, the one place the version is written.
EXPECTED_SHORT_VERSION = sys.argv[3]
rc = 0

def fail(msg):
    global rc
    print("BUNDLE FAIL: " + msg)
    rc = 1

def load(path):
    with open(path, "rb") as handle:
        return plistlib.load(handle)

def check(label, bundle, bundle_id):
    print("--- %s: %s" % (label, bundle))

    info_path = os.path.join(bundle, "Info.plist")
    if not os.path.isfile(info_path):
        fail("%s has no Info.plist" % label)
        return
    try:
        info = load(info_path)
    except Exception as error:
        fail("%s Info.plist does not parse: %s" % (label, error))
        return

    # Positive control, in the same read: a key that MUST be there. Without it, an "absent"
    # verdict below would only prove the reader came back empty.
    got_id = info.get("CFBundleIdentifier")
    if got_id == bundle_id:
        print("  ok (positive control): CFBundleIdentifier = %s" % got_id)
    else:
        fail("%s CFBundleIdentifier is %r, expected %r — the reader is not reading this bundle"
             % (label, got_id, bundle_id))
        return

    short = info.get("CFBundleShortVersionString")
    if short == EXPECTED_SHORT_VERSION:
        print("  ok: CFBundleShortVersionString = %s" % short)
    else:
        fail("%s CFBundleShortVersionString is %r, expected %r"
             % (label, short, EXPECTED_SHORT_VERSION))

    build = info.get("CFBundleVersion")
    if isinstance(build, str) and build.strip():
        print("  ok: CFBundleVersion = %s" % build)
    else:
        fail("%s CFBundleVersion is %r — an extension without one cannot be installed" % (label, build))

    export = info.get("ITSAppUsesNonExemptEncryption")
    if export is False:
        print("  ok: ITSAppUsesNonExemptEncryption = false (a real Boolean)")
    else:
        fail("%s ITSAppUsesNonExemptEncryption is %r, expected the Boolean false" % (label, export))

    if "UIRequiresFullScreen" in info:
        fail("%s still declares UIRequiresFullScreen, which iOS 26 deprecates" % label)
    else:
        print("  ok: UIRequiresFullScreen absent")

    privacy_path = os.path.join(bundle, "PrivacyInfo.xcprivacy")
    if not os.path.isfile(privacy_path):
        fail("%s has no PrivacyInfo.xcprivacy at its bundle root" % label)
        return
    try:
        privacy = load(privacy_path)
    except Exception as error:
        fail("%s PrivacyInfo.xcprivacy does not parse: %s" % (label, error))
        return
    print("  ok: PrivacyInfo.xcprivacy present at the bundle root")

    if privacy.get("NSPrivacyTracking") is not False:
        fail("%s NSPrivacyTracking is %r, expected false" % (label, privacy.get("NSPrivacyTracking")))
    if privacy.get("NSPrivacyTrackingDomains") != []:
        fail("%s NSPrivacyTrackingDomains is %r, expected empty"
             % (label, privacy.get("NSPrivacyTrackingDomains")))
    if privacy.get("NSPrivacyCollectedDataTypes") != []:
        fail("%s NSPrivacyCollectedDataTypes is %r, expected empty"
             % (label, privacy.get("NSPrivacyCollectedDataTypes")))

    declared = {
        entry.get("NSPrivacyAccessedAPIType"): entry.get("NSPrivacyAccessedAPITypeReasons")
        for entry in privacy.get("NSPrivacyAccessedAPITypes", []) or []
    }
    reasons = declared.get("NSPrivacyAccessedAPICategoryFileTimestamp")
    if reasons == ["C617.1"]:
        print("  ok: file-timestamp category declared with reason C617.1")
    else:
        fail("%s declares file-timestamp reasons %r, expected ['C617.1']" % (label, reasons))
    print("  declared API categories: %s" % (", ".join(sorted(declared)) or "(none)"))

check("app", app, "live.discomarder.memosng")
check("extension", appex, "live.discomarder.memosng.share")

# An extension's CFBundleVersion must equal its host's or the host will not install.
try:
    host_build = load(os.path.join(app, "Info.plist")).get("CFBundleVersion")
    ext_build = load(os.path.join(appex, "Info.plist")).get("CFBundleVersion")
    if host_build == ext_build:
        print("--- ok: app and extension share CFBundleVersion %s" % host_build)
    else:
        fail("app CFBundleVersion %r != extension %r" % (host_build, ext_build))
except Exception as error:
    fail("could not compare bundle versions: %s" % error)

sys.exit(rc)
PY
}

# Both halves of the warnings mutation below build the same way; only the tree differs.
build_memos_features() { # $1 = where the build log goes; returns xcodebuild's own exit code
  ( cd Packages/MemosFeatures \
    && xcodebuild build \
         -scheme MemosFeatures \
         -configuration Debug \
         -destination 'generic/platform=iOS Simulator' \
         -derivedDataPath "$GATE_WORK/warnings/MemosFeatures" \
         -clonedSourcePackagesDirPath "$GATE_WORK/warnings/spm" \
         -onlyUsePackageVersionsFromResolvedFile \
         -skipPackagePluginValidation ) > "$1" 2>&1
}

s_warnings() {
  # Every package builds clean or not at all — all five, because a warning that no build makes
  # fatal is a warning nobody retires.
  #
  # Four of them declare macOS as well as iOS, so SwiftPM builds them here on the build host and
  # -warnings-as-errors on the command line is the whole mechanism.
  #
  # MemosFeatures cannot be reached that way. Its screens are UIKit and SwiftUI-on-iOS and SwiftPM
  # has no iOS destination: measured on this host 2026-08-25, `swift build` refuses the package at
  # the manifest platform check, and forcing the compiler across with -Xswiftc -sdk/-target ends in
  # "using sysroot for 'MacOSX' but targeting 'iPhone'". So it is built by xcodebuild for the
  # simulator, and the fatality for that build comes from the target's OWN manifest
  # (.treatAllWarnings(as: .error) in Packages/MemosFeatures/Package.swift) rather than from a flag
  # here. Every setting xcodebuild takes from a command line or an xcconfig reaches the
  # dependencies as well, and each way of asking it for warnings-as-errors fails on somebody
  # else's code: SWIFT_TREAT_WARNINGS_AS_ERRORS=YES alone collides with the -suppress-warnings
  # Xcode gives package dependencies; adding SWIFT_SUPPRESS_WARNINGS=NO makes OpenAPIKit's
  # forced-cast warning this gate's failure; scoping both to the simulator SDK only moves it to
  # MarkdownUI's @_implementationOnly warning. A gate that goes red for a warning nobody here can
  # fix is a gate that gets ignored.
  #
  # Each package is its own root here, so SwiftPM would resolve each one's graph afresh from the
  # manifests' lower bounds — and a new upstream tag then reaches this step alone, past the pins
  # the rest of the gate builds against. It did: three tags published 1–3 Sep 2026 (generator
  # 1.13.1, runtime 1.12.1, http-types 1.7.0) put 192 unused-`public import` diagnostics into the
  # generated client while the pinned xcodebuild had none. So the tracked Package.resolved is
  # placed beside each manifest and the build is refused any version it does not name — the same
  # mechanism as -onlyUsePackageVersionsFromResolvedFile on the test build. SwiftPM accepts a
  # file that pins more packages than the root needs (measured on this host 2026-09-03).
  local rc=0 pkg
  for pkg in Packages/MemosAPI Packages/MemosCore Packages/MemosOutbox Packages/MemosShareKit; do
    echo "--- $pkg with -warnings-as-errors (SwiftPM, this host, tracked pins)"
    cp Package.resolved "$pkg/Package.resolved" || { rc=1; continue; }
    swift build --package-path "$pkg" \
      --scratch-path "$GATE_WORK/warnings/$(basename "$pkg")" \
      --only-use-versions-from-resolved-file \
      -Xswiftc -warnings-as-errors || rc=$?
    rm -f "$pkg/Package.resolved"
  done

  echo "--- Packages/MemosFeatures with warnings as errors (xcodebuild, iOS simulator, Debug)"
  # A one-line pre-check, so a manifest that simply lost the declaration says so plainly instead of
  # through a build log.
  if sed 's|//.*||' Packages/MemosFeatures/Package.swift \
     | grep -q 'treatAllWarnings(as: \.error'; then
    echo "ok (pre-check): MemosFeatures declares .treatAllWarnings(as: .error)"
  else
    echo "WARNAERR FAIL (early hint): Packages/MemosFeatures/Package.swift no longer declares" \
         ".treatAllWarnings(as: .error) — the canary build below is the authority on that"
    rc=1
  fi

  # That text is a hint, and only a hint. A declaration can be commented out, moved onto the test
  # target or conditioned away and the build still exits 0 with its warnings merely printed
  # (measured on this host 2026-08-25). Reading the build LOG for the flag was no better: a source
  # file can print whatever sentence a reader is looking for, and two rounds of review found two
  # more ways to write one. So nothing textual is load-bearing here any more.
  #
  # The proof is a controlled mutation judged by EXIT CODES. The target is built as it stands, and
  # then built again with a throwaway file that holds nothing but warnings. If warnings are fatal,
  # that second build cannot compile — so a canary that SURVIVES is the failure, and no source
  # file can spoof a compiler's refusal to produce an object.
  local mf_build_log="$GATE_WORK/warnings/MemosFeatures-build.log"
  local mf_canary_log="$GATE_WORK/warnings/MemosFeatures-canary.log"
  mkdir -p "$GATE_WORK/warnings"
  # Every source of the target is made to compile again: an incremental build that compiles nothing
  # cannot go red for a warning sitting in a file it skipped.
  find Packages/MemosFeatures/Sources -name '*.swift' -exec touch {} +
  # The same pins as the four builds above: xcodebuild reads a package's resolved file from beside
  # its manifest, and the flag in build_memos_features refuses any version it does not name.
  cp Package.resolved Packages/MemosFeatures/Package.resolved \
    || { echo "WARNAERR FAIL: cannot place the tracked pins beside Packages/MemosFeatures"; return 1; }
  build_memos_features "$mf_build_log"
  local real_rc=$?

  # The canary is written at ONE fixed path, and a file already sitting there is not ours to
  # replace: it would be built as part of the target, and whatever its symbols refer to could fail
  # the canary build for a reason that has nothing to do with warnings — which this step would read
  # as the canary doing its job. So an occupied path stops the step instead.
  local canary_path="$GATE_TARGET/Packages/MemosFeatures/Sources/MemosFeatures/GateWarningsCanary.swift"
  local canary_rc=0
  if [ -e "$canary_path" ] || [ -L "$canary_path" ]; then
    echo "WARNAERR FAIL: something already exists at $canary_path, which is where this step writes"
    echo "               its canary. It is never overwritten — a file of somebody else's failing"
    echo "               that build would read as a warning being fatal. Rename it and run again."
    echo "MemosFeatures build exit $real_rc; the canary build did not run, so this step cannot pass"
    cp "$mf_build_log" .gate-artifacts/MemosFeatures-warnings-build.log
    rm -f Packages/MemosFeatures/Package.resolved
    [ "$rc" -ne 0 ] || rc=1
    return $rc
  fi
  # Named before it is written, so the give-back can take it away even if this shell is killed in
  # the middle of the build below.
  GATE_CANARY_FILE="$canary_path"
  cat > "$GATE_CANARY_FILE" <<'SWIFT'
// Written by the gate for one build and deleted again: proof that a warning in this target cannot
// compile. Two warnings that can never be anything but warnings on their own.
#warning("mac-gate canary: a warning in MemosFeatures must be fatal")

private func gateWarningsCanary() {
    let gateWarningsCanaryValue = 1
}
SWIFT
  build_memos_features "$mf_canary_log"
  canary_rc=$?
  rm -f "$GATE_CANARY_FILE"
  GATE_CANARY_FILE=""
  rm -f Packages/MemosFeatures/Package.resolved

  cp "$mf_build_log" .gate-artifacts/MemosFeatures-warnings-build.log
  cp "$mf_canary_log" .gate-artifacts/MemosFeatures-canary-build.log
  # Diagnostics from the real build, for a human reading a failure. Evidence, not verdict.
  grep -E 'error:|warning:|\*\* BUILD' "$mf_build_log" | tail -15
  echo "MemosFeatures build exit $real_rc; canary build exit $canary_rc (logs in .gate-artifacts)"
  local canary_verdict="$GATE_TARGET/scripts/warnings-canary-verdict.sh"
  if [ -x "$canary_verdict" ]; then
    "$canary_verdict" "$real_rc" "$canary_rc" || rc=1
  else
    echo "WARNAERR FAIL: $canary_verdict is missing or not executable, so the two exit codes"
    echo "               cannot be judged and this step proves nothing"
    rc=1
  fi
  return $rc
}

s_deps() {
  local rc=0 pkg
  for pkg in Packages/*/; do
    [ -f "$pkg/Package.swift" ] || continue
    echo "--- swift package show-dependencies: $pkg (tracked pins)"
    # Listed from the same pins the builds used, so the graph this prints is the graph that built.
    cp Package.resolved "$pkg/Package.resolved" || { rc=1; continue; }
    swift package --package-path "$pkg" --scratch-path "$GATE_WORK/scratch/$(basename "$pkg")" \
      --only-use-versions-from-resolved-file show-dependencies || rc=$?
    rm -f "$pkg/Package.resolved"
  done
  # The dependency rule is a property of the manifests, so it is checked on the manifests, with a
  # positive control in the same run: a grep that finds nothing proves nothing on its own.
  echo "--- dependency rule (Features -> Core -> API) ---"
  if grep -n "MemosCore\|MemosFeatures" Packages/MemosAPI/Package.swift; then
    echo "DEPRULE FAIL: MemosAPI depends on a higher layer"; rc=1
  else
    echo "DEPRULE ok: MemosAPI/Package.swift has no MemosCore/MemosFeatures reference"
  fi
  if grep -n "MemosFeatures" Packages/MemosCore/Package.swift; then
    echo "DEPRULE FAIL: MemosCore depends on MemosFeatures"; rc=1
  else
    echo "DEPRULE ok: MemosCore/Package.swift has no MemosFeatures reference"
  fi
  # The outbox is the durability layer: it must stay buildable and readable on its own, which it
  # only does while it names no other layer of this app at all.
  if grep -n "MemosAPI\|MemosCore\|MemosFeatures" Packages/MemosOutbox/Package.swift; then
    echo "DEPRULE FAIL: MemosOutbox names another layer"; rc=1
  else
    echo "DEPRULE ok: MemosOutbox/Package.swift names no other layer"
  fi
  # The share extension may carry no client, no session and no credential, so the package it
  # takes its logic from may name no layer but the outbox. An extension is a separate process
  # with a fraction of the memory and its own entitlements; whatever it links, it ships.
  if grep -n "MemosAPI\|MemosCore\|MemosFeatures" Packages/MemosShareKit/Package.swift; then
    echo "DEPRULE FAIL: MemosShareKit names a layer the share extension may not carry"; rc=1
  else
    echo "DEPRULE ok: MemosShareKit/Package.swift names no layer but MemosOutbox"
  fi
  if grep -n "MemosCore" Packages/MemosFeatures/Package.swift; then
    echo "DEPRULE ok (positive control): MemosFeatures/Package.swift references MemosCore"
  else
    echo "DEPRULE FAIL: positive control missing — MemosFeatures does not reference MemosCore"; rc=1
  fi
  # Every raw Security call lives in ONE file. A delete whose query names no access group matches
  # items in every group the app can reach, which is how the device credential deleted itself;
  # confining those calls to Keychain.swift, where the access group is not optional, is what makes
  # "every query names its group" checkable instead of habitual. Sources only — a test may plant a
  # corrupt item to prove the wrapper raises on it. Like the dependency rule this is a LITERAL
  # text grep, so no other source file may carry the string at all, comments included: prose
  # elsewhere names the statuses in words.
  echo "--- keychain rule (raw SecItem calls live in Keychain.swift) ---"
  local strays
  strays="$(grep -rl 'SecItem' --include='*.swift' Packages/*/Sources Sources \
    | grep -v '^Packages/MemosCore/Sources/MemosCore/Security/Keychain.swift$')"
  if [ -n "$strays" ]; then
    echo "KEYCHAIN FAIL: the Security call prefix appears outside Keychain.swift:"
    echo "$strays"
    rc=1
  else
    echo "KEYCHAIN ok: no raw SecItem call outside Keychain.swift"
  fi
  if grep -q 'SecItemDelete' Packages/MemosCore/Sources/MemosCore/Security/Keychain.swift; then
    echo "KEYCHAIN ok (positive control): Keychain.swift is where SecItemDelete lives"
  else
    echo "KEYCHAIN FAIL: positive control missing — Keychain.swift has no SecItemDelete"; rc=1
  fi
  return $rc
}

s_sharelink() {
  # SwiftUI's built-in share-link control shares a value it is already holding, so a row built from
  # one can only ever hand over something that exists before the tap — which is how a signed
  # household URL was handed to a recipient instead of the file (MEMNG-207). No test in the
  # Features bundle can tell that control from a Button: SwiftUI exposes no view tree, and the
  # accessibility probe reads the same label either way. So it is held the way the dependency rule
  # and the keychain rule are held, by a literal grep with a positive control in the same run. The
  # arithmetic lives in a script of its own because that script's text must carry the literal, and
  # anything under the checked package may not.
  echo "--- share-link rule (no share-link control in the Features layer) ---"
  local sharelink_rule="$GATE_TARGET/scripts/sharelink-rule.sh"
  if [ -x "$sharelink_rule" ]; then
    "$sharelink_rule" "$GATE_TARGET"
    return $?
  fi
  echo "SHARELINK FAIL: $sharelink_rule is missing or not executable, so the Features layer was"
  echo "                never checked and this step proves nothing"
  return 1
}

s_textsel() {
  # A minted token's plaintext is on screen once, and the Copy button hands it over as a pasteboard
  # item that expires (MEMNG-138). SwiftUI's text-selection modifier reopens the lane it closes: the
  # system's own Copy over the same Text, straight to the general pasteboard, past the expiring
  # write, and over a fragment at that. No test in the Features bundle can see an ABSENT modifier —
  # SwiftUI exposes no view tree and the accessibility probe reads the same label either way — so it
  # is held the way the share-link control's absence is held, by a literal grep with a positive
  # control in the same run. The arithmetic lives in a script of its own for the same reason: that
  # script's text must carry the literal, and the files it checks may not.
  echo "--- text-selection rule (the token management screen's secret is not selectable) ---"
  local textsel_rule="$GATE_TARGET/scripts/textselection-rule.sh"
  if [ -x "$textsel_rule" ]; then
    "$textsel_rule" "$GATE_TARGET"
    return $?
  fi
  echo "TEXTSELECTION FAIL: $textsel_rule is missing or not executable, so the token management"
  echo "                    screen was never checked and this step proves nothing"
  return 1
}

s_buttonstyle() {
  # A card on the token management screen is ONE row of a List, and SwiftUI presses a row's
  # default-styled buttons on a tap anywhere in that row — with several in one row, not necessarily
  # the one under the finger, so a tap on a token's name revoked a different token and a tap on a
  # minted token's plaintext pressed Done and took the one look at it away (MEMNG-476, MEMNG-477).
  # The rule is negative because every positive form of it is satisfied by a style that confines
  # nothing: the screen may not name the plain control type at all, and the house component is the
  # only way to put a control on it. The arithmetic lives in a script of its own for the reason the
  # share-link rule's does: that script's text must carry the literal, and the file it checks may
  # not.
  echo "--- token-screen button rule (every control on that screen goes through the house component) ---"
  local buttonstyle_rule="$GATE_TARGET/scripts/managetokens-buttonstyle-rule.sh"
  if [ -x "$buttonstyle_rule" ]; then
    "$buttonstyle_rule" "$GATE_TARGET"
    return $?
  fi
  echo "BUTTONSTYLE FAIL: $buttonstyle_rule is missing or not executable, so the token management"
  echo "                  screen's controls were never checked and this step proves nothing"
  return 1
}

s_refusal() {
  # A refusal is judged where the answer arrives and acted on one or more actor hops later, and in
  # between a renewal can replace the credential it was about. The fix is one typed value carrying
  # the epoch of the credential that EARNED the refusal and one decision taken at the effect
  # (MEMNG-270); what this step adds is that a NEW classification or effect site cannot be added
  # without a reviewer seeing it. Two rules, and they are not equal: rule 1 is a literal grep and a
  # HINT, rule 2 is the fence — pinned entry points and pinned call counts. The arithmetic lives in
  # a script of its own for the reason the share-link rule's does: that script's text must carry the
  # literal, and the scope it checks may not.
  echo "--- refusal-sites rule (one typed refusal, an enumerated set of effects) ---"
  local refusal_rule="$GATE_TARGET/scripts/refusal-sites-rule.sh"
  if [ -x "$refusal_rule" ]; then
    "$refusal_rule" "$GATE_TARGET"
    return $?
  fi
  echo "REFUSAL FAIL: $refusal_rule is missing or not executable, so the refusal sites were never"
  echo "              checked and this step proves nothing"
  return 1
}

s_apicover() {
  # The generated client's filter is inclusion-only: an operation the config does not name is not
  # generated, no build mentions it, and the first sign is a feature nobody can write. That is the
  # same silence this repo already met from the other side (a nullable union dropped from a
  # generated type), so the subtraction the config is derived from — every operationId in the
  # vendored document minus a named exclusion set — is checked here rather than trusted. The
  # arithmetic lives in a script of its own for the reason the other two rules' does: that script
  # carries the exclusion set and its reasons, and the files it checks may not.
  echo "--- openapi-coverage rule (every vendored operation generated or knowingly excluded) ---"
  local coverage_rule="$GATE_TARGET/scripts/openapi-coverage-rule.sh"
  if [ -x "$coverage_rule" ]; then
    "$coverage_rule" "$GATE_TARGET"
    return $?
  fi
  echo "OPENAPI-COVERAGE FAIL: $coverage_rule is missing or not executable, so the generator's"
  echo "                       filter was never checked and this step proves nothing"
  return 1
}

s_testcount() {
  # Swift Testing does not emit XCTest's "Executed N tests" line (a correct Swift Testing bundle
  # reads 0 there), so the per-bundle counts come from the result bundle, which is authoritative
  # for both harnesses. A bundle that EXECUTED zero cases is a failure: a suite that silently stops
  # being built, or one whose every case skipped itself, would otherwise pass the gate.
  [ -d "$XCRESULT" ] || { echo "no result bundle at $XCRESULT"; return 1; }
  xcrun xcresulttool get test-results tests --path "$XCRESULT" --format json \
    > .gate-artifacts/test-results.json || return 1
  /usr/bin/python3 - "$GATE_TEST_BUNDLES" <<'PY'
import json, sys
wanted = sys.argv[1].split()
data = json.load(open(".gate-artifacts/test-results.json"))

# A case that SKIPPED did not run, and this count exists to answer "did each bundle run anything".
# Several suites here skip themselves when their preconditions are absent (no server credentials,
# no device capability), so a bundle counted by its Test Case NODES reports a full suite while
# having executed nothing — the failure this step was written to catch, passing it. Only the
# outcomes that mean a body executed are counted; everything else — Skipped, and any result this
# walker has never been shown — is counted apart and named. The tuple is the quick mode's counter's,
# kept in step by hand: the two are separate heredocs, and only this one is fed a full-gate result
# bundle.
EXECUTED = ("Passed", "Failed", "Expected Failure")

def walk(node, bundle, ran, idle):
    kind = node.get("nodeType")
    name = node.get("name", "")
    if kind in ("Unit test bundle", "UI test bundle"):
        bundle = name[:-len(".xctest")] if name.endswith(".xctest") else name
        ran.setdefault(bundle, 0)
        idle.setdefault(bundle, 0)
    if kind == "Test Case" and bundle:
        if node.get("result") in EXECUTED:
            ran[bundle] = ran.get(bundle, 0) + 1
        else:
            idle[bundle] = idle.get(bundle, 0) + 1
    for child in node.get("children", []) or []:
        walk(child, bundle, ran, idle)

ran, idle = {}, {}
for root in data.get("testNodes", []) or []:
    walk(root, None, ran, idle)
print("test counts per bundle: " + (", ".join(f"{k}={v}" for k, v in sorted(ran.items())) or "(none)"))
print("skipped or not run: " + (", ".join(f"{k}={v}" for k, v in sorted(idle.items())) or "(none)"))
# Every run that OBTAINED the counts writes them here before any of them is judged — before the
# loop below and before the shell's comparison — so a run that either one FAILS still hands back
# the file a deliberate reduction is re-recorded from, the shape the pins step's Package.resolved
# copy already has. A run that never obtained counts leaves no candidate and exits non-zero: no
# result bundle returns 1 at the `-d "$XCRESULT"` test, a failing `xcresulttool` returns 1 on its
# own line, and JSON this cannot parse or walk raises here, which exits this block non-zero and is
# handed back as the step's `count_rc`. One row per bundle the gate wanted, in that order, because
# the comparison is per bundle and the baseline is required to name exactly this set.
with open(".gate-artifacts/testcount-baseline.tsv", "w") as candidate:
    for bundle in wanted:
        candidate.write("%s\t%d\n" % (bundle, ran.get(bundle, 0)))

rc = 0
for bundle in wanted:
    n = ran.get(bundle, 0)
    skipped = idle.get(bundle, 0)
    print(f"Executed {n} tests in {bundle}")
    if n < 1:
        print(f"TESTCOUNT FAIL: {bundle} executed {n} test cases ({skipped} skipped or not run)")
        rc = 1
sys.exit(rc)
PY
  local count_rc=$? compare_rc verdict baseline
  verdict="$GATE_TARGET/scripts/testcount-verdict.sh"
  baseline="$GATE_TARGET/tests/gate/testcount-baseline.tsv"
  # Running at all is a floor, not a count: a bundle that lost cases still runs something. The
  # counts just written are judged against the tracked baseline, and both halves are reported
  # before either one decides the step, so a failing count never hides what the comparison said.
  if [ -x "$verdict" ]; then
    "$verdict" .gate-artifacts/testcount-baseline.tsv "$baseline"
    compare_rc=$?
  else
    echo "TESTCOUNT FAIL: $verdict is missing or not executable, so the per-bundle counts were"
    echo "                never compared with the tracked baseline and this step proves nothing"
    compare_rc=1
  fi
  [ "$count_rc" -eq 0 ] || return "$count_rc"
  return "$compare_rc"
}

# --- the quick mode's own sequence ----------------------------------------------------------------
# Everything above this line is the preamble both modes share: the lock check, the work
# directories, the disk sweep, this run's private device and its accessibility keys. From here the
# two part company. The quick sequence lints, generates the project (which is also what puts the
# tracked Package.resolved where SwiftPM reads it), compiles the test bundles, and runs the scope it
# was given on the device — nothing else, and each step only if the one before it passed. It ends by
# exiting, so the full gate's steps below are never reached and MAC_GATE_REMOTE_SUMMARY, the line a
# verdict is read from, is never printed.
if [ "${GATE_QUICK:-0}" -eq 1 ]; then
  QUICK_XCRESULT="$GATE_TARGET/.gate-artifacts/MemosNG-quick.xcresult"
  # One scope, already validated on the controller: --only-testing is passed through verbatim,
  # --bundle is the same thing spelled with a bundle name. Empty means every bundle.
  if [ -n "$GATE_QUICK_ONLY_TESTING" ]; then
    quick_scope="$GATE_QUICK_ONLY_TESTING"
  else
    quick_scope="$GATE_QUICK_BUNDLE"
  fi

  s_quick_generate() {
    [ -f project.yml ] || { echo "no project.yml in $GATE_TARGET — nothing to generate"; return 3; }
    bin/generate.sh --spec project.yml
  }

  s_quick_build() {
    # -onlyUsePackageVersionsFromResolvedFile for the same reason the full gate's test build
    # carries it: a lockfile pins only the builds that READ it, and a quick build free to resolve
    # its own way would compile against a graph nothing in this repo names.
    xcodebuild build-for-testing \
      -scheme MemosNG \
      -destination "$GATE_DESTINATION" \
      -derivedDataPath "$DERIVED" \
      -onlyUsePackageVersionsFromResolvedFile \
      -skipPackagePluginValidation 2>&1 | tee .gate-artifacts/quick-build.log
    return "${PIPESTATUS[0]}"
  }

  s_quick_tests() {
    rm -rf "$QUICK_XCRESULT"
    set -- xcodebuild test-without-building \
      -scheme MemosNG \
      -destination "$GATE_DESTINATION" \
      -derivedDataPath "$DERIVED" \
      -resultBundlePath "$QUICK_XCRESULT" \
      -onlyUsePackageVersionsFromResolvedFile \
      -skipPackagePluginValidation
    [ -z "$quick_scope" ] || set -- "$@" "-only-testing:$quick_scope"
    "$@" 2>&1 | tee .gate-artifacts/quick-test.log
    quick_run_rc="${PIPESTATUS[0]}"
    # A green run of nothing is the failure this counts for. xcodebuild accepts an -only-testing
    # identifier that names no test and reports success, and Swift Testing emits no "Executed N
    # tests" line to contradict it — so the count comes from the result bundle, the same walk the
    # full gate's testcount step uses, scoped to what was asked for.
    if [ ! -d "$QUICK_XCRESULT" ]; then
      echo "QUICK FAIL: no result bundle at $QUICK_XCRESULT, so nothing says a test ran"
      [ "$quick_run_rc" -ne 0 ] || quick_run_rc=1
      return "$quick_run_rc"
    fi
    if ! xcrun xcresulttool get test-results tests --path "$QUICK_XCRESULT" --format json \
         > .gate-artifacts/quick-test-results.json; then
      echo "QUICK FAIL: the result bundle at $QUICK_XCRESULT could not be read"
      [ "$quick_run_rc" -ne 0 ] || quick_run_rc=1
      return "$quick_run_rc"
    fi
    /usr/bin/python3 - "$quick_scope" <<'QUICKCOUNT_PY'
import json, sys
scope = sys.argv[1]
bundle = scope.split("/")[0] if scope else ""
data = json.load(open(".gate-artifacts/quick-test-results.json"))

# A case that SKIPPED did not run, and this count exists to answer "did anything run". Several
# suites here skip themselves when their preconditions are absent (no server credentials, no
# device capability), so a scope of nothing but those would otherwise come back green having
# exercised no code at all. Only the outcomes that mean a body executed are counted; everything
# else — Skipped, and any result this walker has never been shown — is counted apart and named.
EXECUTED = ("Passed", "Failed", "Expected Failure")

def walk(node, current, ran, idle):
    kind = node.get("nodeType")
    name = node.get("name", "")
    if kind in ("Unit test bundle", "UI test bundle"):
        current = name[:-len(".xctest")] if name.endswith(".xctest") else name
        ran.setdefault(current, 0)
        idle.setdefault(current, 0)
    if kind == "Test Case" and current:
        if node.get("result") in EXECUTED:
            ran[current] = ran.get(current, 0) + 1
        else:
            idle[current] = idle.get(current, 0) + 1
    for child in node.get("children", []) or []:
        walk(child, current, ran, idle)

ran, idle = {}, {}
for root in data.get("testNodes", []) or []:
    walk(root, None, ran, idle)
print("executed test cases for the quick scope: "
      + (", ".join("%s=%d" % (k, v) for k, v in sorted(ran.items())) or "(none)"))
print("skipped or not run: "
      + (", ".join("%s=%d" % (k, v) for k, v in sorted(idle.items())) or "(none)"))
executed = ran.get(bundle, 0) if bundle else sum(ran.values())
skipped = idle.get(bundle, 0) if bundle else sum(idle.values())
if executed < 1:
    print("QUICK FAIL: %s executed %d test cases (%d skipped or not run)"
          % (scope or "every bundle", executed, skipped))
    sys.exit(1)
print("Executed %d test cases for %s (%d skipped or not run)"
      % (executed, scope or "every bundle", skipped))
QUICKCOUNT_PY
    if [ $? -ne 0 ] && [ "$quick_run_rc" -eq 0 ]; then quick_run_rc=1; fi
    return "$quick_run_rc"
  }

  quick_tests_rc="-"
  quick_build_rc="-"
  # Lint before anything is generated or compiled: it is the same s_format the full gate runs, it
  # reads nothing a build produces, and a run that stops here costs seconds instead of the minutes
  # a build would spend before failing the merge verdict for a reason already known.
  echo "::: lint :::"
  s_format
  quick_lint_rc=$?
  echo "MAC_GATE_STEP lint $quick_lint_rc"
  quick_exit="$quick_lint_rc"
  if [ "$quick_lint_rc" -eq 0 ]; then
    echo "::: generate :::"
    s_quick_generate
    quick_build_rc=$?
    echo "MAC_GATE_STEP generate $quick_build_rc"
    if [ "$quick_build_rc" -eq 0 ]; then
      echo "::: build :::"
      s_quick_build
      quick_build_rc=$?
      echo "MAC_GATE_STEP build $quick_build_rc"
    fi
    if [ "$quick_build_rc" -eq 0 ]; then
      echo "::: tests${quick_scope:+ ($quick_scope)} :::"
      s_quick_tests
      quick_tests_rc=$?
      echo "MAC_GATE_STEP tests $quick_tests_rc"
      quick_exit="$quick_tests_rc"
    else
      echo "::: tests skipped (the build failed) :::"
      quick_exit="$quick_build_rc"
    fi
  else
    echo "::: generate, build and tests skipped (the lint failed) :::"
  fi
  echo "MAC_GATE_QUICK_REMOTE: lint=$quick_lint_rc build=$quick_build_rc tests=$quick_tests_rc"
  exit "$quick_exit"
fi

step xcodegen   s_xcodegen
step entitlements s_entitlements
step swiftformat s_format
step pins       s_pins
step xcodebuild s_xcodebuild
step bundle     s_bundlecheck
step warnaserr  s_warnings
step deps       s_deps
step refusal    s_refusal
step sharelink  s_sharelink
step textsel    s_textsel
step buttonstyle s_buttonstyle
step apicover   s_apicover
step testcount  s_testcount

echo "MAC_GATE_REMOTE_SUMMARY:$summary | exit=$first_fail"
exit "$first_fail"
REMOTE_EOF
} | ssh -o BatchMode=yes "$host" 'bash -s' 2>&1 | tee -a "$log"
remote_rc="${PIPESTATUS[1]}"
record remote "$remote_rc"

# The quick mode's three numbers come from the line the build host printed, read back out of the log
# the stream above was tee'd into. Anything that is not a run of digits is not a number this
# script will repeat: a remote that stopped before it said anything leaves them all as "-", which is
# the honest answer and cannot be misread as a zero.
if [ "$QUICK" -eq 1 ]; then
  quick_remote_line="$(sed -n 's/^MAC_GATE_QUICK_REMOTE: //p' "$log" | tail -1)"
  quick_field() {
    local value
    value="$(printf '%s\n' "$quick_remote_line" | sed -n "s/.*$1=\\([^ ]*\\).*/\\1/p")"
    case "$value" in
      ''|*[!0-9]*) printf -- '-' ;;
      *) printf '%s' "$value" ;;
    esac
  }
  QUICK_LINT_RC="$(quick_field lint)"
  QUICK_BUILD_RC="$(quick_field build)"
  QUICK_TESTS_RC="$(quick_field tests)"
fi

# --- (7) copy the evidence back ---------------------------------------------------------------
say "--- step: copyback ---"
rsync -a -e ssh "$host:$target/.gate-artifacts/" "$artifacts/" 2>&1 | tee -a "$log"
record copyback "${PIPESTATUS[0]}"
say "artifacts   : $artifacts"

end_run

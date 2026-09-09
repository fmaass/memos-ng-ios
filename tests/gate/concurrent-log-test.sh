#!/usr/bin/env bash
#
# Two gate runs at once must not be able to overwrite each other's log.
#
# The failure this exists for: a caller redirected the gate's stdout to a generically named file in
# a shared scratch directory, a second agent's run redirected its own stdout to the SAME name, and
# the truncation took the first run's evidence with it — the reader had nothing left to read and the
# run had to be started again. A gate whose only record is the file its caller happened to open is a
# gate one careless `>` can erase, so the gate keeps its own complete log at a path only that run
# can have produced: MAC_GATE_ARTIFACTS, named for the branch and the run token, and named back on
# the line before the verdict so the caller can find it.
#
# The probe drives the one mode that needs no build host — `--classify-only` — because the property
# under test is about the log, not about a build. Both runs are given the SAME repository, the SAME
# branch, the SAME artifacts directory and the SAME caller redirect: everything a collision needs.
# What they must not share is their own log.
#
# Run it directly (`tests/gate/concurrent-log-test.sh`) or let the gate run it: it ships beside the
# other suites in tests/gate and the gate's selftest step runs every one of them.
#
# Exit: 0 = each run kept its own intact, self-named log; 1 = at least one check failed (named).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
GATE="$repo_root/bin/mac-gate.sh"
[ -x "$GATE" ] || { echo "FAIL: $GATE is not an executable file"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-concurrent-log-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

fails=0
checks=0
ok()   { checks=$((checks + 1)); echo "ok   $1"; }
bad()  { checks=$((checks + 1)); fails=$((fails + 1)); echo "FAIL $1"; }

# The fixture: a repository whose origin/main is the baseline the classifier measures against, and
# a branch off it. Everything the probe reads it built itself.
BRANCH="fix/concurrent-log"
BRANCH_SLUG="fix-concurrent-log"
work="$tmp/repo" origin="$tmp/repo.git"
{
  git init --quiet --bare "$origin" \
  && git init --quiet -b main "$work" \
  && git -C "$work" config user.email gate-test@example.invalid \
  && git -C "$work" config user.name "gate test" \
  && git -C "$work" config commit.gpgsign false \
  && git -C "$work" config core.hooksPath "$tmp/no-hooks"
} || { echo "FAIL: cannot build the fixture repository"; exit 1; }
mkdir -p "$work/docs"
printf 'a guide\n' > "$work/docs/guide.md"
printf 'MARKETING_VERSION: "1.0.0"\n' > "$work/project.yml"
git -C "$work" add -A >/dev/null || exit 1
git -C "$work" commit --quiet -m "baseline" || exit 1
git -C "$work" remote add origin "$origin" || exit 1
git -C "$work" push --quiet origin main || exit 1
git -C "$work" checkout --quiet -b "$BRANCH" || exit 1
printf 'more guide\n' >> "$work/docs/guide.md"
git -C "$work" commit --quiet -am "docs" || exit 1

# The artifacts directory is SHARED by both runs and lives outside the repository: shared because
# two runs writing to two directories would prove nothing about their names, and outside because a
# file created inside the tree would join the change set the classifier is reading.
art="$tmp/artifacts"
mkdir -p "$art"

# The control on the count below: nothing here wrote a run log before the runs did.
pre_count="$(find "$art" -maxdepth 1 -name 'mac-gate*.log' | wc -l | tr -d ' ')"
if [ "$pre_count" = 0 ]; then
  ok "the shared artifacts directory holds no run log before the runs"
else
  bad "the shared artifacts directory already held $pre_count run log(s) — the count below proves nothing"
fi

# One name, opened with `>` by both runs: the collision the incident was.
caller_log="$tmp/gate-red2.log"

run_one() {
  cd "$work" && env -u MAC_GATE_HOST -u MAC_GATE_BRANCH \
    MAC_GATE_ARTIFACTS="$art" "$GATE" --classify-only > "$caller_log" 2>&1
}
run_one & pid_a=$!
run_one & pid_b=$!
wait "$pid_a"; rc_a=$?
wait "$pid_b"; rc_b=$?

# 0 = the docs-only fast path applies. Both runs classified the same tree, so both must say it; a
# refusal or a crash would leave no log for reasons that have nothing to do with the name.
if [ "$rc_a" = 0 ] && [ "$rc_b" = 0 ]; then
  ok "both concurrent --classify-only runs finished with the fast-path exit code"
else
  bad "a run did not classify: exit codes were $rc_a and $rc_b (expected 0 and 0)"
  [ ! -s "$caller_log" ] || sed 's/^/     | /' "$caller_log"
fi

mapfile -t logs < <(find "$art" -maxdepth 1 -type f -name 'mac-gate*.log' | sort)
if [ "${#logs[@]}" -eq 2 ]; then
  ok "two runs of the same branch left two distinct logs"
else
  bad "expected 2 run logs in the shared artifacts directory, found ${#logs[@]}: ${logs[*]:-none}"
fi

# The search above is wider than the rule below on purpose: a gate that went back to one shared
# name is found here and judged there, rather than missed by the pattern and reported as absent.

# Each log has to be intact and attributable to the run that wrote it. Attribution is not a claim
# in the text: the file NAMES ITSELF, so a log whose content belongs to another run says so.
for f in "${logs[@]}"; do
  base="${f##*/}"
  if [ -s "$f" ]; then ok "$base is not empty"; else bad "$base is empty"; fi
  missing=""
  for needle in 'CLASSIFY verdict=' 'CLASSIFY base=' 'CLASSIFY reason='; do
    grep -qF "$needle" "$f" || missing="$missing '$needle'"
  done
  if [ -z "$missing" ]; then
    ok "$base holds the whole classification"
  else
    bad "$base is truncated — it is missing$missing"
  fi
  if grep -qF "CLASSIFY log=$f" "$f"; then
    ok "$base names its own path, so its content belongs to its own run"
  else
    bad "$base does not name itself (no 'CLASSIFY log=$f' line) — it cannot be attributed to a run"
  fi
  case "$base" in
    mac-gate-"$BRANCH_SLUG"-*.log) ok "$base is named for the branch and this run" ;;
    *) bad "$base is not named for the branch ($BRANCH_SLUG) and a per-run token" ;;
  esac
done

# The positive control on the fixture: the caller's file was really shared, so the runs really did
# have the chance to overwrite one another where it was the only record.
if [ -e "$caller_log" ]; then
  ok "both runs were pointed at the one caller path $(basename "$caller_log")"
else
  bad "the shared caller path was never written — the collision this probe is about did not happen"
fi

echo "gate concurrent run logs: $((checks - fails)) of $checks checks passed"
[ "$fails" -eq 0 ] || { echo "CONCURRENT-LOG-TEST FAIL: $fails check(s) failed"; exit 1; }
echo "CONCURRENT-LOG-TEST ok"

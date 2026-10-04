#!/usr/bin/env bash
#
# Merged lanes must disappear without costing another branch its mirror or build cache.
# Run locally or through the gate's selftest; no build host is needed.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-reap-XXXXXX")" || exit 1
# macOS temp paths can traverse /var, while the reaper compares physical paths.
tmp="$(cd "$tmp" && pwd -P)" || exit 1
trap 'rm -rf "$tmp"' EXIT
gate="$tmp/gate"
work="$tmp/work"
current=fix/current
printf '%s\n' main fix/on-origin > "$tmp/origin-heads"
printf '%s\n' main fix/local-only > "$tmp/local-heads"
sort -u "$tmp/origin-heads" "$tmp/local-heads" > "$tmp/survivors"

for branch in fix/merged fix/deep/merged fix/fresh-lock fix/old-lock fix/ownerless-lock \
  fix/on-origin fix/local-only fix/young fix/recent-work "$current"; do
  mkdir -p "$gate/$branch" "$work/$branch/DerivedData"
  printf 'mirror\n' > "$gate/$branch/project.yml"
  printf 'cache\n' > "$work/$branch/DerivedData/cache"
  touch -t 202001010000 "$gate/$branch" "$work/$branch" || exit 1
done
touch "$gate/fix/young" "$work/fix/young" "$work/fix/recent-work"
for branch in fix/fresh-lock fix/old-lock fix/ownerless-lock; do
  mkdir -p "$gate/$branch.lock"
  [ "$branch" != fix/ownerless-lock ] || continue
  printf 'owner\n' > "$gate/$branch.lock/owner"
done
touch -t 202001010000 "$gate/fix/old-lock.lock/owner" || exit 1
printf '%s\n' "$$" > "$gate/fix/old-lock.lock/remote-pid"

# With no reaper, exercise the old behaviour: the directories survive and the assertions fail.
if [ -f "$repo_root/scripts/reap-gate-lanes.sh" ]; then
  . "$repo_root/scripts/reap-gate-lanes.sh"
  reap_gate_lanes "$gate" "$work" "$current" "$tmp/survivors" > "$tmp/reap.log" 2>&1
  rc=$?
else
  : > "$tmp/reap.log"
  rc=0
fi

fails=0
[ "$rc" -eq 0 ] || { echo "FAIL reaper exited $rc"; cat "$tmp/reap.log"; fails=$((fails + 1)); }
for branch in fix/merged fix/deep/merged; do
  for dir in "$gate/$branch" "$work/$branch" "$gate/$branch.lock"; do
    if [ -e "$dir" ]; then
      echo "FAIL stale lane survived: ${dir#"$tmp/"}"
      fails=$((fails + 1))
    fi
  done
done
for branch in fix/fresh-lock fix/old-lock fix/ownerless-lock fix/on-origin fix/local-only \
  fix/young fix/recent-work "$current"; do
  if [ ! -f "$gate/$branch/project.yml" ] || [ ! -f "$work/$branch/DerivedData/cache" ]; then
    echo "FAIL protected lane changed: $branch"
    fails=$((fails + 1))
  fi
done
for branch in fix/fresh-lock fix/old-lock fix/ownerless-lock; do
  if [ ! -d "$gate/$branch.lock" ]; then
    echo "FAIL lock removed: $branch"
    fails=$((fails + 1))
  fi
done
for file in fix/fresh-lock.lock/owner fix/old-lock.lock/owner fix/old-lock.lock/remote-pid; do
  if [ ! -f "$gate/$file" ]; then
    echo "FAIL lock contents removed: $file"
    fails=$((fails + 1))
  fi
done
if [ "$fails" -eq 0 ]; then
  logged=0
  while read -r tag action size dir; do
    if [ "$tag $action" != 'GATE_REAP removing' ] || [ -z "$size" ]; then
      echo "FAIL missing directory size in reap log"
      fails=$((fails + 1))
    fi
    case "$dir" in
      "$gate/fix/merged"|"$work/fix/merged"|"$gate/fix/deep/merged"|"$work/fix/deep/merged") ;;
      *) echo "FAIL unexpected directory in reap log: $dir"; fails=$((fails + 1)) ;;
    esac
    logged=$((logged + 1))
  done < "$tmp/reap.log"
  [ "$logged" -eq 4 ] || { echo "FAIL expected four sized directory logs, got $logged"; fails=$((fails + 1)); }
fi
# Both sweeps use this predicate after selecting a victim; stamps cannot prove a run is dead.
mkdir -p "$gate/fix/sweep-stale" "$work/fix/sweep-stale"
touch -t 202001010000 "$gate/fix/sweep-stale" "$work/fix/sweep-stale" || exit 1
for root in "$gate" "$work"; do
  for branch in fix/old-lock fix/sweep-stale; do
    aged="$(find "$root/$branch" -maxdepth 0 -type d -mtime +3 -print)" || exit 1
    [ -n "$aged" ] || { echo "FAIL sweep fixture is not older than three days"; fails=$((fails + 1)); }
  done
  if gate_lane_is_unlocked "$gate" "$work" "$root/fix/old-lock"; then
    echo "FAIL hygiene predicate admitted a locked stale lane: $root/fix/old-lock"
    fails=$((fails + 1))
  fi
  if ! gate_lane_is_unlocked "$gate" "$work" "$root/fix/sweep-stale"; then
    echo "FAIL hygiene predicate rejected an unlocked stale lane: $root/fix/sweep-stale"
    fails=$((fails + 1))
  fi
done
# A failed run removes its own rebuild trees and nothing else; a passed one keeps them.
drop="$tmp/drop/work/fix/lane"
mkdir -p "$drop/warnings/MemosCore" "$drop/DerivedData"
printf 'cache\n' > "$drop/warnings/MemosCore/cache"
printf 'cache\n' > "$drop/DerivedData/cache"
out="$(gate_drop_failed_rebuilds "$drop" 0)"; drc=$?
if [ "$drc" -ne 0 ] || [ -n "$out" ] || [ ! -f "$drop/warnings/MemosCore/cache" ]; then
  echo "FAIL a passed run lost its rebuild trees or spoke (exit $drc): $out"; fails=$((fails + 1))
fi
for bad_rc in '' x1 -1; do
  out="$(gate_drop_failed_rebuilds "$drop" "$bad_rc")"; drc=$?
  if [ "$drc" -ne 1 ] || [ ! -f "$drop/warnings/MemosCore/cache" ] || ! printf '%s' "$out" | grep -q 'kept'; then
    echo "FAIL exit code '$bad_rc' removed the rebuild trees or did not say so (exit $drc): $out"; fails=$((fails + 1))
  fi
done
out="$(gate_drop_failed_rebuilds "" 65)"; drc=$?
if [ "$drc" -ne 1 ] || ! printf '%s' "$out" | grep -q 'no work directory'; then
  echo "FAIL an empty work directory was not refused (exit $drc): $out"; fails=$((fails + 1))
fi
# A lane that is a symlink to another lane, or a path that is not plain and absolute, removes nothing.
other="$tmp/drop/work/fix/other"
mkdir -p "$other/warnings"; printf 'cache\n' > "$other/warnings/cache"
ln -s "$other" "$tmp/drop/work/fix/alias"
ln -s "$tmp/drop/work" "$tmp/drop/root-alias"
for odd in "$tmp/drop/work/fix/alias" "$tmp/drop/root-alias/fix/other" "$tmp/drop/work/fix/x/../other" "$tmp/drop/work/fix/./other" \
  "$tmp/drop/work/fix//other" "/$tmp/drop/work/fix/other" "${other#/}"; do
  out="$(cd / && gate_drop_failed_rebuilds "$odd" 65)"; drc=$?
  if [ "$drc" -ne 1 ] || [ ! -f "$other/warnings/cache" ] || ! printf '%s' "$out" | grep -q 'kept'; then
    echo "FAIL work directory '$odd' was not refused, or another lane lost its trees (exit $drc): $out"; fails=$((fails + 1))
  fi
done
out="$(gate_drop_failed_rebuilds "$drop" 65)"; drc=$?
if [ "$drc" -ne 0 ] || [ -e "$drop/warnings" ] || [ ! -f "$drop/DerivedData/cache" ] \
   || ! printf '%s' "$out" | grep -q "^GATE_HYGIENE rebuilds: the run failed (exit 65), removed its own $drop/warnings ([0-9]* KiB)$"; then
  echo "FAIL a failed run did not remove exactly its rebuild trees, naming them (exit $drc): $out"; fails=$((fails + 1))
fi
out="$(gate_drop_failed_rebuilds "$drop" 65)"; drc=$?
[ "$drc" -eq 0 ] && [ -z "$out" ] || { echo "FAIL a failed run with no rebuild trees left was not a no-op (exit $drc): $out"; fails=$((fails + 1)); }
# ... and the gate's remote script calls it with its own work tree and verdict, before its summary.
gate_text="${MAC_GATE_SCRIPT:-$repo_root/bin/mac-gate.sh}"
calls="$(grep -n '^gate_drop_failed_rebuilds "\$GATE_WORK" "\$first_fail"$' "$gate_text" | cut -d: -f1)"
summary_at="$(grep -n '^echo "MAC_GATE_REMOTE_SUMMARY:' "$gate_text" | cut -d: -f1)"
if [ "$(printf '%s\n' "$calls" | grep -c .)" -ne 1 ] || [ -z "$summary_at" ] || [ "$calls" -ge "$summary_at" ]; then
  echo "FAIL $gate_text does not call gate_drop_failed_rebuilds once before its remote summary (calls: ${calls:-none})"
  fails=$((fails + 1))
fi
if [ "$fails" -ne 0 ]; then
  echo "REAP-LANES-TEST FAIL: $fails assertion(s) failed"
  exit 1
fi
echo "ok   removed both unlocked, absent branches older than 24 hours, including the nested lane"
echo "ok   preserved fresh, old, and ownerless locks and their lanes"
echo "ok   preserved local-only, origin, current, and younger-than-24-hour lanes"
echo "ok   logged all four removed directories with sizes"
echo "ok   shared hygiene predicate protects old locked gate/work lanes and admits unlocked ones"
echo "ok   a failed run removes only its own rebuild trees, naming them; a passed run keeps them"
echo "ok   the gate's remote script calls that cleanup once, before its summary"
echo "REAP-LANES-TEST ok"

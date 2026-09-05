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
if [ "$fails" -ne 0 ]; then
  echo "REAP-LANES-TEST FAIL: $fails assertion(s) failed"
  exit 1
fi
echo "ok   removed both unlocked, absent branches older than 24 hours, including the nested lane"
echo "ok   preserved fresh, old, and ownerless locks and their lanes"
echo "ok   preserved local-only, origin, current, and younger-than-24-hour lanes"
echo "ok   logged all four removed directories with sizes"
echo "REAP-LANES-TEST ok"

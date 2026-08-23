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
# Git is the only medium of exchange between the two machines. The gate directory is a mirror,
# never a checkout: it is rsync'd with --delete, it is never opened in Xcode, and a developer's
# own clone on the build host is never a target (the containment check below enforces that).
#
# Usage:
#   MAC_GATE_HOST=<ssh-alias> bin/mac-gate.sh
#
# Environment:
#   MAC_GATE_HOST        (required) ssh alias/host of the Mac build host
#   MAC_GATE_BRANCH      override the branch that names the gate directory (default: current)
#   MAC_GATE_SIMULATOR   simulator device name (default: iPhone 17)
#   MAC_GATE_ARTIFACTS   local directory for the copied-back .xcresult/screenshots/log
#                        (default: <repo>/.gate-artifacts)
#   MAC_GATE_TEST_BUNDLES  space-separated test bundles that must each run >= 1 test
#                        (default: MemosCoreTests MemosAPITests MemosFeaturesTests)
#
# Exit codes: 2 = refusal (unsafe or unusable inputs, nothing was copied or run);
#             otherwise the exit code of the first failing step.

set -uo pipefail

GATE_ROOT_REMOTE='$HOME/build/memos-ng-ios/gate'
SIMULATOR="${MAC_GATE_SIMULATOR:-iPhone 17}"
TEST_BUNDLES="${MAC_GATE_TEST_BUNDLES:-MemosCoreTests MemosAPITests MemosFeaturesTests}"

die_refuse() {
  printf 'mac-gate: REFUSED: %s\n' "$1" >&2
  exit 2
}

# Single-quote escaping for values interpolated into a script sent to the build host, so a branch
# name can never become remote shell syntax.
esc() { printf "%s" "$1" | sed "s/'/'\\\\''/g"; }

# --- inputs -----------------------------------------------------------------------------------
host="${MAC_GATE_HOST:-}"
[ -n "$host" ] || die_refuse "MAC_GATE_HOST is not set (ssh alias of the Mac build host)"

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

artifacts="${MAC_GATE_ARTIFACTS:-$repo_root/.gate-artifacts}"
mkdir -p "$artifacts" || die_refuse "cannot create the artifacts directory $artifacts"
log="$artifacts/mac-gate.log"
: > "$log" || die_refuse "cannot write $log"

say() { printf '%s\n' "$*" | tee -a "$log"; }

# --- (5) provenance ---------------------------------------------------------------------------
{
  printf '=== mac-gate %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'host        : %s\n' "$host"
  printf 'repo        : %s\n' "$repo_root"
  printf 'branch      : %s\n' "$branch"
  printf 'HEAD        : %s\n' "$head_sha"
  printf 'HEAD subject: %s\n' "$(git log -1 --pretty=%s)"
  printf 'simulator   : %s\n' "$SIMULATOR"
  printf -- '--- git status --porcelain (full) ---\n'
  git status --porcelain
  printf -- '--- git diff --stat (working tree vs HEAD) ---\n'
  git diff --stat HEAD
  printf -- '--- end provenance ---\n'
} 2>&1 | tee -a "$log"

# --- (2) resolve the remote target and refuse anything outside the gate root -------------------
# Resolved on the build host, where the path actually exists: lexically (so a `..` in the branch
# name cannot escape) AND physically (so a symlink planted in the gate root cannot either).
preflight_out="$(
  {
    printf "branch='%s'\n" "$(esc "$branch")"
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
mkdir -p "$target" || { echo "REFUSE cannot create $target"; exit 2; }
echo "TARGET $target"
PRE_EOF
  } | ssh -o BatchMode=yes "$host" 'bash -s' 2>&1
)"
preflight_rc=$?
printf '%s\n' "$preflight_out" | tee -a "$log" >/dev/null
if [ "$preflight_rc" -ne 0 ]; then
  printf '%s\n' "$preflight_out" >&2
  exit 2
fi
target="$(printf '%s\n' "$preflight_out" | sed -n 's/^TARGET //p' | tail -1)"
[ -n "$target" ] || die_refuse "the build host did not return a gate target"
say "gate target : $host:$target"

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
  say "$line"
  exit "$first_fail"
}

# --- (3) mirror the worktree ------------------------------------------------------------------
say "--- step: rsync ---"
rsync -a --delete \
  --exclude '.git' \
  --exclude '.build' \
  --exclude 'DerivedData' \
  --exclude '*.xcodeproj' \
  --exclude '*.xcresult' \
  --exclude '.gate-artifacts' \
  -e ssh \
  "$repo_root"/ "$host:$target/" 2>&1 | tee -a "$log"
record rsync "${PIPESTATUS[0]}"
[ "$first_fail" -eq 0 ] || summary_and_exit

# --- (4) the ordered, fail-fast checks on the build host --------------------------------------
say "--- step: remote ---"
{
  printf "GATE_TARGET='%s'\n" "$(esc "$target")"
  printf "GATE_SIMULATOR='%s'\n" "$(esc "$SIMULATOR")"
  printf "GATE_TEST_BUNDLES='%s'\n" "$(esc "$TEST_BUNDLES")"
  cat <<'REMOTE_EOF'
set -uo pipefail
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
GATE_WORK="$(printf '%s' "$GATE_TARGET" \
  | sed 's#/build/memos-ng-ios/gate/#/build/memos-ng-ios/work/#')"
[ "$GATE_WORK" != "$GATE_TARGET" ] || { echo "remote: cannot derive a work directory"; exit 2; }
mkdir -p "$GATE_WORK" || { echo "remote: cannot create $GATE_WORK"; exit 2; }
DERIVED="$GATE_WORK/DerivedData"

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
  xcodegen generate --spec project.yml
}

s_format() { swift format lint --strict --recursive . ; }

s_xcodebuild() {
  xcodebuild test \
    -scheme MemosNG \
    -destination "platform=iOS Simulator,name=$GATE_SIMULATOR" \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$XCRESULT" \
    -skipPackagePluginValidation
}

s_warnings() {
  # The layers below the UI build clean or not at all. xcodebuild cannot be told to treat warnings
  # as errors for two package targets only, so they are built again through SwiftPM — which is why
  # both declare macOS as well as iOS.
  local rc=0 pkg
  for pkg in Packages/MemosAPI Packages/MemosCore; do
    echo "--- $pkg with -warnings-as-errors"
    swift build --package-path "$pkg" \
      --scratch-path "$GATE_WORK/warnings/$(basename "$pkg")" \
      -Xswiftc -warnings-as-errors || rc=$?
  done
  return $rc
}

s_deps() {
  local rc=0 pkg
  for pkg in Packages/*/; do
    [ -f "$pkg/Package.swift" ] || continue
    echo "--- swift package show-dependencies: $pkg"
    swift package --package-path "$pkg" --scratch-path "$GATE_WORK/scratch/$(basename "$pkg")" \
      show-dependencies || rc=$?
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
  if grep -n "MemosCore" Packages/MemosFeatures/Package.swift; then
    echo "DEPRULE ok (positive control): MemosFeatures/Package.swift references MemosCore"
  else
    echo "DEPRULE FAIL: positive control missing — MemosFeatures does not reference MemosCore"; rc=1
  fi
  return $rc
}

s_testcount() {
  # Swift Testing does not emit XCTest's "Executed N tests" line (a correct Swift Testing bundle
  # reads 0 there), so the per-bundle counts come from the result bundle, which is authoritative
  # for both harnesses. A bundle that ran zero tests is a failure: a suite that silently stops
  # being built would otherwise pass the gate.
  [ -d "$XCRESULT" ] || { echo "no result bundle at $XCRESULT"; return 1; }
  xcrun xcresulttool get test-results tests --path "$XCRESULT" --format json \
    > .gate-artifacts/test-results.json || return 1
  /usr/bin/python3 - "$GATE_TEST_BUNDLES" <<'PY'
import json, sys
wanted = sys.argv[1].split()
data = json.load(open(".gate-artifacts/test-results.json"))

def walk(node, bundle, counts):
    kind = node.get("nodeType")
    name = node.get("name", "")
    if kind in ("Unit test bundle", "UI test bundle"):
        bundle = name[:-len(".xctest")] if name.endswith(".xctest") else name
        counts.setdefault(bundle, 0)
    if kind == "Test Case" and bundle:
        counts[bundle] = counts.get(bundle, 0) + 1
    for child in node.get("children", []) or []:
        walk(child, bundle, counts)

counts = {}
for root in data.get("testNodes", []) or []:
    walk(root, None, counts)
print("test counts per bundle: " + (", ".join(f"{k}={v}" for k, v in sorted(counts.items())) or "(none)"))
rc = 0
for bundle in wanted:
    n = counts.get(bundle, 0)
    print(f"Executed {n} tests in {bundle}")
    if n < 1:
        print(f"TESTCOUNT FAIL: {bundle} ran {n} tests")
        rc = 1
sys.exit(rc)
PY
}

step xcodegen   s_xcodegen
step swiftformat s_format
step xcodebuild s_xcodebuild
step warnaserr  s_warnings
step deps       s_deps
step testcount  s_testcount

echo "MAC_GATE_REMOTE_SUMMARY:$summary | exit=$first_fail"
exit "$first_fail"
REMOTE_EOF
} | ssh -o BatchMode=yes "$host" 'bash -s' 2>&1 | tee -a "$log"
remote_rc="${PIPESTATUS[1]}"
record remote "$remote_rc"

# --- (7) copy the evidence back ---------------------------------------------------------------
say "--- step: copyback ---"
rsync -a -e ssh "$host:$target/.gate-artifacts/" "$artifacts/" 2>&1 | tee -a "$log"
record copyback "${PIPESTATUS[0]}"
say "artifacts   : $artifacts"

summary_and_exit

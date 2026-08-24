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
# The ordered checks are: generate the project, lint, test, rebuild the two lower layers with
# warnings as errors, check the dependency rule, read the SHIPPING bundles back, and count the
# tests that actually ran.
#
# Git is the only medium of exchange between the two machines. The gate directory is a mirror,
# never a checkout: it is rsync'd with --delete, it is never opened in Xcode, and a developer's
# own clone on the build host is never a target (the containment check below enforces that).
#
# Usage:
#   MAC_GATE_HOST=<ssh-alias> bin/mac-gate.sh
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
#   MAC_GATE_ARTIFACTS   local directory for the copied-back .xcresult/screenshots/log
#                        (default: <repo>/.gate-artifacts)
#   MAC_GATE_TEST_BUNDLES  ADDITIONAL test bundles that must each run >= 1 test. The three
#                        bundles below are always enforced and cannot be removed by setting
#                        this — an override that could shrink the list would let a suite stop
#                        being built without the gate noticing.
#
# Exit codes: 2 = refusal (unsafe or unusable inputs, nothing was copied or run);
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

# The private device is named here, where the branch and this process are known: the branch so a
# stray device says which run left it behind, the pid so two runs of the SAME branch (a re-run
# started before the first one let go) still cannot land on one device. Reduced to the character
# set the branch validation above already allows, minus '/', and cut short enough to stay a
# readable name in `simctl list`.
branch_slug="$(printf '%s' "$branch" | tr '/' '-' | tr -c 'A-Za-z0-9._-' '-')"
branch_slug="${branch_slug:0:40}"
DEVICE_NAME="gate-${branch_slug}-$$"

artifacts="${MAC_GATE_ARTIFACTS:-$repo_root/.gate-artifacts}"
mkdir -p "$artifacts" || die_refuse "cannot create the artifacts directory $artifacts"
log="$artifacts/mac-gate.log"
: > "$log" || die_refuse "cannot write $log"

say() { printf '%s\n' "$*" | tee -a "$log"; }

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
trap 'remove_gate_device' EXIT
trap 'remove_gate_device; exit 130' INT
trap 'remove_gate_device; exit 143' TERM
trap 'remove_gate_device; exit 129' HUP

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
echo "GATE_ROOT $gate_root"
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
  --exclude '.git' --exclude 'signing.local.yml' \
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
  printf "GATE_DEVICE_NAME='%s'\n" "$(esc "$DEVICE_NAME")"
  printf "GATE_DEVICE_TYPE='%s'\n" "$(esc "$DEVICE_TYPE")"
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

# --- the simulator this run gets ----------------------------------------------------------------
# A simulator holds ONE installation per bundle id, so two branches building on the same device
# overwrite each other's app and the loser launches against the winner's frameworks — dyld
# "Symbol not found", a red gate, and nothing wrong with the code. Each run therefore gets a
# device of its own and gives it back. The trap is the giving back, and it has to hold on the
# paths nobody plans for: a failing step, a refusal, the SIGHUP this shell gets when the ssh
# connection goes away. An undeleted device is disk on a build host that has little to spare.
GATE_DEVICE_UDID=""
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
trap 'device_cleanup' EXIT
trap 'device_cleanup; exit 130' INT
trap 'device_cleanup; exit 143' TERM
trap 'device_cleanup; exit 129' HUP

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
  if [ "$second" = 'group.live.discomarder.memosng' ]; then
    echo "ENTITLEMENT ok: the app group is named as a migration source, after it"
  else
    echo "ENTITLEMENT FAIL: the second keychain access group is '$second'"; rc=1
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

s_xcodebuild() {
  xcodebuild test \
    -scheme MemosNG \
    -destination "$GATE_DESTINATION" \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$XCRESULT" \
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
step entitlements s_entitlements
step swiftformat s_format
step xcodebuild s_xcodebuild
step bundle     s_bundlecheck
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

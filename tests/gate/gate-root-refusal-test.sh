#!/usr/bin/env bash
#
# A gate root the build host cannot create is refused naming what stopped it: the nearest part of
# the path that exists, with its mode and owner, not a bare `Permission denied`.
#
# On 2026-09-03 the preflight refused with `mkdir: …: Permission denied` and `REFUSE cannot create
# the gate root`, and it took a second look on the host to find ~/build left mode 000. The cases
# below build that shape, and two others, in a throwaway directory and feed the path to
# gate_root_refusal (scripts/gate-root-refusal.sh). The last part cuts the preflight out of
# bin/mac-gate.sh and runs it with HOME pointed at the throwaway tree, so the refusal is shown to be
# the one the gate itself prints.
#
# Run locally or through the gate's selftest; no build host is needed. Cannot run as root, where a
# mode-000 directory stops nothing (the control below says so rather than passing).
# GATE_ROOT_REFUSAL and MAC_GATE_SCRIPT point the test at other copies (used to prove it red).
#
# Exit: 0 = every case behaved as expected; 1 = at least one did not (the failures are named).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
HELPER="${GATE_ROOT_REFUSAL:-$repo_root/scripts/gate-root-refusal.sh}"
GATE="${MAC_GATE_SCRIPT:-$repo_root/bin/mac-gate.sh}"
for f in "$HELPER" "$GATE"; do
  [ -f "$f" ] || { echo "FAIL: $f is missing"; exit 1; }
done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-root-refusal-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
tmp="$(cd "$tmp" && pwd -P)" || exit 1
# The modes are given back first, or the removal itself is refused.
trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

fails=0
cases=0
ok()  { cases=$((cases + 1)); echo "ok   $1"; }
bad() { cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $1"; }
show() { printf '%s\n' "$1" | sed 's/^/     | /'; }

# shellcheck source=/dev/null
. "$HELPER"
me="$(id -un)"

expect() { # $1 = case label, $2 = the path the mkdir wanted, $3... = strings the line must hold
  local label="$1" wanted="$2" out n needle; shift 2
  if mkdir -p "$wanted" 2>/dev/null; then
    bad "$label: control: mkdir -p $wanted succeeded, so there is no refusal to describe"
    return
  fi
  out="$(gate_root_refusal "$wanted")"
  n="$(printf '%s\n' "$out" | grep -c .)"
  if [ "$n" -ne 1 ]; then bad "$label: expected exactly one line, got $n"; show "$out"; return; fi
  for needle in "REFUSE cannot create the gate root $wanted" "$@"; do
    if ! printf '%s\n' "$out" | grep -qF -- "$needle"; then
      bad "$label: the refusal does not name '$needle'"; show "$out"; return
    fi
  done
  ok "$label: $out"
}

if [ "$(id -u)" -eq 0 ]; then
  bad "control: running as root, where mode 000 stops nothing — the cases below cannot bite"
fi

# (1) The 2026-09-03 shape: ~/build exists, mode 000, and everything under it is out of reach.
mkdir -p "$tmp/h1/build"
chmod 000 "$tmp/h1/build"
expect "a mode-000 ~/build" "$tmp/h1/build/memos-ng-ios/gate" \
  "nearest existing ancestor $tmp/h1/build is mode d--------- owner $me:" "not writable and searchable by $me"

# (2) ~/build is a file.
mkdir -p "$tmp/h2"
printf 'not a directory\n' > "$tmp/h2/build"
expect "a ~/build that is a file" "$tmp/h2/build/memos-ng-ios/gate" \
  "nearest existing ancestor $tmp/h2/build is mode -rw" "(not a directory)"

# (3) No ~/build at all, under a home the user cannot write: the walk stops at the home.
mkdir -p "$tmp/h3"
chmod 555 "$tmp/h3"
expect "no ~/build under a read-only home" "$tmp/h3/build/memos-ng-ios/gate" \
  "nearest existing ancestor $tmp/h3 is mode dr-xr-xr-x owner $me:" "not writable and searchable by $me"

# (4) A dangling symlink where ~/build should be: named as itself, not walked past.
mkdir -p "$tmp/h4"
ln -s "$tmp/h4/gone" "$tmp/h4/build"
expect "a dangling ~/build symlink" "$tmp/h4/build/memos-ng-ios/gate" \
  "nearest existing ancestor $tmp/h4/build is mode l"

# --- the gate's own preflight -----------------------------------------------------------------------
# The preflight as the gate sends it: the helpers it carries, then its body, run with HOME pointed at
# case (1). It has to stop at the gate root, exit 2, and print the named refusal.
assemble() { # $1 = 1 to carry the helper, 0 not to
  printf "branch='fix/x'\nlock_owner='test'\norigin_fetched='0'\nreap_skip_reason='test'\nsurviving_branches=''\n"
  [ "$1" -eq 0 ] || cat "$HELPER"
  awk "/cat <<'PRE_EOF'\$/ { f = 1; next } f && /^PRE_EOF\$/ { exit } f { print }" "$GATE"
}
pre="$tmp/preflight.sh"
assemble 1 > "$pre"
assemble 0 > "$tmp/preflight-no-helper.sh"
if grep -q 'gate_root_raw="\$HOME/build/memos-ng-ios/gate"' "$pre"; then
  ok "control: the preflight body was cut out of the gate"
else
  bad "cannot find the preflight body (cat <<'PRE_EOF' … PRE_EOF) in $GATE"
fi
out="$(HOME="$tmp/h1" bash "$pre" 2>&1)"; rc=$?
# The LAST line, so a refusal that let the preflight carry on (and be stopped by a later check) fails.
if [ "$rc" -eq 2 ] \
   && printf '%s\n' "$out" | tail -n 1 | grep -qF "REFUSE cannot create the gate root $tmp/h1/build/memos-ng-ios/gate: the nearest existing ancestor $tmp/h1/build is mode d---------"; then
  ok "the gate's preflight refuses a mode-000 ~/build naming it (exit 2)"
else
  bad "the gate's preflight did not name the mode-000 ~/build (exit $rc)"; show "$out"
fi
# Without the helper — a tree that predates it — the preflight still refuses; the name is all it loses.
out="$(HOME="$tmp/h1" bash "$tmp/preflight-no-helper.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s\n' "$out" | tail -n 1 | grep -qxF "REFUSE cannot create the gate root $tmp/h1/build/memos-ng-ios/gate"; then
  ok "without the helper the preflight still refuses the gate root (exit 2)"
else
  bad "without the helper the preflight did not refuse the gate root (exit $rc)"; show "$out"
fi
# And it carries the helper: the preflight above got it from this test, the gate from its copy.
# Counted, not `grep -q`: a reader that stops at the first hit leaves the writer a broken pipe, and
# under pipefail that reads as no hit at all.
carried="$(grep -v '^[[:space:]]*#' "$GATE" | grep -cF 'cat "$GATE_RUN_COPY/scripts/gate-root-refusal.sh"')"
if [ "${carried:-0}" -ge 1 ]; then
  ok "the gate hands scripts/gate-root-refusal.sh to the build host with the preflight"
else
  bad "the gate does not hand scripts/gate-root-refusal.sh to the build host"
fi

echo "gate root refusal: $((cases - fails)) of $cases checks passed"
[ "$fails" -eq 0 ]

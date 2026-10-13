#!/usr/bin/env bash
#
# scripts/local-lint.sh, the gate's local lint (MEMNG-807): the same `swift format lint --strict
# --recursive .` the build host runs, on the calling machine, before the run queues for the estate
# lock. Driven here with a fake `swift` and a fake `docker` first on PATH, so what is checked is what
# the helper DOES with each answer:
#   - a native swift-format of the build host's major is used first; its lint rc and its output are
#     the helper's, and MAC_GATE_LOCALLINT names both sides' versions;
#   - without one, the docker image swift:6.3 is used only when it is already present — the helper
#     never pulls, and the tree goes in read-only;
#   - neither: the fall-through code (100), and the reason says what was missing;
#   - a tool that could not render a verdict (timeout, docker refusing, an rc swift-format never
#     gives for findings) falls through as well (101), never as a pass and never as a refusal;
#   - and, where this machine has the real image, the real lint agrees on one bad and one clean file.
#
# Run it directly or let the gate run it: it is one of the selftests the gate names. Exit: 0 =
# every case behaved as expected (a case this machine cannot run prints SKIP and why); 1 = not.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
HELPER="${LOCAL_LINT_HELPER:-$repo_root/scripts/local-lint.sh}"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-locallint-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "${tmp:?}"' EXIT

fails=0
cases=0
ok()   { cases=$((cases + 1)); echo "ok   $1"; }
bad()  { cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $1"; }
skip() { echo "SKIP $1"; }
show() { printf '%s\n' "$1" | sed 's/^/     | /'; }

if [ ! -r "$HELPER" ]; then
  echo "FAIL $HELPER is missing"
  echo "local-lint-test: 1 case(s), 1 failure(s)"
  exit 1
fi

# --- the trees -------------------------------------------------------------------------------------
# The repo's own .swift-format, so the real-image case reads the rules the gate reads. The bad file
# breaks two of them: a declaration far past lineLength 100, and an indentation of 2 where 4 is set.
new_tree() { # $1 = name, $2 = bad|clean
  local t="$tmp/tree-$1"
  mkdir -p "$t/Sources"
  cp "$repo_root/.swift-format" "$t/.swift-format" || return 1
  if [ "$2" = bad ]; then
    {
      printf 'struct Wide {\n'
      printf '  let aVeryLongPropertyNameThatKeepsGoing: [String: [Int]] = ["first": [1, 2, 3], "second": [4, 5, 6], "third": [7]]\n'
      printf '}\n'
    } > "$t/Sources/Bad.swift"
  else
    printf 'struct Narrow {\n    let value = 1\n}\n' > "$t/Sources/Clean.swift"
  fi
  printf '%s' "$t"
}
BAD="$(new_tree bad bad)" || { echo "FAIL: cannot build the bad tree"; exit 1; }
CLEAN="$(new_tree clean clean)" || { echo "FAIL: cannot build the clean tree"; exit 1; }

# --- the fakes -------------------------------------------------------------------------------------
# Each records every call (arguments and working directory) to $FAKE_DIR/calls and answers from the
# FAKE_* variables a case sets.
make_fakes() { # $1 = dir, then the fakes to install (swift, docker)
  local dir="$1" f; shift
  mkdir -p "$dir/bin"
  for f in "$@"; do
    case "$f" in
      swift) cat > "$dir/bin/swift" <<'SWIFT_EOF'
#!/usr/bin/env bash
printf 'swift %s | cwd=%s\n' "$*" "$PWD" >> "$FAKE_DIR/calls"
# A hang that ignores TERM, as a wedged tool would: only a KILL ends it.
hang() { trap '' TERM; sleep 30; exit 0; }
case "$*" in
  "format --version") [ "${FAKE_HANG:-}" != version ] || hang; [ -z "${FAKE_SWIFT_VERSION:-}" ] || printf '%s\n' "$FAKE_SWIFT_VERSION"; exit "${FAKE_SWIFT_VERSION_RC:-0}" ;;
  "format lint --strict --recursive .")
    [ "${FAKE_HANG:-}" != lint ] || hang
    [ -z "${FAKE_LINT_OUT:-}" ] || printf '%s\n' "$FAKE_LINT_OUT" >&2
    exit "${FAKE_LINT_RC:-0}" ;;
esac
exit 64
SWIFT_EOF
      ;;
      docker) cat > "$dir/bin/docker" <<'DOCKER_EOF'
#!/usr/bin/env bash
printf 'docker %s | cwd=%s\n' "$*" "$PWD" >> "$FAKE_DIR/calls"
hang() { trap '' TERM; sleep 30; exit 0; }
case "$1" in
  pull) exit 0 ;;
  image) [ "${FAKE_HANG:-}" != inspect ] || hang; [ "${2:-}" = inspect ] && exit "${FAKE_INSPECT_RC:-0}"; exit 64 ;;
  run)
    case "$*" in
      *" swift format --version") [ "${FAKE_HANG:-}" != dockerversion ] || hang; printf '%s\n' "${FAKE_DOCKER_VERSION:-6.3.3}"; exit 0 ;;
      *" swift format lint --strict --recursive .")
        # The container's own timeout is the fake's argument, never obeyed: only the client's ends it.
        [ "${FAKE_HANG:-}" != dockerlint ] || hang
        [ -z "${FAKE_LINT_OUT:-}" ] || printf '%s\n' "$FAKE_LINT_OUT" >&2
        exit "${FAKE_LINT_RC:-0}" ;;
    esac
    exit 64 ;;
esac
exit 64
DOCKER_EOF
      ;;
    esac
    chmod +x "$dir/bin/$f"
  done
}

# A PATH holding only what the helper itself needs, for the case where neither tool may be found
# however this machine is set up: the fakes' directory is put in front of it.
MINBIN="$tmp/minbin"
mkdir -p "$MINBIN"
for tool in bash env timeout sed head tr cat grep awk date mkdir rm dirname sleep; do
  p="$(command -v "$tool" 2>/dev/null)" || continue
  case "$p" in /*) ln -s "$p" "$MINBIN/$tool" ;; esac
done

# One helper call in a clean bash: OUT (stdout and stderr), RC and CALLS afterwards.
run_helper() { # $1 = case name, $2 = tree, $3 = minimal|full PATH, then the fakes to install
  local name="$1" tree="$2" pathmode="$3" path; shift 3
  FAKE_DIR="$tmp/case-$name"
  mkdir -p "$FAKE_DIR"
  : > "$FAKE_DIR/calls"
  make_fakes "$FAKE_DIR" "$@"
  path="$FAKE_DIR/bin:$PATH"
  [ "$pathmode" = minimal ] && path="$FAKE_DIR/bin:$MINBIN"
  local t0; t0="$(date +%s)"
  # Bounded from outside as well, so a helper that does hang fails this case instead of the suite.
  OUT="$(timeout -k 5 120 env "PATH=$path" FAKE_DIR="$FAKE_DIR" FAKE_HANG="${FAKE_HANG:-}" FAST="${FAST:-}" \
    FAKE_SWIFT_VERSION="${FAKE_SWIFT_VERSION-6.3.3}" FAKE_SWIFT_VERSION_RC="${FAKE_SWIFT_VERSION_RC:-0}" \
    FAKE_DOCKER_VERSION="${FAKE_DOCKER_VERSION:-6.3.3}" FAKE_INSPECT_RC="${FAKE_INSPECT_RC:-0}" \
    FAKE_LINT_OUT="${FAKE_LINT_OUT:-}" FAKE_LINT_RC="${FAKE_LINT_RC:-0}" \
    "$MINBIN/bash" -c 'source "$1" || exit 99
      # The hang cases shrink every deadline to a second, so the real escalation is what they time.
      if [ -n "$FAST" ]; then
        LOCAL_LINT_TIMEOUT=1 LOCAL_LINT_VERSION_TIMEOUT=1 LOCAL_LINT_INSPECT_TIMEOUT=1
        LOCAL_LINT_DOCKER_VERSION_TIMEOUT=1 LOCAL_LINT_DOCKER_MARGIN=1 LOCAL_LINT_KILL_AFTER=1
      fi
      local_lint_report "$2" "6.3.0 (pinned, read 2026-10-13)" 6' \
    local-lint-test "$HELPER" "$tree" 2>&1)"
  RC=$?
  SECS=$(( $(date +%s) - t0 ))
  CALLS="$(cat "$FAKE_DIR/calls")"
}
has()   { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
lline() { printf '%s\n' "$OUT" | grep '^MAC_GATE_LOCALLINT ' | tail -1; }
PIN="mac=6.3.0 (pinned, read 2026-10-13)"
ERR_LINE="Sources/Bad.swift:2:101: error: [LineLength] line is too long"

# --- (a) native, a formatting error: the lint's rc and its line are the helper's ---------------------
FAKE_LINT_RC=1 FAKE_LINT_OUT="$ERR_LINE" run_helper native-bad "$BAD" minimal swift docker
if [ "$RC" -eq 1 ]; then ok "(a) native lint finds an error: the helper exits 1"; else bad "(a) native bad: exit $RC, expected 1"; show "$OUT"; fi
if has "$ERR_LINE"; then ok "(a) the lint's own error line reaches the output"; else bad "(a) the error line is missing"; show "$OUT"; fi
if [ "$(lline)" = "MAC_GATE_LOCALLINT rc=1 local=native version=6.3.3 $PIN" ]; then
  ok "(a) MAC_GATE_LOCALLINT names rc=1, the tool, the local version and the Mac's"
else bad "(a) the MAC_GATE_LOCALLINT line is [$(lline)]"; show "$OUT"; fi
if printf '%s\n' "$CALLS" | grep -qxF "swift format lint --strict --recursive . | cwd=$BAD"; then
  ok "(a) the lint ran as 'swift format lint --strict --recursive .' in the tree's root"
else bad "(a) the lint call was not the gate's, in the tree root"; show "$CALLS"; fi
if printf '%s\n' "$CALLS" | grep -q '^docker '; then bad "(a) docker was consulted although a native swift-format answered"; show "$CALLS"
else ok "(a) a native swift-format is used first: docker is never consulted"; fi
if printf '%s\n' "$CALLS" | grep -E '^swift ' | grep -vE '^swift format (--version|lint --strict --recursive \.) ' | grep -q .; then
  bad "(a) swift was called with something other than --version or the lint (a rewrite?)"; show "$CALLS"
else ok "(a) swift is asked for its version and the lint, nothing else (no 'format -i')"; fi

# --- (b) native, a clean tree -----------------------------------------------------------------------
FAKE_LINT_RC=0 run_helper native-clean "$CLEAN" minimal swift docker
if [ "$RC" -eq 0 ] && [ "$(lline)" = "MAC_GATE_LOCALLINT rc=0 local=native version=6.3.3 $PIN" ]; then
  ok "(b) a clean tree: exit 0 and rc=0 on the line"
else bad "(b) native clean: exit $RC, line [$(lline)]"; show "$OUT"; fi

# --- (c) neither tool on PATH: the fall-through, and what was missing --------------------------------
run_helper none "$CLEAN" minimal
if [ "$RC" -eq 100 ]; then ok "(c) no swift and no docker: the fall-through code 100"; else bad "(c) none: exit $RC, expected 100"; show "$OUT"; fi
if has "fell through" && has "no native swift-format" && has "no docker"; then
  ok "(c) the output says it fell through, and that neither a native swift-format nor docker was found"
else bad "(c) the fall-through reason does not name what was missing"; show "$OUT"; fi
if [ "$(lline)" = "MAC_GATE_LOCALLINT rc=- local=none version=- $PIN" ]; then
  ok "(c) MAC_GATE_LOCALLINT says rc=- local=none"
else bad "(c) the line is [$(lline)]"; show "$OUT"; fi

# --- (d) docker present, the image absent: fall through, and never pull ------------------------------
FAKE_INSPECT_RC=1 run_helper no-image "$BAD" minimal docker
if [ "$RC" -eq 100 ] && has "swift:6.3"; then ok "(d) the image is not present: fall-through 100, and the reason names swift:6.3"
else bad "(d) no image: exit $RC"; show "$OUT"; fi
if printf '%s\n' "$CALLS" | grep -q '^docker image inspect swift:6.3 '; then ok "(d) presence was asked with 'docker image inspect swift:6.3'"
else bad "(d) docker image inspect was never called"; show "$CALLS"; fi
if printf '%s\n' "$CALLS" | grep -qE '^docker (pull|run)'; then bad "(d) docker pulled or ran although the image is absent"; show "$CALLS"
else ok "(d) nothing was pulled and nothing run"; fi

# --- (d2) docker with the image: the lint goes in read-only, without network and without a pull ------
FAKE_LINT_RC=1 FAKE_LINT_OUT="$ERR_LINE" run_helper docker-bad "$BAD" minimal docker
if [ "$RC" -eq 1 ] && has "$ERR_LINE" \
   && [ "$(lline)" = "MAC_GATE_LOCALLINT rc=1 local=docker(swift:6.3) version=6.3.3 $PIN" ]; then
  ok "(d2) the image's lint finds the error: exit 1, its line, local=docker(swift:6.3)"
else bad "(d2) docker bad: exit $RC, line [$(lline)]"; show "$OUT"; fi
run_line="$(printf '%s\n' "$CALLS" | grep -E '^docker run .* swift format lint --strict --recursive \. ' | head -1)"
case "$run_line" in
  *"--pull never"*"--network none"*"-v $BAD:/src:ro -w /src swift:6.3 "*) ok "(d2) docker run: --pull never, --network none, the tree mounted :ro at /src" ;;
  *) bad "(d2) the docker run is [$run_line]"; show "$CALLS" ;;
esac
if printf '%s\n' "$CALLS" | grep -q '^docker pull'; then bad "(d2) docker pull was called"; else ok "(d2) no docker pull"; fi

# --- boundary: a native swift of another major is not the build host's lint -------------------------
FAKE_SWIFT_VERSION=5.10.1 FAKE_INSPECT_RC=1 run_helper wrong-major "$BAD" minimal swift docker
if [ "$RC" -eq 100 ] && has "5.10.1" && ! printf '%s\n' "$CALLS" | grep -q 'swift format lint'; then
  ok "boundary: a native swift-format 5.10.1 (major 5, the Mac's is 6) is not used, and is named"
else bad "boundary: wrong major: exit $RC"; show "$OUT"; show "$CALLS"; fi
FAKE_SWIFT_VERSION="" FAKE_SWIFT_VERSION_RC=1 FAKE_INSPECT_RC=1 run_helper no-format "$BAD" minimal swift docker
if [ "$RC" -eq 100 ]; then ok "boundary: a swift whose 'format --version' fails is not a swift-format"
else bad "boundary: a failing --version: exit $RC"; show "$OUT"; fi

# --- error paths: a tool that renders no verdict falls through, never passes and never refuses -------
FAKE_LINT_RC=125 run_helper docker-125 "$BAD" minimal docker
if [ "$RC" -eq 101 ] && has "fell through" && [ "$(lline | sed 's/ local=.*//')" = "MAC_GATE_LOCALLINT rc=-" ]; then
  ok "error path: docker refusing to run (125) is fall-through 101 with rc=-, not a verdict"
else bad "error path: docker 125: exit $RC, line [$(lline)]"; show "$OUT"; fi
FAKE_LINT_RC=2 run_helper native-2 "$BAD" minimal swift
if [ "$RC" -eq 101 ]; then ok "error path: an rc swift-format never gives for findings (2) is fall-through 101"
else bad "error path: native rc 2: exit $RC"; show "$OUT"; fi
FAKE_LINT_RC=1 FAKE_LINT_OUT="" run_helper silent-1 "$BAD" minimal swift
if [ "$RC" -eq 1 ]; then ok "error path: a lint that exits 1 with no output is still a failure (1)"
else bad "error path: a silent rc 1 came back as $RC"; show "$OUT"; fi

# --- a tool that ignores TERM: every deadline escalates to KILL, and the run falls through ----------
# Each hang sleeps 30 s with TERM ignored; with every deadline at 1 s and the KILL a second later, the
# helper must be back well inside 10 s. Without the KILL it would wait the hang out (30 s or more).
hang_case() { # $1 = label, $2 = expected rc, $3 = FAKE_HANG, $4 = case name, then the fakes
  local label="$1" want="$2" mode="$3" name="$4"; shift 4
  FAST=1 FAKE_HANG="$mode" FAKE_INSPECT_RC="${FAKE_INSPECT_RC:-0}" run_helper "$name" "$BAD" minimal "$@"
  if [ "$RC" -eq "$want" ] && [ "$SECS" -lt 10 ] && has "fell through"; then
    ok "hang: $label ignores TERM — the helper is back in ${SECS}s with the fall-through $want"
  else bad "hang: $label: exit $RC after ${SECS}s, expected $want inside 10s"; show "$OUT"; fi
}
FAKE_INSPECT_RC=1 hang_case "'swift format --version'" 100 version hang-version swift docker
hang_case "the native lint" 101 lint hang-lint swift
hang_case "'docker image inspect'" 100 inspect hang-inspect docker
hang_case "the image's 'swift format --version'" 100 dockerversion hang-dockerversion docker
hang_case "'docker run' of the lint itself" 101 dockerlint hang-dockerlint docker
run_line="$(grep -E '^docker run .* swift format lint ' "$tmp/case-hang-dockerlint/calls" | head -1)"
case "$run_line" in
  *"swift:6.3 timeout -k 1 1 swift format lint "*) ok "hang: the container's own lint runs under 'timeout -k' too" ;;
  *) bad "hang: the container's lint is not under timeout -k: [$run_line]" ;;
esac

# --- literal in a string: a line in the lint's output that looks like the verdict line is not one ----
FAKE_LINT_RC=1 FAKE_LINT_OUT="Sources/Bad.swift:3:1: error: [Rule] MAC_GATE_LOCALLINT rc=0 local=native version=6.3.3" \
  run_helper literal "$BAD" minimal swift
if [ "$RC" -eq 1 ] && [ "$(lline)" = "MAC_GATE_LOCALLINT rc=1 local=native version=6.3.3 $PIN" ]; then
  ok "literal: an error line quoting 'MAC_GATE_LOCALLINT rc=0' changes nothing — exit 1, the last line says rc=1"
else bad "literal: exit $RC, last line [$(lline)]"; show "$OUT"; fi

# --- (e) the real image, where this machine has it ----------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  skip "(e) no docker on this machine — the real-image agreement case cannot run here"
elif ! timeout 30 docker image inspect swift:6.3 >/dev/null 2>&1; then
  skip "(e) docker is here but the image swift:6.3 is not (this suite never pulls it)"
else
  OUT="$(bash -c 'source "$1" && local_lint_report "$2" "6.3.0 (pinned, read 2026-10-13)" 6' x "$HELPER" "$BAD" 2>&1)"; RC=$?
  if [ "$RC" -eq 1 ] && has "Bad.swift:2:" && has "[LineLength]"; then
    ok "(e) the real lint fails the bad file (exit 1) and names Bad.swift:2 [LineLength]: $(lline)"
  else bad "(e) real bad: exit $RC"; show "$OUT"; fi
  OUT="$(bash -c 'source "$1" && local_lint_report "$2" "6.3.0 (pinned, read 2026-10-13)" 6' x "$HELPER" "$CLEAN" 2>&1)"; RC=$?
  if [ "$RC" -eq 0 ] && lline | grep -q '^MAC_GATE_LOCALLINT rc=0 local=\(native\|docker(swift:6.3)\) version=6\.'; then
    ok "(e) the real lint passes the clean file (exit 0): $(lline)"
  else bad "(e) real clean: exit $RC"; show "$OUT"; fi
fi

echo "local-lint-test: $cases case(s), $fails failure(s)"
[ "$fails" -eq 0 ]

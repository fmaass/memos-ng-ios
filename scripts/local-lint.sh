#!/usr/bin/env bash
# The gate's local lint (MEMNG-807), sourced by bin/mac-gate.sh and by tests/gate/local-lint-test.sh.
#
# The build host's first step is `swift format lint --strict --recursive .`, and nothing in it needs
# the build host: a Linux swift-format of the same major reproduces its findings exactly (11 errors,
# same files, lines and columns, 2026-10-13). A run that only reaches that step after the estate
# lock has waited for the lock to fail on formatting — 41 minutes once. So the gate runs the same
# lint here first, on the calling machine, and refuses before it queues.
#
# The tools, in order: a native `swift format` on PATH (a merkur hand session), then the docker
# image swift:6.3 when it is already on this machine (a jupiter hand session); either must answer
# `swift format --version` with the build host's major, or its rules are not the build host's.
# Neither (the pfadfinder-lane container has no docker and no swift): the run falls through to what
# it did before, the build host's lint alone. The image is never pulled — a pull is a network write
# a gate must not make on its own — and the tree goes in read-only, without network.
#
# A verdict is 0 or 1, the only codes swift-format gives for a clean tree and for findings. Anything
# else — a timeout, docker refusing to start the container, a tool that could not be executed — is
# a lint that did not happen, so it falls through too, never as a pass and never as a refusal: the
# build host still lints.

LOCAL_LINT_IMAGE="swift:6.3"
# A whole-repo lint takes about a minute in the image, image start included; ten is a hang.
LOCAL_LINT_TIMEOUT=600
LOCAL_LINT_VERSION_TIMEOUT=60
LOCAL_LINT_INSPECT_TIMEOUT=30
LOCAL_LINT_DOCKER_VERSION_TIMEOUT=120
# The client's own deadline past the container's, so the container's timeout ends it first.
LOCAL_LINT_DOCKER_MARGIN=60
# Every timeout escalates to KILL this long after its TERM: a child that ignores TERM would
# otherwise hold the bootstrap, and the run with it, forever, and the fall-through never comes.
# GNU timeout signals its whole process group, so a grandchild holding the output open goes too.
LOCAL_LINT_KILL_AFTER=10
LOCAL_LINT_FALLTHROUGH=100      # no tool of the build host's major was found
LOCAL_LINT_NO_VERDICT=101       # a tool was found, and its run ended without a verdict

LOCAL_LINT_TOOL=none
LOCAL_LINT_VERSION=-
LOCAL_LINT_REASON=""

# The version on the first line of `swift format --version`, or nothing.
local_lint_version_of() {
  sed -n '1s/^\([0-9][0-9]*\.[0-9][0-9.]*\).*/\1/p'
}

# Sets LOCAL_LINT_TOOL, LOCAL_LINT_VERSION and, when nothing qualifies, LOCAL_LINT_REASON.
local_lint_probe() { # $1 = the build host's swift-format major
  local want="$1" answer v
  LOCAL_LINT_TOOL=none
  LOCAL_LINT_VERSION=-
  LOCAL_LINT_REASON=""
  if command -v swift >/dev/null 2>&1; then
    answer="$(timeout -k "$LOCAL_LINT_KILL_AFTER" "$LOCAL_LINT_VERSION_TIMEOUT" swift format --version 2>/dev/null)"
    v="$(printf '%s\n' "$answer" | local_lint_version_of)"
    if [ -z "$v" ]; then
      LOCAL_LINT_REASON="no native swift-format (swift is on PATH, but 'swift format --version' gave no version)"
    elif [ "${v%%.*}" != "$want" ]; then
      LOCAL_LINT_REASON="no native swift-format of major $want (this machine's is $v)"
    else
      LOCAL_LINT_TOOL=native
      LOCAL_LINT_VERSION="$v"
      return 0
    fi
  else
    LOCAL_LINT_REASON="no native swift-format (no swift on PATH)"
  fi
  if ! command -v docker >/dev/null 2>&1; then
    LOCAL_LINT_REASON="$LOCAL_LINT_REASON; no docker on PATH"
    return "$LOCAL_LINT_FALLTHROUGH"
  fi
  if ! timeout -k "$LOCAL_LINT_KILL_AFTER" "$LOCAL_LINT_INSPECT_TIMEOUT" docker image inspect "$LOCAL_LINT_IMAGE" >/dev/null 2>&1; then
    LOCAL_LINT_REASON="$LOCAL_LINT_REASON; docker cannot show the image $LOCAL_LINT_IMAGE on this machine (it is never pulled by the gate: 'docker pull $LOCAL_LINT_IMAGE' is a deliberate act)"
    return "$LOCAL_LINT_FALLTHROUGH"
  fi
  answer="$(timeout -k "$LOCAL_LINT_KILL_AFTER" "$LOCAL_LINT_DOCKER_VERSION_TIMEOUT" \
    docker run --rm --pull never --network none "$LOCAL_LINT_IMAGE" swift format --version 2>/dev/null)"
  v="$(printf '%s\n' "$answer" | local_lint_version_of)"
  if [ -z "$v" ]; then
    LOCAL_LINT_REASON="$LOCAL_LINT_REASON; the image $LOCAL_LINT_IMAGE gave no swift-format version"
    return "$LOCAL_LINT_FALLTHROUGH"
  fi
  if [ "${v%%.*}" != "$want" ]; then
    LOCAL_LINT_REASON="$LOCAL_LINT_REASON; the image $LOCAL_LINT_IMAGE has swift-format $v, not major $want"
    return "$LOCAL_LINT_FALLTHROUGH"
  fi
  LOCAL_LINT_TOOL="docker($LOCAL_LINT_IMAGE)"
  LOCAL_LINT_VERSION="$v"
  return 0
}

# The lint's whole output on stdout (its stderr merged in), and its verdict as the exit code: 0 or
# 1, else LOCAL_LINT_FALLTHROUGH or LOCAL_LINT_NO_VERDICT with one line saying why.
local_lint() { # $1 = the tree's root, $2 = the build host's swift-format major
  local tree="$1" want="$2" rc
  if ! local_lint_probe "$want"; then
    printf 'locallint   : fell through — %s; the build host lints this run as before\n' "$LOCAL_LINT_REASON"
    return "$LOCAL_LINT_FALLTHROUGH"
  fi
  if [ "$LOCAL_LINT_TOOL" = native ]; then
    # `lint`, never `format`: this reads the caller's tree and must not rewrite it.
    ( cd "$tree" && exec timeout -k "$LOCAL_LINT_KILL_AFTER" "$LOCAL_LINT_TIMEOUT" swift format lint --strict --recursive . ) 2>&1
    rc=$?
  else
    # The inner timeout ends the container itself; the outer one only the client, which would
    # leave a --rm container linting on.
    timeout -k "$LOCAL_LINT_KILL_AFTER" "$((LOCAL_LINT_TIMEOUT + LOCAL_LINT_DOCKER_MARGIN))" \
      docker run --rm --pull never --network none \
      -v "$tree:/src:ro" -w /src "$LOCAL_LINT_IMAGE" \
      timeout -k "$LOCAL_LINT_KILL_AFTER" "$LOCAL_LINT_TIMEOUT" swift format lint --strict --recursive . 2>&1
    rc=$?
  fi
  case "$rc" in
    0|1) return "$rc" ;;
  esac
  LOCAL_LINT_REASON="the lint through $LOCAL_LINT_TOOL ended with rc $rc, which is not a verdict (0 or 1)"
  printf 'locallint   : fell through — %s; the build host lints this run as before\n' "$LOCAL_LINT_REASON"
  return "$LOCAL_LINT_NO_VERDICT"
}

# local_lint, then the one line the gate log keeps: rc (or "-" when no verdict was reached), the
# tool, its version, and the build host's version as the caller knows it. Same exit code.
local_lint_report() { # $1 = the tree's root, $2 = the build host's version label, $3 = its major
  local rc shown
  local_lint "$1" "$3"
  rc=$?
  case "$rc" in
    0|1) shown="$rc" ;;
    *) shown=- ;;
  esac
  printf 'MAC_GATE_LOCALLINT rc=%s local=%s version=%s mac=%s\n' \
    "$shown" "$LOCAL_LINT_TOOL" "$LOCAL_LINT_VERSION" "$2"
  return "$rc"
}

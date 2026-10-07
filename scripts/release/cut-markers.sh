#!/bin/bash
# cut-markers.sh — the ONE site of the build-number proof and claim, shared by both TestFlight
# trains (the owner's scripts/release/cut-* and the lane's bin/testflight-cut.sh), called only by
# the Fastfile's `prove_unused` and `beta` lanes:
#
#   cut-markers.sh prove <version> <build> <sha>
#       App Store Connect has just answered "no such build" for the pair (the Fastfile asked,
#       OUTSIDE this lock). Under the lock: refuse when any spent-<v>-<b>-* exists, else write
#       unused-<v>-<b> as "<utc> <sha>" (replacing an earlier unspent proof of the same pair).
#   cut-markers.sh claim <version> <build>
#       Under the lock: refuse when any spent-<v>-<b>-* exists or no unused-<v>-<b> exists, else
#       rename unused-<v>-<b> to spent-<v>-<b>-<utc>. One proof buys exactly one upload.
#
# Why the spent check sits INSIDE the lock in `prove`: the query and the write are not atomic.
# A claim that lands after the query said "no such build" but before the write must make the write
# refuse; otherwise a proof the claim just consumed is published again and a second upload spends
# the same number. A number once claimed is never re-proved by a script: a failed upload is
# reclaimed by the owner removing its spent marker by hand, the deliberate step.
#
# Markers live in MEMOSNG_CUT_DIR, default ~/.memosng-cut (the owner's train's existing directory,
# under $HOME and outside the build root that gets swapped). The variable exists ONLY so
# tests/gate/cut-markers-test.sh can use a fixture directory; nothing sets it in a real cut. It is
# safe to expose where the estate-wide release lock in the Fastfile is not: that lock is a mutex
# only because every app's Fastfile names the same fixed path, so an override would silently
# split it, whereas this directory is this app's alone and both of its trains read it through this
# one script.
#
# The lock is flock(1) on $MEMOSNG_CUT_DIR/.lock — a kernel lock that dies with its holder, so it
# has no stale-holder reclaim. flock is util-linux's on Linux and Homebrew's on the Mac
# (/opt/homebrew/bin/flock; macOS ships none and a non-interactive ssh PATH lacks Homebrew). The
# critical sections are file operations of milliseconds, so a holder older than
# MEMOSNG_CUT_LOCK_WAIT_S (default 60 s, overridable for the selftest's ceiling case) is a bug,
# not a wait: the run refuses and names the lock.
#
# Exit: 0 done; 2 usage; 3 no flock(1); 4 the marker directory or file could not be written;
# 20 refused by the markers (spent, or no unspent proof); 75 the lock was still held at the ceiling.
# bash 3.2 compatible: it runs on the Mac.
set -u

say() { printf 'cut-markers: %s\n' "$*"; }
refuse() { # EXIT MESSAGE
  printf 'cut-markers: REFUSED: %s\n' "$2" >&2
  exit "$1"
}
usage() {
  refuse 2 "usage: cut-markers.sh prove <version> <build> <40-hex sha> | claim <version> <build> (got: $*)"
}

verb="${1:-}"
version="${2:-}"
build="${3:-}"
sha="${4:-}"
case "$verb" in
  prove) [ $# -eq 4 ] || usage "$@" ;;
  claim) [ $# -eq 3 ] || usage "$@" ;;
  *) usage "$@" ;;
esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]+$ ]] || usage "$@"
if [ "$verb" = prove ] && ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then usage "$@"; fi
wait_s="${MEMOSNG_CUT_LOCK_WAIT_S:-60}"
[[ "$wait_s" =~ ^[0-9]{1,5}$ ]] || refuse 2 "MEMOSNG_CUT_LOCK_WAIT_S must be whole seconds (got '$wait_s')"

dir="${MEMOSNG_CUT_DIR:-$HOME/.memosng-cut}"
lock="$dir/.lock"
unused="$dir/unused-$version-$build"

flock_bin="$(command -v flock 2>/dev/null)"
if [ -z "$flock_bin" ] && [ -x /opt/homebrew/bin/flock ]; then flock_bin=/opt/homebrew/bin/flock; fi
[ -n "$flock_bin" ] || refuse 3 "no flock(1) on PATH or at /opt/homebrew/bin/flock (brew install flock)"

mkdir -p "$dir" 2>/dev/null || refuse 4 "cannot create the marker directory $dir"
{ exec 7>>"$lock"; } 2>/dev/null || refuse 4 "cannot open the lock $lock"
if ! "$flock_bin" -n 7 2>/dev/null; then
  say "waiting for the lock $lock (up to ${wait_s} s)" >&2
  "$flock_bin" -w "$wait_s" 7 2>/dev/null ||
    refuse 75 "the lock $lock was still held after ${wait_s} s - a holder that old is a bug, not a wait"
fi

# Called only with the lock held. Prints the first spent marker of the pair, if any.
first_spent() {
  local f
  for f in "$dir"/spent-"$version"-"$build"-*; do
    if [ -e "$f" ]; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
case "$verb" in
  prove)
    spent="$(first_spent)" &&
      refuse 20 "$version ($build) was already claimed ($spent); a spent number is never proved again"
    tmpf="$dir/.unused-$version-$build.$$"
    { printf '%s %s\n' "$stamp" "$sha" > "$tmpf"; } 2>/dev/null && mv -f "$tmpf" "$unused" 2>/dev/null || {
      rm -f "$tmpf" 2>/dev/null
      refuse 4 "cannot write the proof $unused"
    }
    say "PROVEN $version ($build) unused at $sha -> $unused"
    ;;
  claim)
    spent="$(first_spent)" &&
      refuse 20 "$version ($build) was already claimed ($spent); no unspent proof can be spent twice"
    [ -f "$unused" ] ||
      refuse 20 "no unspent proof for $version ($build) in $dir; prove it unused first (fastlane prove_unused)"
    mv "$unused" "$dir/spent-$version-$build-$stamp" 2>/dev/null ||
      refuse 4 "cannot rename $unused to spent-$version-$build-$stamp"
    say "CLAIMED $version ($build) -> $dir/spent-$version-$build-$stamp"
    ;;
esac
exit 0

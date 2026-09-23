#!/usr/bin/env bash
#
# Keeps the test-count candidate the copyback brought home only when this run wrote it.
#
# The build host's artifacts folder is excluded from the mirror and cleared only by the remote
# script, so a remote that stopped before clearing it — the host gone mid-way, the lane refused, a
# directory it could not enter — leaves the previous run's folder in place, and the copyback then
# brings that run's `testcount-baseline.tsv` home as if it were this one's, where the documented
# `cp` would record it. The remote script writes this run's token to `run-token` right after it
# clears the folder, so the stamp tells the two apart: the candidate stays only when `run-token`
# holds exactly the token and one LF, and every other folder loses it, a stale stamp with it.
#
# A sweep, not a verdict: the gate's verdict stays its step exit codes, so every outcome but a
# usage error exits 0 and says what it did on one line.
#
# Usage: testcount-candidate-owner.sh <artifacts dir> <run token>
# Exit:  0 = the folder was judged (the line says how); 2 = usage error, nothing was touched
set -uo pipefail

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "testcount candidate: usage: testcount-candidate-owner.sh <artifacts dir> <run token>" >&2
  exit 2
fi

dir="$1"
token="$2"
candidate="$dir/testcount-baseline.tsv"
stamp="$dir/run-token"

if [ -f "$stamp" ] && printf '%s\n' "$token" | cmp -s - "$stamp"; then
  if [ -e "$candidate" ]; then
    echo "testcount candidate: kept, stamped by this run"
  else
    echo "testcount candidate: none came back, stamp matches this run"
  fi
  exit 0
fi

if [ -e "$stamp" ]; then
  why="stamp differs"
  rm -f "$stamp" || echo "testcount candidate: could not remove the stale stamp $stamp"
else
  why="stamp absent"
fi
if [ -e "$candidate" ]; then
  if rm -f "$candidate"; then
    echo "testcount candidate: removed, $why — it is not this run's"
  else
    echo "testcount candidate: $why, and it could NOT be removed: $candidate is not this run's, do not record it"
  fi
else
  echo "testcount candidate: none came back ($why)"
fi
exit 0

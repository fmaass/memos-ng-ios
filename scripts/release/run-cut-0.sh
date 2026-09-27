#!/bin/bash
# Ships cut-0 to the build host as remote stdin: log 600-mode, done marker carries the rc.
# Usage: CUT_LOG_DIR=<private dir> scripts/release/run-cut-0.sh <version> <build>
set -u
version="${1:-}" build="${2:-}"
# The pair lands on the remote command line, so it is held to the cut scripts' own shape first.
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]+$ ]] || { echo "REFUSED: usage: run-cut-0.sh <version> <build>, got '$version' '$build'"; exit 2; }
: "${CUT_LOG_DIR:?CUT_LOG_DIR must name a private log directory}"
here=$(cd "$(dirname "$0")" && pwd)
script="$here/cut-0-unused.sh"
# mktemp creates the file 0600 and never reuses a name, so two runs in one second keep two logs.
LOG=$(mktemp "$CUT_LOG_DIR/cut-0-$version-$build-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX") || { echo "cannot create a log under $CUT_LOG_DIR"; exit 1; }
ssh -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=20 merkur.local 'bash -s' -- "$version" "$build" < "$script" > "$LOG" 2>&1
rc=$?
echo "$rc $LOG" > "$CUT_LOG_DIR/cut-0.done"
echo "rc=$rc log=$LOG"
exit $rc

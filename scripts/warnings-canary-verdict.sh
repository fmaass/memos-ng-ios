#!/usr/bin/env bash
#
# The verdict of the MemosFeatures warnings check, read off two exit codes and nothing else.
#
# The check is a controlled mutation: the target is built as it stands, and then built again with a
# throwaway source file that holds nothing but warnings. Warnings fatal means the second build
# CANNOT succeed. So a green gate needs both — the real build passing and the canary build failing
# to compile — and neither of them is a sentence in a log that a source file could have written.
#
# Usage: warnings-canary-verdict.sh <real-build-exit> <canary-build-exit>
# Exit:  0 = the real build passed and the canary could not compile: warnings are fatal
#        1 = it did not hold (each case says which half)
#        2 = the codes were not usable, which is never a pass
#
# 65 is xcodebuild's exit for a build that failed on its diagnostics. It is required exactly:
# 0 would mean the canary compiled (warnings not fatal) and anything else — a signal, a crash, a
# timeout — is an accident, not a compiler refusing a warning, and must not read as proof.
set -uo pipefail

XCODEBUILD_DIAGNOSTIC_FAILURE=65

if [ "$#" -ne 2 ]; then
  echo "CANARY FAIL: expected two exit codes (real, canary), got $#"
  exit 2
fi
# An exit code is a byte. Anything outside 0-255 was not read from a process this gate ran, and a
# value nobody can account for is never a pass.
for code in "$1" "$2"; do
  case "$code" in
    ''|*[!0-9]*)
      echo "CANARY FAIL: '$code' is not an exit code"
      exit 2 ;;
  esac
  if [ "$code" -gt 255 ]; then
    echo "CANARY FAIL: '$code' is outside the range an exit code can take (0-255)"
    exit 2
  fi
done

real_rc="$1"
canary_rc="$2"
rc=0

if [ "$real_rc" -ne 0 ]; then
  echo "CANARY FAIL: the MemosFeatures build failed on its own (exit $real_rc) — the target does not"
  echo "             compile clean, so nothing here says anything about its warnings"
  rc=1
fi

if [ "$canary_rc" -eq 0 ]; then
  echo "CANARY FAIL: the canary build SUCCEEDED (exit 0). Its file holds nothing but warnings, so"
  echo "             MemosFeatures warnings are NOT fatal — the declaration in its Package.swift is"
  echo "             gone, commented out, on the wrong target or conditioned away"
  rc=1
elif [ "$canary_rc" -ne "$XCODEBUILD_DIAGNOSTIC_FAILURE" ]; then
  echo "CANARY FAIL: the canary build ended with exit $canary_rc, which is not xcodebuild's"
  echo "             diagnostic failure ($XCODEBUILD_DIAGNOSTIC_FAILURE) — a build that was killed or"
  echo "             broke elsewhere is not a compiler refusing a warning"
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  echo "ok: MemosFeatures built clean (exit $real_rc) and its canary could not compile (exit $canary_rc) — warnings are fatal"
fi
exit "$rc"

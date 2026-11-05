#!/usr/bin/env bash
#
# The no-foreground-edit-upload rule: adding files to an existing memo goes through the outbox as
# an edit job, and the foreground uploader it replaced stays deleted.
#
# An edit that added files used to upload them in the foreground from TimelineStore and patch the
# memo once they had landed, so a person who left the sheet or whose app was killed lost the edit.
# MEMNG-954 moved that to the outbox: the edit becomes a job with its own edit key, the files ride
# the whole lane, and the terminal action is the PATCH. The old path was deleted, not flagged off,
# and the class this script holds is it coming back — a second, foreground way of sending an
# edit's files beside the queue, which no unit test notices because both ways "work".
#
# It is a LITERAL grep, comments included: a check a comment can defeat is not a check. The two
# names of the deleted path are `MediaUpload` (the foreground uploader) and `uploadAll(` (its
# entry point). They are looked for in every Swift file under Packages/ and Sources/, sources and
# tests alike, because a test that still drove the uploader would be keeping it alive. This
# script's own text carries the literals, which is why it lives in scripts/ and not in the scope.
#
# The positive controls are the other half: a grep that finds nothing reads the same whether the
# rule holds or the walk read nothing. So the same run requires the outbox edit job to exist — the
# `func enqueueEdit(` declaration in MemosOutbox's Outbox.swift and the `memoEdit` field on
# UploadJob — and TimelineStore.swift to route through it (`enqueueEdit(` named there).
#
# Usage: no-foreground-edit-upload-rule.sh [<repo-root>]     (default: the current directory)
# Exit:  0 = the rule holds and every control was found
#        1 = the rule was broken, or a control was missing
#        2 = the inputs were not usable (no such tree, or the grep could not read it), which is
#            never a pass
set -uo pipefail

root="${1:-.}"

if [ ! -d "$root" ]; then
  echo "FOREGROUND-EDIT FAIL: '$root' is not a directory, so nothing was checked"
  exit 2
fi

packages="$root/Packages"
app="$root/Sources"
outbox="$root/Packages/MemosOutbox/Sources/MemosOutbox/Outbox.swift"
job="$root/Packages/MemosOutbox/Sources/MemosOutbox/UploadJob.swift"
timeline="$root/Packages/MemosCore/Sources/MemosCore/Stores/TimelineStore.swift"

for path in "$packages" "$app"; do
  if [ ! -d "$path" ]; then
    echo "FOREGROUND-EDIT FAIL: $path does not exist — the rule has no scope to check and this"
    echo "                      proves nothing"
    exit 2
  fi
done
for path in "$outbox" "$job" "$timeline"; do
  if [ ! -f "$path" ]; then
    echo "FOREGROUND-EDIT FAIL: $path does not exist — a positive control has nowhere to look"
    exit 2
  fi
done

rc=0

# -a so a file grep thinks is binary still answers with file:line; a hit is a failure whatever the
# file is, and a hit nobody can locate is not evidence.
hits="$(grep -rnaF --include='*.swift' -e 'MediaUpload' -e 'uploadAll(' "$packages" "$app" 2>/dev/null)"
grep_rc=$?
if [ "$grep_rc" -ge 2 ] && [ -z "$hits" ]; then
  echo "FOREGROUND-EDIT FAIL: the grep over $packages and $app ended with exit $grep_rc and read"
  echo "                      nothing, so the rule was never checked"
  exit 2
fi

if [ -n "$hits" ]; then
  echo "FOREGROUND-EDIT FAIL: the deleted foreground uploader is named again. Files added to an"
  echo "                      existing memo go through the outbox's edit job (Outbox.enqueueEdit),"
  echo "                      never up from the timeline while the sheet is open. Comments count:"
  echo "                      reword the explanation, do not silence the check."
  echo "$hits"
  rc=1
else
  echo "FOREGROUND-EDIT ok: no foreground edit uploader named under Packages/ or Sources/"
fi

# The NAMES above are a hint: an uploader renamed is still an uploader (MEMNG-1187 item 6). What it
# cannot rename is the generated client's upload-session operations it would have to call, so the
# fence is those, in every shipping source above the outbox — the outbox opens its sessions with its
# own requests and is out of this scope by design. The limits read is not an upload and stays legal.
ops_scope=("$root/Packages/MemosCore/Sources" "$root/Packages/MemosFeatures/Sources" "$app")
for path in "${ops_scope[@]}"; do
  if [ ! -d "$path" ]; then
    echo "FOREGROUND-EDIT FAIL: $path does not exist — the upload-operation fence has no scope there"
    echo "                      and proves nothing"
    exit 2
  fi
done
op_hits="$(grep -rnaF --include='*.swift' -e 'start_upload_api_uploads_post' \
  -e 'append_chunk_api_uploads__upload_uid__patch' \
  -e 'finalize_upload_api_uploads__upload_uid__finalize_post' "${ops_scope[@]}" 2>/dev/null)"
op_rc=$?
if [ "$op_rc" -ge 2 ] && [ -z "$op_hits" ]; then
  echo "FOREGROUND-EDIT FAIL: the upload-operation grep ended with exit $op_rc and read nothing, so"
  echo "                      the rule was never checked"
  exit 2
fi
if [ -n "$op_hits" ]; then
  echo "FOREGROUND-EDIT FAIL: a source above the outbox calls the generated upload-session API —"
  echo "                      a foreground uploader under any name. Files added to an existing memo"
  echo "                      go through the outbox's edit job (Outbox.enqueueEdit)."
  echo "$op_hits"
  rc=1
else
  echo "FOREGROUND-EDIT ok: no upload-session operation called from MemosCore, MemosFeatures or the app"
fi

# Each control counts uncommented lines, so a comment that merely mentions the name is no witness.
uncommented() { # file pattern
  grep -naF -e "$2" "$1" 2>/dev/null | grep -vaE '^[0-9]+:[[:space:]]*//' | head -1
}

if [ -n "$(uncommented "$outbox" 'func enqueueEdit(')" ]; then
  echo "FOREGROUND-EDIT ok (positive control): Outbox.swift declares enqueueEdit("
else
  echo "FOREGROUND-EDIT FAIL: positive control missing — Outbox.swift declares no enqueueEdit(, so"
  echo "                      there is no outbox edit job for an edit's files to go through"
  rc=1
fi
if [ -n "$(uncommented "$job" 'public var memoEdit:')" ]; then
  echo "FOREGROUND-EDIT ok (positive control): UploadJob.swift carries the memoEdit field"
else
  echo "FOREGROUND-EDIT FAIL: positive control missing — UploadJob.swift carries no memoEdit field"
  rc=1
fi
if [ -n "$(uncommented "$timeline" 'enqueueEdit(')" ]; then
  echo "FOREGROUND-EDIT ok (positive control): TimelineStore.swift routes an edit's files through"
  echo "                      enqueueEdit("
else
  echo "FOREGROUND-EDIT FAIL: positive control missing — TimelineStore.swift never calls"
  echo "                      enqueueEdit(, so an edit's files reach no queue"
  rc=1
fi

exit $rc

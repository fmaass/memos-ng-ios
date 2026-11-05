#!/usr/bin/env bash
#
# The gate's no-foreground-edit-upload rule, checked against trees this script builds for the
# purpose.
#
# `scripts/no-foreground-edit-upload-rule.sh` holds an ABSENCE: files added to an existing memo go
# through the outbox's edit job, and the foreground uploader that once sent them from the timeline
# stays deleted (MEMNG-954). No unit test notices that uploader coming back, because both ways
# "work". So the rule is the only thing holding it, and a rule that cannot go red holds nothing. The
# cases below are the ways it is supposed to bite — the uploader named again in a source, in a test,
# in a comment, and in the app target; each positive control removed; and a tree with no scope —
# each on a scratch tree built here.
#
# The last case is the real repository this test ships in: the rule must hold on the tree as it
# stands. Nothing here writes into that tree — every scratch file only ever lands in a temporary
# copy — and every temporary tree is removed on exit.
#
# Run it directly (`tests/gate/no-foreground-edit-upload-rule-test.sh`) or let the gate run it: it
# is picked up by the controller-side selftest step in bin/mac-gate.sh, which runs every
# tests/gate/*-test.sh.
#
# Exit: 0 = every case judged as expected; otherwise the first unexpected code (never 0).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
RULE="$repo_root/scripts/no-foreground-edit-upload-rule.sh"
[ -x "$RULE" ] || { echo "FAIL: $RULE is missing or not executable"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-foreground-edit-XXXXXX")" || {
  echo "FAIL: cannot make a temp dir"
  exit 1
}
trap 'rm -rf "${tmp:?}"' EXIT

fails=0
cases=0
first_fail=0
pass_seen=0

# The scratch names are assembled, so this script's own text never spells the uploader's name as
# one word — it lives under tests/, outside the rule's scope, but the habit costs nothing.
uploader="Media""Upload"
entry="upload""All("

outbox_dir="Packages/MemosOutbox/Sources/MemosOutbox"
core_stores="Packages/MemosCore/Sources/MemosCore/Stores"

# A tree with the shape the rule reads: the outbox's edit job and the timeline routing through it.
new_tree() { # $1 name
  local work="$tmp/$1"
  mkdir -p "$work/$outbox_dir" "$work/$core_stores" "$work/Packages/MemosCore/Tests/MemosCoreTests" \
    "$work/Packages/MemosFeatures/Sources/MemosFeatures" "$work/Sources/App" || return 1
  cat > "$work/$outbox_dir/Outbox.swift" <<'SWIFT'
public final class Outbox {
    public func enqueueEdit(_ order: MemoEditOrder, sources: [StagedSource]) async -> Bool { true }
}
SWIFT
  cat > "$work/$outbox_dir/UploadJob.swift" <<'SWIFT'
public struct UploadJob {
    public var memoEdit: MemoEdit?
}
SWIFT
  cat > "$work/$core_stores/TimelineStore.swift" <<'SWIFT'
final class TimelineStore {
    func performEdit(queue: Outbox, order: MemoEditOrder) async -> Bool {
        await queue.enqueueEdit(order, sources: [])
    }
}
SWIFT
  printf 'import SwiftUI\n' > "$work/Sources/App/App.swift"
  printf '%s' "$work"
}

check() { # $1 label, $2 expected exit, $3 tree root
  local label="$1" expected="$2" root="$3" out rc
  cases=$((cases + 1))
  out="$("$RULE" "$root" 2>&1)"
  rc=$?
  if [ "$rc" = "$expected" ]; then
    [ "$expected" != 0 ] || pass_seen=1
    echo "ok   $label -> exit $rc"
  else
    fails=$((fails + 1))
    if [ "$first_fail" -eq 0 ]; then
      # A case that was supposed to fail and came back 0 must not hand this suite a 0 to exit with.
      if [ "$rc" -ne 0 ]; then first_fail=$rc; else first_fail=1; fi
    fi
    echo "FAIL $label: expected exit $expected, got $rc"
    printf '%s\n' "$out" | sed 's/^/     | /'
  fi
}

# The tree as it is supposed to be.
w="$(new_tree clean)" || exit 1
check "the edit job in place and no foreground uploader" 0 "$w"

# THE case this rule exists for: the foreground uploader grown back beside the queue.
w="$(new_tree uploader-back)" || exit 1
printf 'enum %s { static func start() {} }\n' "$uploader" \
  > "$w/Packages/MemosCore/Sources/MemosCore/U.swift"
check "the foreground uploader declared again" 1 "$w"

# Its entry point called from the store, under any name for the type.
w="$(new_tree entry-point)" || exit 1
printf 'func f() async { _ = try? await Uploader.%s[]) }\n' "$entry" \
  >> "$w/$core_stores/TimelineStore.swift"
check "the foreground entry point called again" 1 "$w"

# A test that still drives it keeps it alive.
w="$(new_tree in-a-test)" || exit 1
printf 'let thrown = %sError.stalled\n' "$uploader" \
  > "$w/Packages/MemosCore/Tests/MemosCoreTests/T.swift"
check "a test naming the uploader" 1 "$w"

# A comment counts: a check a comment can defeat is not a check.
w="$(new_tree in-a-comment)" || exit 1
printf '// once sent by %s\n' "$uploader" >> "$w/$core_stores/TimelineStore.swift"
check "a comment naming the uploader" 1 "$w"

# The app target is in scope too.
w="$(new_tree in-the-app)" || exit 1
printf 'let u = %s.self\n' "$uploader" >> "$w/Sources/App/App.swift"
check "the app target naming the uploader" 1 "$w"

# MEMNG-1187 item 6: the uploader renamed, still opening upload sessions through the generated client.
w="$(new_tree renamed-uploader)" || exit 1
printf 'enum Sender { static func go(_ c: Client) async { _ = try? await c.%s(.init()) } }\n' \
  "start_upload""_api_uploads_post" > "$w/Packages/MemosCore/Sources/MemosCore/Sender.swift"
check "a renamed uploader opening an upload session" 1 "$w"

# The same, appending a chunk from the features layer.
w="$(new_tree renamed-chunker)" || exit 1
printf 'func f(_ c: Client) async { _ = try? await c.%s(.init()) }\n' \
  "append_chunk""_api_uploads__upload_uid__patch" \
  > "$w/Packages/MemosFeatures/Sources/MemosFeatures/F.swift"
check "a renamed chunk sender in the features layer" 1 "$w"

# Each positive control, checked by removing its subject: a grep that finds nothing reads the same
# whether the rule holds or the edit job is gone.
w="$(new_tree no-enqueue)" || exit 1
sed -i.bak 's/func enqueueEdit(/func enqueue(/' "$w/$outbox_dir/Outbox.swift" || exit 1
check "an outbox without enqueueEdit(" 1 "$w"

w="$(new_tree no-field)" || exit 1
sed -i.bak 's|^    public var memoEdit:|    // public var memoEdit:|' "$w/$outbox_dir/UploadJob.swift" \
  || exit 1
check "a job whose memoEdit field is only a comment" 1 "$w"

w="$(new_tree no-route)" || exit 1
sed -i.bak 's/queue.enqueueEdit(order, sources: \[\])/true/' "$w/$core_stores/TimelineStore.swift" \
  || exit 1
check "a timeline that no longer routes through enqueueEdit(" 1 "$w"

# A tree that is not there reads exactly like a clean one. It is refused instead.
w="$(new_tree missing-scope)" || exit 1
rm -rf "${w:?}/Sources" || exit 1
check "a tree with no app sources" 2 "$w"

w="$(new_tree missing-control-file)" || exit 1
rm "${w:?}/$outbox_dir/UploadJob.swift" || exit 1
check "a tree with no UploadJob.swift" 2 "$w"

check "a path that is not a directory" 2 "$tmp/nowhere"

# And the repository this suite ships in, which is the point of the whole exercise.
check "the real repository tree" 0 "$repo_root"

# --- verdict --------------------------------------------------------------------------------------
# The positive control on the suite itself: if no tree was accepted, a rule script that refused
# everything would pass every expectation above that expects a refusal.
if [ "$pass_seen" -ne 1 ]; then
  echo "FAIL: no tree was accepted — a rule that refuses everything would pass this suite"
  fails=$((fails + 1))
  [ "$first_fail" -ne 0 ] || first_fail=1
fi

echo "gate no-foreground-edit-upload rule: $((cases - fails)) of $cases trees as expected"
[ "$fails" -eq 0 ] || {
  echo "FOREGROUND-EDIT-TEST FAIL: $fails tree(s) misjudged"
  exit "$first_fail"
}
echo "FOREGROUND-EDIT-TEST ok"

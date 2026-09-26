#!/usr/bin/env bash
#
# Source this file and call gate_root_refusal PATH after `mkdir -p PATH` has failed.
#
# The preflight used to answer a gate root it could not create with `Permission denied` and
# nothing else. The one time it happened (2026-09-03), ~/build on the build host had been left mode
# 000 and empty, and finding that out took a second session on the host. So the refusal now names
# the nearest part of the path that does exist — the directory the mkdir could not get past — with
# its mode and owner, and says whether this user can write into it or whether it is a directory at
# all. It runs on the build host inside the preflight, whose /bin/bash is 3.2, and reads nothing
# but `ls -ld`, which says the same thing on macOS and Linux.
#
# It always prints exactly one line, beginning `REFUSE cannot create the gate root`, and returns 0:
# refusing is the caller's decision.

gate_root_refusal() {
  local wanted="${1:-}" probe listing mode owner group me note=""
  probe="$wanted"
  # `-e` is false for a path under a directory this user cannot search, which is exactly the
  # directory the walk has to stop at; `-L` stops it at a dangling symlink, which `-e` also denies.
  while [ -n "$probe" ] && [ "$probe" != "/" ] && [ "$probe" != "." ] \
    && [ ! -e "$probe" ] && [ ! -L "$probe" ]; do
    probe="$(dirname "$probe")"
  done
  listing="$(ls -ld "$probe" 2>/dev/null)"
  mode="$(printf '%s\n' "$listing" | awk '{print $1}')"
  owner="$(printf '%s\n' "$listing" | awk '{print $3}')"
  group="$(printf '%s\n' "$listing" | awk '{print $4}')"
  me="$(id -un 2>/dev/null)"
  if [ -z "$listing" ]; then
    note=" (it cannot be listed)"
  elif [ ! -d "$probe" ]; then
    note=" (not a directory)"
  elif [ ! -w "$probe" ] || [ ! -x "$probe" ]; then
    note=" (not writable and searchable by ${me:-this user})"
  fi
  echo "REFUSE cannot create the gate root $wanted: the nearest existing ancestor $probe is mode ${mode:-?} owner ${owner:-?}:${group:-?}$note"
  return 0
}

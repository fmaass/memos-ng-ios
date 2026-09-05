#!/usr/bin/env bash
#
# Source this file and call reap_gate_lanes GATE_ROOT WORK_ROOT CURRENT_BRANCH SURVIVORS.
# SURVIVORS lists the union of local and origin heads. Only absent, unlocked lanes older than
# 24 hours are reaped; the current lane is always protected.
# gate_lane_is_unlocked GATE_ROOT WORK_ROOT PATH also protects lanes during hygiene sweeps.

gate_lane_is_unlocked() {
  local gate_root="$1" work_root="$2" path="$3" lane ancestor locks
  case "$path" in
    "$gate_root"/*) lane="${path#"$gate_root/"}" ;;
    "$work_root"/*) lane="${path#"$work_root/"}" ;;
    *) return 1 ;;
  esac
  case "/$lane/" in */../*|*/./*|*//*|*/*.lock/*|*/*.lock.reaped-*/*) return 1 ;; esac
  # An old owner can still hold a live build; only the existing takeover path proves death.
  ancestor="$lane"
  while :; do
    [ ! -e "$gate_root/$ancestor.lock" ] && [ ! -L "$gate_root/$ancestor.lock" ] || return 1
    case "$ancestor" in */*) ancestor="${ancestor%/*}" ;; *) break ;; esac
  done
  # Descendant locks also protect a namespace if an interrupted lane looked like a parent.
  if [ -d "$gate_root/$lane" ]; then
    locks="$(find "$gate_root/$lane" -name '*.lock' -print -prune)" || return 1
    [ -z "$locks" ] || return 1
  fi
  return 0
}

reap_gate_lanes() (
  set -uo pipefail
  local gate_root="$1" work_root="$2" current="$3" survivors="$4"
  local root path lane keep survivor dir physical size old
  [ -f "$survivors" ] && [ -r "$survivors" ] || return 2
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-reap-list-XXXXXX")" || return 1
  trap 'rm -rf "$tmp"' EXIT
  : > "$tmp/lanes"
  for root in "$gate_root" "$work_root"; do
    [ -d "$root" ] || continue
    [ ! -L "$root" ] || return 2
    # Branches can contain any number of slashes. Payload markers stop traversal before
    # dependency trees, and empty leaves include lanes interrupted before their first copy.
    find "$root" -type d \( -name '*.lock' -o -name '*.lock.reaped-*' \
      -o -exec test -f '{}/project.yml' \; \
      -o -exec test -d '{}/DerivedData' \; \
      -o -exec test -d '{}/warnings' \; \
      -o -exec test -d '{}/scratch' \; -o -empty \) -print -prune \
      > "$tmp/paths" || return 1
    while IFS= read -r path; do
      [ "$path" != "$root" ] || continue
      lane="${path#"$root/"}"
      case "$lane" in *.lock|*.lock.reaped-*) continue ;; esac
      printf '%s\n' "$lane" >> "$tmp/lanes"
    done < "$tmp/paths"
  done
  LC_ALL=C sort -u "$tmp/lanes" > "$tmp/sorted" || return 1
  while IFS= read -r lane; do
    case "/$lane/" in */../*|*/./*|*//*|*/*.lock/*|*/*.lock.reaped-*/*) continue ;; esac
    keep=0
    # A namespace containing a protected branch must not be mistaken for a disposable lane.
    case "$current" in "$lane"|"$lane"/*) continue ;; esac
    case "$lane" in "$current"/*) continue ;; esac
    while IFS= read -r survivor; do
      case "$survivor" in "$lane"|"$lane"/*) keep=1; break ;; esac
      case "$lane" in "$survivor"/*) keep=1; break ;; esac
    done < "$survivors"
    [ "$keep" -eq 0 ] || continue
    for dir in "$gate_root/$lane" "$work_root/$lane"; do
      [ ! -L "$dir" ] || { keep=1; break; }
      [ -d "$dir" ] || continue
      physical="$(cd "$dir" && pwd -P)" || return 1
      [ "$physical" = "$dir" ] || { keep=1; break; }
      # Another workstation's live branch may be absent from this clone's refs.
      old="$(find "$dir" -maxdepth 0 -type d -mmin +1440 -print)" || return 1
      [ -n "$old" ] || { keep=1; break; }
    done
    [ "$keep" -eq 0 ] || continue
    gate_lane_is_unlocked "$gate_root" "$work_root" "$gate_root/$lane" || continue
    for dir in "$work_root/$lane" "$gate_root/$lane"; do
      case "$dir" in *.lock|*.lock/*) continue ;; esac
      [ -d "$dir" ] || continue
      size="$(du -sh "$dir")" || return 1
      printf 'GATE_REAP removing %s\n' "$size"
      rm -rf "$dir" || return 1
    done
  done < "$tmp/sorted"
)

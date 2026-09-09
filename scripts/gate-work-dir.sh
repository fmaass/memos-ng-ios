#!/usr/bin/env bash
#
# Source this file and call gate_work_dir GATE_ROOT BRANCH, gate_work_root GATE_ROOT, or
# gate_work_root_resolved GATE_ROOT.
#
# The build scratch of a lane is the `work/` sibling of the gate root the preflight RESOLVED —
# the same root the refusal check measures the target against. It is derived from that root and
# nothing else: rewriting `/build/memos-ng-ios/gate/` into `.../work/` inside the physical path
# assumed ~/build/memos-ng-ios still resolves under a path spelling that out, which stops being
# true the moment the build tree is moved onto another volume (MEMNG-160).
#
# A root that is not absolute or not already resolved, and a branch that is not a plain relative
# path, are refused with exit 2 rather than turned into a directory somewhere unintended.

gate_work_root() {
  local gate_root="${1:-}" parent
  case "$gate_root" in
    /*) ;;
    *) echo "gate_work_root: the gate root is not an absolute path: ${gate_root:-(empty)}" >&2
       return 2 ;;
  esac
  case "$gate_root/" in
    */../*|*/./*|*//*)
      echo "gate_work_root: the gate root is not a resolved path: $gate_root" >&2
      return 2 ;;
  esac
  parent="${gate_root%/*}"
  [ -n "$parent" ] || {
    echo "gate_work_root: the gate root has no parent directory: $gate_root" >&2
    return 2
  }
  printf '%s\n' "$parent/work"
}

gate_work_dir() {
  local gate_root="${1:-}" branch="${2:-}" work_root
  [ -n "$branch" ] || { echo "gate_work_dir: no branch was given" >&2; return 2; }
  case "$branch" in
    /*) echo "gate_work_dir: the branch is not a relative path: $branch" >&2; return 2 ;;
  esac
  case "/$branch/" in
    */../*|*/./*|*//*)
      echo "gate_work_dir: the branch is not a plain path: $branch" >&2
      return 2 ;;
  esac
  work_root="$(gate_work_root "$gate_root")" || return 2
  printf '%s\n' "$work_root/$branch"
}

# The reaper compares physical paths and refuses a root that is a symlink, and a work tree moved
# onto another volume is how this host has bought space before — so what reaches it is resolved,
# the way the code this replaced resolved ~/build/memos-ng-ios/work. A tree that does not exist
# yet keeps its derived name: the first run of a lane still has to be told where to make one.
gate_work_root_resolved() {
  local raw
  raw="$(gate_work_root "${1:-}")" || return 2
  ( cd "$raw" 2>/dev/null && pwd -P ) || printf '%s\n' "$raw"
}

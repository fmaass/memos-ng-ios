#!/usr/bin/env bash
#
# Promotes the test-count candidate the copyback staged to the documented path, and only when this
# run wrote it.
#
# The build host's artifacts folder is excluded from the mirror and cleared only by the remote
# script, so a remote that stopped before clearing it — the host gone mid-way, the lane refused, a
# directory it could not enter — leaves the previous run's folder in place, and the copyback brings
# that run's `testcount-baseline.tsv` home. So the copyback never lands in the artifacts folder: it
# lands in a staging folder of this run's (`incoming-<run token>` inside it), and this script is the
# one thing that moves a candidate out of there. The remote writes this run's token to `run-token`
# on the same && chain that clears and recreates its folder, so that stamp exists only in a folder
# this run created: when the staged `run-token` holds exactly the token and one LF, the candidate is
# promoted to the documented path; any other stamp, or none, and it is deleted where it lies.
#
# The order is what keeps a failure from leaving a half-promoted folder that looks whole:
#   this run's stamp — the candidate alone is renamed into place first (same filesystem, one
#                      rename); only then is the rest moved up. A failed rename promotes nothing.
#   any other stamp  — the candidate is deleted from staging first; only then is the rest moved up,
#                      as evidence of whichever run wrote it, not as this run's. A failed deletion
#                      promotes nothing.
# A name the destination already holds (an earlier run's result bundle) is replaced, never merged
# into. After any failure the staging folder stays where it is, named on the line; the next run's
# startup cleanup discards it and names it again.
#
# Usage: testcount-candidate-owner.sh <staging dir> <artifacts dir> <run token>
# Exit:  0 = the stamp is this run's: the candidate, if one came back, and the rest were promoted and
#            the staging folder removed
#        1 = a deletion or move it decided on failed: the staging folder is kept, and named
#        2 = usage error, nothing was touched
#        3 = the stamp is not this run's (it differs or is absent): the candidate was discarded, the
#            rest promoted and the staging folder removed — this copyback brought no count of this run
set -uo pipefail

if [ "$#" -ne 3 ] || [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
  echo "testcount candidate: usage: testcount-candidate-owner.sh <staging dir> <artifacts dir> <run token>" >&2
  exit 2
fi

staging="$1"
dest="$2"
token="$3"
name="testcount-baseline.tsv"
candidate="$staging/$name"
stamp="$staging/run-token"

# Moves everything left in staging up into the destination, then removes the emptied folder.
promote_rest() {
  local entry base target rc=0
  for entry in "$staging"/* "$staging"/.[!.]* "$staging"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    base="${entry##*/}"
    target="$dest/$base"
    # `mv` onto an existing directory would move INTO it, so a directory on either side is replaced.
    if { [ -d "$entry" ] || [ -d "$target" ]; } && { [ -e "$target" ] || [ -L "$target" ]; }; then
      if ! rm -rf "$target"; then
        echo "testcount candidate: could not replace $target; $staging is kept"
        rc=1
        continue
      fi
    fi
    if ! mv -f "$entry" "$target"; then
      echo "testcount candidate: could not move $base up to $dest; $staging is kept"
      rc=1
    fi
  done
  if [ "$rc" -eq 0 ] && ! rmdir "$staging"; then
    echo "testcount candidate: could not remove the staging folder $staging"
    rc=1
  fi
  return "$rc"
}

if [ ! -d "$staging" ]; then
  echo "testcount candidate: none came back (stamp absent): the copy never created $staging"
  exit 3
fi

if [ -f "$stamp" ] && printf '%s\n' "$token" | cmp -s - "$stamp"; then
  if [ -e "$candidate" ] || [ -L "$candidate" ]; then
    if ! mv -f "$candidate" "$dest/$name"; then
      echo "testcount candidate: stamped by this run, but it could NOT be promoted to $dest/$name; nothing else was moved and $staging is kept"
      exit 1
    fi
    echo "testcount candidate: promoted to $dest/$name, stamped by this run"
  else
    echo "testcount candidate: none came back, stamp matches this run"
  fi
  promote_rest || exit 1
  exit 0
fi

if [ -e "$stamp" ] || [ -L "$stamp" ]; then
  why="stamp differs"
else
  why="stamp absent"
fi
if [ -e "$candidate" ] || [ -L "$candidate" ]; then
  if ! rm -f "$candidate"; then
    echo "testcount candidate: $why, and it could NOT be removed from $staging: it is not this run's; nothing was promoted and $staging is kept"
    exit 1
  fi
  echo "testcount candidate: discarded, $why — it is not this run's"
else
  echo "testcount candidate: none came back ($why)"
fi
echo "testcount candidate: the other files in $staging are moved to $dest as evidence of whichever run wrote them, not as this run's"
promote_rest || exit 1
exit 3

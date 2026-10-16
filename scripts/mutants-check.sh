# shellcheck shell=bash
#
# The mutant batch's check (MEMNG-825), read once and evaluated by bin/mac-gate.sh's bootstrap
# BEFORE the estate lock is requested: a patch directory the batch cannot use is refused there, not
# after a queue wait. It only reads the caller's tree; it never writes into it.
#
# mutants_check <repo root> <patch dir> <freeze dir>
#   Copies every patch into <freeze dir> FIRST and checks the copies, so the bytes it judged are the
#   bytes the run sends: an edit to <patch dir> afterwards reaches nothing. On success <freeze dir>
#   holds NN-<name>.patch, NN-<name>.files (the paths that patch modifies, one per line) and, last,
#   the marker .frozen. On failure it prints the reason on stdout and returns 2.
#
# The rules: 1 to 4 files, each named NN-<name>.patch and nothing else in the directory; each a
# unified diff that only MODIFIES existing files (no /dev/null, rename, copy, mode or binary
# lines), with -p1 paths that are relative, free of "..", made of [A-Za-z0-9._/+-], tracked, and
# under no directory named Tests; each applies with `patch -p1 --dry-run` to a scratch copy of the
# files it touches; no file is touched by two patches; no patch holds the prefix of the heredoc
# terminator the run sends it under.

MUTANTS_MAX=4
MUTANTS_TERMINATOR_PREFIX="MAC_GATE_MUTANT_PATCH_"

mutants_check() {
  local root="$1" dir="$2" freeze="$3" entry base count=0 f path seen="" scratch rc line
  [ -d "$dir" ] || { echo "--mutants $dir is not a directory"; return 2; }
  for entry in "$dir"/* "$dir"/.[!.]*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    base="${entry##*/}"
    if ! printf '%s\n' "$base" | grep -Eq '^[0-9]{2}-[a-z0-9-]+\.patch$'; then
      echo "--mutants $dir: $base is not named NN-<name>.patch (two digits, a dash, lower-case letters, digits and dashes)"
      return 2
    fi
    [ -f "$entry" ] && [ ! -L "$entry" ] || { echo "--mutants $dir: $base is not a regular file"; return 2; }
    case " $seen " in *" ${base%%-*} "*)
      echo "--mutants $dir: two patches carry the number ${base%%-*}"; return 2 ;;
    esac
    seen="$seen ${base%%-*}"
    count=$((count + 1))
  done
  [ "$count" -ge 1 ] || { echo "--mutants $dir holds no patch; a batch needs at least one patch"; return 2; }
  [ "$count" -le "$MUTANTS_MAX" ] \
    || { echo "--mutants $dir holds $count patches; a batch takes at most $MUTANTS_MAX patches (each one holds the shared simulator slot)"; return 2; }

  mkdir -p "$freeze" || { echo "--mutants: cannot create $freeze"; return 2; }
  for entry in "$dir"/[0-9][0-9]-*.patch; do
    cp "$entry" "$freeze/${entry##*/}" || { echo "--mutants: cannot copy ${entry##*/} into $freeze"; return 2; }
  done

  scratch="$freeze/.scratch"
  mkdir -p "$scratch" || { echo "--mutants: cannot create $scratch"; return 2; }
  : > "$freeze/.all-files"
  for f in "$freeze"/[0-9][0-9]-*.patch; do
    base="${f##*/}"
    [ -s "$f" ] || { echo "--mutants: $base is empty"; return 2; }
    [ "$(tail -c 1 "$f" | od -An -c | tr -d ' ')" = '\n' ] \
      || { echo "--mutants: $base does not end with a newline"; return 2; }
    [ "$(tr -d '\000' < "$f" | wc -c)" -eq "$(wc -c < "$f")" ] \
      || { echo "--mutants: $base holds a NUL byte"; return 2; }
    ! grep -qF "$MUTANTS_TERMINATOR_PREFIX" "$f" \
      || { echo "--mutants: $base holds $MUTANTS_TERMINATOR_PREFIX, the heredoc terminator's prefix it is sent under"; return 2; }
    if grep -Eq '^(--- /dev/null|\+\+\+ /dev/null|(new|deleted) file mode|old mode|new mode|rename (from|to)|copy (from|to)|similarity index|Binary files|GIT binary patch)' "$f"; then
      echo "--mutants: $base does not only modify existing files (a mutant may not create, delete, rename or re-mode one)"
      return 2
    fi
    if grep -Eq '^(\*\*\* |Index: |Prereq: )' "$f"; then
      echo "--mutants: $base is not a plain unified diff"; return 2
    fi
    : > "$freeze/${base%.patch}.files"
    while IFS= read -r line; do
      path="${line#+++ }"
      path="${path%%	*}"
      case "$path" in */*) path="${path#*/}" ;; *) echo "--mutants: $base names $path, which has no -p1 prefix"; return 2 ;; esac
      case "/$path/" in
        *//*) echo "--mutants: $base names $path, which is not in canonical form (an empty path segment)"; return 2 ;;
      esac
      case "/$path/" in
        */../*|*/./*) echo "--mutants: $base names $path, a path outside the tree or not relative"; return 2 ;;
      esac
      case "$path" in /*) echo "--mutants: $base names $path, a path outside the tree or not relative"; return 2 ;; esac
      printf '%s\n' "$path" | grep -Eq '^[A-Za-z0-9._/+-]+$' \
        || { echo "--mutants: $base names $(printf '%q' "$path"), which holds characters a patch path may not"; return 2; }
      case "/$path/" in */Tests/*) echo "--mutants: $base touches $path, a file under a Tests directory (a mutant changes product code)"; return 2 ;; esac
      git -C "$root" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 && [ -f "$root/$path" ] \
        || { echo "--mutants: $base names $path, which is not a tracked file of this tree"; return 2; }
      if grep -qxF -- "$path" "$freeze/.all-files"; then
        echo "--mutants: $path is touched by two patches; a batch's mutants must touch disjoint files"; return 2
      fi
      printf '%s\n' "$path" >> "$freeze/${base%.patch}.files"
      printf '%s\n' "$path" >> "$freeze/.all-files"
      mkdir -p "$scratch/$(dirname "$path")" && cp -p "$root/$path" "$scratch/$path" \
        || { echo "--mutants: cannot copy $path into the scratch tree"; return 2; }
    done < <(grep -E '^\+\+\+ ' "$f")
    # Every --- path has to name the same file as its +++ path.
    while IFS= read -r line; do
      path="${line#--- }"; path="${path%%	*}"; path="${path#*/}"
      grep -qxF -- "$path" "$freeze/${base%.patch}.files" \
        || { echo "--mutants: $base has a --- line for $path with no +++ line for it"; return 2; }
    done < <(grep -E '^--- ' "$f")
    [ -s "$freeze/${base%.patch}.files" ] || { echo "--mutants: $base names no file (no +++ line)"; return 2; }
    grep -q '^@@ ' "$f" || { echo "--mutants: $base holds no hunk"; return 2; }
  done
  for f in "$freeze"/[0-9][0-9]-*.patch; do
    (cd "$scratch" && timeout 60 patch -p1 --dry-run -s -N < "$f") >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 0 ] || { echo "--mutants: ${f##*/} does not apply to this tree (patch -p1 --dry-run exit $rc)"; return 2; }
  done
  rm -rf "${scratch:?}" "$freeze/.all-files"
  : > "$freeze/.frozen" || { echo "--mutants: cannot mark $freeze as frozen"; return 2; }
  return 0
}

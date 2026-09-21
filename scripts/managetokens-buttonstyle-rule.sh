#!/usr/bin/env bash
#
# The token-screen button rule: every control the token management screen draws goes through the
# house component, so none of them can be left with the system's default style.
#
# A card on that screen is ONE row of a List (MEMNG-476). SwiftUI treats a tap anywhere in a List
# row as a press of that row's default-styled buttons — and with several of them in one row, not
# necessarily the one under the finger, so a tap on a token's NAME revoked a different token and a
# tap on a minted token's plaintext pressed Done and took the one look at it away. An explicit
# button style confines each control to its own hit target, whichever way that arbitration goes.
#
# The rule is NEGATIVE, because every positive form of it can be satisfied while confining nothing:
# "every Button is followed by a style" is defeated by a comment or a string holding the word, does
# not see the trailing-closure form written without a label, and is satisfied by a style that
# confines nothing. So the screen may not name the type at all, and the house component is the only
# way to put a control on it. It is a LITERAL grep and comments are not exempt: a check a comment
# can defeat is not a check — which is also why this script lives in scripts/, where its own text
# may carry the literal the checked file may not.
#
# The positive control is the other half. A grep that finds nothing proves nothing on its own: it
# reads the same whether the rule holds or the screen was renamed, moved, or the mirror arrived
# empty — and it reads the same for a screen whose controls were simply deleted. So the same run
# requires the house component to be called at least six times in that file, one for each control
# the screen has.
#
# Control 2 is a HINT, not a fence, and stands where the manifest grep for the Features package's
# fatal warnings stands: no positive grep can prove an EXECUTABLE style. A commented-out line keeps
# a naive count at one, and a style that confines nothing satisfies a looser pattern. Matching only
# an UNCOMMENTED line whose first non-blank text is the house style closes the first hole and
# narrows the second; it closes neither completely.
#
# No test in this repository witnesses the style either, and the reason is worth writing down: a
# row hosted outside a real List cell does not merge its controls, so the tree a unit test reads
# holds each control separately whatever style they were given. The witness is the check on a
# device — a tap on a token's NAME does nothing and the list is unchanged.
#
# Both counts below read UNCOMMENTED text only, because a screen whose controls were all replaced
# by a sentence, with the calls left behind as comments, would otherwise pass every part of this
# script. Swift has two comment forms and both are removed before control 1 counts: every
# `/* … */` block first, nesting honoured because Swift nests them (a naive first-to-last strip
# would leave the tail of a nested block standing as live text), then every `//` line. The order
# matters: a `//` inside a block must not swallow that block's closing `*/`. A `/*` inside a
# string literal is the case this leaves open, and the screen has no such string.
#
# Usage: managetokens-buttonstyle-rule.sh [<repo-root>]   (default: the current directory)
# Exit:  0 = the rule holds and both controls answered
#        1 = the rule was broken, or a control failed
#        2 = the inputs were not usable (no such tree, a file missing, or a grep that could not
#            read it), which is never a pass
set -uo pipefail

root="${1:-.}"

if [ ! -d "$root" ]; then
  echo "BUTTONSTYLE FAIL: '$root' is not a directory, so nothing was checked"
  exit 2
fi

screen="$root/Packages/MemosFeatures/Sources/MemosFeatures/Settings/ManageTokensScreen.swift"
component="$root/Packages/MemosFeatures/Sources/MemosFeatures/Design/CardButton.swift"

if [ ! -f "$screen" ]; then
  echo "BUTTONSTYLE FAIL: $screen does not exist — the rule has nothing to read, so a clean grep"
  echo "                  below would only mean the screen moved"
  exit 2
fi
if [ ! -f "$component" ]; then
  echo "BUTTONSTYLE FAIL: $component does not exist — the house component every control on that"
  echo "                  screen is supposed to go through is not there"
  exit 2
fi

rc=0

# -w so the house component's own name is one word and does not answer this grep; -a so a file git
# thinks is binary still answers with file:line rather than "Binary file matches", because a hit
# nobody can locate is not evidence.
hits="$(grep -nawF 'Button' "$screen" 2>/dev/null)"
grep_rc=$?
if [ "$grep_rc" -ge 2 ]; then
  echo "BUTTONSTYLE FAIL: the grep over $screen ended with exit $grep_rc, so the rule was never"
  echo "                  checked"
  exit 2
fi

hit_count="$(printf '%s' "$hits" | grep -c . 2>/dev/null)"
echo "BUTTONSTYLE: $hit_count word-bounded hit(s) for the plain control type in ManageTokensScreen.swift"

if [ -n "$hits" ]; then
  echo "BUTTONSTYLE FAIL: the token management screen names the plain control type. Every control"
  echo "                  in its cards goes through the house component instead, because a card is"
  echo "                  one List row and a default-styled control in it is pressed by a tap"
  echo "                  anywhere in that row (MEMNG-476). Comments count: reword the"
  echo "                  explanation, do not silence the check."
  echo "$hits"
  rc=1
fi

uncommented="$(perl -0777 -pe 's{ ( /\* (?: [^/*]+ | /(?!\*) | \*(?!/) | (?1) )* \*/ ) }{}gsx; s{//[^\n]*}{}g' "$screen" 2>/dev/null)"
strip_rc=$?
if [ "$strip_rc" -ne 0 ] || [ -z "$uncommented" ]; then
  echo "BUTTONSTYLE FAIL: stripping the comments from $screen ended with exit $strip_rc or left"
  echo "                  nothing, so control 1 was never checked"
  exit 2
fi
component_calls="$(printf '%s\n' "$uncommented" | grep -caF 'CardButton(')"
echo "BUTTONSTYLE (control 1): the house component is called $component_calls uncommented time(s) in ManageTokensScreen.swift, 6 wanted"
if [ "$component_calls" -lt 6 ]; then
  echo "BUTTONSTYLE FAIL: positive control 1 — fewer than the screen's six controls go through the"
  echo "                  house component, so the clean grep above may only mean the controls went"
  echo "                  away or the file was never read"
  rc=1
fi

# A commented-out line cannot match: its first non-blank text is the comment marker, not the style.
# That is the whole of what this control is worth, and it is stated as such below.
style_lines="$(grep -caE '^[[:space:]]*\.buttonStyle\(\.borderless\)' "$component" 2>/dev/null)"
grep_rc=$?
if [ "$grep_rc" -ge 2 ]; then
  echo "BUTTONSTYLE FAIL: the control-2 grep over $component ended with exit $grep_rc, so the rule"
  echo "                  was never checked"
  exit 2
fi
echo "BUTTONSTYLE (control 2): $style_lines uncommented line(s) in Design/CardButton.swift begin with the house style, 1 wanted"
echo "BUTTONSTYLE: control 2 is a hint, not a fence — no grep can prove a style EXECUTES, and no"
echo "             test here does either: a row hosted outside a real List cell does not merge its"
echo "             controls. The witness is the check on a device — a tap on a token's name does"
echo "             nothing and the list is unchanged."
if [ "$style_lines" -ne 1 ]; then
  echo "BUTTONSTYLE FAIL: control 2 — the house component does not apply the house style on exactly"
  echo "                  one uncommented line of its own file"
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  echo "BUTTONSTYLE ok: no plain control type in ManageTokensScreen.swift, and both controls answered"
fi

exit $rc

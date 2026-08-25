#!/usr/bin/env python3
"""Read an xcodebuild log back and answer one question: was the MemosFeatures library module
compiled with its warnings fatal?

The gate cannot ask the manifest — a declaration can be commented out, moved to the test target or
conditioned away, and the build still exits 0 with its warnings merely printed. So it asks the
build log, and this is the reader. Kept out of bin/mac-gate.sh so it can be fed a log by
tests/gate/warnings-flag-test.sh instead of only by a ten-minute build.

Usage: read-warnings-flag.py <build.log>
Exit:  0 = a compiler invocation for the MemosFeatures library module carried -warnings-as-errors
       1 = it did not, or the log holds no task for that target at all (a silent log proves
           nothing and is not a pass)
"""

import re
import sys

TARGET_TASK = "in target 'MemosFeatures' from project 'MemosFeatures'"
MODULE = re.compile(r"-module-name MemosFeatures(?![\w-])")
COMPILER = re.compile(r"(^|\s)\S*/(swiftc|swift-frontend)(\s|$)")
FLAG = re.compile(r"(^|\s)-warnings-as-errors(\s|$)")
DIAGNOSTIC = re.compile(r"(^|\s)(warning|error|note):")


def is_invocation(line):
    """A line that RUNS the compiler for the MemosFeatures library module.

    Everything here is a way a line can look like proof without being it. A diagnostic is the
    important one: `#warning("-warnings-as-errors")` in a source file prints a line that carries
    the flag's text, under this target's own task header, in a build that exited 0 — so any line
    the compiler EMITTED is refused before anything else is read. What remains has to name the
    compiler binary and this module: the test target's invocation carries -module-name
    MemosFeaturesTests and is not this one.
    """
    if DIAGNOSTIC.search(line):
        return False
    if not COMPILER.search(line):
        return False
    return bool(MODULE.search(line))


def read(text):
    """Return (tasks, invocations, flagged) for a build log."""
    tasks = invocations = flagged = 0
    mine = False
    for line in text.splitlines():
        # A task's header names its target; the lines under it are that task's command, so a flag
        # is only ever credited to the target whose header it appeared beneath.
        if "in target '" in line:
            mine = TARGET_TASK in line
            if mine:
                tasks += 1
        if not mine or not is_invocation(line):
            continue
        invocations += 1
        if FLAG.search(line):
            flagged += 1
    return tasks, invocations, flagged


def main(argv):
    if len(argv) != 2:
        print("usage: read-warnings-flag.py <build.log>")
        return 2
    try:
        text = open(argv[1], encoding="utf-8", errors="replace").read()
    except OSError as error:
        print("WARNAERR FAIL: cannot read the build log %s: %s" % (argv[1], error))
        return 1

    tasks, invocations, flagged = read(text)
    print("MemosFeatures build tasks in the log: %d" % tasks)
    print("compiler invocations for the MemosFeatures module: %d" % invocations)
    print("of them carrying -warnings-as-errors: %d" % flagged)

    if tasks < 1:
        print("WARNAERR FAIL: the build log holds no task for the MemosFeatures target, so it "
              "says nothing about how that target was compiled")
        return 1
    if invocations < 1:
        print("WARNAERR FAIL: the log holds no compiler invocation for the MemosFeatures module, "
              "so nothing in it says how that module was compiled")
        return 1
    if flagged < 1:
        print("WARNAERR FAIL: no compiler invocation for the MemosFeatures module carried "
              "-warnings-as-errors, so its warnings were not fatal in this build")
        return 1
    print("ok: the MemosFeatures module was compiled with -warnings-as-errors")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
"""The privacy-manifest half of the gate's shipping-bundle read-back, as one verdict.

    privacy-manifest-verdict.py <bundle label> <path to PrivacyInfo.xcprivacy>

The full gate runs this against the BUILT app's and extension's manifests (bin/mac-gate.sh,
s_bundlecheck); tests/gate/privacy-manifest-test.sh feeds it the tracked manifests and edited
copies of them. It lives in a file of its own so the refusal can be exercised without a build.

Each required-reason category written down below for a bundle is held to exactly the reasons
written beside it: the category missing, a reason missing or a reason added fails, naming the
bundle and the difference. Order is not held, because Apple does not read it. The expectation is spelled
out here, not read from the tracked manifests, so an edit that drops an entry from the manifest
cannot also drop it from what the gate expects. When a manifest's reasons change on purpose, this
table changes in the same commit.

Exit: 0 = the manifest holds; 1 = it does not (every difference printed as a BUNDLE FAIL line);
      2 = a usage error (the label is not a bundle this gate reads back).

Runs under the build host's /usr/bin/python3, so it stays within what Python 3.9 accepts.
"""
import os
import plistlib
import sys

EXPECTED_REASONS = {
    "app": {
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1"],
    },
    "extension": {
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1"],
    },
}

SHORT_NAMES = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": "file-timestamp",
    "NSPrivacyAccessedAPICategoryUserDefaults": "user-defaults",
}


def main(argv):
    if len(argv) != 3 or argv[1] not in EXPECTED_REASONS:
        sys.stderr.write("usage: %s <%s> <PrivacyInfo.xcprivacy>\n"
                         % (os.path.basename(argv[0]), "|".join(sorted(EXPECTED_REASONS))))
        return 2
    label, path = argv[1], argv[2]
    failures = []

    def fail(message):
        failures.append(message)
        print("BUNDLE FAIL: %s %s" % (label, message))

    if not os.path.isfile(path):
        fail("has no PrivacyInfo.xcprivacy at its bundle root")
        return 1
    try:
        with open(path, "rb") as handle:
            privacy = plistlib.load(handle)
    except Exception as error:
        fail("PrivacyInfo.xcprivacy does not parse: %s" % error)
        return 1
    if not isinstance(privacy, dict):
        fail("PrivacyInfo.xcprivacy is a %s, expected a dictionary" % type(privacy).__name__)
        return 1
    print("  ok: PrivacyInfo.xcprivacy present at the bundle root")

    if privacy.get("NSPrivacyTracking") is not False:
        fail("NSPrivacyTracking is %r, expected false" % (privacy.get("NSPrivacyTracking"),))
    if privacy.get("NSPrivacyTrackingDomains") != []:
        fail("NSPrivacyTrackingDomains is %r, expected empty"
             % (privacy.get("NSPrivacyTrackingDomains"),))
    if privacy.get("NSPrivacyCollectedDataTypes") != []:
        fail("NSPrivacyCollectedDataTypes is %r, expected empty"
             % (privacy.get("NSPrivacyCollectedDataTypes"),))

    # Entries are collected per category rather than folded into a dict, so a category declared
    # twice is seen instead of the second entry silently replacing the first.
    declared = {}
    for entry in privacy.get("NSPrivacyAccessedAPITypes", []) or []:
        if not isinstance(entry, dict):
            fail("NSPrivacyAccessedAPITypes holds a %s, expected dictionaries" % type(entry).__name__)
            continue
        declared.setdefault(entry.get("NSPrivacyAccessedAPIType"), []).append(
            entry.get("NSPrivacyAccessedAPITypeReasons"))

    for category, expected in sorted(EXPECTED_REASONS[label].items()):
        name = SHORT_NAMES.get(category, category)
        entries = declared.get(category)
        if not entries:
            fail("declares no %s entry (%s), expected reasons %s" % (name, category, expected))
            continue
        if len(entries) > 1:
            fail("declares the %s category %d times, expected once" % (name, len(entries)))
            continue
        reasons = entries[0]
        if not isinstance(reasons, list) or not all(isinstance(r, str) for r in reasons):
            fail("declares %s reasons %r, expected a list of reason codes %s" % (name, reasons, expected))
            continue
        missing = [r for r in expected if r not in reasons]
        unexpected = [r for r in reasons if r not in expected]
        repeated = sorted(set(r for r in reasons if reasons.count(r) > 1))
        if missing or unexpected or repeated:
            detail = []
            if missing:
                detail.append("missing %s" % ", ".join(missing))
            if unexpected:
                detail.append("not expected %s" % ", ".join(unexpected))
            if repeated:
                detail.append("repeated %s" % ", ".join(repeated))
            fail("declares %s reasons %r, expected %r — %s"
                 % (name, reasons, expected, "; ".join(detail)))
        else:
            print("  ok: %s category declared with reasons %s" % (name, ", ".join(expected)))

    print("  declared API categories: %s"
          % (", ".join(sorted(str(c) for c in declared)) or "(none)"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/python3
"""Records the WPN-12/13 simulator clips (MEMNG-779, MEMNG-780, MEMNG-781, MEMNG-783, MEMNG-822, MEMNG-860) on the build host.

Companion of `MediaImageLoaderTests/clip*()` in SelectionChromeClipTests.swift, run while
xcodebuild runs those tests on ONE device this script is told about (it never creates, boots,
shuts down or deletes a device):

    record-selection-clips.py --udid <udid> --out <dir> [--timeout <s>] [--settings]

Per scene the test writes `clip-ready` = `<scene> <nonce>` into the host app's tmp directory; this
script starts `simctl io <udid> recordVideo` into `<out>/<scene>.mov`, answers `clip-recording`
with the same nonce once the first frame is in, gives the scene's touches through `idb ui`
(a SwiftUI Menu opens only on a real touch), stops the recording with SIGINT (which finalises the
movie) and answers `clip-finished` = `<scene> ok|failed <nonce>`: a scene whose touches or movie
failed says so, and the test fails on it rather than on the next scene's silence. A ready file
older than this script's start, or a nonce it already answered, is never taken. `--settings`
records one more scene with no test behind it, once the tests are over: the Settings app's page
for the app, scrolled to its Storage group.

Exit: 0 every expected scene recorded at >= 2 s; 1 anything else; 2 usage.
"""

import argparse
import glob
import json
import os
import signal
import subprocess
import sys
import time

BUNDLE_ID = "live.discomarder.memosng"
IDB = os.path.expanduser("~/Library/Python/3.9/bin/idb")
SCENES = [
    "779a-library-filter-menu",
    "779b-library-select-show-selected",
    "780a-trip-filter-menu",
    "780b-trip-ellipsis-menu",
    "780c-trip-select-remove",
    "781a-collections-retap",
    "783-collection-cards",
    "822-collection-modes-bar",
    "845a-library-scope-row",
    "860a-viewer-bar",
    "860b-viewer-date-capsule",
    "860c-viewer-hide-on-tap",
]
ENV = dict(os.environ, PATH="/opt/homebrew/bin:" + os.environ.get("PATH", "/usr/bin:/bin"))


def log(message):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), message, flush=True)


class Driver:
    def __init__(self, udid, out):
        self.udid = udid
        self.out = out
        self.step = 0
        self.scene = ""

    # --- idb ----------------------------------------------------------------------------------
    def idb(self, *args):
        command = [IDB, *args, "--udid", self.udid]
        done = subprocess.run(command, env=ENV, capture_output=True, text=True, timeout=60)
        if done.returncode != 0:
            raise RuntimeError("idb %s exited %d: %s" % (args[:2], done.returncode, done.stderr[-400:]))
        return done.stdout

    def elements(self):
        """Every accessibility element on screen; each describe is kept for the README's evidence."""
        text = self.idb("ui", "describe-all", "--json")
        self.step += 1
        with open(os.path.join(self.out, "ax", "%s-%02d.json" % (self.scene, self.step)), "w") as f:
            f.write(text)
        found = json.loads(text) if text.strip().startswith("[") else []
        return [e for e in found if isinstance(e, dict) and e.get("frame")]

    @staticmethod
    def centre(element):
        frame = element["frame"]
        return frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] / 2

    def find(self, label, prefix=False, lowest=False, attempts=10):
        for _ in range(attempts):
            hits = [
                e for e in self.elements()
                if ((e.get("AXLabel") or "").startswith(label) if prefix
                    else e.get("AXLabel") == label)
            ]
            if hits:
                hits.sort(key=lambda e: e["frame"]["y"])
                return hits[-1] if lowest else hits[0]
            time.sleep(0.5)
        raise RuntimeError("no element labelled %r on screen (scene %s)" % (label, self.scene))

    def find_id(self, identifier, attempts=10):
        for _ in range(attempts):
            hits = [e for e in self.elements() if e.get("AXUniqueId") == identifier]
            if hits:
                return hits[0]
            time.sleep(0.5)
        raise RuntimeError("no element identified %r on screen (scene %s)" % (identifier, self.scene))

    def find_in_bar(self, label, attempts=10):
        """A navigation-bar item by its label. On iOS 26.5 idb's describe-all lists the bar as one
        empty Group, so the bar is asked point by point along its centre line instead; the
        element describe-point returns carries its own frame, which is what gets tapped."""
        for _ in range(attempts):
            for x in range(8, 402, 12):
                try:
                    element = json.loads(self.idb("ui", "describe-point", str(x), "84", "--json"))
                except (RuntimeError, ValueError):
                    continue
                if isinstance(element, list):
                    element = element[0] if element else None
                if isinstance(element, dict) and element.get("frame") and element.get("AXLabel") == label:
                    return element
            time.sleep(0.5)
        raise RuntimeError("no bar item labelled %r (scene %s)" % (label, self.scene))

    def tap_bar(self, label):
        x, y = self.centre(self.find_in_bar(label))
        self.tap_at(x, y, repr(label))

    def tap_segment(self, identifier, index, count, why):
        """A segment of a segmented control by its place: idb's describe-all stops at the
        control (a TabGroup carrying the identifier) and lists none of its segments."""
        frame = self.find_id(identifier)["frame"]
        x = frame["x"] + frame["width"] * (index + 0.5) / count
        self.tap_at(x, frame["y"] + frame["height"] / 2, why)

    def tap_at(self, x, y, why):
        log("tap %s at %.0f,%.0f" % (why, x, y))
        self.idb("ui", "tap", "%.0f" % x, "%.0f" % y)

    def tap(self, label, prefix=False, lowest=False):
        x, y = self.centre(self.find(label, prefix=prefix, lowest=lowest))
        self.tap_at(x, y, repr(label))

    def swipe(self, x1, y1, x2, y2, duration=0.5):
        log("swipe %.0f,%.0f -> %.0f,%.0f" % (x1, y1, x2, y2))
        self.idb("ui", "swipe", "%.0f" % x1, "%.0f" % y1, "%.0f" % x2, "%.0f" % y2,
                 "--duration", str(duration))

    # --- scenes -------------------------------------------------------------------------------
    def scene_779a(self):
        # The order and the filter are kept between launches, so each pick is the value NOT
        # current: the film shows a change whatever an earlier run left.
        time.sleep(1.5)
        heading = [e.get("AXLabel") for e in self.elements() if " \u00b7 " in (e.get("AXLabel") or "")]
        kind = heading[0].split(" \u00b7 ")[0] if heading else "All Items"
        self.tap("Filter")
        time.sleep(2.5)
        sort = self.find("Sort By", prefix=True).get("AXLabel") or ""
        order = sort.split(", ", 1)[1] if ", " in sort else "Newest First"
        self.tap("Sort By", prefix=True)
        time.sleep(3)
        self.tap("Oldest First" if order == "Newest First" else "Newest First")
        time.sleep(2.5)
        self.tap("Filter")
        time.sleep(2.5)
        self.tap("Photos" if kind == "All Items" else "All Items")
        time.sleep(2.5)

    def scene_779b(self):
        time.sleep(1.5)
        self.tap("Select")
        time.sleep(2)
        tiles = [
            e for e in self.elements()
            if (e.get("AXLabel") or "").startswith("Photo")
            and 150 <= e["frame"]["y"] and e["frame"]["y"] + e["frame"]["height"] <= 760
        ]
        tiles.sort(key=lambda e: (e["frame"]["y"], e["frame"]["x"]))
        if len(tiles) < 3:
            raise RuntimeError("fewer than three tiles on screen to select: %d" % len(tiles))
        for tile in tiles[:3]:
            x, y = self.centre(tile)
            self.tap_at(x, y, "tile %r" % tile.get("AXLabel"))
            time.sleep(1)
        time.sleep(1.5)
        self.tap("Show Selected", prefix=True)
        time.sleep(3)
        self.tap("Show Selected", prefix=True)
        time.sleep(2.5)
        self.tap("Close")
        time.sleep(2)

    def scene_780a(self):
        # One test holds the three trip scenes: this one opens Portugal, 780b and 780c go on in
        # it. The trip's filter is the screen's own, unfiltered on every launch.
        time.sleep(2)
        self.tap("Portugal")
        time.sleep(3.5)
        self.tap_bar("Filter")
        time.sleep(2.5)
        # The menu's rows, or the scene stops; a nested menu's label may carry its value.
        for row in ("All Items", "Captured by me", "Sort By", "Removed from trip"):
            self.find(row, prefix=True)
        self.tap("Visibility", prefix=True)   # the nested menu: Any, Public, Just us
        time.sleep(3)
        self.find("Just us")
        self.tap("Any")   # the choice in force: the menu closes, nothing changes
        time.sleep(2)
        self.tap_bar("Filter")
        time.sleep(2.5)
        self.tap("Videos")   # the trip holds pictures only: the grid empties
        time.sleep(3.5)
        self.tap_bar("Filter")
        time.sleep(2.5)
        self.tap("All Items")   # and fills again
        time.sleep(3.5)

    def scene_780b(self):
        # The ellipsis menu, named Manage for VoiceOver; left by a touch outside it, on the
        # navigation bar's title, so nothing in it is chosen.
        time.sleep(1.5)
        self.tap_bar("Manage")
        time.sleep(2.5)
        for row in ("Rename", "Trip Dates", "Delete Trip"):
            self.find(row)
        time.sleep(1.5)
        self.dismiss_menu()
        time.sleep(2)
        try:
            self.find("Delete Trip", attempts=1)
        except RuntimeError:
            return
        raise RuntimeError("the ellipsis menu is still open after a touch outside it")

    def scene_780c(self):
        time.sleep(1.5)
        self.tap_bar("Select")
        time.sleep(2)
        tiles = [
            e for e in self.elements()
            if (e.get("AXLabel") or "").startswith("Photo")
            and 150 <= e["frame"]["y"] and e["frame"]["y"] + e["frame"]["height"] <= 760
        ]
        tiles.sort(key=lambda e: (e["frame"]["y"], e["frame"]["x"]))
        if len(tiles) < 2:
            raise RuntimeError("fewer than two tiles on screen to select: %d" % len(tiles))
        for tile in tiles[:2]:
            x, y = self.centre(tile)
            self.tap_at(x, y, "tile %r" % tile.get("AXLabel"))
            time.sleep(1)
        time.sleep(1)
        self.tap_bar("More")   # select mode's actions menu
        time.sleep(2.5)
        self.find("Remove 2 pictures from trip", prefix=True)   # the menu is open
        # Visibility belongs to a memo, not to the pictures select mode chooses: no row for it.
        offered = [
            e.get("AXLabel") for e in self.elements()
            if (e.get("AXLabel") or "").startswith("Set visibility")
        ]
        if offered:
            raise RuntimeError("select mode's More offers a visibility row: %r" % offered)
        time.sleep(1.5)
        self.tap("Remove 2 pictures from trip", prefix=True)   # the row ends in an ellipsis
        time.sleep(2.5)
        self.find("Remove 2 pictures from Portugal?")
        self.find("They stay in your library.")
        time.sleep(2)
        self.tap("Cancel")
        time.sleep(2)
        self.tap_bar("Close")   # select mode ends; the trip's Filter is back
        time.sleep(2.5)

    def dismiss_menu(self):
        """A touch outside an open menu closes it and reaches nothing under it. Not the title: on
        iOS 26.5 the ellipsis menu opens over the bar (x 44-294, y 62-219, Rename first), so a
        touch on the title or at 201,80 chooses Rename. Right of the menu, mid-screen, is clear."""
        self.tap_at(380, 500, "outside the menu, right of it")

    def scene_781a(self):
        # MEMNG-822 amends the re-tap: over a trip it returns the modes row, and Back reaches
        # the root. The bar's lowest "Collections" is the modes row's icon, then the tab.
        time.sleep(2)
        self.tap("Portugal")
        time.sleep(3.5)
        self.tap("Collections", lowest=True)
        time.sleep(3)
        self.tap("Collections", lowest=True)
        time.sleep(3)
        self.back()
        time.sleep(3.5)

    def scene_822(self):
        # MEMNG-845: the row comes and goes as the Library's scope row does (scene_845a): the
        # trip opens on the tabs, its scroll brings the row, the top gives the tabs back.
        time.sleep(2)
        self.tap("Portugal")
        time.sleep(3.5)
        self.fold()   # the capsule morphs into the Collections icon and the modes
        time.sleep(3)
        self.tap_segment("collection-modes", 1, 3, "'Journal' segment")
        time.sleep(3)
        self.tap_segment("collection-modes", 2, 3, "'Map' segment")
        time.sleep(3)
        self.tap_segment("collection-modes", 0, 3, "'Photos' segment")
        time.sleep(3)
        self.tap_id("collection-modes-show-tabs", "the row's Collections icon")   # full capsule
        time.sleep(3)
        self.tap("Collections", lowest=True)   # pressed where it shows: the row again
        time.sleep(3)
        self.swipe(200, 400, 200, 700, 0.6)   # back to the top: the tabs
        time.sleep(3)
        self.fold()
        time.sleep(3)
        self.find_id("collection-modes")   # the row before Back, or the scene stops here
        self.back()
        time.sleep(3.5)

    def scene_845a(self):
        # The Library's scope row, the reference scene_822 is matched to (MEMNG-845).
        time.sleep(2)
        self.swipe(200, 600, 200, 300, 0.6)   # the capsule morphs into the icon and the scope
        time.sleep(3)
        self.tap_segment("library-scope", 1, 3, "'Months' segment")
        time.sleep(3)
        self.tap_segment("library-scope", 2, 3, "'All' segment")
        time.sleep(3)
        self.tap_segment("library-scope", 0, 3, "'Years' segment")
        time.sleep(3)
        self.tap_id("library-show-tabs", "the row's Library icon")   # full capsule
        time.sleep(3)
        self.tap("Library", lowest=True)   # pressed where it shows: the row again
        time.sleep(3)
        self.swipe(200, 300, 200, 750, 0.6)   # back to the top: the tabs
        time.sleep(2)
        self.swipe(200, 300, 200, 750, 0.6)
        time.sleep(3)

    def scene_860a(self):
        # MEMNG-860: the viewer's bottom bar. One test holds the three viewer scenes: this one
        # opens the first picture of the Library, 860b and 860c go on in the same viewer.
        time.sleep(2)
        tiles = [
            e for e in self.elements()
            if (e.get("AXLabel") or "").startswith("Photo")
            and 150 <= e["frame"]["y"] and e["frame"]["y"] + e["frame"]["height"] <= 760
        ]
        tiles.sort(key=lambda e: (e["frame"]["y"], e["frame"]["x"]))
        if not tiles:
            raise RuntimeError("no tile on screen to open")
        x, y = self.centre(tiles[0])
        self.tap_at(x, y, "tile %r" % tiles[0].get("AXLabel"))
        time.sleep(3.5)
        for label in ("Share", "Favorite", "Info", "Close"):
            self.find(label)   # the bar's three controls and the top row, or the scene stops
        time.sleep(3)

    def scene_860b(self):
        # The date capsule: it follows the page, so a swipe to the next picture moves it.
        time.sleep(2)
        self.swipe(330, 440, 70, 440, 0.4)
        time.sleep(3)
        self.swipe(70, 440, 330, 440, 0.4)
        time.sleep(3)

    def scene_860c(self):
        # Hide-on-tap: one tap on the picture takes the top row, the capsule and the bar away,
        # the next brings all three back. The pause between them keeps the two taps apart, so
        # neither reads as the double tap that zooms.
        time.sleep(2)
        self.tap_at(201, 440, "the picture, to hide the chrome")
        time.sleep(3)
        self.tap_at(201, 440, "the picture, to show the chrome")
        time.sleep(3)
        self.find("Info")   # the bar is back, or the scene stops here
        self.tap("Close")
        time.sleep(2.5)

    def fold(self):
        """A short drag down that stays inside the trip's few points of travel: a longer one
        overshoots the end, and the bounce back counts as travel up, which unfolds the bar."""
        self.swipe(200, 600, 200, 545, 1.0)

    def tap_id(self, identifier, why):
        x, y = self.centre(self.find_id(identifier))
        self.tap_at(x, y, why)

    def back(self):
        """The navigation bar's Back, by its label, else where iOS draws it."""
        try:
            self.tap("Back")
        except RuntimeError:
            self.tap_at(32, 80, "Back by place")

    def scene_783(self):
        time.sleep(2.5)
        for label, prefix in (("Portugal", False), ("#garden", False), ("Oct 2026", False),
                              ("2026", False)):
            row = self.find(label, prefix=prefix)
            _, y = self.centre(row)
            if y > 700:
                self.swipe(200, 700, 200, 380, 0.6)
                time.sleep(1.5)
                _, y = self.centre(self.find(label, prefix=prefix))
            self.swipe(370, y, 40, y, 0.7)
            time.sleep(1.8)
            self.swipe(40, y, 370, y, 0.7)
            time.sleep(1.5)
        time.sleep(1)
        self.tap("Sep 2026")
        time.sleep(4)

    def scene_settings(self):
        time.sleep(2)
        for name in ("Apps",):
            self.scroll_to(name)
            self.tap(name)
            time.sleep(2)
        self.scroll_to("memos", prefix_any=True)
        time.sleep(2.5)
        self.scroll_to("Clear media cache on next launch")
        time.sleep(2.5)
        # The row's middle is its label, which does not flip a switch: the switch sits at the
        # row's trailing edge.
        for _ in range(2):
            row = self.find("Clear media cache on next launch")
            frame = row["frame"]
            self.tap_at(frame["x"] + frame["width"] - 35, frame["y"] + frame["height"] / 2,
                        "the Clear media cache switch")
            time.sleep(2.5)

    def scroll_to(self, label, prefix_any=False):
        for _ in range(16):
            hits = [
                e for e in self.elements()
                if (label.lower() in (e.get("AXLabel") or "").lower() if prefix_any
                    else e.get("AXLabel") == label)
                and 80 <= e["frame"]["y"] <= 760
            ]
            if hits:
                if prefix_any:
                    # A tap on a list still moving only stops it: let the swipe settle, look again.
                    time.sleep(1.5)
                    hits = [
                        e for e in self.elements()
                        if label.lower() in (e.get("AXLabel") or "").lower()
                        and 80 <= e["frame"]["y"] <= 760
                    ] or hits
                    x, y = self.centre(hits[0])
                    self.tap_at(x, y, repr(hits[0].get("AXLabel")))
                return
            # Short and slow, so the list barely coasts and no row passes unseen between looks.
            self.swipe(200, 600, 200, 420, 1.0)
            time.sleep(1)
        raise RuntimeError("no %r after scrolling (scene %s)" % (label, self.scene))

    # --- one recorded scene ----------------------------------------------------------------------
    def record(self, scene, answer):
        """Records `scene`; `answer(name, verdict)` writes a handshake file, or does nothing without
        a test."""
        self.scene = scene
        self.step = 0
        movie = os.path.join(self.out, scene + ".mov")
        rec_log = open(os.path.join(self.out, scene + ".recordVideo.log"), "w")

        def default_sigint():
            signal.signal(signal.SIGINT, signal.SIG_DFL)

        recorder = subprocess.Popen(
            ["xcrun", "simctl", "io", self.udid, "recordVideo", "--codec=h264", "--force", movie],
            stdout=rec_log, stderr=subprocess.STDOUT, preexec_fn=default_sigint)
        started = time.time()
        while time.time() - started < 15:
            with open(rec_log.name) as f:
                if "Recording started" in f.read():
                    break
            if recorder.poll() is not None:
                raise RuntimeError("recordVideo exited %s before it started" % recorder.returncode)
            time.sleep(0.1)
        log("recording %s since %.3f" % (scene, time.time()))
        answer("clip-recording")
        failure = None
        try:
            getattr(self, "scene_" + scene.split("-")[0])()
        except Exception as error:  # the movie is still stopped and the test still answered
            failure = error
        recorder.send_signal(signal.SIGINT)
        try:
            recorder.wait(timeout=15)
        except subprocess.TimeoutExpired:
            recorder.kill()
            failure = failure or RuntimeError("recordVideo outlived SIGINT by 15 s")
        duration = None
        if not failure:
            duration = subprocess.run(
                ["/opt/homebrew/bin/ffprobe", "-v", "error", "-show_entries", "format=duration",
                 "-of", "default=nw=1:nk=1", movie], capture_output=True, text=True).stdout.strip()
            log("scene %s: %s lasts %s s" % (scene, movie, duration))
            if not duration or float(duration) < 2.0:
                failure = RuntimeError("clip %s lasts %r s, under 2 s" % (movie, duration))
        answer("clip-finished", "failed" if failure else "ok")
        if failure:
            raise RuntimeError("scene %s: %s" % (scene, failure))
        return duration


def live_ready(udid, since):
    """The tmp directory whose `clip-ready` was written after `since`, or None: an install made
    after this script started can move the app to a new data container, so every container of the
    device is looked in, never one read once at the start."""
    root = os.path.expanduser(
        "~/Library/Developer/CoreSimulator/Devices/%s/data/Containers/Data/Application" % udid)
    newest = None
    for path in glob.glob(os.path.join(root, "*", "tmp", "clip-ready")):
        try:
            stamp = os.path.getmtime(path)
        except OSError:
            continue
        if stamp > since and (newest is None or stamp > newest[0]):
            newest = (stamp, os.path.dirname(path))
    return newest[1] if newest else None


def put(directory, name, content):
    staging = os.path.join(directory, ".%s.%d" % (name, os.getpid()))
    with open(staging, "w") as f:
        f.write(content + "\n")
    os.replace(staging, os.path.join(directory, name))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--udid", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--timeout", type=int, default=2400)
    parser.add_argument("--settings", action="store_true")
    parser.add_argument("--only", default="", help="comma-separated scenes expected, default all")
    try:
        args = parser.parse_args()
    except SystemExit:
        sys.exit(2)
    os.makedirs(os.path.join(args.out, "ax"), exist_ok=True)
    # "-" expects no test scene at all: the Settings scene alone, after an earlier run.
    expected = [] if args.only == "-" else ([s for s in args.only.split(",") if s] or SCENES)
    started = time.time()
    deadline = started + args.timeout
    driver = Driver(args.udid, args.out)
    durations = {}
    answered = set()
    while len(durations) < len(expected):
        if time.time() > deadline:
            log("RECORD FAIL: scenes %s not seen within %d s" % (
                [s for s in expected if s not in durations], args.timeout))
            sys.exit(1)
        tmp = live_ready(args.udid, started)
        fields = []
        if tmp:
            try:
                with open(os.path.join(tmp, "clip-ready")) as f:
                    fields = f.read().split()
            except OSError:
                fields = []
        if len(fields) != 2 or fields[1] in answered:
            time.sleep(0.25)
            continue
        log("clip-ready in %s" % tmp)
        scene, nonce = fields
        answered.add(nonce)
        if scene not in expected:
            log("RECORD FAIL: the test asked for an unknown scene %r" % scene)
            put(tmp, "clip-recording", "%s %s" % (scene, nonce))
            put(tmp, "clip-finished", "%s failed %s" % (scene, nonce))
            sys.exit(1)
        try:
            durations[scene] = driver.record(
                scene, lambda name, verdict=None, s=scene, n=nonce: put(
                    tmp, name, " ".join(f for f in (s, verdict, n) if f)))
        except Exception as error:
            log("RECORD FAIL: %s" % error)
            sys.exit(1)
    if args.settings:
        try:
            # Settings reopens where it was left; terminated first, it opens at its root.
            subprocess.run(["xcrun", "simctl", "terminate", args.udid, "com.apple.Preferences"],
                           capture_output=True, timeout=60)
            subprocess.run(["xcrun", "simctl", "launch", args.udid, "com.apple.Preferences"],
                           check=True, capture_output=True, timeout=60)
            time.sleep(3)
            durations["781b-settings-storage"] = driver.record(
                "settings-storage", lambda name, verdict=None: None)
            os.replace(os.path.join(args.out, "settings-storage.mov"),
                       os.path.join(args.out, "781b-settings-storage.mov"))
        except Exception as error:
            log("RECORD FAIL: settings: %s" % error)
            sys.exit(1)
    for scene, duration in durations.items():
        log("CLIP %s %s s" % (scene, duration))
    log("RECORD OK: %d clips in %s" % (len(durations), args.out))


if __name__ == "__main__":
    main()

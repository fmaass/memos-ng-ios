import Foundation
import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// The way OUT of the search sheet (MEMNG-187).
///
/// The sheet could take the timeline to a day and could not show it: the anchored list, and the
/// notice on top of it naming the day, are drawn underneath the sheet that asked for them. Two
/// things are asserted here because both are silent when they are wrong. The first is the label —
/// the row promises an outcome ("Show Jun 12 · 4 memos"), and a promise about a count is a sentence
/// that can be false in three different ways. The second is what the row DOES, which is the half a
/// screenshot cannot show: activating it takes the sheet away, and activating the grid above it
/// does not (MEMNG-178 still stands for the field).
@MainActor
@Suite("Search day commit")
struct SearchDayCommitTests {
    /// One locale, so the assertions are about the words this file chooses and not about how a
    /// device somewhere writes a date.
    private static let english = Locale(identifier: "en_US")

    private static func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        HeatmapDateJump.anchorCalendar.date(
            from: DateComponents(year: year, month: month, day: dayOfMonth)
        )!
    }

    private static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    /// An account with two days on it, answered for on the 26th.
    private static var counts: SearchDayCounts {
        SearchDayCounts(
            byDay: ["2026-06-12": 4, "2026-08-24": 3], today: day(2026, 8, 26), loaded: true
        )
    }

    // MARK: - what the row says

    @Test("the row names the day and how much is on it")
    func theLabelSaysTheOutcome() {
        let june12 = Self.day(2026, 6, 12)
        let many = SearchDayCommit.label(for: june12, count: 4, locale: Self.english)

        #expect(many.hasPrefix("Show "), "the row does not say what it will do: \(many)")
        #expect(many.hasSuffix(" · 4 memos"), "\(many)")
        // The day itself, cut in the calendar the squares are cut in, and with no year on it: the
        // row is a destination a few screens down this list, not an anniversary.
        #expect(many.contains("Jun"), "\(many)")
        #expect(many.contains("12"), "\(many)")
        #expect(!many.contains("2026"), "\(many)")

        #expect(
            SearchDayCommit.label(for: june12, count: 1, locale: Self.english)
                .hasSuffix(" · 1 memo"),
            "one memo was pluralised"
        )
        #expect(
            SearchDayCommit.label(for: june12, count: 0, locale: Self.english)
                .hasSuffix(" · no memos"),
            "a day with nothing on it read as a number"
        )

        // Control: the date is the day's own, so the sentence moves when the day does.
        let next = SearchDayCommit.label(for: Self.day(2026, 6, 13), count: 4, locale: Self.english)
        #expect(next != many)
    }

    /// The third form, and the one that is a lie if it is written as a zero: a day the sheet has
    /// no counts for says the day alone.
    @Test("a day the sheet knows no count for is named without one")
    func anUnknownCountIsNotAZero() {
        let unknown = SearchDayCommit.label(
            for: Self.day(2026, 6, 12), count: nil, locale: Self.english
        )

        #expect(unknown.hasPrefix("Show "))
        #expect(unknown.contains("Jun"), "\(unknown)")
        #expect(!unknown.contains("·"), "an unknown count was written out anyway: \(unknown)")
        #expect(!unknown.contains("memo"), "\(unknown)")
    }

    @Test("the row carries the day it names, and a row with no day carries nothing")
    func theRowCarriesItsDay() {
        let row = SearchDayCommit.row(
            for: Self.day(2026, 6, 12), count: 4, locale: Self.english
        )
        #expect(row.anchor == .day(year: 2026, month: 6, day: 12))
        #expect(row.label.hasSuffix(" · 4 memos"))

        // Nothing chosen: a neutral word, and nothing behind it to commit.
        let idle = SearchDayCommit.row(for: nil, count: nil, locale: Self.english)
        #expect(idle.anchor == nil)
        #expect(!idle.label.isEmpty, "the disabled row says nothing at all")
        #expect(!idle.label.contains("Show"), "a row that does nothing promised to show something")
    }

    // MARK: - what each way of choosing does to the sheet

    @Test("a day chosen in the field leaves the sheet up; the commit row takes it away")
    func onlyTheCommitRowDismisses() {
        let anchor = MemoQueryAnchor.day(year: 2026, month: 6, day: 12)

        #expect(
            !SearchDayChoice.field(anchor).dismisses,
            "a scrub release put the sheet away (MEMNG-178)"
        )
        #expect(SearchDayChoice.shown(anchor).dismisses, "the sheet stayed over the day it opened")
        // Both take the timeline to the same day: the difference is the sheet and nothing else.
        #expect(SearchDayChoice.field(anchor).anchor == anchor)
        #expect(SearchDayChoice.shown(anchor).anchor == anchor)
    }

    /// The commit row commits what the FIELD is on, which is the day a scrub settled at — the
    /// property that makes the row an outcome of the gesture rather than a second choice of day.
    @Test("the row commits the day the scrub settled on, and follows the finger before that")
    func theRowFollowsTheField() {
        let selection = SearchDaySelection(today: Self.day(2026, 8, 26))
        let counts = Self.counts

        selection.scrub(to: Self.day(2026, 6, 12))
        let committed = selection.endScrub()
        let settled = SearchDayCommit.row(
            for: selection.day,
            count: counts.count(on: selection.day),
            locale: Self.english
        )
        #expect(settled.anchor == committed, "the row would open a day the timeline is not on")
        #expect(settled.label.hasSuffix(" · 4 memos"), "\(settled.label)")

        // Mid-scrub, before any release, the row already names the day under the finger — it is
        // the field's own sentence, not the last request's.
        selection.scrub(to: Self.day(2026, 8, 24))
        let moving = SearchDayCommit.row(
            for: selection.day,
            count: counts.count(on: selection.day),
            locale: Self.english
        )
        #expect(moving.anchor == .day(year: 2026, month: 8, day: 24))
        #expect(moving.label.hasSuffix(" · 3 memos"), "\(moving.label)")
    }

    // MARK: - what the sheet knows about a day

    @Test("a day is a count, a zero, or nothing known at all")
    func aDayIsACountAZeroOrNothing() {
        let counts = Self.counts

        #expect(counts.count(on: Self.day(2026, 6, 12)) == 4)
        // A day inside the account's history with nothing written on it is a ZERO — the account
        // lived through it. That is not the same answer as a day the counts do not cover.
        #expect(counts.count(on: Self.day(2026, 7, 1)) == 0)
        #expect(counts.count(on: Self.day(2026, 8, 26)) == 0, "today, nothing written yet")
        #expect(counts.count(on: Self.day(2026, 6, 11)) == nil, "a day before the first memo")
        #expect(counts.count(on: Self.day(2026, 8, 27)) == nil, "tomorrow")
        #expect(counts.firstActivity == Self.day(2026, 6, 12))

        // And before the server has answered, nothing at all is known — including about days the
        // account certainly did write on.
        let unread = SearchDayCounts(byDay: [:], today: Self.day(2026, 8, 26), loaded: false)
        #expect(unread.count(on: Self.day(2026, 8, 20)) == nil)
        #expect(unread.firstActivity == nil)
    }

    /// The clamp MEMNG-187 asks for. The timeline anchors by asking for memos created BEFORE the
    /// chosen day, so a day picked before the first memo lands on a feed with nothing in it — the
    /// one case the "nearest earlier memos" landing cannot answer.
    @Test("the picker is not offered a day before the first memo")
    func theRangeStartsAtTheFirstMemo() {
        let days = Self.counts.offerableDays(earliestDrawn: Self.day(2026, 6, 3))

        #expect(days.lowerBound == Self.day(2026, 6, 12), "a day before the first memo was offered")
        #expect(days.upperBound == Self.day(2026, 8, 26))
        #expect(!days.contains(Self.day(2026, 6, 11)))
        #expect(days.contains(Self.day(2026, 6, 12)))
        #expect(!days.contains(Self.day(2026, 8, 27)), "tomorrow was offered")

        // Until the counts land there is no first day to know, and the oldest day the grid draws
        // stands in — the field is usable while the read is in flight rather than stuck on today.
        let unread = SearchDayCounts(byDay: [:], today: Self.day(2026, 8, 26), loaded: false)
        #expect(
            unread.offerableDays(earliestDrawn: Self.day(2026, 6, 3)).lowerBound
                == Self.day(2026, 6, 3)
        )
        #expect(unread.offerableDays(earliestDrawn: nil).lowerBound == Self.day(2026, 8, 26))
        // A stand-in later than today cannot invert the range.
        #expect(
            unread.offerableDays(earliestDrawn: Self.day(2026, 9, 9)).lowerBound
                == Self.day(2026, 8, 26)
        )
    }

    /// The bounds cross the same zone boundary the field itself does: a picker deals in instants
    /// shown in the DEVICE's calendar, and a bound cut in UTC is a bound on the day before or after
    /// for everybody who is not on Greenwich.
    @Test("the picker's bounds are the days a person sees, wherever the device is")
    func theRangeIsInTheDevicesCalendar() throws {
        let zones = [
            Self.calendar("UTC"), Self.calendar("Europe/Berlin"), Self.calendar("Pacific/Auckland"),
        ]
        for zone in zones {
            let range = Self.counts.pickerRange(earliestDrawn: nil, in: zone)
            let low = zone.dateComponents([.year, .month, .day], from: range.lowerBound)
            let high = zone.dateComponents([.year, .month, .day], from: range.upperBound)

            #expect(
                low.year == 2026 && low.month == 6 && low.day == 12,
                "\(zone.timeZone.identifier) starts the picker at \(low)"
            )
            #expect(
                high.year == 2026 && high.month == 8 && high.day == 26,
                "\(zone.timeZone.identifier) ends the picker at \(high)"
            )
            // The bound is the START of its day there, so the whole of the first and last day is
            // inside the range rather than half of each falling outside it.
            #expect(range.lowerBound == zone.startOfDay(for: range.lowerBound))
            let middle = try #require(SearchDay.pickerDate(for: Self.day(2026, 7, 1), in: zone))
            #expect(range.contains(middle))
        }
    }

    /// The pair the counts cannot tell apart on their own, and the one the sheet gets wrong in
    /// silence: an account the server ANSWERED for with nothing, against an account it has not
    /// answered for yet. Both are an empty dictionary. Read as the second, a household on its
    /// first day gets a row that will not say what today holds and a picker running back over
    /// twelve weeks of days that hold nothing and never did (MEMNG-187, review round 1).
    @Test("an answered emptiness is a zero and one offerable day; an unread one is neither")
    func aLoadedEmptyAccountIsNotAnUnreadOne() {
        let today = Self.day(2026, 8, 26)
        let drawn = Self.day(2026, 6, 3)
        let empty = SearchDayCounts(byDay: [:], today: today, loaded: true)
        let unread = SearchDayCounts(byDay: [:], today: today, loaded: false)

        // The label. An answered account says what today holds, which is nothing; an unanswered
        // one says the day alone rather than inventing that emptiness.
        #expect(empty.count(on: today) == 0)
        #expect(unread.count(on: today) == nil)
        let said = SearchDayCommit.label(
            for: today, count: empty.count(on: today), locale: Self.english
        )
        let silent = SearchDayCommit.label(
            for: today, count: unread.count(on: today), locale: Self.english
        )
        #expect(said.hasSuffix(" · no memos"), "an answered empty day said no count: \(said)")
        #expect(!silent.contains("·"), "an unread day claimed a count: \(silent)")
        // An answered account still covers today ALONE: yesterday is outside what it can say.
        #expect(empty.count(on: Self.day(2026, 8, 25)) == nil)

        // The range. One day to offer, and the grid does not stand in for it — a stand-in is for
        // a read still in flight.
        #expect(empty.offerableDays(earliestDrawn: drawn) == today...today)
        #expect(
            unread.offerableDays(earliestDrawn: drawn).lowerBound == drawn,
            "an unread sheet locked the field to today while the read was in flight"
        )
        let picker = empty.pickerRange(earliestDrawn: drawn, in: Self.calendar("Europe/Berlin"))
        #expect(
            picker.lowerBound == picker.upperBound,
            "the picker offered a day before the account existed"
        )
        // Control: the same call on an account WITH history is a range, so the collapse above is
        // this case and not the method always answering one day.
        let real = Self.counts.pickerRange(earliestDrawn: drawn, in: Self.calendar("Europe/Berlin"))
        #expect(real.lowerBound < real.upperBound)
    }

    // MARK: - the row on a real screen

    private static func scrubber(
        counts: [String: Int],
        loaded: Bool = false,
        chose: @escaping (SearchDayChoice) -> Void
    ) -> some View {
        SearchDateScrubber(
            grid: HeatmapPresentation.grid(from: counts),
            counts: counts,
            countsLoaded: loaded,
            chose: chose
        )
    }

    /// Today, as the server keys it — the day the sheet opens on, so the row under an unscrubbed
    /// grid is about a day the fixture can put a count on.
    private static var todayKey: String { HeatmapDateJump.key(for: .now) }

    @Test("the commit row is on the screen, saying what showing the day will show")
    func theRowIsDrawnWithItsCount() {
        let labels = ScreenProbe.labels(
            of: Self.scrubber(counts: [Self.todayKey: 4], chose: { _ in })
        )

        // Positive control: the probe can see the card at all, so the absence of a row below
        // would mean something.
        #expect(labels.contains("Activity"), "the probe saw nothing of the card: \(labels)")
        #expect(
            labels.contains { $0.hasPrefix("Show ") && $0.hasSuffix(" · 4 memos") },
            "no commit row naming the day's four memos: \(labels)"
        )
    }

    @Test("a sheet whose counts have not landed offers the day without inventing a count")
    func theRowWaitsForItsCount() {
        let labels = ScreenProbe.labels(of: Self.scrubber(counts: [:], chose: { _ in }))

        #expect(
            labels.contains { $0.hasPrefix("Show ") && !$0.contains("·") },
            "the waiting row claimed a count: \(labels)"
        )
    }

    /// The same empty dictionary one state later, threaded all the way to the row: the answer
    /// arrived and it was nothing. The row says so rather than going quiet — the half of the fix
    /// a value test cannot reach, because `countsLoaded` has to survive the trip through the view.
    @Test("a sheet answered with nothing says today holds nothing")
    func theRowNamesAnAnsweredEmptiness() {
        let labels = ScreenProbe.labels(
            of: Self.scrubber(counts: [:], loaded: true, chose: { _ in })
        )

        #expect(labels.contains("Activity"), "the probe saw nothing of the card: \(labels)")
        #expect(
            labels.contains { $0.hasPrefix("Show ") && $0.hasSuffix(" · no memos") },
            "an answered-empty sheet would not say what today holds: \(labels)"
        )
    }

    @Test("activating the commit row shows the day and takes the sheet with it")
    func theCommitRowDismissesTheSheet() throws {
        let chosen = Box<SearchDayChoice?>(nil)
        let activated = TapProbe.activate(
            in: Self.scrubber(counts: [Self.todayKey: 4], chose: { chosen.value = $0 })
        ) { ($0.accessibilityLabel ?? "").hasPrefix("Show ") }

        #expect(activated, "no commit row on the screen to activate")
        let choice = try #require(chosen.value, "the commit row chose nothing")
        #expect(choice.dismisses, "the sheet stayed up over the day it was told to show")

        // And it is the day the field is on, read in the calendar the squares are cut in.
        let parts = HeatmapPresentation.dayCalendar.dateComponents(
            [.year, .month, .day], from: .now
        )
        let year = try #require(parts.year)
        let month = try #require(parts.month)
        let dayOfMonth = try #require(parts.day)
        #expect(choice.anchor == .day(year: year, month: month, day: dayOfMonth))
    }

    /// MEMNG-192: the grid is on the screen, and there is nothing on the screen that puts it
    /// away. It used to fold behind a disclosure, and a card a household folded once was one it
    /// never found again — the date section then opened as a title over a field with nothing under
    /// it to scrub.
    @Test("the activity grid is always drawn, and nothing offers to hide it")
    func theHeatmapCannotBeHidden() {
        let counts = [Self.todayKey: 4]

        // Positive control on the same screen: the grid really is in the tree, so the absence
        // below is an absence rather than a walk that read nothing at all.
        #expect(
            TapProbe.contains(in: Self.scrubber(counts: counts, chose: { _ in })) {
                ($0.accessibilityHint ?? "").contains("Adjust to choose a day")
            },
            "the grid is not on the screen at all"
        )
        #expect(
            !TapProbe.contains(in: Self.scrubber(counts: counts, chose: { _ in })) { element in
                let value = element.accessibilityValue ?? ""
                return (element.accessibilityHint ?? "").localizedCaseInsensitiveContains("hides")
                    || value == "Shown" || value == "Hidden"
            },
            "something still offers to hide the activity heatmap (MEMNG-192)"
        )
    }

    /// The other half, and the one MEMNG-178 fought for: choosing on the grid is moving a FIELD.
    /// A screen reader's activation of the grid is the same call the end of a scrub makes.
    @Test("choosing a day on the grid leaves the sheet up")
    func theGridDoesNotDismissTheSheet() throws {
        let chosen = Box<SearchDayChoice?>(nil)
        let activated = TapProbe.activate(
            in: Self.scrubber(counts: [Self.todayKey: 4], chose: { chosen.value = $0 })
        ) { ($0.accessibilityHint ?? "").contains("Adjust to choose a day") }

        #expect(activated, "no scrubbable grid on the screen to activate")
        let choice = try #require(chosen.value, "the grid chose nothing")
        #expect(!choice.dismisses, "a day chosen on the grid put the sheet away")
    }
}

/// Activating an element the way a screen reader does, which is the only way to ask a SwiftUI row
/// whether it actually DOES anything without a UI test target.
///
/// `accessibilityActivate()` is the call VoiceOver makes on a double tap, and SwiftUI routes it to
/// the same closure a finger runs. Measuring a row proves it is drawn; hosting it and activating it
/// is what proves the closure under it is wired to anything at all.
@MainActor
private enum TapProbe {
    static func activate(
        in view: some View,
        size: CGSize = CGSize(width: 393, height: 852),
        where matches: (NSObject) -> Bool
    ) -> Bool {
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        // Walked as soon as the element exists rather than after a window somebody guessed: every
        // turn of the run loop is one more chance for SwiftUI to publish its accessibility tree,
        // and the walk stops at the first match. The bound is a bound on FAILURE only — an element
        // that is not there is not going to appear — so a loaded build host waits longer instead
        // of reporting something that did not happen.
        var activated = false
        for _ in 0..<40 {
            var elements: [NSObject] = []
            collect(window, into: &elements)
            if let target = elements.first(where: matches) {
                activated = target.accessibilityActivate()
                break
            }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            host.view.layoutIfNeeded()
        }

        window.isHidden = true
        window.rootViewController = nil
        return activated
    }

    /// Whether any element on the screen matches — the same walk as `activate`, without acting.
    /// It waits the same way, so a `false` is "not there after forty turns of the run loop"
    /// rather than "not there yet"; pair it with a match that IS expected on the same screen.
    static func contains(
        in view: some View,
        size: CGSize = CGSize(width: 393, height: 852),
        where matches: (NSObject) -> Bool
    ) -> Bool {
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        var found = false
        for _ in 0..<40 {
            var elements: [NSObject] = []
            collect(window, into: &elements)
            if elements.contains(where: matches) {
                found = true
                break
            }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            host.view.layoutIfNeeded()
        }

        window.isHidden = true
        window.rootViewController = nil
        return found
    }

    private static func collect(_ node: Any, into found: inout [NSObject]) {
        if let element = node as? NSObject {
            found.append(element)
            if let children = element.accessibilityElements {
                for child in children { collect(child, into: &found) }
            }
        }
        if let view = node as? UIView {
            for subview in view.subviews { collect(subview, into: &found) }
        }
    }
}

# All collected by day — text export of the mockup (2026-09-27)

Interactive source: `all-by-day-mockup.html` beside this file (Claude artifact
https://claude.ai/artifact/8TZR6qt29D1wuyT6XzDLo9, versions 1–5 on 2026-09-27). Owner's decision
on 2026-09-27, 20:40 CEST, after two rejected drafts: a separate Day screen between Months and All
("I don't like that there is a dedicated day view where you swap to the next day"), and a Days
level of any kind. The All view stays the one place every picture lives.

## 1 · The complaint

The All view is too dense to read, and once you scroll the date is gone.

## 2 · The design: every day is a group

Inside All, each day is collected into its own group, in taken order, newest first, under the
sticky month heading ("Sep 2026 · 106 items") that exists today.

- **Heading row.** The weekday in bold, then the date ("Sat 27 Sep"), the count right-aligned.
- **Tags line.** Under the heading when the day's memos carry tags: the tags of that day's memos,
  at most three and "+N". They are what tells two hiking Saturdays apart. The Timeline stays the
  only place a day has words beyond that.
- **Mosaic block.** The day's pictures as one block, inset 12 pt from the edges with 12 pt rounded
  corners, 2 pt gaps, in a 3-column grid that cycles the SAME four frame patterns Months uses
  (decision 9): A hero left (2×2) with two squares stacked right, B a row of three squares, C hero
  right (2×2) with two squares stacked left, D a full-width 16:9 frame. The cycle runs A B C B D and
  a day starts it one step later than the day before it, so two neighbouring days never open the
  same way (owner, 21:20 CEST: "only one hero frame? we should mix it up a bit"). A day with one or
  two pictures gets full-width 16:9 frames only; a remainder that does not fill a pattern is squares,
  a single leftover a wide frame. A video tile carries its "▶ 0:14" mark bottom-right as today.
- **Air between days.** 22 pt between one day's block and the next heading.
- **Not chosen:** the even 3-column grid inside a day (kept on the mock's switch for comparison).

## 3 · The date while scrolling

A glass pill, top centre under the header and clear of the options and Select buttons, names the
day whose group is at the top of the screen ("Sat · 27 Sep 2026") and updates as groups pass. It
appears on scroll and fades one second after the scrolling stops. Tapping it opens Months at that
month; that is the way up. The other three placements on the mock's switch (above the dock, top
left, the header's second line as a live date) were compared and not chosen.

## 4 · What is unchanged

- Years and Months exactly as decided (page 3929 decisions 9 and 11; `photos-library-mockup.md`).
- A day tile in Months opens All with that day's group under the month heading (the MEMNG-587 jump,
  now landing on the day's heading rather than the day's first tile). "and N more days" opens All at
  the month's first shown day.
- Three tabs, the dock state rule, the header chrome and the options menu (decisions 5, 8, 10, 11, 12).
- A tap on a picture opens the viewer.

## 5 · On the record

- memos-ng plan page 3929: decision 13 appended 2026-09-27 (All collected by day).
- Conformance handover page 4121: addendum with one more member, Conformance 5.
- MEMNG-587: its jump target moves to the day heading once Conformance 5 lands.
- Web client: the same two additions to the All page (`/resources`), so both clients keep one design;
  filed separately.

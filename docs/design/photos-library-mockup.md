memos-ng · WP-9 · plan page 3929 · Epic MEMNG-505

# The picture library, rebuilt after the iOS Photos app

A walkthrough of what the approved plan will build on `/resources`, so the understanding can be checked before any code exists. The phone on the left is a working mock: switch the tabs and the pill, open the filter menu, press Select, scroll the grid. Revised 2026-09-23 twice: the Months day mosaic (from your screenshots) and the app tab pill. Revised 2026-10-23 for the iOS app: Months shows nine days per month with two heroes (your answer B).

Owner decision 2026-09-22 · Codex plan gate APPROVE, round 3 · Milestone 328, target 2026-10-31 · Tickets MEMNG-501…511

(Mock legend: tile colours stand in for thumbnails; the month counts are examples, not the live figures. Tiles: owned by you / someone else's public picture / ▶ video.)

## 1 · The floating dock — One row, always: the tab pill, or the Library icon plus Years | Months | All

Rebuilt on 2026-09-23 after your note that the two-row dock, with the Years | Months | All pill appearing and vanishing, was confusing. The dock now works exactly like the iOS 26 Photos app: a single liquid-glass row. At rest it is the app tab pill, Library | Timeline | Places, and nothing else. Timeline in the middle is the default destination when the app opens. Sort and filter are not in the dock; they live in the header (section 2).

- Once you scroll inside the Library the tab pill collapses to the Library icon on the left and Years | Months | All takes its place, with All as the default. That is the state in your latest screenshot. It stays that way while you read; it only expands back to the three tabs when you return to the top or tap the Library icon. Tapping the Library tab while it is active toggles between the two states, so Years and Months are reachable even when the library is too short to scroll.
- Tab pill replaces the drawer for the three main destinations: the Library, the memo feed (today's home route) and the Places map. Explore, Archived and Settings stay in the header menu. On Timeline and Places the dock never shows the Years | Months | All segment. The native iOS app already has exactly these three tabs (Timeline, Library, Places), so the web dock brings the two clients into line.
- Timeline in the mock is now the real feed: day headers, one card per memo with author, time, visibility, text, the picture grid (a row of three, then pairs, as the justified layout packs them) and tag chips. Its header is the one you prefer from the iOS app: settings top-left, new-memo top-right, always visible while scrolling; the inline "Any thoughts…" field at the top of the web feed goes, the new-memo button opens the editor instead.
- Years | Months | All pill switches between the three Library views. The chosen view is also in the URL.

Try it on the mock: wheel or drag inside the phone and watch the tab pill collapse to the Library icon with Years | Months | All beside it; scroll back to the top, or tap the icon, and the three tabs return. Tap Timeline or Places to see the dock on the other routes. Tap the round options button top right for the sort and filter menu.

## 2 · The header — Options and Select, in liquid glass, top right

Your correction of 2026-09-23 from the second set of screenshots. The Library header has a large bold title with a small line under it, and two glass buttons on the right: a round options button and, to its right, the "Select" capsule. Both are translucent and blurred with a hairline edge and a top highlight, like every control on this screen.

- Options button opens a glass dropdown under the buttons with three groups: sort ("Sort by Newest First" checked by default, "Sort by Oldest First"), kind ("All Items" checked by default, "Photos", "Videos") and tags ("All tags" checked by default, then every tag with its picture count). Each row carries a checkmark on the active choice; sort, kind and tag land in the URL. The Photos app's extra filters (Favorites, Edited, Screenshots, Shared) and view options are not part of this round.
- Select enters select mode (section 7). The capsule is replaced by round glass buttons while selecting.
- Scrolled, on All (your answer A of 2026-10-23, MEMNG-676): once the All grid leaves its top, the large "Library" shrinks to a small "Library" centred in the bar, as in Photos, and the "All Items · Newest First" line goes with it. The two glass buttons stay where they are, and the bar keeps its height, so the pictures under it do not jump as it collapses. Back at the top, the large title and its line return. Years and Months keep the large title while they scroll. The date pill stays top centre under the header, and steps aside while a day heading passes under it, so the title, the line, the day heading and the pill are never drawn on top of each other.
- On Timeline the header is settings top-left and new-memo top-right, fixed while scrolling, as in the iOS app. Places keeps its own header.

## 3 · Finding a picture — By tag, from the options menu. No text search.

Settled on 2026-09-23: a text search finds almost nothing, so it goes. What people have in hand when they look for a picture is a tag, a month or a place.

- Tags in the options menu. The third group of the menu lists every tag with its picture count; picking one filters the whole Library, All, Months and Years alike, and the header subtitle shows the tag. The counts in Months and Years follow the tag, so they never disagree with the grid.
- Gone: the search button (header and dock), the Photos-style search screen, the text field. The existing memo text search route stays where it is, reachable from the menu, untouched.
- Later, if wanted: people or objects inside pictures. Nothing in this round prevents it.

## 4 · The All view — Every picture, newest first, under a header per month

Pages through the whole library as you scroll and orders it by the date the picture was taken. A sticky header names each month, with its count, and the grid keeps the current justified row layout.

- Same tile everywhere. Videos open in the lightbox on a single tap, like photos.
- A failed request shows an error with a retry button, never an empty "no pictures" state.

## 5 · Which date counts — The EXIF capture date, else the memo's date

Owner decision 2026-09-22. Every picture gets one `takenAt` value, and both the ordering and the month and year grouping use it: (1) capture_instant — the EXIF capture time, when the photo carries one; (2) memo.created_at — the date of the memo the picture belongs to; (3) attachment.created_at — only for an orphan that belongs to no memo; (✕) captured_at — never used.

| Live figure (2026-09-22) | Value | Consequence |
| --- | --- | --- |
| Attachments in the library | 1 795 | All become reachable (today: 200). |
| Without any capture date | 624 | All from the June 2026 migration; with the memo date they spread over their real months, back to May 2026. |
| Videos | 169 | The Videos filter and the count badges use the same date. |
| Years with dated pictures | 1 | The Years view shows one card today. Backdated memos can add earlier years. |

## 6 · Months and Years — Months: the nine busiest days of each month, two of them as heroes

Corrected on 2026-09-23 after your reference screenshots. Months is not a list of month cards. Each month gets a bold title ("Sep 2026"), then one tile per shown day, edge to edge with hairline gaps. Not every day: the nine days with the most pictures and a small "and N more days" line under the month when it had more. The day number sits top-left on its tile, bold white, no chip and no count badge. Years keeps one wide card per year.

Amended 2026-10-23 (your answer B on the decision canvas, board 2): nine days per month instead of six, and two large tiles. The busiest day is the large tile at the top, the second-busiest the large tile further down, and the seven other days are small, in date order between them; "and N more days" follows. In the 3-column grid that is: hero left with two stacked right, a row of three, hero right with two stacked left. Every other month is the mirror image (hero right at the top, hero left further down), so neighbouring months do not look alike. A month with fewer than nine days keeps the same order and stops at its last day: one day is a single hero, two are a hero and one small tile, five are a hero, two small beside it and two in the row below. Only a month showing more than nine days would reach the full-width frame.

- Tap a day tile and the All view opens scrolled to that day. The page loads as many pages as needed to get there.
- Tap "and N more days" and the All view opens at that month's first shown day, where every day is there.
- Tap a year card and Months opens filtered to that year.
- The key photo of a day is the newest picture of that day. No multi-photo collage inside one day tile.
- Day and month boundaries are computed in Europe/Zurich on the server and in the browser.
- Which days are shown is by picture count, ties to the later day. Which of them get a hero is by the same count since 2026-10-23: the two busiest days, ties to the later day. Where the heroes sit is the fixed pattern above.

## 7 · Select — Select mode: glass buttons above, a toolbar below

Tapping "Select" swaps the header buttons for round glass buttons: one that selects all of your pictures in view (tap again to clear) and a close button that ends select mode. The dock is replaced by a flat toolbar, as in the Photos app: a round glass share button on the left, "N Items Selected" in the centre and a round glass delete button on the right.

- Tiles: a tap toggles a small blue checkmark in the tile's bottom-right corner instead of opening the picture. Unselected pictures keep their brightness, as in the Photos app. Only your own pictures can be selected; other members' pictures are dimmed and inert.
- Share opens the phone's share sheet with the selected original files. Files are fetched one by one before the sheet opens; a spinner on the button covers the wait.
- Delete asks for confirmation first, then deletes sequentially through the existing single-picture endpoint. On the first failure the run stops and a toast reports how many succeeded and how many failed. Counts in Months and Years refresh afterwards.
- Not this round: download, add-to-memo, print, and the Photos app's "more" menu in select mode.

## 8 · Points worth a second look (the numbered cheap-to-change choices)

01 Years ships now, even with a single card. 02 No search button and no text search; pictures are found by tag. 03 The dock appears on desktop too. 09 The app tab pill (Library | Timeline | Places) in the dock; inside the Library, scrolling collapses it to the Library icon plus Years | Months | All (folded into the plan as decision 11). 04 Select does share and delete; other people's pictures cannot be selected at all. 05 Sort and filter live in the header options menu; the inline All / Images / Videos switch disappears. 06 Jumping to an old month loads pages until it arrives; a smarter cursor becomes a follow-up if the jump exceeds 3 s on the iPhone. 07 No virtualization. 08 Out of scope this round: favourites, "edited" and screenshot filters, multi-photo collages inside a day tile, content-driven hero selection, add-to-memo from Select, a bulk-delete endpoint, database migrations.

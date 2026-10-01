# TestFlight notes

`fastlane beta` sends the section headed with the archived version and build as the build's
"What to Test" text, and refuses to upload when that section is missing or empty. Testers read
these words: first person singular, no ticket keys, no internal host names. TestFlight shows them
as plain text, so each point stays on one line.

## 2.2.1 (30)

- Nothing on screen changes.
- Live updates keep the reconnect delay the server last asked for until it sends a new one, instead of falling back to about a second.
- If the server says "slow down" with a very long wait, the app waits at most its longest reconnect delay.
- Use the app over a longer stretch, ideally while the server restarts or is busy; it should keep working and catch up on new items. Nothing to click.
- Upload a few photos and a video; they should finish and appear in the Library as in 2.2.0 (29).

## 2.2.0 (29)

- The tab bar reads Library, Timeline, Places, and the app opens on Timeline. Scroll the Library and the bar turns into the Library icon plus Years, Months and All; back at the top, or with a tap on the Library icon, the tabs return.
- The Library has a new header with an options menu for the sort, the kind (All Items, Photos, Videos) and the tags, and a Select button. The picker in the navigation bar and the bar above the grid are gone.
- Months shows up to six days per month, the ones with the most pictures, as a mosaic, with an "and N more days" line under a month that has more. Tap a day and the Library jumps to that day in All; the line opens All at that month. Tapping something else before it gets there drops the jump.
- All now groups pictures by day: a heading with the weekday, the date and the day's count, then that day's pictures in a mosaic that opens differently from the day before. While you scroll, a pill at the top names the day on screen; tap it to open Months at that month. It fades a second after you stop.
- Days and months in the Library now follow Zurich time, whatever time zone the phone is set to, so a Months tile, its count and its day in All agree on where a day ends.
- Select pictures in All: tap Select, then tap pictures to choose them. Only your own pictures can be chosen; other people's are dimmed. Select All chooses all of your own pictures in view. Share downloads the originals and offers them all in one share sheet.
- Delete asks "Delete N Items?" first. The pictures are deleted from the server and from any memo they belong to, and this can't be undone. Closing select mode does not stop a delete already under way. If some fail, a message says how many were deleted and how many failed.
- Photo and video uploads now go at most two at a time, and the app waits when the server asks it to slow down. An interrupted upload continues from where it stopped when the server still has the part already sent; otherwise it starts again. The app checks this while it is open.
- In the Library, the Timeline and a memo, a picture whose link has expired now asks for a fresh link and loads, instead of showing as failed. If new pictures arrive in the Library at the same moment, one can still show as failed until the Library next refreshes.
- This version still needs memos-ng 2.0.0. Sign-in tells you when the server is older than the app.

## 2.1.2 (28)

- The same app as 2.1.1 (27), rebuilt from an unchanged tree. This build checks that the build and TestFlight lane still work end to end after the build machine moved its build trees to a new drive.
- Nothing in the app changed. The All-by-day layout and selecting pictures to share or delete are still to come.
- This version still needs memos-ng 2.0.0. Sign-in tells you when the server is older than the app.

## 2.1.1 (27)

- Tap a day in Months and the Library jumps to that day in All, scrolled into view. If you tap something else before it gets there, the jump is dropped.
- The tab bar is now Library, Timeline, Places, and the app opens on Timeline.
- Inside the Library the tab bar collapses to the Library icon plus Years, Months and All. The picker is gone from the navigation bar.
- The Images and Videos filter moved into the options menu as its own group. There is no bar above the grid any more.
- Months shows at most six days per month, the busiest ones, laid out as a hero mosaic, with a row that says how many more days there are.
- An intermediate build: the All-by-day layout and selecting pictures to share or delete are still to come.
- This version still needs memos-ng 2.0.0. Sign-in tells you when the server is older than the app.

## 2.1.0 (26)

- The Library now sorts pictures by the day they were taken, newest first, with a header for each month. Months follow your phone's time zone.
- A new Years | Months | All control sits at the top of the Library. Years shows one card per year with a cover picture and a count. Tap a year to see its months. Months shows each month with a tile per day: its cover, the day number and how many pictures were taken that day. All is the grid you know. The Images, Videos and tag filters still apply everywhere.
- Tapping a day does nothing yet. Jumping from a day into the grid comes in a later build, and so does selecting pictures to share or delete.
- This version still needs memos-ng 2.0.0. Sign-in tells you when the server is older than the app.

## 2.0.0 (25)

- This version needs memos-ng 2.0.0. At sign-in, the app now reads the server's version and tells you when the server is older than the app.
- Find pictures by tag from the Library's options menu. The Timeline's text search and its heatmap are gone: almost all the memos are pictures with little text, so tags are the way to find them.
- Background uploads: an upload that was waiting for a network connection is no longer sent twice once it is underway. A finished upload no longer shows as still in progress. Cancelling a withdrawn upload works even when its record cannot be saved.

## 1.5.5 (24)

- Photos and videos now upload in the background as one whole file each, and a failed upload is sent again whole. Uploads already underway when the app updates finish the way they started.
- New uploads start while the app is open; in the background it finishes what is already underway.
- An edit made while signed in to one account is no longer sent to another account's server.
- A picture that another device replaced is no longer mistaken for the original when a save is sent again.
- An upload that was moving on to its next part is no longer cancelled or sent twice.

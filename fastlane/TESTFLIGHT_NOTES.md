# TestFlight notes

`fastlane beta` sends the section headed with the archived version and build as the build's
"What to Test" text, and refuses to upload when that section is missing or empty. Testers read
these words: first person singular, no ticket keys, no internal host names. TestFlight shows them
as plain text, so each point stays on one line.

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

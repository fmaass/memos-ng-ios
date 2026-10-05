# TestFlight notes

`fastlane beta` sends the section headed with the archived version and build as the build's
"What to Test" text, and refuses to upload when that section is missing or empty. Testers read
these words: first person singular, no ticket keys, no internal host names. TestFlight shows them
as plain text, so each point stays on one line.

## 2.2.1 (40)

- The tab bar is now the app's own and the only one: the glass bar at the left edge that Leading drew. The System bar and the Settings → Appearance → Tab bar switch are gone.
- On the Timeline, scrolling down narrows the bar in place to the Timeline icon, its left edge not moving. Scrolling back up or tapping the icon widens it again. It now narrows and widens smoothly instead of jumping, and one scroll down no longer shrinks, grows and shrinks it again.
- In the Library, scrolling down turns the bar into the Library icon with Years | Months | All beside it, and scrolling back to the top or tapping the Library icon turns it back.
- Please try the Timeline: scroll down and up, and tap the narrowed icon. Then the Library: scroll down and back. Then switch between the three tabs a few times.
- Nothing else changed in this build.

## 2.2.1 (39)

- With the System tab bar, the Library's Years | Months | All row is now drawn with the app's own glass instead of the system's bottom toolbar, so it should appear and go smoothly.
- The tab bar itself is unchanged: the same System bar, centred, shrinking on the Timeline as before.
- The Leading switch is still in Settings → Appearance → Tab bar, and Leading is unchanged.
- Please scroll the Library down and back up a few times with System selected, and judge how the row comes and goes.

## 2.2.1 (38)

- New: a second kind of tab bar to try. Settings → Appearance → Tab bar: System or Leading. System is the bar you have now and stays the default, so nothing changes until you switch.
- Leading draws the bar at the left edge, where the shrunken system bar's icon sits. On the Timeline, scroll down: the bar should shrink to the Timeline icon in place, its left edge not moving. Scroll up or tap the icon and it grows back from the same edge. Please watch whether it really looks like the bar is not moving.
- In the Library with Leading, scrolling down turns the bar into the Library icon with Years | Months | All beside it, and scrolling back to the top turns it back. Please watch whether the glass flows from one into the other rather than jumping.
- Places has no list to scroll, so its bar does not shrink there; tapping between tabs works as before.
- Nothing else changed in this build.

## 2.2.1 (37)

- After Close in the Library's Select mode, the tab bar no longer comes back on top of the Years | Months | All bar when you had come to the Library from the Timeline. One bar at the bottom, the one the screen is in.
- I reproduced this one in a test before changing anything, with the app started on the Timeline as yours is: before the change the two bars stood together for the whole two seconds the test watched; after it, one bar. The one thing the test cannot do is shrink the tab bar the way a real finger does on the Timeline, so please try that path too: scroll the Timeline until the bar shrinks, open the Library, Select, Close.
- Everything from build 36 is in here too: in Select every picture can be picked, Share works on any of them, Delete removes only your own and says how many it skips. Please tap a picture in Select if you have not yet.
- Nothing else changed in this build.

## 2.2.1 (36)

- In Select, every picture in the Library can now be picked, including the ones another member added. Before, those tiles were dimmed and a tap on them did nothing.
- Share works on any picture you pick, whoever added it.
- Delete removes only your own pictures. When the selection also holds someone else's, the question says how many it deletes and how many it skips because they belong to another member. With none of your own picked, Delete stays off.
- Select All now picks every picture in view, yours and another member's. Delete then removes only yours and says how many it skips, as for pictures picked one by one.
- Nothing else changed in this build.
- Build 34 said Select worked again before I had checked it on a phone, and it did not. Please tap a picture in Select and tell me whether the checkmark appears on it.

## 2.2.1 (35)

- Sign-in no longer ends in silence when the server refuses the previous credential in the same moment: you now see a sentence that says what happened.
- The token-management sign-on no longer loses the browser's answer when it arrives exactly as its twelve-minute deadline runs out.
- An account whose display name is empty is now named by its e-mail address instead of a blank, both on the Settings account row and on the token-management screen.
- Under the hood, a session is ended in order at every sign-out and account switch, and several tests that failed now and then are steady.
- Nothing changed on the Library or Select screens in this build. Your report on build 34 — tapping a picture in Select does nothing, and both bars after Close — is still open; I am working on reproducing it on a device before I call it fixed.
- This version still needs memos-ng 2.0.0. Sign-in tells you when the server is older than the app.

## 2.2.1 (34)

- Select in the Library works again: tap Select, then tap pictures and videos to pick them. Before, the tiles did not react.
- Close Select and exactly one bar comes back at the bottom — the tab bar or the Library toolbar, whichever was there before. Build 33 sometimes showed both at once.
- Scroll back up to the top of the Library and the tab bar with Library, Timeline and Places returns on its own. The Library icon in the toolbar still does it too.
- The Years, Months and All capsule in the Library toolbar is narrower and sits close to the Library icon.
- Places: the map pins have a white border and a pointer whose tip marks the exact spot.
- Switch accounts and the Library now shows the new account's pictures straight away instead of the previous account's rows.
- Month and year covers no longer flip to a picture from a previous account after a switch.
- This version still needs memos-ng 2.0.0. Sign-in tells you when the server is older than the app.
- I could not check this on a phone: tell me whether the tab bar comes back at the right moment when you reach the top, and whether the swap on the way down still feels right.

## 2.2.1 (33)

- Scroll a few millimetres down in the Library and the tab bar steps aside for the Library icon plus Years, Months and All, the same toolbar as in build 32. Before, only a tap did this.
- Tap the Library tab from Timeline or Places and the Library now opens with the tab bar. Tap it again while you are in the Library and the toolbar comes at once, also on a page too short to scroll.
- Only the Library icon brings the tab bar back. Scrolling back to the top keeps the toolbar.
- For half a second after the bars swap, the Library ignores the list shifting by itself as the screen settles, so tapping the Library icon at the bottom of All should not bring the toolbar straight back. Your own scrolling, and the Library jumping to a month or a day, still count in that half second.
- Scrolling while Select is open does not change which bar comes back when you close Select. Timeline and Places are unchanged.
- This version still needs memos-ng 2.0.0. Sign-in tells you when the server is older than the app.
- I could not check this on a phone: tell me how the swap animates, and whether it starts at the right point of your scroll or too early or too late.

## 2.2.1 (32)

- The bar the app drew itself in the Library is gone: the Library icon plus Years, Months and All that took the tab bar's place once you scrolled, or on a second tap on the Library tab.
- Tap the Library tab, coming from Timeline or Places or again while you are already in the Library: the tab bar steps aside for a toolbar that iOS draws, with the Library icon at the left and Years, Months and All beside it as the standard iOS segmented control.
- Tap the Library icon in that toolbar and the tab bar with Library, Timeline and Places comes back. You stay in the Library.
- Scrolling in the Library no longer changes the bar, whichever of the two is showing. Timeline and Places are unchanged from build 31.
- When the app opens on the Library, the tab bar shows first; Years, Months and All appear after a tap on the Library tab.
- In Select mode only the Select toolbar shows at the bottom. Closing Select brings back whichever bar was there before.
- I could not check this on a phone: switch between the tab bar and the Library toolbar a few times and tell me how the change animates.
- I could not check this on a phone either: the toolbar with the Library icon and Years, Months and All is wider than the tab bar, so the change does not happen in place. Tell me whether that looks right.
- One more I could not check on a phone: open Select in All and look whether the Select toolbar shows as a dark band with a hard upper edge.
- This version still needs memos-ng 2.0.0. Sign-in tells you when the server is older than the app.

## 2.2.1 (31)

- The bar with Library, Timeline and Places is now the standard iOS tab bar instead of one the app drew itself, so iOS draws its glass and the selection glides from tab to tab, as in other apps on the phone. Switch between the three tabs and watch the selection move.
- Timeline and Places now open with a large title; the Library keeps its own large header. In the Timeline the title folds into the top bar as you scroll.
- Scroll down in the Timeline: the tab bar shrinks out of the way.
- Scroll down in the Library and the bar turns into the Library icon plus Years, Months and All. It now stays that way when you switch between Years, Months and All, and when you scroll back to the top; only a tap on the Library icon brings back Library, Timeline and Places.
- Tap the Library tab while you are already in the Library: the bar turns into Years, Months and All at once, without scrolling.
- Open Places: the tab bar stays at the bottom while the map loads. Before, it sat in the middle of the screen for a moment.
- Years, Months and All are still drawn by the app, not by iOS. Their bar now has glass that reacts when you press it, but the highlight jumps to your choice instead of gliding like the tabs.
- This version still needs memos-ng 2.0.0. Sign-in tells you when the server is older than the app.

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

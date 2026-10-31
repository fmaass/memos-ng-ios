# TestFlight notes

`fastlane beta` sends the section headed with the archived version and build as the build's
"What to Test" text, and refuses to upload when that section is missing or empty. Testers read
these words: first person singular, no ticket keys, no internal host names. TestFlight shows them
as plain text, so each point stays on one line.

## 2.4.0 (76)

- I can invite guests to a trip with a scannable QR pass, see who joined on which device, and revoke a device or end the pass.
- A guest who scans a trip pass can upload pictures to that one trip in guest mode, without touching my own sign-in.
- An upload in flight shows as a Live Activity on the lock screen and in the Dynamic Island.
- A local notification tells me when a memo is live or when a file needs a fix, and tapping it opens that memo or the Transfers sheet.
- An interrupted upload resumes from where the server left off instead of sending the whole file again.
- Picked photos are staged into the queue in the background, so a large pick survives the app leaving the screen.
- Uploads started from the share sheet run in their own background session and finish even after the share sheet closes.
- I can change a memo's visibility while it is still uploading, from the memo or from the Transfers sheet.

## 2.4.0 (75)

- The Library, Years, Months and Tags now start on everyone's Public pictures, not only mine; a month's, a year's and a tag's Journal shows Public memos only.
- Post works while picked photos are still loading: the memo shows on the timeline right away with a ring until its files are in.
- A Transfers strip above the timeline shows uploads in flight; tapping it opens a sheet with each file's state and, for a held file, the reason.
- Failed uploads retry by cause: a short glitch retries soon, no connection waits for the network, and a file that needs me says why it is held.
- The Info sheet in the viewer shows the memo's visibility as a chip I can tap to change it.
- When a queued visibility change has turned into making a memo more public, the app asks again instead of refusing.

## 2.4.0 (74)

- The Library, Years, Months and Tags now start on everyone's Public pictures, not only mine; a month's, a year's and a tag's Journal shows Public memos only.
- Post works while picked photos are still loading: the memo shows on the timeline right away with a ring until its files are in.
- A Transfers strip above the timeline shows uploads in flight; tapping it opens a sheet with each file's state and, for a held file, the reason.
- Failed uploads retry by cause: a short glitch retries soon, no connection waits for the network, and a file that needs me says why it is held.
- The Info sheet in the viewer shows the memo's visibility as a chip I can tap to change it.
- When a queued visibility change has turned into making a memo more public, the app asks again instead of refusing.

## 2.4.0 (73)

- The edit sheet now has the visibility menu. Making a memo more private saves straight away; making it more public asks once first, and Cancel changes nothing. Long-pressing a memo follows the same rule.
- A test switch for uploads started from the share sheet: Settings, memos, Upload spike (debug). It is off by default and changes nothing while off. With it on, Manage tokens can mint a one-day test token and share the spike log.

## 2.4.0 (72)

- Pictures I keep to the household now show up only inside their trip or album. The Library, Years, Months and Tags start on Public, and Any in the Visibility menu shows everything again.
- When I scroll the library's All view, the big "Library" title shrinks to a small centred one and the line under it goes, so nothing piles up at the top of the screen.
- Scrubbing the filmstrip no longer jumps to another photo when a picture is deleted while I'm dragging.
- Open in Places now always switches to the map, even when I ask for the same photo twice, and it tells me why when the map is empty or failed to load.

## 2.4.0 (71)

- A picture I put back into an album stays on the album's screen even when the refresh after it fails.
- The album picker now lists albums made on another phone.
- On an album, renaming and deleting say Rename Album and Delete Album.
- Add to Album shows up in a memo's viewer even when that memo has scrolled out of the loaded timeline.

## 2.4.0 (70)

- In a memo's viewer, from the Timeline or a memo's own screen, I can add the picture on screen to an album.

## 2.4.0 (69)

- In Select, Add to Album replaces Show Selected: I pick an album or start a new one, and the chosen pictures go into it.
- The viewer's ⋯ menu has Add to Album for the picture on screen.

## 2.4.0 (68)

- Tapping a day far down All by day now opens it at once with a single request, instead of reading the whole library from the top.
- The pictures above that day load as I scroll up, and the grid keeps my place while they fill in.

## 2.4.0 (67)

- Each month in the Library shows more day tiles by default, with two large hero tiles.
- Year, Month and the Library show only my own pictures; family pictures appear inside trips.
- Collections now lists Trips, Albums, Tags, Months and Years, and I can create an album from the New Album card or the +.
- An album opens with its grid and map, and in Select I can remove pictures from it.
- Adding pictures to an album comes in the next build.

## 2.4.0 (66)

- A long trip that shows only part of its photos now says which part: the first photos for an oldest-first trip, the newest for a newest-first one.

## 2.4.0 (65)

- In the Library's Select mode, the menu now has Add, which opens an Add to collection sheet listing my trips; picking one adds the chosen pictures to it.
- A trip whose photos fail to load no longer reloads them over and over; pulling to refresh still tries again.
- A cover I choose for a tag, a month or a year no longer flips back when a refresh lands while it is still being saved.
- A memo started on a trip's last day no longer gets the trip's tag if I post it after the trip has ended.
- Please select a few pictures in the Library, tap Add, add them to a trip and check they show up on the trip.

## 2.4.0 (64)

- Tapping the date at the top of the picture viewer now opens an Info sheet: when the picture was taken, its memo, where it was taken, the file and the camera.
- The Where card shows a small map with a pin and the place name, and Open in Places jumps to that spot on the Places map.
- The File card shows the type, size, dimensions, file name and who added it; the Camera card appears only when the photo carries camera data.
- The date at the top of the viewer no longer gets cut off.
- Please open a few pictures, tap the date, check the rows make sense, try Open in Places, and swipe to another picture and open Info again.

## 2.4.0 (63)

- Use as Cover is now in the long-press menu of a picture inside a trip, tag, month or year, so a cover can be set straight from the grid.
- The Library tab's long-press menu stays as it was, because the Library has no cover.
- Please long-press a picture in a trip and in a tag, choose Use as Cover, and check the cover and the collection's card both change.

## 2.4.0 (62)

- The picture viewer now has a row of thumbnails above its bottom bar: tap one to jump to it, or drag across the row to scroll through the pictures.
- The thumbnail row hides and comes back with the other controls on a single tap.
- A picture deleted in the Library or Timeline while the viewer is open from a trip's map now disappears from that viewer instead of staying on screen.
- Please open a collection, scrub through it with the thumbnail row, zoom into a picture, jump with the strip and come back, and check swiping still works.

## 2.4.0 (61)

- Share now sends a phone-sized copy of each picture instead of the full original, so large camera files no longer fail to arrive in WhatsApp.
- The share sheet now closes by itself once a share has gone through.
- Sharing several pictures at once gives every file its own name, so none of them is lost when two have the same name.
- Save Original is now in the menu for pictures too, for when I want the full file.
- Please share a few pictures, including a big one, to WhatsApp and to Telegram, and check they arrive and the sheet closes.

## 2.4.0 (60)

- Use as Cover now works on tag, month and year collections as well as trips, from the viewer's menu or with one picture selected.
- A chosen cover is saved on the server, so it stays after a refresh or a reinstall and everyone in the household sees it.
- If a cover cannot be saved, the collection's screen now says why and the previous cover comes back.
- Please choose a cover for a tag, a month and a year, then pull to refresh and check each one stays.

## 2.4.0 (59)

- Deleting a picture inside a trip now moves the viewer on to the next picture instead of closing it.
- On a trip's map, a deleted picture leaves the cluster's photo list, and the list stays open while pictures remain.
- Please delete a test picture from a trip's viewer and check that the next picture shows; then delete one from the trip map's photo list.

## 2.4.0 (58)

- Every collection now has the Library's filter button: a tag, a month or a year can show only videos, only photos, or only my own pictures.
- Sort and view options are shared with the Library, so tag, month and year collections now open newest first and grouped by day, like the Library.
- Changing the sort inside a collection changes it for the Library too.
- Trips keep their own filter menu and still show no day headings.
- Please open a tag and a month, pick Videos, and check that only that collection's videos remain; then clear the filter.

## 2.4.0 (57)

- The heart now works on every picture, not only on my own: anyone in the family can mark a picture as a favorite or take the heart away again.
- The Favorites card shows every favorite, whoever set it.
- Please heart a picture someone else posted, check that it appears on the Favorites card, then take the heart away again.

## 2.4.0 (56)

- The bin is now in every picture viewer: the Timeline, the Library, a trip, a collection and the map, on each picture of mine.
- Tapping it asks first, as before; the picture then leaves the grid behind the viewer.
- Pictures that are not mine show no bin.
- Please delete one test picture from the Library viewer and one from a trip, and check that a picture someone else posted has no bin.

## 2.4.0 (55)

- The heart in the picture viewer now works: a tap marks one of my pictures as a favorite, and another tap takes it back.
- On a picture that is not mine, the heart says why it cannot be changed.
- Collections has a Favorites card: a heart, the number of favorites, and one of them as its cover.
- Please favorite a few pictures from the Library and a memo, open the Favorites card, then unfavorite its cover picture and check the card changes.

## 2.4.0 (54)

- An opened picture has a glass bar at the bottom: Share, an Info button and the bin for a picture I may delete.
- The top of the viewer shows when the picture was taken: Today, Yesterday, the weekday, or the date, with the time beneath.
- A single tap hides the viewer's controls and another tap brings them back; a double tap still zooms.
- Info opens a sheet with when the picture was taken, the memo it belongs to and the file's type, size and dimensions.
- Show Memo, Save Original and Use as Cover now sit in the ⋯ menu at the top right.
- The heart is shown but does nothing yet.
- Please open a picture from the Library, a memo and the map, tap once to hide and show the controls, open Info, and share one picture from the bar.

## 2.4.0 (53)

- A trip now has its own controls in the top bar: Filter, a menu with Rename, Trip Dates and Delete Trip, and Select.
- A trip's Filter offers All Items, Photos or Videos, Sort By and Removed from trip.
- The Library's and a trip's filters now also offer Captured by me and Visibility, which narrows the pictures to those of one visibility.
- In a trip's select mode, More offers Remove from trip, which asks first and keeps the pictures in the library.
- In the Library's select mode, the chosen pictures can be added to a trip in one step.
- Please open a trip, try each Filter choice, select two pictures and open More, then select pictures in the Library and add them to a trip.

## 2.4.0 (52)

- When a trip, tag, month or year is open, the bottom capsule now behaves as it does in the Library: it opens with the four tabs, and the Photos, Journal and Map tabs take their place once the grid scrolls.
- Scrolling back to the top morphs the three tabs back into the four. Tapping the Collections icon brings the four back at any time, and tapping Collections again brings the three.
- The Map keeps whichever capsule was showing when it was chosen.
- Please open a trip, scroll down and back up, tap the Collections icon and then the Collections tab, and compare the motion with the Library's Years, Months and All.

## 2.4.0 (51)

- When a trip, tag, month or year is open, the Photos, Journal and Map tabs now sit in the bottom capsule, where the Library's Years, Months and All tabs are, instead of in a row under the cover picture. Photos is chosen when the collection opens, and the grid starts right under the cover.
- Scrolling the grid folds the capsule down to the four icons. Tapping the Collections icon brings the three tabs back, and Back returns to the Collections list with the four icons.
- Select mode's toolbar takes the bar's place as before, and the three tabs return when Select ends.
- Please open a trip and a tag card, switch between the three tabs, scroll down, tap the Collections icon, and go back.

## 2.4.0 (50)

- A tag, month or year card on the Collections tab now opens its own collection screen, with the card's cover picture and name on top and the Photos, Journal and Map tabs below, instead of jumping to the Library.
- Photos lists that collection's pictures newest first, in the same grid as a trip, and they can be selected, shared and deleted from there.
- Journal shows the memos of the collection: every memo carrying the tag, or every memo from that month or year.
- Map shows the places of the collection's pictures.
- Trip-only actions such as renaming, changing the dates or removing a picture stay off these automatic collections.
- In a trip's Journal, two memos from the same day now have a gap between them, as the Timeline has.
- Please open a tag card, a month card and a year card, try the three tabs on each, and open the Journal of a trip that has two memos on one day.

## 2.4.0 (49)

- A memo whose pictures have all finished uploading is created right away instead of waiting for the next cold start of the app.
- The outbox arms its retry timer on the job's own next attempt time, not only on each file's deadline, so a held memo is retried when it is due.
- Switching mobile data on or off while an upload hands over to its successor applies the new setting to that successor.
- Signing out and back in with another account no longer lets a delayed cancel from the old account cancel the new account's capture.
- The New trip sheet's counts and date spans refresh after deletes from the Library, the Timeline and partial deletes, and a refusal left over from a signed-out session can no longer reach the sheet after a new sign-in.
- Please create a memo with several pictures on mobile data and toggle mobile data while it uploads, then sign out, sign in again, delete a picture and open the New trip sheet.

## 2.4.0 (48)

- Show Selected no longer turns the screen black when the selection has pictures from more than one day.
- The Library's filter menu has View Options: Group by Day, which is on, and a choice between Mixed Sizes and a Square Grid of three to a row; turning Group by Day off shows one flat grid without day headings, and either switch keeps the picture I was looking at in view.
- The choice is kept, so the grid opens the way I left it.
- Please select pictures from two different days and tap Show Selected, then open the Library's filter, turn Group by Day off and on, and switch between Mixed Sizes and Square Grid while scrolled into the middle of the grid.

## 2.4.0 (47)

- The Library's round button is now a filter: All items, Photos or Videos, with Sort By underneath, laid out like the Photos app.
- Select All is gone from the Library; in Select mode the bar's middle button reads Show Selected with the count and narrows the grid to those pictures until it is tapped again.
- Collections opens on rows of square cover cards with the name inside the picture and the count in the corner; Tags, Months and Years now have rows of their own next to Trips, and a trip's own tag is no longer listed as a tag.
- Tapping Collections again while it is already selected goes back to its root.
- The pin on trips is gone; the composer offers the trip whose dates contain today.
- Storage moved into the phone's Settings app under memos: it shows the size of the media cache and has a switch to clear it the next time the app opens.
- Please open the Library's filter and change the sort, select a few pictures and open Show Selected, scroll the Collections rows and tap a card, re-tap Collections from inside a trip, and try the cache switch in Settings.

## 2.3.0 (46)

- Trips now live on the server. Every phone signed in to my server sees the same trips with the same pictures, and the trips this phone kept for itself are gone; the Portugal 2026 trip is already listed.
- Creating a trip, renaming it, choosing its cover, changing its start and end, removing a picture, adding it back and deleting the trip all happen on the server and show up on the other phone after a refresh.
- Show Removed lists the pictures the server has removed from the trip and says not available while that list is still loading.
- Creating a trip twice in quick succession with different details is refused instead of answering with the first trip.
- A picture removed from a trip stays out of its grid, map and summary, and a picture deleted while the viewer is open leaves the viewer instead of coming back on the next swipe.
- Please open Collections and check that Portugal 2026 is listed with its pictures, create a trip on one phone and look for it on the other, and remove a picture from a trip and add it back.

## 2.2.3 (45)

- The gear is gone: my avatar in the Timeline's toolbar opens an Account sheet with my account, the token this phone holds, Manage tokens, the default visibility and Sign out.
- Appearance and Upload over mobile data moved into the phone's Settings app, under memos, where the version is shown too; the app follows a change made there without a relaunch.
- Clear cache is now the last item of the Library's ⋯ menu.
- Timeline and Places no longer carry a title; the Library heading sits at the screen edge, and Collections carries the same header.
- In a trip's viewer, Use as Cover moved into the ⋯ menu, next to Show Memo.
- Tapping a photo in a trip's Journal opens the viewer on the trip, starting at that photo, instead of leaving for the Timeline; tapping its text still opens the memo.
- Please open the Account sheet from the avatar, change Appearance in the phone's Settings app and come back, open a Journal photo, and set a cover from the viewer's menu.

## 2.2.2 (44)

- I can pin one trip from its menu. While it is pinned, a new memo gets the trip's tag on its own line, shown as a chip I can remove with ✕. The pin ends by itself 7 days after the trip's last picture.
- While a trip is pinned, a new memo starts as Just us; change the pill to post it publicly.
- The middle visibility level is now called Just us, on the memo card and in the share sheet.
- A trip now shows every picture and video of its memos in one flat grid, oldest first.
- A trip can have a start and an end, with a time of day for the first and last day, and every picture taken in between belongs to it, tagged or not. New trip fills in the dates from the tag's first and last picture.
- A trip's Journal shows its memos oldest first, each on the day of its first picture, and its Map shows only the trip's places.
- I can choose any picture as a trip's cover with Use as Cover, and the Collections list has a Years row.
- In a trip I can Select pictures to share them, delete my own, or Remove them from the trip; Show Removed in the trip's menu lists them with Add Back. Removing never changes a memo.
- Please pin a trip and post a memo, give a trip a start and end time, and remove a picture from a trip and add it back.

## 2.2.2 (43)

- I added a fourth tab, Collections, for trips. A trip is made from a tag: New trip lists my tags that have photos, and puts the short, recent ones I would call a journey under Suggested.
- When I open a trip I see its photos oldest first, grouped by day, under a header with the cover, the title, the dates and the count.
- Tapping a photo opens the viewer across that trip's photos only, and Show Memo still takes me to the memo it belongs to.
- From a trip's menu I can rename it, move it up or down in the list, or delete it. Deleting a trip only removes the trip: its photos and memos stay.
- On a trip's screen the main bar folds when I scroll down, just as it does on the Timeline.
- Please make a trip from one of your tags, scroll through it, open a few photos and swipe across them, then rename the trip and delete it again.

## 2.2.1 (42)

- Pressing a tab no longer loses the main bar to a scroll reading that arrives late from a list you had already left: the bar now stays where the press put it.
- I could not reproduce the lost press after an unfold and a quick run of tab presses on this build, so nothing changed there; two new checks hold the bar to that exact sequence from now on.
- Everything else is as in 41.

## 2.2.1 (41)

- The selected tab now sits on a pill that slides to the tab you tap, with a small bounce, and a tab swells under your finger while you press it. I built both to match the system tab bar's own.
- The bar is now drawn once over the whole app instead of once per tab, so switching tabs no longer redraws it.
- Everything else is as in 40.
- Please tap through the three tabs, press and hold a tab, and check the Timeline narrowing and the Library's Years | Months | All row once more.

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

# TestFlight notes

`fastlane beta` sends the section headed with the archived version and build as the build's
"What to Test" text, and refuses to upload when that section is missing or empty. Testers read
these words: first person singular, no ticket keys, no internal host names. TestFlight shows them
as plain text, so each point stays on one line.

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

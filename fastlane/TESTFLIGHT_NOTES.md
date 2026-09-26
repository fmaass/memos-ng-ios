# TestFlight notes

`fastlane beta` sends the section headed with the archived version and build as the build's
"What to Test" text, and refuses to upload when that section is missing or empty. Testers read
these words: first person singular, no ticket keys, no internal host names. TestFlight shows them
as plain text, so each point stays on one line.

## 1.5.5 (24)

- Photos and videos now upload in the background as one whole file each, and a failed upload is sent again whole. Uploads already underway when the app updates finish the way they started.
- New uploads start while the app is open; in the background it finishes what is already underway.
- An edit made while signed in to one account is no longer sent to another account's server.
- A picture that another device replaced is no longer mistaken for the original when a save is sent again.
- An upload that was moving on to its next part is no longer cancelled or sent twice.

# Changelog

All notable changes to this project are listed here, newest first.
Versions follow [Semantic Versioning](https://semver.org): **major** for redesigns, **minor** for new features, **patch** for fixes.

The repository starts at v0.3.1. Earlier versions were released to the website before the project was in git, so they are listed here but have no tagged source.

## [1.0.2] — 2026-11-25

### Changed
- Feedback no longer lives in Optimizer's project: the app sends it to Axis Optic, my developer project, through its `feedback` function, which checks the user's sign-in and shows them only their own tickets
- The admin connection for my developer app, Console, is `functions/console.js` (was `optic.js`), and it accepts calls only from Axis Optic's Google-signed service accounts, with no shared secrets

## [1.0.1] — 2026-11-23

### Security
- Premium beta's features are checked on the server too, not only hidden in the app: address search, flight and commute lookups, Google Calendar (linking, syncing, events) and sharing (people, groups, event guests, trip sharing). Disconnecting Google and answering or leaving an invitation stay open to everyone. The every-minute Google Calendar check skips accounts without premium beta
- New accounts get an email to verify their address. Invitations and anything shared with you are matched by email, so they need a verified one: until then you aren't listed for others to find, and an invitation link can only be claimed by the address it was sent to. Settings shows "Verify your email" with a Resend button until it's done
- Canvas links can only reach the public internet: every check (not only adding one) requires https and refuses private, loopback, link-local (including the metadata server), carrier-grade NAT and IPv6 local addresses, and internal host names, on every redirect too (at most 5)
- firestore.rules, the live rules for the whole project, is now in the repo (it was git-ignored); the outdated firestore.rules.example is gone

## [1.0.0] — 2026-11-23

### Added
- Change your name in Settings (Account); People shows the new one too
- Make an account from the sign-in page (no invitation needed): a regular account, with premium beta only ever switched on from Axis Optic. The sign-in page is laid out like Scorecards', with a short pitch beside the form on a wide screen and the version under it
- The website (axisoptic.com) can read Optimizer's live version, as it does Scorecards' and Axis Team's
- To-dos page, open to everyone: all your to-dos in one column by due date, with a month beside it that shows only to-dos (check them off there, or tap a day to add one). A toolbar in the middle of the header switches between that, the urgent / important matrix, and your groups side by side (starting with one blank "To-dos" group), and its New adds a to-do, a group, or a Canvas calendar; every group can be renamed
- Syncing a Canvas calendar asks whether its assignments get a group of their own or go in one you have (each still tagged with its class)
- Urgent / important matrix view: drag to-dos from Not sorted into four boxes. While it's your view, the calendar's to-do list tags each to-do with its box

### Changed
- Without premium beta, Canvas is checked when the app opens (unless it was in the last 5 minutes) and with the To-dos toolbar's refresh button, which says when it last updated; at most 5 refreshes in 5 minutes, counted on the server. No every-minute check and no Canvas notifications without it (Settings' Notifications and Canvas alerts are premium beta's)
- The To-dos toolbar is centered on the whole page, moving over only when the title needs the room
- Every other page (Home, Calendar, Trips, Journal, Net worth, Ask, People) is now premium beta, listed under a line in the side bar
- Only Canvas calendars can be linked from To-dos; a Google Calendar link is turned away with a pointer to the Calendar page
- Settings' Calendar section (Google sync, calendar layout) only shows with premium beta
- Focus is premium beta's too: without it, a session never takes over the app, and the app no longer waits on checking for one when it opens
- Send feedback is laid out like Scorecards' form: what it's about, where, the details, then Submit; just one box to type in. Its places are what you have: To-dos, Canvas sync, notifications and so on, plus premium beta's features (Home, Focus, Calendar, the assistant…) only while you have it
- On a phone, the bottom bar and your picture are gone: a ☰ at the top left of every page slides the website's side bar in over the app, with every page (Settings too) and your account. The calendar's list of calendars has its own icon now
- The to-do list opens at the top, on what's due soonest, instead of jumping down to today; overdue to-dos fold under "N overdue" on the Today line
- A to-do's ⋯ (or a long press) shows what you can do with it straight away: edit, check off, move to a box, open in Canvas, delete. A Canvas item's details are under Details

### Fixed
- Your name now shows in the side bar and Settings right after making an account, instead of only your email
- The ☰ lines up with the page's edge

## [0.3.1] — 2026-11-15

### Added
- Send feedback from Settings to Axis Optic, my developer app
- Page-view analytics

### Changed
- Firebase config and the journal key moved out of the code into git-ignored files, with templates
- Test and preview data replaced with fictional names and places

## 0.3.0 — 2026-11-15

### Added
- Premium beta: net worth and the assistant are early features for accounts switched on in Axis Optic, checked on the server
- Axis Optic integration: user list, account details, premium beta switch and new-user alerts

## 0.2.4 — 2026-11-13

### Fixed
- Google Calendar connect now goes through Google in the same tab instead of a popup, which Google's consent pages could cut off

## 0.2.3 — 2026-11-13

### Fixed
- Google Calendar connect no longer gives up while Google's consent pages are still open

## 0.2.2 — 2026-11-13

### Added
- Built-in assistant (Gemini on Vertex AI) in a resizable side panel and on its own Ask page, able to read and change the calendar, to-dos and trips, with per-feature permissions and undo
- Optimizer-only calendars
- Journal headers, appear-as dates and undo and redo while writing

### Changed
- Month view tasks: a check circle and time-ordered days
- Gas entries need only miles or gallons

## 0.2.1 — 2026-11-05

### Changed
- Month view redesigned: thin dividers, solid all-day and faded timed events, multi-day bars and "+N more" lists
- Hovering an entry brightens it instead of showing a pop-up

## 0.2.0 — 2026-11-05

### Added
- Trips: flights by number, drives with predicted traffic, stays and activities in each place's time zone, PDF export
- Sharing trips, events and groups with other people, with roles and hidden entries
- Address autocomplete and maps on calendar entries and trips
- Canvas due times, locations and descriptions from the calendar feed

## 0.1.2 — 2026-11-04

### Added
- Focus page with a session panel; while a session runs, every device stays on it

### Changed
- Removed the dashboard's Customize mode

### Fixed
- Scrollbars appearing in the side bar

## 0.1.1 — 2026-11-02

### Added
- "Keep past events" archiving for Google Calendar
- Calendar layout choice for tablets and big phones
- Website side bar with folding, like Axis Team's

### Changed
- Calendar toolbar reorganized, with Calendars and To-do columns you can show or hide

## 0.1.0 — 2026-11-01

### Added
- First version: Home dashboard, Google Calendar with a sideways week, Canvas calendar feeds with push notifications, the Axis Journal, and net worth from Asset Track

[1.0.1]: https://github.com/jdball5555/optimizer/releases/tag/v1.0.1
[1.0.0]: https://github.com/jdball5555/optimizer/releases/tag/v1.0.0
[0.3.1]: https://github.com/jdball5555/optimizer/releases/tag/v0.3.1

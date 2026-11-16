# Changelog

All notable changes to this project are listed here, newest first.
Versions follow [Semantic Versioning](https://semver.org): **major** for redesigns, **minor** for new features, **patch** for fixes.

The repository starts at v0.3.1. Earlier versions were released to the website before the project was in git, so they are listed here but have no tagged source.

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

[0.3.1]: https://github.com/jdball5555/optimizer/releases/tag/v0.3.1

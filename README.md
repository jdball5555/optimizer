# Optimizer — Personal Command Center

A personal command center that brings my calendars, school work, trips, journal and finances into one app, with a built-in AI assistant that can read and change them. Built with Flutter and Firebase, for the web, Android, iOS and macOS.

**Live site:** [optimizer.axisoptic.com](https://optimizer.axisoptic.com) (invite only)

## Overview

Optimizer started as a way to stop switching between Google Calendar, Canvas, my journal app and my finance tracker. It reads and writes the same data as my other Axis apps (Axis Journal and Asset Track), so nothing is copied or re-entered, and it adds what none of them had on their own: one calendar for everything, trip planning, focus sessions and an assistant that understands all of it.

## Features

- **Calendar.** Google Calendar sync for several accounts, kept in step by the server every minute. Week, month and to-do views, a sideways week that fits on one screen, undo and history, optional "keep past events" archiving, and Optimizer-only calendars.
- **Canvas.** Reads a school's Canvas calendar feed, turns assignments into tasks with due times, and sends push notifications for new assignments and moved due dates.
- **Trips.** A trip planner with flights looked up by number, drive times with predicted traffic, stays and activities on each place's own clock, address autocomplete, maps, PDF export, and sharing with per-person roles and hidden entries.
- **People.** Invitations to events, groups and trips between Optimizer accounts, or by link for anyone not on it yet.
- **Journal.** The same encrypted entries as Axis Journal, with headers, people references and habits.
- **Net worth.** Everything from Asset Track: net worth over time, accounts, spending by category, investments and gas mileage.
- **Assistant.** Gemini, run by the server, with tools to read and change the calendar, to-dos and trips. Each kind of data and each kind of change is switched on separately, changes can be confirmed first, and every change can be undone.
- **Focus.** Timed focus sessions that lock the app to one screen on every device until they end.
- **Premium beta.** Early features (net worth and the assistant) for accounts switched on from my developer app, Axis Optic, enforced on the server.

## Built with

- [Flutter](https://flutter.dev) (Dart) for web, Android, iOS and macOS
- Firebase: Authentication, Cloud Firestore, Cloud Functions (Node.js), Cloud Messaging, Hosting and Analytics
- Gemini on Vertex AI, for the assistant
- Google Calendar API, Routes API and Places API (New)
- AeroDataBox, for flight lookups

## Project structure

```
lib/
  main.dart            app entry point
  shell/               navigation: side bar, phone bar, the assistant's panel
  dashboard/           Home
  calendar/            Google and Canvas calendars, views, editing, undo
  trips/               trip planner, itinerary, sharing, PDF
  people/              invitations and groups
  journal/             Axis Journal entries and habits
  networth/            Asset Track data
  ai/                  the assistant: chat, tools, settings
  focus/               focus sessions
  premium/             premium beta
  settings/            settings and feedback
functions/
  index.js             Canvas feeds and notifications
  google.js            Google Calendar sync
  people.js            invitations, groups, shared trips
  trips.js, places.js  flights, drive times, addresses
  assistant.js         the assistant's relay to Gemini
  optic.js, premium.js user admin and premium beta for Axis Optic
test/                  widget and unit tests, plus layout previews
```

## Privacy and security

This repository is public as part of my portfolio, so everything that connects to the live app or holds personal data is kept out of it:

- **No credentials or project connection.** The Firebase config (`lib/firebase_options.dart`, `web/firebase-messaging-sw.js`), the project alias and the journal's encryption key are git-ignored. Each has a `.example` template with placeholders.
- **Server-side secrets** (the Google OAuth client secret and API keys) live in Firebase's secret store, never in the code.
- **Data access.** Every user's data sits under their own user ID and the Firestore rules let only that user read it (`firestore.rules.example`). Shared data, like invitations and Google sign-ins, is server-only, written by Cloud Functions that act only for the signed-in caller.
- **Test data is made up.** Names, places and amounts in the tests and previews are fictional.

## Running locally

1. Install the [Flutter SDK](https://docs.flutter.dev/get-started/install) and the [Firebase CLI](https://firebase.google.com/docs/cli).
2. Create a Firebase project, then run `flutterfire configure` (or copy `lib/firebase_options.example.dart` to `lib/firebase_options.dart` and fill it in).
3. Copy `web/firebase-messaging-sw.example.js` to `web/firebase-messaging-sw.js` and `lib/journal/journal_key.example.dart` to `lib/journal/journal_key.dart`, and fill them in.
4. Copy `firestore.rules.example` to `firestore.rules` and deploy it.
5. Run `flutter pub get`, then `flutter run -d chrome --web-port 5050`. Google sign-in expects port 5050.
6. Functions: `cd functions && npm install`, put `GOOGLE_OAUTH_CLIENT_ID=…` in `functions/.env`, set the `GOOGLE_OAUTH_CLIENT_SECRET` secret, then `firebase deploy --only functions`.

Tests: `flutter test` for the app and `cd functions && npm test` for the server.

## How it was built

This project was built with AI-assisted development. I designed the app and directed the work, and I used **Claude** (Anthropic) in **Claude Code** to write and iterate on the code. Each release is tagged, and the [changelog](CHANGELOG.md) lists what changed in each one.

## Status

**Current version: 0.3.1.** In active development. See the [changelog](CHANGELOG.md) for version history.

## License

The source code is available under the [MIT License](LICENSE). The Axis and Optimizer names and the app icon are not covered by the license.

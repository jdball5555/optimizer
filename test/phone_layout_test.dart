import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/calendar/calendar_models.dart';
import 'package:optimizer/calendar/calendar_page.dart';
import 'package:optimizer/calendar/canvas.dart';
import 'package:optimizer/journal/habit_store.dart';
import 'package:optimizer/dashboard/dashboard_page.dart';
import 'package:optimizer/journal/journal_page.dart';
import 'package:optimizer/networth/net_worth_page.dart';
import 'package:optimizer/theme.dart';
import 'package:optimizer/util/fields.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview/pages_preview_test.dart' show journal, finance, FeedService;

FeedService calendar() {
  final svc = FeedService();
  svc.accounts.add(GoogleAccount(email: 'me@example.com'));
  final cal = GoogleCalendar(id: 'p', accountEmail: 'me@example.com', name: 'Me', color: const Color(0xFF4285F4), primary: true, accessRole: 'owner');
  svc.calendars.add(cal);
  final today = dayStart(DateTime.now());
  final sunday = addDays(today, -(today.weekday % 7));
  CalendarEvent ev(int d, double h, double len, String t, {bool allDay = false}) => CalendarEvent(
      id: '$t$d$h', calendar: cal, title: t, description: '', location: '',
      start: allDay ? addDays(sunday, d) : addDays(sunday, d).add(Duration(minutes: (h * 60).round())),
      end: allDay ? addDays(sunday, d + 1) : addDays(sunday, d).add(Duration(minutes: ((h + len) * 60).round())),
      allDay: allDay, color: cal.color);
  svc.fake = [
    for (var d = 0; d < 7; d++) ...[ev(d, 9, 1, 'Standup'), ev(d, 9.5, 0.25, 'Quick call'), ev(d, 13, 3, 'Class with a long name')],
    for (var k = 0; k < 4; k++) ev(2, 0, 0, 'Due $k', allDay: true),
  ];
  return svc;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  moreTests();

  for (final size in const [Size(412, 915), Size(360, 740)]) {
    final pages = <String, Widget Function()>{
      'calendar': () => CalendarPage(service: calendar()),
      'journal': () => JournalPage(store: journal()),
      'net worth': () => NetWorthPage(store: finance()),
      'dashboard': () => DashboardPage(uid: 'u', calendar: calendar(), journal: journal(), finance: finance(), onNavigate: (_) {}),
    };
    for (final MapEntry(key: name, value: page) in pages.entries) {
      testWidgets('$name fits a ${size.width.toInt()}x${size.height.toInt()} phone', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final errors = <String>[];
        final old = FlutterError.onError;
        FlutterError.onError = (d) => errors.add(d.exceptionAsString().split('\n').first);
        await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: page())));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 300));
        FlutterError.onError = old;
        expect(errors, isEmpty);
      });
    }
  }
}

/// Like the app: every page built at once in an IndexedStack, one showing.
/// (A scrollbar without its own controller fails only in this setting.)
Widget appLike(int index) => IndexedStack(index: index, children: [
      DashboardPage(uid: 'u', calendar: calendar(), journal: journal(), finance: finance(), onNavigate: (_) {}),
      CalendarPage(service: calendar()),
      JournalPage(store: journal(), habits: habits()),
      NetWorthPage(store: finance()),
    ]);

HabitStore habits() {
  final h = [
    Habit('h1', {'title': 'Run', 'targetStreak': 21, 'isGoodHabit': true, 'iconKey': 'run'}),
    Habit('h2', {'title': 'No phone in bed', 'targetStreak': 30, 'isGoodHabit': false}),
  ];
  final today = DateTime.now();
  return HabitStore.withData('u', h, [
    for (var i = 0; i < 6; i++) HabitLog('l$i', {'habitId': 'h1', 'date': Timestamp.fromDate(today.subtract(Duration(days: i))), 'completed': i != 3}),
  ]);
}

/// Runs [body] with Flutter's error reporting captured, and puts it back
/// before returning (flutter_test requires that before any expect).
Future<List<String>> collectErrors(WidgetTester tester, Widget child, [Future<void> Function()? then]) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final errors = <String>[];
  final old = FlutterError.onError;
  FlutterError.onError = (d) => errors.add(d.exceptionAsString().split('\n').first);
  try {
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: child)));
    await tester.pump(const Duration(milliseconds: 300));
    if (then != null) await then();
  } finally {
    FlutterError.onError = old;
  }
  return errors;
}

void moreTests() {
  for (var i = 0; i < 4; i++) {
    testWidgets('page $i opens and scrolls inside the app-like stack on a phone', (tester) async {
      final errors = await collectErrors(tester, appLike(i), () async {
        // The scrollbar only looks for its scroll position once you scroll.
        await tester.dragFrom(const Offset(200, 500), const Offset(0, 300));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 600));
      });
      expect(errors, isEmpty);
    });
  }

  testWidgets('habits tab: shows streaks and logs a day on tap', (tester) async {
    final errors = await collectErrors(tester, JournalPage(store: journal(), habits: habits()), () async {
      await tester.tap(find.text('Habits'));
      await tester.pump(const Duration(milliseconds: 300));
    });
    // Each habit is in today's rings and in its history card.
    expect(find.text('Run'), findsNWidgets(2));
    expect(find.text('No phone in bed'), findsNWidgets(2));
    expect(errors, isEmpty);
  });

  testWidgets('a Canvas to-do’s details: when it’s due and what the feed says about it', (tester) async {
    final svc = calendar();
    final feed = CanvasFeed('f1', {'name': 'Fall classes', 'color': '#22C55E'});
    svc.canvasFeeds.add(feed);
    final due = dayStart(DateTime.now()).add(const Duration(days: 2, hours: 23, minutes: 59));
    svc.canvasTasks = [
      CanvasTask(
        id: 't1', feed: feed, calendar: feed.calendarFor('ENGL 101'), title: 'Essay 2', course: 'ENGL 101', due: due, allDay: false, assignment: true,
        description: 'Write 1200 words.', location: 'Science Hall 102',
      ),
    ];
    final errors = await collectErrors(tester, CalendarPage(service: svc), () async {
      await tester.tap(find.text('Week'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('To-do').last);
      await tester.pumpAndSettle();
    });
    await tester.longPress(find.text('Essay 2'));
    await tester.pumpAndSettle();
    expect(find.textContaining(RegExp(r'^Due .* · 11:59\sPM$')), findsOneWidget);
    expect(find.text('Write 1200 words.'), findsOneWidget);
    expect(find.text('Science Hall 102'), findsOneWidget);
    expect(errors, isEmpty);
  });

  testWidgets('to-do lists Canvas items and checks them off', (tester) async {
    final svc = calendar();
    final feed = CanvasFeed('f1', {'name': 'Fall classes', 'color': '#22C55E'});
    svc.canvasFeeds.add(feed);
    final now = DateTime.now();
    svc.canvasTasks = [
      CanvasTask(id: 't1', feed: feed, calendar: feed.calendarFor('ENGL 101'), title: 'Essay 2', course: 'ENGL 101', due: now.add(const Duration(hours: 5)), allDay: false),
      CanvasTask(id: 't2', feed: feed, calendar: feed.calendarFor('BIO 110'), title: 'Quiz 4', course: 'BIO 110', due: now.subtract(const Duration(days: 2)), allDay: false),
    ];
    final errors = await collectErrors(tester, CalendarPage(service: svc), () async {
      // On a phone the views are in a menu.
      await tester.tap(find.text('Week'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('To-do').last);
      await tester.pumpAndSettle();
    });
    expect(find.text('Essay 2'), findsOneWidget);
    // The overdue one sits above the white Today line, under its own day.
    expect(find.text('1 overdue above'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Quiz 4')).dy, lessThan(tester.getTopLeft(find.text('TODAY')).dy));

    // Checked off: it stays, crossed out, then leaves three seconds after the last tick.
    await tester.tap(find.text('Quiz 4'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Quiz 4'), findsOneWidget);
    expect(tester.widget<Text>(find.text('Quiz 4')).style?.decoration, TextDecoration.lineThrough);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Quiz 4'), findsNothing);
    expect(find.textContaining('Done (1)'), findsOneWidget);
    expect(errors, isEmpty);
  });
}

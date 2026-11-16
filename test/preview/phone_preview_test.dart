import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/calendar/calendar_page.dart';
import 'package:optimizer/calendar/canvas.dart';
import 'package:optimizer/dashboard/dashboard_page.dart';
import 'package:optimizer/journal/journal_page.dart';
import 'package:optimizer/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phone_layout_test.dart' show calendar, habits;
import 'calendar_preview_test.dart' show loadFonts, skipPreview;
import 'pages_preview_test.dart' show journal, finance, shot;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> phone(WidgetTester tester, Widget page, String name, [Future<void> Function()? then]) async {
    await tester.runAsync(loadFonts);
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      debugShowCheckedModeBanner: false,
      home: RepaintBoundary(key: const ValueKey('shot'), child: Scaffold(body: SafeArea(child: page))),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    if (then != null) await then();
    await shot(tester, name);
    tester.view.reset();
  }

  testWidgets(skip: skipPreview, 'phone calendar', (tester) => phone(tester, CalendarPage(service: calendar()), 'phone_week'));
  testWidgets(skip: skipPreview, 'phone journal', (tester) => phone(tester, JournalPage(store: journal()), 'phone_journal'));

  testWidgets(skip: skipPreview, 'phone habits', (tester) => phone(tester, JournalPage(store: journal(), habits: habits()), 'phone_habits', () async {
        await tester.tap(find.text('Habits'));
        await tester.pump(const Duration(milliseconds: 300));
      }));
  testWidgets(skip: skipPreview, 'phone todo', (tester) {
    final svc = calendar();
    final feed = CanvasFeed('f1', {
      'name': 'Fall 2026',
      'courseColors': {'BIO 110': '#22C55E', 'ENGL 101': '#A855F7', 'CHEM 107': '#F97316', 'MATH 151': '#06B6D4'},
    });
    svc.canvasFeeds.add(feed);
    final now = DateTime.now();
    svc.canvasTasks = [
      CanvasTask(id: 'a', feed: feed, calendar: feed.calendarFor('BIO 110'), title: 'Quiz 4', course: 'BIO 110', due: now.subtract(const Duration(days: 1)), allDay: false),
      CanvasTask(id: 'b', feed: feed, calendar: feed.calendarFor('ENGL 101'), title: 'Essay 2: Argument', course: 'ENGL 101', due: now.add(const Duration(hours: 3)), allDay: false),
      CanvasTask(id: 'c', feed: feed, calendar: feed.calendarFor('CHEM 107'), title: 'Lab report', course: 'CHEM 107', due: now.add(const Duration(days: 1)), allDay: true),
      CanvasTask(id: 'd', feed: feed, calendar: feed.calendarFor('MATH 151'), title: 'Problem set 6', course: 'MATH 151', due: now.add(const Duration(days: 4)), allDay: false),
      CanvasTask(id: 'e', feed: feed, calendar: feed.calendarFor('ENGL 101'), title: 'Reading response 5', course: 'ENGL 101', due: now.add(const Duration(days: 4, hours: 2)), allDay: false),
      CanvasTask(id: 'f', feed: feed, calendar: feed.calendarFor('BIO 110'), title: 'Lab 7 prelab', course: 'BIO 110', due: now.add(const Duration(days: 1, hours: 1)), allDay: false),
    ];
    return phone(tester, CalendarPage(service: svc), 'phone_todo', () async {
      await tester.tap(find.text('Week'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('To-do').last);
      await tester.pumpAndSettle();
    });
  });
  testWidgets(skip: skipPreview, 'phone dashboard', (tester) =>
      phone(tester, DashboardPage(uid: 'u', calendar: calendar(), journal: journal(), finance: finance(), onNavigate: (_) {}), 'phone_dashboard'));

  for (final view in ['Month']) {
    testWidgets(skip: skipPreview, 'phone ${view.toLowerCase()}', (tester) => phone(tester, CalendarPage(service: calendar()), 'phone_${view.toLowerCase()}', () async {
          await tester.tap(find.text('Week'));
          await tester.pumpAndSettle();
          await tester.tap(find.text(view).last);
          await tester.pumpAndSettle();
        }));
  }
}

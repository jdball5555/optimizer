import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/calendar/calendar_models.dart';
import 'package:optimizer/calendar/calendar_page.dart';
import 'package:optimizer/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview/calendar_preview_test.dart' show FakeService;

class UndoService extends FakeService {
  bool undone = false;
  void change() => remember('Changed “Dentist”', () async => undone = true);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final width in [360.0, 900.0, 1400.0]) {
    testWidgets('undo asks first, then reverses the latest change (${width.toInt()} wide)', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final svc = UndoService()..accounts.add(GoogleAccount(email: 'me@example.com'));
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: CalendarPage(service: svc)));
      await tester.pump();

      svc.change();
      await tester.pump();
      expect(tester.takeException(), isNull); // the phone row still fits
      final button = width < 640 ? find.text('Undo') : find.byTooltip('Undo: Changed “Dentist”');
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Undo this change?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(svc.undone, isFalse);

      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Undo'));
      await tester.pumpAndSettle();
      expect(svc.undone, isTrue);
      expect(svc.lastChange, isNull);
      expect(find.text('Undo'), findsNothing); // the phone's button goes away again
    });
  }

  testWidgets('the desktop layout, chosen in Settings, fits a phone and a small tablet', (tester) async {
    addTearDown(() => calendarLayout.value = CalendarLayout.auto);
    calendarLayout.value = CalendarLayout.desktop;
    for (final size in [const Size(412, 900), const Size(820, 1180), const Size(1180, 820)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final svc = UndoService()..accounts.add(GoogleAccount(email: 'me@example.com'));
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: CalendarPage(key: ValueKey(size), service: svc)));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '$size');
      expect(find.byTooltip('Sync with Google now'), findsOneWidget, reason: 'desktop toolbar at $size');
    }
    tester.view.reset();
  });

  test('all-day order: your events, then Canvas by class and name, checked-off last', () {
    GoogleCalendar cal(String name, {bool canvas = false}) => GoogleCalendar(
        id: name, accountEmail: canvas ? 'canvas' : 'me', name: name, color: Colors.blue, primary: false, accessRole: 'owner');
    final day = DateTime(2026, 11, 6);
    CalendarEvent e(String title, GoogleCalendar c, {bool done = false}) => CalendarEvent(
        id: title, calendar: c, title: title, description: '', location: '', start: day, end: day.add(const Duration(days: 1)),
        allDay: true, color: Colors.blue, done: done);
    final list = [
      e('Quiz 4', cal('BIO 110', canvas: true), done: true),
      e('Essay 2', cal('ENGL 101', canvas: true)),
      e('Payday', cal('Me')),
      e('Prelab', cal('BIO 110', canvas: true)),
      e('Chapter 9', cal('BIO 110', canvas: true)),
    ]..sort(compareAllDay);
    expect(list.map((x) => x.title), ['Payday', 'Chapter 9', 'Prelab', 'Essay 2', 'Quiz 4']);
  });
}

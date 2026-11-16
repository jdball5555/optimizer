import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/calendar/calendar_models.dart';
import 'package:optimizer/calendar/flipped_timeline.dart';
import 'package:optimizer/calendar/month_agenda.dart';
import 'package:optimizer/calendar/month_view.dart';
import 'package:optimizer/theme.dart';
import 'package:optimizer/util/fields.dart';

import 'preview/calendar_preview_test.dart' show loadFonts, skipPreview;
import 'preview/pages_preview_test.dart' show shot;

final _cal = GoogleCalendar(
  id: 'primary',
  accountEmail: 'me@example.com',
  name: 'Me',
  color: const Color(0xFF000000),
  primary: true,
  accessRole: 'owner',
);

CalendarEvent _event(String id, DateTime start, DateTime end, {bool allDay = false}) => CalendarEvent(
      id: id,
      calendar: _cal,
      title: 'Event $id',
      description: '',
      location: '',
      start: start,
      end: end,
      allDay: allDay,
      color: readableColor(_cal.color),
    );

/// A Canvas item due at a moment, the way canvasEvent makes it.
CalendarEvent _task(String title, DateTime day, {Color color = const Color(0xFF4285F4), bool done = false, DateTime? due}) => CalendarEvent(
      id: title,
      calendar: GoogleCalendar(id: 'f::BIO', accountEmail: 'canvas', name: 'BIO', color: color, primary: false, accessRole: 'reader'),
      title: '${done ? '✓ ' : ''}$title',
      description: '',
      location: '',
      start: day,
      end: addDays(day, 1),
      allDay: true,
      color: color,
      done: done,
      due: due,
    );

Future<void> _pump(WidgetTester tester, Widget child, {Size size = const Size(1400, 900)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: child)));
  await tester.pump();
}

void main() {
  test('pure black calendars are lifted so they show on black', () {
    final c = readableColor(const Color(0xFF000000));
    expect(c.computeLuminance(), greaterThanOrEqualTo(0.12));
    // Colors that are already readable are left alone.
    expect(readableColor(const Color(0xFF039BE5)), const Color(0xFF039BE5));
  });

  testWidgets('week rows fill the height; a lone event fills its row, overlaps split it', (tester) async {
    final sunday = DateTime(2026, 10, 25);
    final days = [for (var i = 0; i < 7; i++) addDays(sunday, i)];
    final monday = days[1];
    final events = [
      _event('solo', monday.add(const Duration(hours: 9)), monday.add(const Duration(hours: 10))),
      _event('a', monday.add(const Duration(hours: 13)), monday.add(const Duration(hours: 15))),
      _event('b', monday.add(const Duration(hours: 14)), monday.add(const Duration(hours: 16))),
      _event('all', monday, addDays(monday, 1), allDay: true),
    ];
    await _pump(
      tester,
      FlippedTimeline(days: days, events: events, hourWidth: 60, onEventTap: (_) {}, onSlotTap: (_, {bool allDay = false}) {}),
    );
    expect(tester.takeException(), isNull);

    final solo = tester.getSize(find.ancestor(of: find.text('Event solo'), matching: find.byType(EventBlock)));
    final a = tester.getSize(find.ancestor(of: find.text('Event a'), matching: find.byType(EventBlock)));
    final b = tester.getSize(find.ancestor(of: find.text('Event b'), matching: find.byType(EventBlock)));
    // 7 rows share ~860px, so each is well over 100px tall.
    expect(solo.height, greaterThan(100));
    expect(a.height, lessThan(solo.height / 2 + 1));
    expect(a.height, b.height);
    // All-day events are chunky, not hairlines.
    final allDay = tester.getSize(find.ancestor(of: find.text('Event all'), matching: find.byType(EventBlock)));
    expect(allDay.height, greaterThanOrEqualTo(28));
  });

  testWidgets('day view and a small dashboard panel lay out without overflow', (tester) async {
    final day = DateTime(2026, 10, 27);
    final events = [_event('x', day.add(const Duration(hours: 8)), day.add(const Duration(hours: 9)))];
    await _pump(tester, FlippedTimeline(days: [day], events: events, hourWidth: 96, onEventTap: (_) {}));
    expect(tester.takeException(), isNull);

    final week = [for (var i = 0; i < 7; i++) addDays(day, i)];
    await _pump(
      tester,
      SizedBox(width: 700, height: 380, child: FlippedTimeline(days: week, events: events, hourWidth: 64, compact: true, onEventTap: (_) {})),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('hovering an event doesn’t change its size', (tester) async {
    final day = DateTime(2026, 10, 27);
    final events = [_event('tiny', day.add(const Duration(hours: 9)), day.add(const Duration(hours: 9, minutes: 15)))];
    await _pump(tester, FlippedTimeline(days: [day], events: events, hourWidth: 96, onEventTap: (_) {}));
    final block = find.byType(EventBlock);
    final before = tester.getRect(block);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getTopLeft(block) + const Offset(4, 30));
    await tester.pumpAndSettle();
    expect(tester.widget<EventBlock>(block).open, isTrue);
    expect(tester.getRect(block), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('month view renders without layout errors', (tester) async {
    final day = DateTime(2026, 10, 1);
    final events = [
      for (var i = 0; i < 12; i++) _event('m$i', day.add(Duration(hours: 8 + i)), day.add(Duration(hours: 9 + i))),
      _event('long', day, addDays(day, 3), allDay: true),
    ];
    await _pump(tester, MonthView(month: day, events: events, onDayTap: (_) {}, onEventTap: (_) {}));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('more'), findsWidgets);
  });

  group('a week of the month', () {
    // Sunday to Saturday.
    final week = [for (var i = 0; i < 7; i++) DateTime(2026, 10, 25 + i)];
    CalendarEvent single(String id, int d, {bool allDay = false}) => allDay
        ? _event(id, week[d], addDays(week[d], 1), allDay: true)
        : _event(id, week[d].add(const Duration(hours: 9)), week[d].add(const Duration(hours: 10)));
    CalendarEvent across(String id, int from, int to) => _event(id, week[from], addDays(week[to], 1), allDay: true);
    MonthEntry entry(MonthWeekLayout l, String id) => l.entries.singleWhere((e) => e.event.id == id);

    test('something across days takes one row, and only on those days', () {
      final l = layoutMonthWeek(week, [across('trip', 1, 3), single('mon', 1), single('wed', 3), single('thu', 4), single('sat', 6)], 5);
      final trip = entry(l, 'trip');
      expect([trip.row, trip.first, trip.last], [0, 1, 3]);
      expect(entry(l, 'mon').row, 1, reason: 'under it, on a day it covers');
      expect(entry(l, 'wed').row, 1);
      expect(entry(l, 'thu').row, 0, reason: 'the day after isn’t moved by it');
      expect(entry(l, 'sat').row, 0);
    });

    test('a lower one leaves the rows above it free on its days', () {
      final l = layoutMonthWeek(week, [across('a', 1, 2), across('b', 2, 4), single('thu', 4)], 5);
      expect(entry(l, 'a').row, 0);
      expect(entry(l, 'b').row, 1, reason: 'the same row all the way');
      expect(entry(l, 'thu').row, 0, reason: 'free on Thursday');
    });

    test('two that don’t meet can share a row', () {
      final l = layoutMonthWeek(week, [across('a', 0, 1), across('b', 3, 5)], 5);
      expect([entry(l, 'a').row, entry(l, 'b').row], [0, 0]);
    });

    test('too many: the last row says how many more, only on that day', () {
      final l = layoutMonthWeek(week, [for (var i = 0; i < 5; i++) single('m$i', 2), single('thu', 3)], 3);
      expect(l.entries.where((e) => e.first == 2).map((e) => e.row), [0, 1]);
      expect(l.more, [0, 0, 3, 0, 0, 0, 0]);
      expect(l.days[2], hasLength(5), reason: 'all of them there to list');
      expect(entry(l, 'thu').row, 0);
    });

    test('a day runs all-day events, tasks with no time, then by time', () {
      final wed = week[3];
      final l = layoutMonthWeek(
          week,
          [
            _task('due 1pm', wed, due: wed.add(const Duration(hours: 13))),
            single('at 2pm', 3).copyWith(start: wed.add(const Duration(hours: 14)), end: wed.add(const Duration(hours: 15))),
            _task('no time', wed),
            single('at 9am', 3),
            _task('due 9:30', wed, due: wed.add(const Duration(hours: 9, minutes: 30))),
            single('holiday', 3, allDay: true),
          ],
          8);
      expect(([...l.entries]..sort((a, b) => a.row.compareTo(b.row))).map((e) => e.event.id), ['holiday', 'no time', 'at 9am', 'due 9:30', 'due 1pm', 'at 2pm']);
    });

    test('a task keeps its place by time once it’s done', () {
      final wed = week[3];
      final l = layoutMonthWeek(week, [_task('due 9am', wed, due: wed.add(const Duration(hours: 9)), done: true), single('at noon', 3).copyWith(start: wed.add(const Duration(hours: 12)), end: wed.add(const Duration(hours: 13)))], 8);
      expect(entry(l, 'due 9am').row, 0);
      expect(entry(l, 'at noon').row, 1);
    });

    test('exactly enough room needs no “more”', () {
      final l = layoutMonthWeek(week, [for (var i = 0; i < 3; i++) single('m$i', 2)], 3);
      expect(l.more, everyElement(0));
      expect(l.entries, hasLength(3));
    });

    test('where a day is full, a long one is counted there and carries on after it', () {
      final l = layoutMonthWeek(week, [across('a', 1, 3), across('b', 1, 3), single('x', 2), single('y', 2)], 2);
      final b = l.entries.where((e) => e.event.id == 'b').map((e) => (e.first, e.last)).toList();
      expect(entry(l, 'a').row, 0);
      expect(b, [(1, 1), (3, 3)]);
      expect(l.more[2], 3);
    });
  });

  testWidgets(skip: skipPreview, 'month_grid', (t) async {
    await t.runAsync(loadFonts);
    t.view.physicalSize = const Size(1300, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    const blue = Color(0xFF4285F4), green = Color(0xFF34D399), rose = Color(0xFFFB7185), amber = Color(0xFFFBBF24);
    CalendarEvent e(String title, Color c, DateTime start, DateTime end, {bool allDay = false, bool done = false}) => CalendarEvent(
        id: title, calendar: _cal, title: title, description: '', location: '', start: start, end: end, allDay: allDay, color: c, done: done);
    CalendarEvent at(String title, Color c, int day, int hour) => e(title, c, DateTime(2026, 11, day, hour), DateTime(2026, 11, day, hour + 1));
    CalendarEvent full(String title, Color c, int from, int to) => e(title, c, DateTime(2026, 11, from), DateTime(2026, 11, to + 1), allDay: true);
    CalendarEvent task(String title, Color c, int day, double? hour, {bool done = false}) => _task(title, DateTime(2026, 11, day),
        color: c, done: done, due: hour == null ? null : DateTime(2026, 11, day).add(Duration(minutes: (hour * 60).round())));
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(),
      debugShowCheckedModeBanner: false,
      builder: (_, c) => RepaintBoundary(key: const ValueKey('shot'), child: c!),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(12),
          child: MonthView(month: DateTime(2026, 11), onDayTap: (_) {}, onEventTap: (_) {}, events: [
            full('Conference in Austin', blue, 3, 6),
            full('Family visiting', rose, 4, 5),
            full('Thanksgiving trip', green, 25, 29),
            full('Holiday', amber, 11, 11),
            at('Dentist', blue, 3, 9),
            at('Team lunch', green, 6, 12),
            at('Gym', rose, 7, 7),
            at('Coffee with Sam', amber, 10, 8),
            for (var h = 8; h < 18; h++) at('Meeting $h', blue, 12, h),
            at('Oil change', amber, 26, 9),
            at('Dinner', rose, 27, 18),
            task('Essay 2 · 11:59 PM', green, 10, 23.98),
            task('Quiz 4 · 9:00 AM', rose, 10, 9),
            task('Office hours', blue, 10, null),
            full('Veterans Day', rose, 10, 10),
            task('Lab report · 5:00 PM', amber, 11, 17, done: true),
            task('Reading response · 11:59 PM', blue, 19, 23.98),
          ]),
        ),
      ),
    ));
    await t.pump();
    await shot(t, 'month_grid');
  });

  group('the month', () {
    final month = DateTime(2026, 10);
    final thu = DateTime(2026, 10, 15);
    Future<(List<DateTime>, List<String>)> pump(WidgetTester t, List<CalendarEvent> events) async {
      final days = <DateTime>[], tapped = <String>[];
      await _pump(t, MonthView(month: month, events: events, onDayTap: days.add, onEventTap: (e) => tapped.add(e.id)));
      return (days, tapped);
    }

    testWidgets('its days are divided by lines, with no gaps between them', (t) async {
      await pump(t, []);
      final cell = t.getTopLeft(find.text('16')).dx - t.getTopLeft(find.text('15')).dx;
      expect(cell, closeTo(1400 / 7, 1));
      expect(find.byWidgetPredicate((w) => w is Material && w.shape is RoundedRectangleBorder && w.borderRadius == null), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('a full day is solid; something with times is faded', (t) async {
      const blue = Color(0xFF4285F4);
      CalendarEvent colored(String id, bool allDay) => CalendarEvent(
          id: id,
          calendar: _cal,
          title: id,
          description: '',
          location: '',
          start: allDay ? thu : thu.add(const Duration(hours: 9)),
          end: allDay ? addDays(thu, 1) : thu.add(const Duration(hours: 10)),
          allDay: allDay,
          color: blue);
      await pump(t, [colored('full', true), colored('timed', false)]);
      Color fill(String title) => t.widget<Material>(find.ancestor(of: find.textContaining(title), matching: find.byType(Material)).first).color!;
      expect(fill('full'), blue);
      expect(fill('timed').computeLuminance(), lessThan(blue.computeLuminance() / 2));
    });

    testWidgets('an entry opens; empty space adds; “+N more” lists them all, and each opens', (t) async {
      final events = [for (var i = 0; i < 12; i++) _event('m$i', thu.add(Duration(hours: 8 + i)), thu.add(Duration(hours: 9 + i)))];
      final (days, tapped) = await pump(t, events);
      await t.tap(find.textContaining('Event m0'));
      expect(tapped, ['m0']);
      final more = find.textContaining('more');
      expect(more, findsOneWidget);
      await t.tap(more);
      await t.pumpAndSettle();
      expect(days, isEmpty, reason: 'it doesn’t start a new event');
      expect(find.text('Thursday, October 15'), findsOneWidget);
      final list = find.byType(Dialog);
      expect(find.descendant(of: list, matching: find.textContaining('Event m')), findsNWidgets(12));
      await t.tap(find.descendant(of: list, matching: find.text('Event m11')));
      await t.pumpAndSettle();
      expect(tapped, ['m0', 'm11']);
      expect(find.byType(Dialog), findsNothing);
      await t.tap(find.text('20'));
      expect(days, [DateTime(2026, 10, 20)]);
      expect(t.takeException(), isNull);
    });

    group('a task', () {
      Future<(List<String>, List<String>)> pumpTasks(WidgetTester t, List<CalendarEvent> events) async {
        final opened = <String>[], checked = <String>[];
        await _pump(t, MonthView(month: month, events: events, onDayTap: (_) {}, onEventTap: (e) => opened.add(e.id), onTaskTap: (e) => checked.add(e.id)));
        return (opened, checked);
      }

      testWidgets('is faded like something with times, with a circle for its bar', (t) async {
        const blue = Color(0xFF4285F4);
        await pumpTasks(t, [
          _task('Essay', thu, color: blue),
          CalendarEvent(
              id: 'timed', calendar: _cal, title: 'Timed', description: '', location: '', start: thu.add(const Duration(hours: 9)), end: thu.add(const Duration(hours: 10)), allDay: false, color: blue),
        ]);
        Color fill(String title) => t.widget<Material>(find.ancestor(of: find.textContaining(title), matching: find.byType(Material)).first).color!;
        expect(fill('Essay'), fill('Timed'));
        final tile = find.ancestor(of: find.text('Essay'), matching: find.byType(Material)).first;
        expect(find.descendant(of: tile, matching: find.byType(TaskCircle)), findsOneWidget);
        expect(find.byType(TaskCircle), findsOneWidget, reason: 'only tasks have one');
        expect(t.takeException(), isNull);
      });

      testWidgets('its circle checks it off and its tile opens it', (t) async {
        final (opened, checked) = await pumpTasks(t, [_task('Essay', thu)]);
        await t.tap(find.byType(TaskCircle));
        expect(checked, ['Essay']);
        expect(opened, isEmpty, reason: 'the circle doesn’t open it');
        await t.tap(find.text('Essay'));
        expect(opened, ['Essay']);
        expect(checked, ['Essay'], reason: 'the tile doesn’t check it');
      });

      testWidgets('once done, the circle is checked and the title has no ✓ as well', (t) async {
        await pumpTasks(t, [_task('Essay', thu, done: true)]);
        expect(find.byIcon(Icons.check), findsOneWidget);
        expect(find.text('Essay'), findsOneWidget);
      });

      testWidgets('can be checked off in the list of “+N more”, and shows it there', (t) async {
        final (opened, checked) = await pumpTasks(t, [for (var i = 0; i < 12; i++) _task('Task $i', thu)]);
        await t.tap(find.textContaining('more'));
        await t.pumpAndSettle();
        final circle = find.descendant(of: find.byType(Dialog), matching: find.byType(TaskCircle)).first;
        await t.tap(circle);
        await t.pumpAndSettle();
        expect(checked, ['Task 0']);
        expect(opened, isEmpty);
        expect(find.byType(Dialog), findsOneWidget, reason: 'it stays open');
        expect(find.descendant(of: find.byType(Dialog), matching: find.byIcon(Icons.check)), findsOneWidget);
        expect(t.takeException(), isNull);
      });

      testWidgets('on a phone: its circle checks it off and its card opens it', (t) async {
        final opened = <String>[], checked = <String>[];
        final now = DateTime.now();
        await _pump(
          t,
          MonthAgenda(month: now, events: [_task('Essay', dayStart(now))], onEventTap: (e) => opened.add(e.id), onTaskTap: (e) => checked.add(e.id), onNewEvent: (_) {}),
          size: const Size(412, 800),
        );
        await t.tap(find.byType(TaskCircle));
        expect(checked, ['Essay']);
        expect(opened, isEmpty);
        await t.tap(find.text('Essay'));
        expect(opened, ['Essay']);
        expect(t.takeException(), isNull);
      });

      testWidgets('on a phone: in the same order as the grid', (t) async {
        final now = dayStart(DateTime.now());
        await _pump(
          t,
          MonthAgenda(
            month: now,
            events: [
              _task('due 1pm', now, due: now.add(const Duration(hours: 13))),
              _event('9am', now.add(const Duration(hours: 9)), now.add(const Duration(hours: 10))),
              _task('no time', now),
              _event('holiday', now, addDays(now, 1), allDay: true),
            ],
            onEventTap: (_) {},
            onNewEvent: (_) {},
          ),
          size: const Size(412, 800),
        );
        final tops = [for (final s in ['Event holiday', 'no time', 'Event 9am', 'due 1pm']) t.getTopLeft(find.text(s)).dy];
        expect(tops, [...tops]..sort());
      });
    });

    testWidgets('something across days is one piece over the lines, at one height', (t) async {
      final sunday = DateTime(2026, 10, 11);
      await pump(t, [_event('long', sunday.add(const Duration(days: 1)), sunday.add(const Duration(days: 4)), allDay: true)]);
      final bar = t.getRect(find.ancestor(of: find.text('Event long'), matching: find.byType(Material)).first);
      expect(bar.width, greaterThan(1400 / 7 * 3 - 5));
      expect(t.takeException(), isNull);
    });
  });

  testWidgets('flipped timeline renders with system text scaling (1.15x) without overflow', (tester) async {
    final now = DateTime.now();
    final today = dayStart(now);
    final sunday = addDays(today, -(today.weekday % 7));
    final days = [for (var i = 0; i < 7; i++) addDays(sunday, i)];
    final events = [
      _event('today1', today.add(const Duration(hours: 9)), today.add(const Duration(hours: 10))),
      _event('today2', today.add(const Duration(hours: 10)), today.add(const Duration(hours: 11))),
      _event('allDayToday', today, addDays(today, 1), allDay: true),
      _event('sun1', sunday.add(const Duration(hours: 14)), sunday.add(const Duration(hours: 15, minutes: 30))),
    ];

    for (final scale in [1.15, 1.3, 1.5]) {
      final errors = <String>[];
      final old = FlutterError.onError;
      FlutterError.onError = (d) => errors.add(d.exceptionAsString().split('\n').first);

      tester.view.physicalSize = const Size(2112, 1320); // Android tablet landscape
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale), size: const Size(2112, 1320)),
          child: Scaffold(
            body: FlippedTimeline(
              days: days,
              events: events,
              hourWidth: 80,
              onEventTap: (_) {},
              onSlotTap: (_, {bool allDay = false}) {},
            ),
          ),
        ),
      ));
      await tester.pump();
      FlutterError.onError = old;
      expect(errors, isEmpty, reason: 'RenderFlex overflow occurred at scale $scale: $errors');
    }
  });
}

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/calendar/calendar_models.dart';
import 'package:optimizer/calendar/calendar_history.dart';
import 'package:optimizer/calendar/calendar_page.dart';
import 'package:optimizer/calendar/calendar_service.dart';
import 'package:optimizer/calendar/event_editor.dart';
import 'package:optimizer/calendar/flipped_timeline.dart';
import 'package:optimizer/calendar/history_page.dart';
import 'package:optimizer/theme.dart';

import 'preview/calendar_preview_test.dart' show loadFonts, skipPreview;
import 'preview/pages_preview_test.dart' show shot;

class _Service extends CalendarService {
  _Service() : super('test');

  final saved = <String, bool>{};

  @override
  Future<void> loadRange(DateTime from, DateTime to, {bool force = false, bool quiet = false}) async {}

  @override
  Future<void> saveEventHidden(CalendarEvent e, bool hide) async => saved[e.key] = hide;

  @override
  Future<void> saveHistory(HistoryEntry e) async {}
}

void main() {
  final cal =
      GoogleCalendar(id: 'p', accountEmail: 'me@example.com', name: 'Personal', color: const Color(0xFF4285F4), primary: true, accessRole: 'owner');
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final event = CalendarEvent(
      id: 'e1',
      calendar: cal,
      title: 'Dentist',
      description: '',
      location: '',
      start: today.add(const Duration(hours: 9)),
      end: today.add(const Duration(hours: 10)),
      allDay: false,
      color: cal.color);

  _Service service() => _Service()
    ..accounts.add(GoogleAccount(email: 'me@example.com'))
    ..calendars.add(cal)
    ..debugAddEvent(event);

  List<CalendarEvent> shown(_Service s) => s.eventsBetween(today, today.add(const Duration(days: 1)));

  group('hiding an event', () {
    test('it leaves the calendar and comes back, and nothing is deleted', () async {
      final s = service();
      expect(shown(s).single.title, 'Dentist');
      await s.hideEvent(event);
      expect(s.saved[event.key], isTrue);
      expect(shown(s), isEmpty);
      expect(s.hiddenEventCount, 1);
      s.setShowHiddenEvents(true);
      final faint = shown(s).single;
      expect(faint.title, 'Dentist', reason: 'all still there');
      expect(faint.color.a, lessThan(0.6), reason: 'and faint, to tell it from the rest');
      expect(s.isEventHidden(faint), isTrue);
      await s.unhideEvent(event);
      expect(s.saved[event.key], isFalse);
      expect(s.hiddenEventCount, 0);
      expect(s.showHiddenEvents, isFalse, reason: 'nothing left to show');
      expect(shown(s).single.color, cal.color);
    });

    test('undo brings it back', () async {
      final s = service();
      await s.hideEvent(event);
      expect(s.lastChange?.label, contains('Dentist'));
      await s.undoLast();
      expect(s.hiddenEventCount, 0);
    });

    Future<_Service> details(WidgetTester t, {bool hidden = false}) async {
      final s = service();
      if (hidden) await s.hideEvent(event);
      t.view.physicalSize = const Size(1200, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
            body: Builder(builder: (context) => TextButton(onPressed: () => showEventDetails(context, s, event), child: const Text('Open')))),
      ));
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('More'));
      await t.pumpAndSettle();
      return s;
    }

    testWidgets('it’s in the event’s ⋯ menu', (t) async {
      final s = await details(t);
      await t.tap(find.text('Hide from my calendar'));
      await t.pumpAndSettle();
      expect(s.isEventHidden(event), isTrue);
      expect(find.text('Dentist'), findsNothing, reason: 'the popup closes');
    });

    testWidgets('a hidden one offers to come back', (t) async {
      final s = await details(t, hidden: true);
      await t.tap(find.text('Show on my calendar'));
      await t.pumpAndSettle();
      expect(s.isEventHidden(event), isFalse);
    });
  });

  group('the calendar page', () {
    Future<_Service> page(WidgetTester t, {Size size = const Size(1700, 900), bool hidden = false}) async {
      final s = service();
      if (hidden) await s.hideEvent(event);
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(theme: buildTheme(), home: CalendarPage(service: s)));
      await t.pump(const Duration(milliseconds: 100));
      return s;
    }

    testWidgets('the header goes panels, then Today, then Week and Month, then everything else', (t) async {
      await page(t);
      double left(Finder f) => t.getTopLeft(f).dx;
      double right(Finder f) => t.getTopRight(f).dx;
      final toggle = find.text('To-do').first;
      final previous = find.byTooltip('Previous (K)'), next = find.byTooltip('Next (J)');
      final week = find.text('Week'), month = find.text('Month');
      final create = find.byTooltip('New event (C)');
      expect(right(toggle), lessThan(left(previous)));
      expect(left(find.widgetWithText(TextButton, 'Today')), greaterThan(right(previous)));
      expect(right(next), lessThan(left(week)));
      expect(right(week), lessThan(left(month)));
      expect(right(month), lessThan(left(create)));
      expect(left(previous) - right(toggle), lessThan(40), reason: 'right beside them');
      expect(t.takeException(), isNull);
    });

    testWidgets('the buttons after the title stay put, whatever the month, in Week and in Month', (t) async {
      await page(t);
      final seen = <double>[];
      for (final view in ['Month', 'Week']) {
        await t.tap(find.text(view));
        await t.pump(const Duration(milliseconds: 100));
        final spots = <double>{};
        for (var n = 0; n < 13; n++) {
          spots.add(t.getTopLeft(find.byTooltip('Previous (K)')).dx);
          await t.tap(find.byTooltip('Next (J)'));
          await t.pump(const Duration(milliseconds: 100));
        }
        expect(spots, hasLength(1), reason: 'in $view, not a pixel');
        seen.add(spots.single);
      }
      // Week has more buttons, so short of room its row shrinks a touch.
      expect((seen.first - seen.last).abs(), lessThan(2), reason: 'and no jump between the two');
      expect(t.takeException(), isNull);
    });

    for (final size in const [Size(1100, 800), Size(800, 800)]) {
      testWidgets('it fits ${size.width.toInt()} wide', (t) async {
        await page(t, size: size);
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('with nothing hidden, there’s no tile for it', (t) async {
      await page(t);
      expect(find.textContaining('Show hidden events'), findsNothing);
    });

    testWidgets('with something hidden, a tile of its own shows them', (t) async {
      final s = await page(t, hidden: true);
      expect(find.text('Show hidden events (1)'), findsOneWidget);
      expect(s.showHiddenEvents, isFalse);
      await t.tap(find.text('Show hidden events (1)'));
      await t.pump();
      expect(s.showHiddenEvents, isTrue);
    });

    testWidgets('on a calendar’s row, the ⋯ is just dots, level with the name', (t) async {
      await page(t);
      final name = find.text('Personal');
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: t.getCenter(name));
      await t.pump(const Duration(milliseconds: 300));
      final row = find.ancestor(of: name, matching: find.byType(Stack)).first;
      final icon = find.descendant(of: row, matching: find.byIcon(Icons.more_horiz));
      expect(icon, findsOneWidget);
      expect((t.getCenter(icon).dy - t.getCenter(name).dy).abs(), lessThan(1), reason: 'centered top to bottom with the text');
      expect(find.ancestor(of: icon, matching: find.byWidgetPredicate((w) => w is Material && w.shape is CircleBorder)), findsNothing,
          reason: 'no circle around it');
      expect(t.getRect(icon).bottom, lessThanOrEqualTo(t.getRect(row).bottom), reason: 'nothing cut off');
      await mouse.removePointer();
    });
  });

  group('hovering on the calendar', () {
    final day = DateTime(today.year, today.month, today.day);
    CalendarEvent at(String title, double start, double hours) => CalendarEvent(
        id: title,
        calendar: cal,
        title: title,
        description: '',
        location: '',
        start: day.add(Duration(minutes: (start * 60).round())),
        end: day.add(Duration(minutes: ((start + hours) * 60).round())),
        allDay: false,
        color: cal.color);

    // Small enough that the whole day's in view, whatever time it is now:
    // the calendar opens scrolled to the current time.
    Future<List<String>> timeline(WidgetTester t, List<CalendarEvent> events, {double hourWidth = 40}) async {
      t.view.physicalSize = const Size(1700, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final tapped = <String>[];
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: FlippedTimeline(days: [day], events: events, hourWidth: hourWidth, onEventTap: (e) => tapped.add(e.title))),
      ));
      await t.pump();
      return tapped;
    }

    Future<TestGesture> hover(WidgetTester t, Offset at) async {
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: at);
      await t.pump(const Duration(milliseconds: 200));
      addTearDown(mouse.removePointer);
      return mouse;
    }

    testWidgets('hovering a big entry leaves the small one inside it reachable', (t) async {
      final tapped = await timeline(t, [at('Big', 1, 6), at('Small', 3, 1)]);
      Rect tile(String title) => t.getRect(find.byWidgetPredicate((w) => w is EventBlock && w.event.title == title));
      final big = tile('Big'), small = tile('Small');
      expect(small.left, greaterThan(big.left));
      expect(small.right, lessThan(big.right));
      await hover(t, Offset(big.left + 8, big.center.dy));
      final inside = small.center;
      await t.tapAt(inside);
      await t.pump();
      expect(tapped, ['Small'], reason: 'the big one didn’t come in front of it');
    });

    testWidgets('a tiny entry shows its whole name in a thin strip while you’re on it', (t) async {
      final tapped = await timeline(t, [at('Take the morning medicine', 2, 0.25)]);
      final tile = t.getRect(find.byType(EventBlock));
      expect(tile.width, lessThan(40));
      final strip = find.byKey(const ValueKey('tiny-title'));
      expect(strip, findsNothing, reason: 'only while hovering');
      final mouse = await hover(t, tile.center);
      expect(strip, findsOneWidget);
      expect(find.descendant(of: strip, matching: find.text('Take the morning medicine')), findsOneWidget);
      expect(t.getSize(strip).height, lessThanOrEqualTo(22), reason: 'really thin');
      expect(t.getSize(strip).width, greaterThan(tile.width));
      // Part of the tile: starting where it does, in its colors, with no shadow of its own.
      expect([t.getTopLeft(strip).dx, t.getTopLeft(strip).dy], [tile.left, tile.top]);
      final look = t
          .widget<Container>(find.descendant(of: strip, matching: find.byWidgetPredicate((w) => w is Container && w.decoration != null)).first)
          .decoration as BoxDecoration;
      expect(look.color, eventFill(t.widget<EventBlock>(find.byType(EventBlock)).event, open: true));
      expect(look.boxShadow, isNull);
      expect((look.borderRadius as BorderRadius).bottomLeft, Radius.zero, reason: 'the tile carries on below');
      final name = t.widget<Text>(find.descendant(of: strip, matching: find.text('Take the morning medicine')));
      expect(name.style!.fontSize, 13, reason: 'the same as a tile’s title');
      // It can't get in the way of a click.
      await t.tapAt(tile.center);
      await t.pump();
      expect(tapped, ['Take the morning medicine']);
      await mouse.moveTo(const Offset(1600, 800));
      await t.pump(const Duration(milliseconds: 200));
      expect(strip, findsNothing, reason: 'gone once you move off');
      expect(t.takeException(), isNull);
    });

    testWidgets('a clipped-off strip stays on screen at the end of the day', (t) async {
      await timeline(t, [at('Something very late with a long long name', 23.5, 0.25)], hourWidth: 50);
      final tile = t.getRect(find.byType(EventBlock));
      await hover(t, tile.center);
      final strip = t.getRect(find.byKey(const ValueKey('tiny-title')));
      expect(strip.width, greaterThan(tile.width));
      expect(strip.left, lessThan(tile.left), reason: 'it reaches back rather than run off the end');
      expect((strip.right - tile.right).abs(), lessThan(1), reason: 'ending where the tile does');
      final name = t.getRect(find.text('Something very late with a long long name'));
      expect(name.right, lessThanOrEqualTo(tile.left), reason: 'the name stops before the tile');
      expect(t.takeException(), isNull);
    });

    for (final (where, start) in [('reaching right', 2.0), ('reaching left', 23.5)]) {
      testWidgets('the color strip runs straight up from the tile into the name, $where', (t) async {
        await timeline(t, [at('Something with a long long name', start, 0.25)], hourWidth: 50);
        final block = find.byType(EventBlock);
        await hover(t, t.getCenter(block));
        final inTile = t.getRect(find.descendant(of: block, matching: find.byWidgetPredicate((w) => w is Container && w.color == cal.color)));
        final inName = t.getRect(find.descendant(
            of: find.byKey(const ValueKey('tiny-title')), matching: find.byWidgetPredicate((w) => w is ColoredBox && w.color == cal.color)));
        expect([inName.left, inName.right], [inTile.left, inTile.right], reason: 'not a pixel to either side');
        expect(inName.top, inTile.top);
        expect(inName.bottom, lessThan(inTile.bottom));
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('a tiny entry is tinted with a colored edge, like any other, not solid', (t) async {
      await timeline(t, [at('Tiny', 2, 0.25)]);
      final tile = find.byType(EventBlock);
      expect(t.getSize(tile).width, lessThan(22));
      final filled = find.descendant(of: tile, matching: find.byWidgetPredicate((w) => w is Container && w.color == cal.color));
      expect(filled, findsOneWidget);
      expect(t.getSize(filled).width, lessThan(6), reason: 'the edge, not the whole tile');
    });

    testWidgets('hovering an entry brings up no white box and no white outline', (t) async {
      final lunch = at('Lunch', 12, 2);
      await timeline(t, [lunch]);
      final tile = find.byType(EventBlock);
      await hover(t, t.getCenter(tile));
      await t.pump(const Duration(seconds: 2));
      expect(find.descendant(of: tile, matching: find.byType(Tooltip)), findsNothing);
      final shape = t.widget<Material>(find.descendant(of: tile, matching: find.byType(Material)).first).shape as RoundedRectangleBorder;
      expect(shape.side.color, eventHoverEdge(lunch));
    });

    testWidgets('an entry with room for its name gets no strip', (t) async {
      await timeline(t, [at('Lunch', 12, 2)]);
      final tile = t.getRect(find.byType(EventBlock));
      await hover(t, tile.center);
      expect(find.byKey(const ValueKey('tiny-title')), findsNothing);
    });

    testWidgets('nor does a tiny one whose name already fits', (t) async {
      expect(titleCutOff('OK', 60), isFalse);
      expect(titleCutOff('Take the morning medicine', 40), isTrue);
      expect(titleCutOff('Take the morning medicine', 200), isFalse, reason: 'not super small: it just trails off');
    });
  });

  group('deleting a Google event asks where', () {
    Future<_Editing> open(WidgetTester t, {bool writable = true}) async {
      final s = _Editing()..writable = writable;
      s
        ..accounts.add(GoogleAccount(email: 'me@example.com'))
        ..calendars.add(cal)
        ..debugAddEvent(event);
      t.view.physicalSize = const Size(1200, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
            body: Builder(builder: (context) => TextButton(onPressed: () => showEventDetails(context, s, event), child: const Text('Open')))),
      ));
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('More'));
      await t.pumpAndSettle();
      await t.tap(find.text('Delete event'));
      await t.pumpAndSettle();
      return s;
    }

    testWidgets('in Google too', (t) async {
      final s = await open(t);
      await t.tap(find.text('Delete in Google too'));
      await t.pumpAndSettle();
      expect(s.calls, ['deleteGoogleEvent']);
    });

    testWidgets('only in Optimizer leaves Google alone, and stays gone', (t) async {
      final s = await open(t);
      await t.tap(find.text('Only in Optimizer'));
      await t.pumpAndSettle();
      expect(s.calls, isEmpty);
      expect(s.eventsBetween(today, today.add(const Duration(days: 1))), isEmpty);
      s.setShowHiddenEvents(true);
      expect(s.eventsBetween(today, today.add(const Duration(days: 1))), isEmpty, reason: 'deleted isn’t hidden');
    });

    testWidgets('cancel does nothing', (t) async {
      final s = await open(t);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(s.calls, isEmpty);
      expect(s.eventsBetween(today, today.add(const Duration(days: 1))), isNotEmpty);
    });

    testWidgets('a read-only calendar can only be deleted here', (t) async {
      await open(t, writable: false);
      expect(find.text('Delete in Google too'), findsNothing);
      expect(find.text('Only in Optimizer'), findsOneWidget);
    });
  });

  group('history', () {
    _Editing service() {
      final s = _Editing();
      return s
        ..accounts.add(GoogleAccount(email: 'me@example.com'))
        ..calendars.add(cal)
        ..debugAddEvent(event);
    }

    EventDraft moved() => EventDraft(
        calendarKey: cal.key,
        title: 'Dentist 2',
        start: event.start.add(const Duration(hours: 1)),
        end: event.end.add(const Duration(hours: 1)),
        allDay: false,
        location: 'Main St');

    test('a change to Google is written down with what it was, and reverts there', () async {
      final s = service();
      await s.saveEvent(moved(), original: event);
      final e = s.history.single;
      expect([e.action, e.google, e.title], [HistoryAction.changed, true, 'Dentist 2']);
      expect(e.details.join(' / '), allOf(contains('Name: Dentist to Dentist 2'), contains('When:'), contains('Location: Main St')));
      s.calls.clear();
      await s.revertHistory(e);
      expect(s.calls, ['saveGoogleEvent']);
      expect((s.lastBody!['body'] as Map)['summary'], 'Dentist');
      expect(e.reverted, isTrue);
      expect(s.history.length, 1, reason: 'reverting isn’t another change to revert');
    });

    test('a Google delete comes back', () async {
      final s = service();
      await s.deleteEvent(event);
      final e = s.history.single;
      expect(e.action, HistoryAction.deleted);
      s.calls.clear();
      await s.revertHistory(e);
      expect(s.calls, ['saveGoogleEvent']);
      expect(s.lastBody!.containsKey('eventId'), isFalse, reason: 'made again');
    });

    test('adding one can be taken back', () async {
      final s = service();
      await s.saveEvent(EventDraft(calendarKey: cal.key, title: 'New', start: event.start, end: event.end, allDay: false));
      s.calls.clear();
      await s.revertHistory(s.history.single);
      expect(s.calls, ['deleteGoogleEvent']);
    });

    test('deleted only in Optimizer: back without touching Google', () async {
      final s = service();
      await s.removeEventHere(event);
      expect(s.history.single.google, isFalse);
      expect(shownIn(s, today), isEmpty);
      await s.revertHistory(s.history.single);
      expect(shownIn(s, today), isNotEmpty);
      expect(s.calls, isEmpty);
    });

    test('hiding goes in too, and undo marks it as put back', () async {
      final s = service();
      await s.hideEvent(event);
      expect(s.history.single.action, HistoryAction.hid);
      await s.undoLast();
      expect(s.history.single.reverted, isTrue);
      expect(s.history.length, 1);
    });

    test('reverting takes the change off undo, so it can’t happen twice', () async {
      final s = service();
      await s.hideEvent(event);
      await s.revertHistory(s.history.single);
      expect(s.lastChange, isNull);
    });

    test('kept in Optimizer only says so', () {
      final e = HistoryEntry(id: '1', at: DateTime.now(), action: HistoryAction.keptHere, title: 'X');
      expect(e.revertWarning, contains('Optimizer only'));
      expect(HistoryEntry(id: '1', at: DateTime.now(), action: HistoryAction.changed, title: 'X', google: true).revertWarning,
          contains('Google Calendar'));
    });

    test('saved and read back', () {
      final e = HistoryEntry(
          id: '1',
          at: DateTime(2026, 11, 3, 9),
          action: HistoryAction.changed,
          title: 'X',
          google: true,
          before: snapshotOf(event),
          after: snapshotOf(event),
          reverted: true);
      final back = HistoryEntry.fromDoc('1', e.toJson());
      expect([back.at, back.action, back.title, back.google, back.reverted], [e.at, HistoryAction.changed, 'X', true, true]);
      expect(back.before!['title'], 'Dentist');
    });

    testWidgets('the page lists what changed, by day, and asks before reverting', (t) async {
      final s = service();
      await s.saveEvent(moved(), original: event);
      t.view.physicalSize = const Size(1200, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(theme: buildTheme(), home: CalendarHistoryPage(service: s)));
      await t.pump();
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Dentist 2'), findsOneWidget);
      expect(find.textContaining('Google Calendar and Optimizer'), findsOneWidget);
      expect(find.textContaining('30 days'), findsOneWidget);
      await t.tap(find.text('Revert'));
      await t.pumpAndSettle();
      expect(find.textContaining('also changes it in Google Calendar'), findsOneWidget);
      s.calls.clear();
      await t.tap(find.widgetWithText(FilledButton, 'Revert'));
      await t.pumpAndSettle();
      expect(s.calls, ['saveGoogleEvent']);
      expect(find.text('Reverted'), findsOneWidget);
      expect(find.text('Revert'), findsNothing);
    });

    testWidgets('with nothing yet, it says so', (t) async {
      await t.pumpWidget(MaterialApp(theme: buildTheme(), home: CalendarHistoryPage(service: service())));
      await t.pump();
      expect(find.textContaining('Nothing yet'), findsOneWidget);
    });
  });

  testWidgets(skip: skipPreview, 'history_and_tiny', (t) async {
    await t.runAsync(loadFonts);
    t.view.physicalSize = const Size(1100, 620);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final s = _Editing()
      ..accounts.add(GoogleAccount(email: 'me@example.com'))
      ..calendars.add(cal)
      ..debugAddEvent(event);
    await s.saveEvent(
        EventDraft(
            calendarKey: cal.key,
            title: 'Dentist',
            start: event.start.add(const Duration(hours: 1)),
            end: event.end.add(const Duration(hours: 1)),
            allDay: false,
            location: 'Main St Dental'),
        original: event);
    await s.removeEventHere(event);
    await s.hideEvent(event);
    await t.pumpWidget(MaterialApp(
        theme: buildTheme(),
        debugShowCheckedModeBanner: false,
        builder: (_, c) => RepaintBoundary(key: const ValueKey('shot'), child: c!),
        home: CalendarHistoryPage(service: s)));
    await t.pump();
    await shot(t, 'calendar_history');
    final day = today;
    CalendarEvent at(String title, double start, double hours, Color c) => CalendarEvent(
        id: title,
        calendar: cal,
        title: title,
        description: '',
        location: '',
        start: day.add(Duration(minutes: (start * 60).round())),
        end: day.add(Duration(minutes: ((start + hours) * 60).round())),
        allDay: false,
        color: c);
    await t.pumpWidget(MaterialApp(
        theme: buildTheme(),
        debugShowCheckedModeBanner: false,
        builder: (_, c) => RepaintBoundary(key: const ValueKey('shot'), child: c!),
        home: Scaffold(
            body: FlippedTimeline(days: [
          day
        ], events: [
          at('Long block of work', 1, 6, const Color(0xFF4285F4)),
          at('Inside it', 3, 1, const Color(0xFF34D399)),
          at('Take the morning medicine', 8, 0.25, const Color(0xFFFB7185)),
          at('Next thing', 8.4, 1.5, const Color(0xFFFBBF24))
        ], hourWidth: 96, onEventTap: (_) {}))));
    await t.pump();
    final tiny = t.getCenter(find.byWidgetPredicate((w) => w is EventBlock && w.event.title.startsWith('Take')));
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tiny);
    await t.pump(const Duration(milliseconds: 250));
    await shot(t, 'tiny_title');
    await mouse.removePointer();
  });

  group('backing out of an editor', () {
    Future<void> editor(WidgetTester t, {_Editing? service}) async {
      final s = (service ?? _Editing())
        ..accounts.add(GoogleAccount(email: 'me@example.com'))
        ..calendars.add(cal);
      t.view.physicalSize = const Size(1400, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
            body:
                Builder(builder: (context) => TextButton(onPressed: () => showEventEditor(context, s, existing: event), child: const Text('Open')))),
      ));
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
    }

    testWidgets('with nothing changed, it just goes', (t) async {
      await editor(t);
      await t.tap(find.byTooltip('Back'));
      await t.pumpAndSettle();
      expect(find.text('Discard your changes?'), findsNothing);
      expect(find.text('Edit event'), findsNothing);
    });

    testWidgets('with a change, Back asks, and can stay', (t) async {
      await editor(t);
      await t.enterText(find.widgetWithText(TextField, 'Title'), 'Dentist moved');
      await t.pump();
      await t.tap(find.byTooltip('Back'));
      await t.pumpAndSettle();
      expect(find.text('Discard your changes?'), findsOneWidget);
      await t.tap(find.text('Keep editing'));
      await t.pumpAndSettle();
      expect(find.text('Edit event'), findsOneWidget);
      expect(find.text('Dentist moved'), findsOneWidget);
    });

    testWidgets('Cancel asks the same, and Discard leaves', (t) async {
      await editor(t);
      await t.enterText(find.widgetWithText(TextField, 'Title'), 'Dentist moved');
      await t.pump();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(FilledButton, 'Discard'));
      await t.pumpAndSettle();
      expect(find.text('Edit event'), findsNothing);
    });

    testWidgets('changing it back to how it was isn’t a change', (t) async {
      await editor(t);
      await t.enterText(find.widgetWithText(TextField, 'Title'), 'Dentist moved');
      await t.pump();
      await t.enterText(find.widgetWithText(TextField, 'Title'), 'Dentist');
      await t.pump();
      await t.tap(find.byTooltip('Back'));
      await t.pumpAndSettle();
      expect(find.text('Discard your changes?'), findsNothing);
    });

    testWidgets('saving doesn’t ask about discarding', (t) async {
      final s = _Editing();
      await editor(t, service: s);
      await t.enterText(find.widgetWithText(TextField, 'Title'), 'Dentist moved');
      await t.pump();
      await t.tap(find.text('Save changes'));
      await t.pumpAndSettle();
      await t.tap(find.text('Save to Google'));
      await t.pumpAndSettle();
      expect(find.text('Discard your changes?'), findsNothing);
      expect(find.text('Edit event'), findsNothing);
      expect(s.calls, ['saveGoogleEvent']);
    });

    testWidgets('saving with nothing changed asks nothing at all', (t) async {
      final s = _Editing();
      await editor(t, service: s);
      await t.tap(find.text('Save changes'));
      await t.pumpAndSettle();
      expect(find.text('Save to Google Calendar too?'), findsNothing);
      expect(s.calls, isEmpty);
    });
  });
}

List<CalendarEvent> shownIn(CalendarService s, DateTime day) => s.eventsBetween(day, day.add(const Duration(days: 1)));

/// A service with a pretend server.
class _Editing extends _Service {
  final calls = <String>[];
  Map<String, dynamic>? lastBody;
  bool writable = true;

  @override
  bool canEdit(GoogleCalendar c) => writable;

  @override
  Future<void> saveHistory(HistoryEntry e) async {}

  @override
  Future<void> saveEventRemoved(CalendarEvent e, bool remove) async {}

  @override
  Future<Object?> callServer(String name, Map<String, dynamic> data) async {
    calls.add(name);
    lastBody = data;
    return {'id': 'saved'};
  }
}

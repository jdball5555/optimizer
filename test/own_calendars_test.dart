import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/ai/ai_service.dart';
import 'package:optimizer/ai/assistant_tools.dart';
import 'package:optimizer/calendar/calendar_history.dart';
import 'package:optimizer/calendar/calendar_models.dart';
import 'package:optimizer/calendar/calendar_page.dart';
import 'package:optimizer/calendar/calendar_service.dart';
import 'package:optimizer/calendar/canvas.dart';
import 'package:optimizer/theme.dart';
import 'package:optimizer/util/fields.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview/calendar_preview_test.dart' show loadFonts, skipPreview;
import 'preview/pages_preview_test.dart' show FeedService, shot;

/// The real service, with nothing behind it: what it would write, it notes.
class _Service extends CalendarService {
  _Service() : super('test');
  final server = <String>[];
  final events = <String, Map<String, dynamic>?>{};
  final cals = <String, Map<String, dynamic>?>{};

  @override
  Future<void> writeOwnCalendar(String id, Map<String, dynamic>? data) async => cals[id] = data;
  @override
  Future<void> writeOwnEvent(String id, Map<String, dynamic>? data) async => events[id] = data;
  @override
  Future<void> saveHistory(HistoryEntry e) async {}
  @override
  Future<Object?> callServer(String name, Map<String, dynamic> data) async {
    server.add(name);
    return {'id': 'g1'};
  }
}

class _Ai extends ChangeNotifier implements AiService {
  @override
  Set<AiShare> shared = AiShare.values.toSet();
  @override
  Set<AiAct> acts = {AiAct.calendar};
  @override
  bool confirmChanges = false;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final day = DateTime(2026, 11, 10);
  EventDraft draft(GoogleCalendar c, {String title = 'Gym'}) =>
      EventDraft(calendarKey: c.key, title: title, start: day.add(const Duration(hours: 9)), end: day.add(const Duration(hours: 10)), allDay: false);
  List<CalendarEvent> shown(CalendarService s) => s.eventsBetween(day, addDays(day, 1));

  group('a calendar of your own', () {
    test('its events are shown, and nothing goes to Google', () async {
      final s = _Service();
      final c = await s.createOwnCalendar('Home', Colors.teal);
      expect(c.isOwn, isTrue);
      expect(s.canEdit(c), isTrue, reason: 'with no Google account linked at all');
      await s.saveEvent(draft(c));
      expect(shown(s).single.title, 'Gym');
      expect(shown(s).single.calendar.key, c.key);
      expect(s.server, isEmpty);
    });

    test('an all-day event carries its days, so it lands on them in any time zone', () async {
      final s = _Service();
      final c = await s.createOwnCalendar('Home', Colors.teal);
      await s.saveEvent(EventDraft(calendarKey: c.key, title: 'Trip', start: day, end: addDays(day, 2), allDay: true));
      final doc = s.events.values.single!;
      expect([doc['date'], doc['endDate']], ['2026-11-10', '2026-11-12']);
      expect(shown(s).single.allDay, isTrue);
    });

    test('comes before synced calendars, without taking over as the default', () async {
      final s = _Service();
      s.accounts.add(GoogleAccount(email: 'me@example.com'));
      final google = GoogleCalendar(id: 'p', accountEmail: 'me@example.com', name: 'Me', color: Colors.blue, primary: true, accessRole: 'owner');
      s.calendars.add(google);
      await s.createOwnCalendar('Home', Colors.teal);
      expect(s.writableCalendars.map((x) => x.name), ['Home', 'Me']);
      expect(s.defaultCalendar?.key, google.key);
    });

    test('is the default when there’s nothing else', () async {
      final s = _Service();
      final c = await s.createOwnCalendar('Home', Colors.teal);
      expect(s.defaultCalendar?.key, c.key);
    });

    test('changes and deletes of its events can be undone', () async {
      final s = _Service();
      final c = await s.createOwnCalendar('Home', Colors.teal);
      await s.saveEvent(draft(c));
      await s.saveEvent(draft(c, title: 'Run'), original: shown(s).single);
      expect(shown(s).single.title, 'Run');
      await s.undoLast();
      expect(shown(s).single.title, 'Gym');
      await s.deleteEvent(shown(s).single);
      expect(shown(s), isEmpty);
      await s.undoLast();
      expect(shown(s).single.title, 'Gym');
      expect(s.server, isEmpty);
    });

    test('can be renamed and recolored, and that can be undone', () async {
      final s = _Service();
      final c = await s.createOwnCalendar('Home', Colors.teal);
      await s.updateOwnCalendar(c, name: 'Family', color: const Color(0xFF3B82F6));
      expect(s.ownCalendars.single.name, 'Family');
      expect(s.ownCalendars.single.color.toARGB32(), 0xFF3B82F6);
      await s.undoLast();
      expect(s.ownCalendars.single.name, 'Home');
    });

    test('deleting one takes its events with it, as one thing to undo', () async {
      final s = _Service();
      final c = await s.createOwnCalendar('Home', Colors.teal);
      final other = await s.createOwnCalendar('Work', Colors.orange);
      await s.saveEvent(draft(c));
      await s.saveEvent(draft(other, title: 'Standup'));
      expect(s.ownEventCount(c), 1);
      await s.deleteOwnCalendar(c);
      expect(s.ownCalendars.map((x) => x.name), ['Work']);
      expect(shown(s).map((e) => e.title), ['Standup']);
      expect(s.cals[c.id], isNull);
      await s.undoLast();
      expect(s.ownCalendars.map((x) => x.name), ['Home', 'Work']);
      expect(shown(s).map((e) => e.title), unorderedEquals(['Standup', 'Gym']));
    });

    group('moving an event to or from Google', () {
      Future<(_Service, GoogleCalendar, GoogleCalendar)> both({String role = 'owner'}) async {
        final s = _Service();
        s.accounts.add(GoogleAccount(email: 'me@example.com'));
        final google = GoogleCalendar(id: 'p', accountEmail: 'me@example.com', name: 'Me', color: Colors.blue, primary: true, accessRole: role);
        s.calendars.add(google);
        return (s, await s.createOwnCalendar('Home', Colors.teal), google);
      }

      test('from yours to Google: made there, gone from here', () async {
        final (s, mine, google) = await both();
        await s.saveEvent(draft(mine));
        await s.saveEvent(draft(google), original: shown(s).single);
        expect(s.server, ['saveGoogleEvent']);
        expect(s.ownEventCount(mine), 0);
      });

      test('from Google to yours: made here, deleted there', () async {
        final (s, mine, google) = await both();
        final there = CalendarEvent(
            id: 'g9', calendar: google, title: 'Gym', description: '', location: '', start: day, end: addDays(day, 1), allDay: true, color: google.color);
        await s.saveEvent(draft(mine), original: there);
        expect(s.ownEventCount(mine), 1);
        expect(s.server, ['deleteGoogleEvent']);
      });

      test('off a calendar that can’t be changed: refused, and nothing copied', () async {
        final (s, mine, google) = await both(role: 'reader');
        final there = CalendarEvent(
            id: 'g9', calendar: google, title: 'Gym', description: '', location: '', start: day, end: addDays(day, 1), allDay: true, color: google.color);
        await expectLater(s.saveEvent(draft(mine), original: there), throwsException);
        expect(s.ownEventCount(mine), 0);
        expect(s.server, isEmpty);
      });
    });
  });

  group('the side panel’s order', () {
    testWidgets('yours, then Google, then hidden events, then school', (t) async {
      t.view.physicalSize = const Size(1500, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final svc = _Sidebar();
      await svc.createOwnCalendar('Home', Colors.teal);
      svc.accounts.add(GoogleAccount(email: 'me@example.com'));
      svc.calendars.add(GoogleCalendar(id: 'p', accountEmail: 'me@example.com', name: 'Me', color: Colors.blue, primary: true, accessRole: 'owner'));
      final feed = CanvasFeed('f', {'name': 'Fall classes'});
      svc.canvasFeeds.add(feed);
      svc.canvasCourses['f'] = ['BIO 110'];
      await svc.hideEvent(CalendarEvent(
          id: 'x', calendar: svc.calendars.first, title: 'x', description: '', location: '', start: day, end: addDays(day, 1), allDay: true, color: Colors.blue));
      await t.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: CalendarPage(service: svc))));
      await t.pump(const Duration(milliseconds: 300));
      final tops = [
        for (final label in ['My calendars', 'Home', 'me@example.com', 'Show hidden events (1)', 'Fall classes', 'BIO 110']) t.getTopLeft(find.text(label)).dy,
      ];
      expect(tops, [...tops]..sort(), reason: 'top to bottom in that order');
      expect(t.takeException(), isNull);
    });

    testWidgets(skip: skipPreview, 'own_calendars_sidebar', (t) async {
      await t.runAsync(loadFonts);
      t.view.physicalSize = const Size(1000, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final svc = _Sidebar();
      await svc.createOwnCalendar('Home', const Color(0xFF14B8A6));
      await svc.createOwnCalendar('Side project', const Color(0xFFF97316));
      svc.accounts.add(GoogleAccount(email: 'me@example.com'));
      svc.calendars.add(GoogleCalendar(id: 'p', accountEmail: 'me@example.com', name: 'Me', color: const Color(0xFF4285F4), primary: true, accessRole: 'owner'));
      svc.canvasFeeds.add(CanvasFeed('f', {'name': 'Fall classes'}));
      svc.canvasCourses['f'] = ['BIO 110', 'ENGL 101'];
      await svc.hideEvent(CalendarEvent(
          id: 'x', calendar: svc.calendars.first, title: 'x', description: '', location: '', start: day, end: addDays(day, 1), allDay: true, color: Colors.blue));
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(),
        debugShowCheckedModeBanner: false,
        builder: (_, child) => RepaintBoundary(key: const ValueKey('shot'), child: child!),
        home: Scaffold(body: CalendarPage(service: svc)),
      ));
      await t.pump(const Duration(seconds: 1));
      await shot(t, 'own_calendars_sidebar');
    });

    testWidgets('a new calendar can be made from it', (t) async {
      t.view.physicalSize = const Size(1500, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final svc = _Sidebar();
      await t.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: CalendarPage(service: svc))));
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.byTooltip('New calendar'));
      await t.pumpAndSettle();
      await t.tap(find.text('Create'));
      await t.pump();
      expect(find.text('Give it a name.'), findsOneWidget);
      await t.enterText(find.byType(TextField), '  School stuff ');
      await t.tap(find.text('Create'));
      await t.pumpAndSettle();
      expect(svc.ownCalendars.single.name, 'School stuff');
      expect(find.text('School stuff'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('the assistant', () {
    AssistantTools tools(CalendarService s, {bool ask = false, bool Function(String)? answer, Set<AiAct>? acts}) => AssistantTools(
        ai: _Ai()
          ..confirmChanges = ask
          ..acts = acts ?? {AiAct.calendar},
        calendar: s,
        confirm: (w) async => answer?.call(w) ?? true);

    test('makes a calendar, and puts an event on it', () async {
      final s = _Service();
      final t = tools(s);
      final made = await t.run('create_calendar', {'name': 'Study', 'color': '#3B82F6'});
      expect(made.changed, isTrue);
      expect(s.ownCalendars.single.name, 'Study');
      expect(s.ownCalendars.single.color.toARGB32(), 0xFF3B82F6);
      await t.run('create_event', {'title': 'Review', 'start': '2026-11-10T09:00', 'calendar_id': made.result['calendar_id']});
      expect(shown(s).single.calendar.name, 'Study');
      expect(s.server, isEmpty);
    });

    test('renames and recolors one, but leaves synced calendars alone', () async {
      final s = _Service();
      s.accounts.add(GoogleAccount(email: 'me@example.com'));
      s.calendars.add(GoogleCalendar(id: 'p', accountEmail: 'me@example.com', name: 'Me', color: Colors.blue, primary: true, accessRole: 'owner'));
      await s.createOwnCalendar('Study', Colors.teal);
      final t = tools(s);
      final list = (await t.run('list_calendars', {})).result['calendars'] as List;
      expect(list.first['name'], 'Study', reason: 'yours first');
      expect(list.first['optimizer_only'], isTrue);
      expect(list.last.containsKey('optimizer_only'), isFalse);
      final changed = await t.run('update_calendar', {'calendar_id': list.first['id'], 'name': 'Revision', 'color': '#EF4444'});
      expect(changed.changed, isTrue);
      expect(s.ownCalendars.single.name, 'Revision');
      expect(s.ownCalendars.single.color.toARGB32(), 0xFFEF4444);
      final refused = await t.run('update_calendar', {'calendar_id': list.last['id'], 'name': 'Nope'});
      expect(refused.changed, isFalse);
      expect(refused.result['error'], contains('synced'));
      expect(s.calendars.single.name, 'Me');
    });

    test('doesn’t make a second calendar with the same name', () async {
      final s = _Service();
      await s.createOwnCalendar('Study', Colors.teal);
      final r = await tools(s).run('create_calendar', {'name': 'study'});
      expect(r.changed, isFalse);
      expect(r.result['error'], contains('already'));
      expect(s.ownCalendars, hasLength(1));
    });

    test('asks first when that’s on, and takes no for an answer', () async {
      final s = _Service();
      final asked = <String>[];
      final t = tools(s, ask: true, answer: (w) {
        asked.add(w);
        return false;
      });
      final r = await t.run('create_calendar', {'name': 'Study'});
      expect(asked, ['Add calendar “Study”']);
      expect(r.changed, isFalse);
      expect(s.ownCalendars, isEmpty);
    });

    test('can’t do any of it with Change your calendar off', () async {
      final s = _Service();
      final t = tools(s, acts: {});
      expect(t.declarations().map((d) => d['name']), isNot(contains('create_calendar')));
      final r = await t.run('create_calendar', {'name': 'Study'});
      expect(r.result['error'], contains('switched off'));
      expect(s.ownCalendars, isEmpty);
    });

    group('deleting', () {
      test('a calendar goes, with its events, once you say yes', () async {
        final s = _Service();
        final c = await s.createOwnCalendar('Study', Colors.teal);
        await s.saveEvent(draft(c));
        final asked = <String>[];
        final t = tools(s, answer: (w) {
          asked.add(w);
          return true;
        });
        final list = (await t.run('list_calendars', {})).result['calendars'] as List;
        final r = await t.run('delete_calendar', {'calendar_id': list.single['id']});
        expect(r.changed, isTrue);
        expect(asked.single, 'Delete calendar “Study” and the event on it');
        expect(s.ownCalendars, isEmpty);
        expect(shown(s), isEmpty);
        await s.undoLast();
        expect(s.ownCalendars.single.name, 'Study');
        expect(shown(s).single.title, 'Gym');
      });

      test('a calendar always asks, even with checking before changes off', () async {
        final s = _Service();
        await s.createOwnCalendar('Study', Colors.teal);
        final t = tools(s, ask: false, answer: (_) => false);
        final list = (await t.run('list_calendars', {})).result['calendars'] as List;
        expect((await t.run('delete_calendar', {'calendar_id': list.single['id']})).changed, isFalse);
        expect(s.ownCalendars, hasLength(1));
      });

      test('a synced calendar can’t be', () async {
        final s = _Service();
        s.accounts.add(GoogleAccount(email: 'me@example.com'));
        s.calendars.add(GoogleCalendar(id: 'p', accountEmail: 'me@example.com', name: 'Me', color: Colors.blue, primary: true, accessRole: 'owner'));
        final t = tools(s);
        final list = (await t.run('list_calendars', {})).result['calendars'] as List;
        expect((await t.run('delete_calendar', {'calendar_id': list.single['id']})).result['error'], contains('synced'));
        expect(s.calendars, hasLength(1));
      });

      Future<(_Removing, AssistantTools, String, List<String>)> withGoogleEvent({String role = 'owner'}) async {
        final s = _Removing();
        s.accounts.add(GoogleAccount(email: 'me@example.com'));
        final google = GoogleCalendar(id: 'p', accountEmail: 'me@example.com', name: 'Me', color: Colors.blue, primary: true, accessRole: role);
        s.calendars.add(google);
        s.debugAddEvent(CalendarEvent(id: 'g1', calendar: google, title: 'Lunch', description: '', location: '', start: day, end: addDays(day, 1), allDay: true, color: google.color));
        final asked = <String>[];
        final t = tools(s, ask: true, answer: (w) {
          asked.add(w);
          return true;
        });
        // As Gemini would get it. fetchBetween needs Firestore, so read what's shown.
        final id = t.debugIdOf(s.eventsBetween(day, addDays(day, 1)).single);
        return (s, t, id, asked);
      }

      test('a Google event goes from Google, and says so', () async {
        final (s, t, id, asked) = await withGoogleEvent();
        await t.run('delete_event', {'event_id': id});
        expect(asked.single, startsWith('Delete “Lunch” from Google Calendar'));
        expect(s.server, ['deleteGoogleEvent']);
      });

      test('or only from Optimizer, leaving Google alone', () async {
        final (s, t, id, asked) = await withGoogleEvent();
        final r = await t.run('delete_event', {'event_id': id, 'only_in_optimizer': true});
        expect(asked.single, contains('stays in Google Calendar'));
        expect(r.note, 'Took “Lunch” off Optimizer');
        expect(s.server, isEmpty);
        expect(s.removed, hasLength(1));
      });

      test('on a calendar that can’t be edited, only from Optimizer', () async {
        final (s, t, id, _) = await withGoogleEvent(role: 'reader');
        final no = await t.run('delete_event', {'event_id': id});
        expect(no.result['error'], contains('only_in_optimizer'));
        expect(s.removed, isEmpty);
        expect(s.server, isEmpty);
        expect((await t.run('delete_event', {'event_id': id, 'only_in_optimizer': true})).changed, isTrue);
        expect(s.removed, hasLength(1));
      });
    });

    test('all it does in one message is undone together', () async {
      final s = _Service();
      final t = tools(s);
      await s.asOneChange('Assistant', () async {
        final made = await t.run('create_calendar', {'name': 'Study'});
        await t.run('create_event', {'title': 'Review', 'start': '2026-11-10T09:00', 'calendar_id': made.result['calendar_id']});
      });
      await s.undoLast();
      expect(s.ownCalendars, isEmpty);
      expect(shown(s), isEmpty);
    });
  });
}

class _Removing extends _Service {
  final removed = <String>[];
  @override
  Future<void> saveEventRemoved(CalendarEvent e, bool remove) async => remove ? removed.add(e.key) : removed.remove(e.key);
}

class _Sidebar extends FeedService {
  @override
  Future<void> writeOwnCalendar(String id, Map<String, dynamic>? data) async {}
  @override
  Future<void> saveEventHidden(CalendarEvent e, bool hide) async {}
  @override
  Future<void> saveHistory(HistoryEntry e) async {}
}

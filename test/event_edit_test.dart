import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/calendar/calendar_models.dart';
import 'package:optimizer/calendar/calendar_service.dart';
import 'package:optimizer/calendar/event_editor.dart';
import 'package:optimizer/theme.dart';
import 'package:optimizer/widgets/address_field.dart';

import 'preview/calendar_preview_test.dart' show FakeService;

class RecordingService extends FakeService {
  EventDraft? toGoogle;
  EventDraft? kept;
  CalendarEvent? deleted;
  @override
  Future<void> deleteEvent(CalendarEvent e) async => deleted = e;
  @override
  Future<String?> saveEvent(EventDraft d, {CalendarEvent? original}) async {
    toGoogle = d;
    return null;
  }
  @override
  Future<void> saveLocalEdit(CalendarEvent original, EventDraft d) async => kept = d;
}

void main() {
  final cal = GoogleCalendar(id: 'p', accountEmail: 'me@example.com', name: 'Me', color: const Color(0xFF4285F4), primary: true, accessRole: 'owner');
  final event = CalendarEvent(
    id: 'e1', calendar: cal, title: 'Dentist', description: '', location: '',
    start: DateTime(2026, 11, 3, 9), end: DateTime(2026, 11, 3, 10), allDay: false, color: cal.color,
  );

  setUp(() => CalendarService.debugCanLinkGoogle = true);
  tearDown(() => CalendarService.debugCanLinkGoogle = null);

  Future<RecordingService> editAndSave(WidgetTester tester, String choice) async {
    final svc = RecordingService()
      ..accounts.add(GoogleAccount(email: 'me@example.com'))
      ..calendars.add(cal);
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Builder(builder: (context) => Scaffold(body: TextButton(onPressed: () => showEventEditor(context, svc, existing: event), child: const Text('open')))),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Location'), 'Main St Dental');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(find.text('Save to Google Calendar too?'), findsOneWidget);
    await tester.tap(find.text(choice));
    await tester.pumpAndSettle();
    return svc;
  }

  testWidgets('Save to Google sends the change to Google Calendar', (tester) async {
    final svc = await editAndSave(tester, 'Save to Google');
    expect(svc.toGoogle?.location, 'Main St Dental');
    expect(svc.kept, isNull);
  });

  testWidgets('Only in Optimizer keeps it here, on the same event', (tester) async {
    final svc = await editAndSave(tester, 'Only in Optimizer');
    expect(svc.kept?.location, 'Main St Dental');
    expect(svc.kept?.calendarKey, cal.key);
    expect(svc.toGoogle, isNull);
  });

  test('an Optimizer-only change shows a ✎ and keeps the event’s identity', () {
    final edited = event.copyWith(title: 'Dentist (moved)', localEdit: true);
    expect(edited.shownTitle, '✎ Dentist (moved)');
    expect(edited.key, event.key);
  });

  testWidgets('the edit page can delete the event, after asking', (tester) async {
    final svc = RecordingService()
      ..accounts.add(GoogleAccount(email: 'me@example.com'))
      ..calendars.add(cal);
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Builder(builder: (context) => Scaffold(body: TextButton(onPressed: () => showEventEditor(context, svc, existing: event), child: const Text('open')))),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Delete event'), 200, scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete event'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete in Google too'));
    await tester.pumpAndSettle();
    expect(svc.deleted?.id, 'e1');
    expect(find.text('Edit event'), findsNothing); // back where it came from
  });

  group('an entry’s map', () {
    Future<void> details(WidgetTester tester, CalendarEvent e, Size size) async {
      final svc = RecordingService()
        ..accounts.add(GoogleAccount(email: 'me@example.com'))
        ..calendars.add(cal);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Builder(builder: (context) => Scaffold(body: TextButton(onPressed: () => showEventDetails(context, svc, e), child: const Text('open')))),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    final located = CalendarEvent(
      id: 'e2', calendar: cal, title: 'Contest', description: 'Bring your uniform', location: 'Alamodome, San Antonio, TX',
      start: DateTime(2026, 11, 3, 9), end: DateTime(2026, 11, 3, 10), allDay: false, color: cal.color,
    );

    testWidgets('details: the map on the right, the location under it', (tester) async {
      await details(tester, located, const Size(1200, 900));
      expect(tester.takeException(), isNull);
      final map = tester.getRect(find.byType(PlaceMap));
      expect(tester.widget<PlaceMap>(find.byType(PlaceMap)).to, 'Alamodome, San Antonio, TX');
      expect(map.left, greaterThan(tester.getRect(find.text('Bring your uniform')).right));
      final where = tester.getRect(find.text('Alamodome, San Antonio, TX'));
      expect(where.top, greaterThanOrEqualTo(map.bottom));
      expect(where.left, greaterThanOrEqualTo(map.left));
      expect(find.text('Alamodome, San Antonio, TX'), findsOneWidget, reason: 'not also with everything else');
    });

    testWidgets('details on a phone: the map first, nothing cut off', (tester) async {
      await details(tester, located, const Size(390, 800));
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.byType(PlaceMap)).top, lessThan(tester.getRect(find.text('Bring your uniform')).top));
    });

    testWidgets('details with no location have no map', (tester) async {
      await details(tester, event, const Size(1200, 900));
      expect(tester.takeException(), isNull);
      expect(find.byType(PlaceMap), findsNothing);
    });

    testWidgets('the editor: the Location field is under the map on the right, even while it’s empty', (tester) async {
      final svc = RecordingService()
        ..accounts.add(GoogleAccount(email: 'me@example.com'))
        ..calendars.add(cal);
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Builder(builder: (context) => Scaffold(body: TextButton(onPressed: () => showEventEditor(context, svc, existing: event), child: const Text('open')))),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Add a location to see it here'), findsOneWidget);
      final field = tester.getRect(find.widgetWithText(TextField, 'Location'));
      expect(field.left, greaterThan(tester.getRect(find.widgetWithText(TextField, 'Title')).right));
      expect(field.top, greaterThan(tester.getRect(find.text('Add a location to see it here')).bottom));
    });
  });
}

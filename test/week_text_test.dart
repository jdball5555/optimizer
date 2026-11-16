import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/calendar/calendar_models.dart';
import 'package:optimizer/calendar/vertical_week.dart';
import 'package:optimizer/theme.dart';
import 'package:optimizer/util/fields.dart';

final _cal = GoogleCalendar(id: 'p', accountEmail: 'me@example.com', name: 'Me', color: const Color(0xFF4285F4), primary: true, accessRole: 'owner');

void main() {
  final sunday = DateTime(2026, 11, 1);
  final days = [for (var i = 0; i < 7; i++) addDays(sunday, i)];
  CalendarEvent at(String title, int day, double hour, double hours) => CalendarEvent(
      id: '$title$day$hour',
      calendar: _cal,
      title: title,
      description: '',
      location: '',
      start: addDays(sunday, day).add(Duration(minutes: (hour * 60).round())),
      end: addDays(sunday, day).add(Duration(minutes: ((hour + hours) * 60).round())),
      allDay: false,
      color: _cal.color);
  CalendarEvent allDay(String title, int day) =>
      CalendarEvent(id: title, calendar: _cal, title: title, description: '', location: '', start: addDays(sunday, day), end: addDays(sunday, day + 1), allDay: true, color: _cal.color);

  Future<void> pump(WidgetTester t, List<CalendarEvent> events, {double width = 360, void Function(CalendarEvent)? onTap}) async {
    t.view.physicalSize = Size(width, 740);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: VerticalWeek(days: days, events: events, onEventTap: onTap ?? (_) {}))));
    await t.pump();
  }

  /// How big it really draws, after any scaling on the way to the screen.
  double drawnSize(WidgetTester t, String text) {
    final f = find.text(text);
    final style = t.widget<Text>(f).style!;
    final box = t.renderObject<RenderBox>(f);
    final scale = box.getTransformTo(null).getMaxScaleOnAxis();
    return style.fontSize! * scale;
  }

  testWidgets('a long title stays readable: it wraps rather than shrinks', (t) async {
    await pump(t, [at('Organic chemistry lecture', 3, 9, 2)]);
    expect(drawnSize(t, 'Organic chemistry lecture'), greaterThanOrEqualTo(12));
    expect(t.takeException(), isNull);
  });

  testWidgets('so does one sharing its time with another, in half the width', (t) async {
    await pump(t, [at('Standup', 3, 9, 1), at('Quick call', 3, 9, 1)]);
    expect(drawnSize(t, 'Quick call'), greaterThanOrEqualTo(12));
    expect(t.takeException(), isNull);
  });

  testWidgets('and all-day ones', (t) async {
    await pump(t, [allDay('Thanksgiving break', 3)]);
    expect(drawnSize(t, 'Thanksgiving break'), greaterThanOrEqualTo(12));
    expect(t.takeException(), isNull);
  });

  testWidgets('a crowded, tiny day doesn’t overflow, at any phone size', (t) async {
    for (final width in const [320.0, 360.0, 412.0]) {
      await pump(t, [
        for (var i = 0; i < 6; i++) at('Five minute thing $i', 2, 9, 5 / 60),
        at('Fifteen', 4, 10, 0.25),
        at('Half hour meeting with a long name', 5, 10, 0.5),
        for (var i = 0; i < 5; i++) allDay('All day $i', 1),
      ], width: width);
      expect(t.takeException(), isNull);
    }
  });

  testWidgets('a very short event is still tall enough to read', (t) async {
    await pump(t, [at('Pills', 3, 9, 5 / 60)]);
    final tile = find.ancestor(of: find.text('Pills'), matching: find.byType(Material)).first;
    expect(t.getSize(tile).height, greaterThanOrEqualTo(17));
  });

  testWidgets('tapping still opens it', (t) async {
    final opened = <String>[];
    await pump(t, [at('Standup', 3, 9, 1)], onTap: (e) => opened.add(e.title));
    await t.tap(find.text('Standup'));
    expect(opened, ['Standup']);
  });

  testWidgets('its time still shows where there’s room', (t) async {
    await pump(t, [at('Lab', 3, 13, 3)]);
    expect(find.text('1:00'), findsOneWidget);
  });
}

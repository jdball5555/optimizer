import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/calendar/calendar_models.dart';
import 'package:optimizer/calendar/flipped_timeline.dart';
import 'package:optimizer/theme.dart';
import 'package:optimizer/util/fields.dart';

final _cal = GoogleCalendar(id: 'p', accountEmail: 'a', name: 'Me', color: const Color(0xFF4285F4), primary: true, accessRole: 'owner');

void main() {
  final sunday = DateTime(2026, 10, 25);
  final days = [for (var i = 0; i < 7; i++) addDays(sunday, i)];
  final events = [
    for (var d = 0; d < 7; d++)
      for (var k = 0; k <= d % 5; k++)
        CalendarEvent(
            id: 'a$d$k',
            calendar: _cal,
            title: 'All day $k',
            description: '',
            location: '',
            start: days[d],
            end: addDays(days[d], 1),
            allDay: true,
            color: _cal.color),
  ];

  for (final column in [false, true]) {
    for (final (w, h, compact) in [
      (1600.0, 940.0, false),
      (1400.0, 700.0, false),
      (1200.0, 560.0, false),
      (900.0, 420.0, false),
      (700.0, 380.0, true),
      (600.0, 300.0, true)
    ]) {
      testWidgets('week with busy all-day rows at ${w.toInt()}x${h.toInt()}${compact ? ' compact' : ''}${column ? ', in their own column' : ''}',
          (tester) async {
        tester.view.physicalSize = Size(w, h);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final errors = <String>[];
        final old = FlutterError.onError;
        FlutterError.onError = (d) => errors.add(d.exceptionAsString().split('\n').first);
        await tester.pumpWidget(MaterialApp(
          theme: buildTheme(),
          home:
              Scaffold(body: FlippedTimeline(days: days, events: events, hourWidth: 80, compact: compact, allDayColumn: column, onEventTap: (_) {})),
        ));
        await tester.pump();
        FlutterError.onError = old;
        expect(errors, isEmpty);
      });
    }
  }
}

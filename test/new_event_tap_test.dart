import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/calendar/flipped_timeline.dart';
import 'package:optimizer/calendar/vertical_week.dart';
import 'package:optimizer/theme.dart';

void main() {
  final days = [for (var i = 0; i < 7; i++) DateTime(2026, 11, 1 + i)];

  testWidgets('tapping empty space in the week starts a new event there', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    DateTime? tapped;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: FlippedTimeline(
          days: days,
          events: const [],
          hourWidth: 100,
          onEventTap: (_) {},
          onSlotTap: (start, {bool allDay = false}) => tapped = start,
        ),
      ),
    ));
    await tester.pump();
    // A mouse click too, though a mouse drag pans the hours.
    await tester.tapAt(const Offset(900, 200), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(tapped, isNotNull);
    expect(tapped!.year, 2026);
  });

  testWidgets('and on the phone’s week', (tester) async {
    tester.view.physicalSize = const Size(412, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    DateTime? tapped;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: VerticalWeek(
          days: days,
          events: const [],
          onEventTap: (_) {},
          onSlotTap: (start, {bool allDay = false}) => tapped = start,
        ),
      ),
    ));
    await tester.pump();
    await tester.tapAt(const Offset(250, 500));
    await tester.pump();
    expect(tapped, isNotNull);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/people/invites.dart';
import 'package:optimizer/people/people_page.dart';
import 'package:optimizer/people/people_service.dart';
import 'package:optimizer/theme.dart';

import 'calendar_preview_test.dart' show loadFonts, skipPreview, FakeService;
import 'pages_preview_test.dart' show shot;

void main() {
  for (final (name, size) in [('people_desktop', const Size(1200, 900)), ('people_phone', const Size(412, 915))]) {
    testWidgets(skip: skipPreview, name, (tester) async {
      await tester.runAsync(loadFonts);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final calendar = FakeService();
      final start = DateTime.now().add(const Duration(days: 2, hours: 3));
      calendar.invites['i1'] = Invite('i1', {
        'kind': 'event',
        'status': 'pending',
        'fromName': 'Sam Rivera',
        'fromEmail': 'sam@example.com',
        'event': {'title': 'Game night', 'start': start.millisecondsSinceEpoch, 'end': start.add(const Duration(hours: 3)).millisecondsSinceEpoch},
      });
      calendar.invites['i2'] = Invite('i2', {'kind': 'group', 'status': 'pending', 'fromName': 'Mom', 'group': {'name': 'Family'}});
      final people = PeopleService.preview('me', [
        PeopleGroup('g1', {
          'name': 'Roommates',
          'role': 'owner',
          'ownerName': 'Alex',
          'members': [
            {'email': 'alex@example.com', 'name': 'Alex', 'status': 'owner'},
            {'email': 'alex@example.com', 'name': 'Alex Chen', 'status': 'accepted'},
            {'email': 'jordan@example.com', 'name': '', 'status': 'pending'},
            {'email': 'kim@example.com', 'name': 'Kim', 'status': 'declined'},
          ],
        }),
        PeopleGroup('g2', {
          'name': 'Study group',
          'role': 'member',
          'ownerName': 'Priya',
          'members': [
            {'email': 'priya@example.com', 'name': 'Priya', 'status': 'owner'},
            {'email': 'alex@example.com', 'name': 'Alex Chen', 'status': 'accepted'},
          ],
        }),
      ]);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(key: const ValueKey('shot'), child: Scaffold(body: PeoplePage(people: people, calendar: calendar, myEmail: 'alex@example.com'))),
      ));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      await shot(tester, name);
      tester.view.reset();
    });
  }
}

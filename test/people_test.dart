import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/people/invites.dart';
import 'package:optimizer/people/people_page.dart';
import 'package:optimizer/people/people_service.dart';
import 'package:optimizer/theme.dart';

import 'preview/calendar_preview_test.dart' show FakeService;

class GroupService extends PeopleService {
  GroupService({this.id = ''}) : super.preview('me', []);

  /// The new group's id ('' skips the invite step).
  final String id;
  final made = <String>[];
  @override
  Future<String> saveGroup(String name, {PeopleGroup? group}) async {
    made.add(name);
    return id;
  }

  @override
  Future<InviteLinks> inviteToGroup(String groupId, List<String> emails) async =>
      [for (final e in emails) (email: e, link: 'https://optimizer.axisoptic.com/?invite=t-$e')];
}

void main() {
  testWidgets('making a group closes its name box cleanly', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final people = GroupService();
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(body: PeoplePage(people: people, calendar: FakeService(), myEmail: 'me@example.com')),
    ));
    await tester.tap(find.text('New group'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Roommates');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(people.made, ['Roommates']);
  });

  testWidgets('inviting someone not on Optimizer gives you their link to copy', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final people = GroupService(id: 'g1');
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(body: PeoplePage(people: people, calendar: FakeService(), myEmail: 'me@example.com')),
    ));
    await tester.tap(find.text('New group'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Roommates');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.text('Invite people to Roommates'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'alex@example.com');
    await tester.tap(find.text('Invite'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Invite people to Roommates'), findsNothing);
    expect(find.text('Send alex@example.com their invitation'), findsOneWidget);
    await tester.tap(find.text('Copy link'));
    await tester.pumpAndSettle();
    expect(find.text('Link for alex@example.com copied'), findsOneWidget);
  });
}

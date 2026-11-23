import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:optimizer/calendar/calendar_page.dart';
import 'package:optimizer/dashboard/dashboard_page.dart';
import 'package:optimizer/networth/net_worth_page.dart';
import 'package:optimizer/people/people_page.dart';
import 'package:optimizer/people/people_service.dart';
import 'package:optimizer/theme.dart';
import 'package:optimizer/trips/trip_models.dart';
import 'package:optimizer/trips/trip_store.dart';
import 'package:optimizer/todos/todos_page.dart';
import 'package:optimizer/trips/trips_page.dart';
import 'package:optimizer/widgets/tiles.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview/calendar_preview_test.dart' show loadFonts, skipPreview;
import 'preview/pages_preview_test.dart' show FeedService, finance, journal, shot;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final now = DateTime.now();
  final month = DateFormat.MMMM().format(now);
  Trip tokyo() => Trip(
      id: 't',
      title: 'Tokyo',
      how: TripHow.fly,
      start: DateTime(now.year, now.month, now.day + 3),
      end: DateTime(now.year, now.month, now.day + 6),
      items: [
        TripItem(
            id: 'a',
            kind: TripItemKind.activity,
            title: 'Museum',
            start: DateTime(now.year, now.month, now.day + 3, 10),
            end: DateTime(now.year, now.month, now.day + 3, 12)),
      ]);

  // Each page, and how to find its title.
  final pages = <(String, Widget Function(), bool Function(String))>[
    (
      'Home',
      () => DashboardPage(uid: 'u', calendar: FeedService(), journal: journal(), finance: finance(), onNavigate: (_) {}),
      (s) => s == greetingAt(now),
    ),
    ('Calendar', () => CalendarPage(service: FeedService()), (s) => s.startsWith(month)),
    ('Trips', () => TripsPage(store: TripStore.preview('u', [tokyo()]), active: true), (s) => s == 'Trips'),
    ('A trip', () => TripsPage(store: TripStore.preview('u', [tokyo()])..openId = 't', active: true), (s) => s == 'Tokyo'),
    ('Net worth', () => NetWorthPage(store: finance()), (s) => s == 'Overview'),
    ('To-dos', () => TodosPage(service: FeedService()), (s) => s == 'To-dos'),
    ('People', () => PeoplePage(people: PeopleService.preview('u', const []), calendar: FeedService(), myEmail: 'me@x.com'), (s) => s == 'People'),
  ];

  for (final size in const [Size(1500, 950), Size(1100, 800), Size(820, 800), Size(412, 915), Size(360, 700)]) {
    for (final (name, page, isTitle) in pages) {
      testWidgets('$name’s title is where every other page’s is, at ${size.width.toInt()} wide', (t) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        late BuildContext context;
        await t.pumpWidget(MaterialApp(
          theme: buildTheme(),
          home: Scaffold(body: Builder(builder: (c) {
            context = c;
            return page();
          })),
        ));
        await t.pump(const Duration(milliseconds: 200));
        final title = find.byWidgetPredicate((w) => w is Text && (w.style?.fontSize ?? 0) >= 19 && w.data != null && isTitle(w.data!));
        expect(title, findsWidgets);
        expect(t.getTopLeft(title.first).dy, PageSpace.top(context));
        expect(t.takeException(), isNull);
      });
    }
  }

  testWidgets('the calendar’s panel starts level with its title', (t) async {
    t.view.physicalSize = const Size(1500, 950);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: CalendarPage(service: FeedService()))));
    await t.pump(const Duration(milliseconds: 200));
    final panel = find.byWidgetPredicate((w) => w is ListView).first;
    expect(t.getTopLeft(panel).dy + 8, 32);
  });

  for (final (shotName, size) in const [('wide', Size(1500, 950)), ('phone', Size(390, 844))]) {
    testWidgets(skip: skipPreview, 'page_tops_$shotName', (t) async {
      await t.runAsync(loadFonts);
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      for (final (name, page, _) in pages) {
          await t.pumpWidget(MaterialApp(
          theme: buildTheme(),
          debugShowCheckedModeBanner: false,
          builder: (_, c) => RepaintBoundary(key: const ValueKey('shot'), child: c!),
          home: Scaffold(body: SafeArea(child: page())),
        ));
        await t.pump(const Duration(milliseconds: 300));
        await shot(t, 'top_${shotName}_${name.replaceAll(' ', '_')}');
      }
      t.view.reset();
    });
  }
}

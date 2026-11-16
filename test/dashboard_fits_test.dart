import 'dart:convert';

import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/calendar/calendar_models.dart';
import 'package:optimizer/calendar/calendar_service.dart';
import 'package:optimizer/calendar/canvas.dart';
import 'package:optimizer/dashboard/dashboard_page.dart';
import 'package:optimizer/focus/focus_page.dart';
import 'package:optimizer/journal/journal_store.dart';
import 'package:optimizer/networth/finance_store.dart';
import 'package:optimizer/networth/net_worth_page.dart';
import 'package:optimizer/theme.dart';
import 'package:optimizer/trips/trip_models.dart';
import 'package:optimizer/util/fields.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview/calendar_preview_test.dart' show loadFonts;
import 'preview/pages_preview_test.dart' show journal, finance, FeedService;

void main() {
  FeedService service() {
    final svc = FeedService();
    svc.accounts.add(GoogleAccount(email: 'me@example.com'));
    final cal = GoogleCalendar(id: 'p', accountEmail: 'me@example.com', name: 'Me', color: const Color(0xFF4285F4), primary: true, accessRole: 'owner');
    svc.calendars.add(cal);
    final feed = CanvasFeed('f1', {'name': 'Fall classes', 'color': '#22C55E'});
    svc.canvasFeeds.add(feed);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    svc.fake = [
      for (var i = 0; i < 6; i++)
        CalendarEvent(
          id: 'e$i',
          calendar: cal,
          title: 'A long event title that keeps on going so it has to be cut off somewhere $i',
          description: '',
          location: i.isEven ? 'Alamodome, 100 Montana St Ste 310 Lot A, San Antonio, TX 78203, USA' : '',
          start: today.add(Duration(hours: 8 + i * 2)),
          end: today.add(Duration(hours: 9 + i * 2)),
          allDay: false,
          color: cal.color,
        ),
      CalendarEvent(id: 'all', calendar: cal, title: 'An all-day thing with a long name too', description: '', location: '', start: today, end: today.add(const Duration(days: 1)), allDay: true, color: cal.color),
    ];
    svc.canvasTasks = [
      for (var i = 0; i < 10; i++)
        CanvasTask(
          id: 't$i',
          feed: feed,
          calendar: feed.calendarFor('ENGL 101-502 Composition and Rhetoric'),
          title: 'Assignment with a really long title that goes on and on and on $i',
          course: 'ENGL 101',
          due: today.add(Duration(days: i % 3, hours: 23, minutes: 59)),
          allDay: false,
          assignment: true,
        ),
    ];
    return svc;
  }

  for (final size in const [
    Size(320, 700), Size(360, 640), Size(412, 915), Size(599, 800), Size(600, 800), Size(700, 800), Size(760, 800), Size(800, 700), Size(899, 800),
    Size(900, 800), Size(956, 900), Size(1000, 800), Size(1100, 800), Size(1181, 800), Size(1182, 800), Size(1280, 800), Size(1440, 900), Size(1600, 1000), Size(1920, 1080), Size(2560, 1300),
  ]) {
    testWidgets('home fits ${size.width.toInt()}x${size.height.toInt()}', (t) async {
      await t.runAsync(loadFonts);
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final errors = <String>[];
      final old = FlutterError.onError;
      FlutterError.onError = (d) {
        final info = d.informationCollector?.call().map((n) => n.toString()).where((l) => l.contains('dart:') || l.contains('.dart')).take(2).join(' | ') ?? '';
        errors.add('${d.exceptionAsString().split('\n').first} @ $info');
      };
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: DashboardPage(uid: 'u', calendar: service(), journal: journal(), finance: finance(), onNavigate: (_) {}, name: 'Alex', focus: const SizedBox(width: 120, height: 40))),
      ));
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      await t.pump(const Duration(milliseconds: 200));
      await t.pump();
      FlutterError.onError = old;
      expect(errors, isEmpty);
    });
  }

  // A layout saved back when panels could be resized, larger system text, and
  // hidden amounts: everything that changes how much each panel has to fit.
  final layouts = <String, List<Map<String, Object>>>{
    'all small': [for (final k in PanelKind.values) {'kind': k.name, 'w': 3, 'h': 1}],
    'all narrow tall': [for (final k in PanelKind.values) {'kind': k.name, 'w': 3, 'h': 2}],
    'all medium': [for (final k in PanelKind.values) {'kind': k.name, 'w': 4, 'h': 1}],
    'all wide short': [for (final k in PanelKind.values) {'kind': k.name, 'w': 6, 'h': 1}],
    'all full tall': [for (final k in PanelKind.values) {'kind': k.name, 'w': 12, 'h': 3}],
  };
  for (final (name, layout) in layouts.entries.map((e) => (e.key, e.value))) {
    for (final width in const [412.0, 800.0, 956.0, 1182.0, 1440.0, 1920.0]) {
      for (final scale in const [1.0, 1.3]) {
        testWidgets('layout "$name" fits $width wide at text ${scale}x', (t) async {
          await t.runAsync(loadFonts);
          SharedPreferences.setMockInitialValues({'optimizer.u.dashboard': jsonEncode(layout)});
          t.view.physicalSize = Size(width, 1000);
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.reset);
          final errors = <String>[];
          final old = FlutterError.onError;
          FlutterError.onError = (d) => errors.add(d.exceptionAsString().split('\n').first);
          await t.pumpWidget(MaterialApp(
            theme: buildTheme(),
            home: MediaQuery.withClampedTextScaling(
              minScaleFactor: scale,
              maxScaleFactor: scale,
              child: Scaffold(body: DashboardPage(uid: 'u', calendar: service(), journal: journal(), finance: finance(), onNavigate: (_) {}, name: 'Alex')),
            ),
          ));
          await t.runAsync(() => Future.delayed(const Duration(milliseconds: 80)));
          await t.pump(const Duration(milliseconds: 200));
          await t.pump();
          FlutterError.onError = old;
          expect(errors, isEmpty);
        });
      }
    }
  }

  // The states real data can be in that sample data isn't.
  FinanceStore bigFinance() {
    final s = finance();
    s.points = [
      for (final p in s.points) NetWorthPoint(id: p.id, date: p.date, total: p.total * 1000),
    ];
    return s;
  }

  Future<List<String>> render(WidgetTester t, Size size, {required CalendarService cal, required FinanceStore money, required JournalStore diary, Future<void> Function()? then}) async {
    await t.runAsync(loadFonts);
    SharedPreferences.setMockInitialValues({});
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final errors = <String>[];
    final old = FlutterError.onError;
    FlutterError.onError = (d) => errors.add(d.exceptionAsString().split('\n').first);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(body: DashboardPage(uid: 'u', calendar: cal, journal: diary, finance: money, onNavigate: (_) {}, name: 'Alex', focus: FocusButton(onOpen: () {}))),
    ));
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 60)));
    await t.pump(const Duration(milliseconds: 200));
    if (then != null) await then();
    await t.pump();
    FlutterError.onError = old;
    return errors;
  }

  final key = encrypt.Encrypter(encrypt.AES(encrypt.Key.fromLength(32), mode: encrypt.AESMode.cbc));
  for (final width in const [360.0, 412.0, 600.0, 800.0, 956.0, 1182.0, 1440.0, 1920.0]) {
    final size = Size(width, 1000);
    testWidgets('nothing linked or loaded yet, $width wide', (t) async {
      expect(await render(t, size, cal: FeedService(), money: FinanceStore.offline('u', key: key), diary: JournalStore.withEntries('u', [])), isEmpty);
    });
    testWidgets('huge balances, $width wide', (t) async {
      expect(await render(t, size, cal: service(), money: bigFinance(), diary: journal()), isEmpty);
    });
    testWidgets('amounts hidden, $width wide', (t) async {
      hideAmounts.value = true;
      addTearDown(() => hideAmounts.value = false);
      expect(await render(t, size, cal: service(), money: finance(), diary: journal()), isEmpty);
    });
    testWidgets('a trip today, $width wide', (t) async {
      final svc = service();
      final now = DateTime.now();
      svc.fake = [...svc.fake, Trip(id: 'trip', title: 'A really long trip name that keeps going and going', destination: 'Alamodome', start: dayStart(now), end: addDays(dayStart(now), 2)).tile];
      expect(await render(t, size, cal: svc, money: finance(), diary: journal()), isEmpty);
    });
    testWidgets('hovering the net worth chart, $width wide', (t) async {
      final errors = await render(t, size, cal: service(), money: bigFinance(), diary: journal(), then: () async {
        final chart = find.byType(NetWorthHero);
        if (chart.evaluate().isEmpty) return;
        await t.ensureVisible(chart);
        await t.pump();
        final box = t.getRect(chart);
        final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: box.center);
        await t.pump();
        for (final f in const [0.02, 0.3, 0.7, 0.98]) {
          await mouse.moveTo(Offset(box.left + box.width * f, box.center.dy + 20));
          await t.pump();
        }
      });
      expect(errors, isEmpty);
    });
  }
}

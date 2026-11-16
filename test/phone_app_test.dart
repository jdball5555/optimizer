import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/ai/assistant_panel.dart';
import 'package:optimizer/calendar/calendar_page.dart';
import 'package:optimizer/dashboard/dashboard_page.dart';
import 'package:optimizer/journal/journal_page.dart';
import 'package:optimizer/networth/net_worth_page.dart';
import 'package:optimizer/theme.dart';
import 'package:optimizer/trips/trip_models.dart';
import 'package:optimizer/trips/trips_page.dart';
import 'package:optimizer/util/fields.dart';
import 'package:optimizer/widgets/tiles.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'phone_layout_test.dart' show calendar, habits;
import 'preview/calendar_preview_test.dart' show loadFonts, skipPreview;
import 'preview/pages_preview_test.dart' show journal, finance, shot;
import 'trips_test.dart' show FakeTrips;

/// Every page as the phone app has it: under a status bar, over the bottom bar,
/// with the assistant's arrow in the corner. Nothing may overflow or throw, at
/// a small phone's width or a big one's.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> show(WidgetTester t, Widget page, Size size) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    t.view.padding = const FakeViewPadding(top: 44);
    addTearDown(t.view.reset);
    final open = ValueNotifier(false);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(),
      debugShowCheckedModeBanner: false,
      builder: (_, child) => RepaintBoundary(key: const ValueKey('shot'), child: child!),
      home: AssistantOverlay(
        open: open,
        enabled: true,
        arrow: true,
        panel: const SizedBox(),
        child: Scaffold(
          body: SafeArea(bottom: false, child: PageEnd(end: AssistantArrowRoom(open: open), child: page)),
          bottomNavigationBar: NavigationBar(height: 64, destinations: const [
            NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'Home'),
            NavigationDestination(icon: Icon(Icons.calendar_view_week_outlined), label: 'Calendar'),
            NavigationDestination(icon: Icon(Icons.menu_book_outlined), label: 'Journal'),
          ]),
        ),
      ),
    ));
    await t.pump(const Duration(milliseconds: 400));
  }

  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
  }

  Future<void> pickView(WidgetTester t, String view) async {
    await t.tap(find.text('Week').first);
    await t.pumpAndSettle();
    await t.tap(find.text(view).last);
    await settle(t);
  }

  Trip trip() {
    final start = addDays(dayStart(DateTime.now()), 5);
    return Trip(id: 'a', title: 'Spring break in New Orleans', destination: 'New Orleans', start: start, end: addDays(start, 4), zone: 'America/Chicago', items: [
      TripItem(id: 'f', kind: TripItemKind.flight, title: 'AA 123 · AUS – MSY', start: start.add(const Duration(hours: 8)), end: start.add(const Duration(hours: 10)), flight: const {'number': 'AA 123', 'departure': {'iata': 'AUS'}, 'arrival': {'iata': 'MSY'}}),
      TripItem(id: 's', kind: TripItemKind.stay, title: 'Hotel Monteleone', location: 'New Orleans', start: start.add(const Duration(hours: 15)), end: addDays(start, 4).add(const Duration(hours: 11))),
      TripItem(id: 'd', kind: TripItemKind.food, title: 'Dinner at Commander’s Palace', start: addDays(start, 1).add(const Duration(hours: 19)), end: addDays(start, 1).add(const Duration(hours: 19))),
    ]);
  }

  // What to do once the page is up, to reach each screen.
  final screens = <String, (Widget Function(), Future<void> Function(WidgetTester)?)>{
    'home': (() => DashboardPage(uid: 'u', calendar: calendar(), journal: journal(), finance: finance(), onNavigate: (_) {}), null),
    'week': (() => CalendarPage(service: calendar()), null),
    'month': (() => CalendarPage(service: calendar()), (t) => pickView(t, 'Month')),
    'todo': (() => CalendarPage(service: calendar()), (t) => pickView(t, 'To-do')),
    'calendars': (
      () => CalendarPage(service: calendar()),
      (t) async {
        await t.tap(find.byTooltip('Calendars'));
        await settle(t);
      }
    ),
    'journal': (() => JournalPage(store: journal(), habits: habits()), null),
    'journal_writing': (
      () => JournalPage(store: journal(), habits: habits()),
      (t) async {
        await t.tap(find.text('Add a new entry'));
        await settle(t);
      }
    ),
    'habits': (
      () => JournalPage(store: journal(), habits: habits()),
      (t) async {
        await t.tap(find.text('Habits'));
        await settle(t);
      }
    ),
    for (final tab in ['Overview', 'Spending', 'Investing', 'Gas', 'History'])
      'money_${tab.toLowerCase()}': (
        () => NetWorthPage(store: finance()),
        (t) async {
          final f = find.text(tab).first;
          await t.ensureVisible(f);
          await t.pump();
          await t.tap(f);
          await settle(t);
        }
      ),
    'trips': (() => TripsPage(store: FakeTrips([trip()]), active: true), null),
    'trip': (
      () => TripsPage(store: FakeTrips([trip()]), active: true),
      (t) async {
        await t.tap(find.text('Spring break in New Orleans').first);
        await settle(t);
      }
    ),
  };

  testWidgets('the month’s name is whole in the toolbar, every month, on a small phone', (t) async {
    await t.runAsync(loadFonts);
    await show(t, CalendarPage(service: calendar()), const Size(360, 740));
    for (var i = 0; i < 12; i++) {
      final title = t.renderObject<RenderParagraph>(find.descendant(of: find.byType(CalendarPage), matching: find.byWidgetPredicate((w) => w is Text && w.style?.fontSize == 19)));
      expect(title.didExceedMaxLines, isFalse, reason: title.text.toPlainText());
      await t.tap(find.byIcon(Icons.chevron_right).last);
      await settle(t);
    }
  });

  testWidgets('an amount in the history never wraps in the middle', (t) async {
    await t.runAsync(loadFonts);
    await show(t, NetWorthPage(store: finance()), const Size(360, 740));
    final f = find.text('History').first;
    await t.ensureVisible(f);
    await t.pump();
    await t.tap(f);
    await settle(t);
    final amount = find.textContaining(RegExp(r'^\$\d')).first;
    expect(t.widget<Text>(amount).maxLines, 1);
    expect(t.renderObject<RenderParagraph>(amount).didExceedMaxLines, isFalse);
    expect(t.takeException(), isNull);
  });

  for (final size in const [Size(360, 740), Size(412, 915)]) {
    for (final MapEntry(key: name, value: (page, then)) in screens.entries) {
      testWidgets('$name at ${size.width.toInt()} wide', (t) async {
        await show(t, page(), size);
        if (then != null) await then(t);
        // The arrow's always clear of what's on the page.
        expect(find.byType(AssistantToggle), findsOneWidget);
        expect(t.takeException()?.toString(), isNull);
      });

      if (!skipPreview) {
        testWidgets('shot ${name}_${size.width.toInt()}', (t) async {
          await t.runAsync(loadFonts);
          await show(t, page(), size);
          if (then != null) await then(t);
          await t.pump(const Duration(milliseconds: 300));
          await shot(t, 'app_${name}_${size.width.toInt()}');
        });
      }
    }
  }
}

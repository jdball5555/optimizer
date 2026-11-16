import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/ai/ai_service.dart';
import 'package:optimizer/ai/assistant.dart';
import 'package:optimizer/ai/assistant_panel.dart';
import 'package:optimizer/calendar/calendar_page.dart';
import 'package:optimizer/theme.dart';
import 'package:optimizer/widgets/tiles.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'phone_layout_test.dart' show calendar;
import 'preview/calendar_preview_test.dart' show loadFonts, skipPreview;
import 'preview/pages_preview_test.dart' show shot;

class _Ai extends ChangeNotifier implements AiService {
  @override
  Set<AiShare> shared = AiShare.values.toSet();
  @override
  Set<AiAct> acts = {AiAct.calendar, AiAct.todos};
  @override
  bool confirmChanges = true;
  @override
  List<AiChat> chats = [];
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const pageKey = ValueKey('page');
  const panelKey = ValueKey('panel');

  Future<ValueNotifier<bool>> pump(WidgetTester t, {double window = 1400, bool enabled = true, bool open = false}) async {
    t.view.physicalSize = Size(window, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final on = ValueNotifier(open);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: AssistantSplit(
          open: on,
          enabled: enabled,
          panel: const SizedBox.expand(key: panelKey),
          child: Builder(builder: (context) => SizedBox.expand(key: pageKey, child: Text('${MediaQuery.sizeOf(context).width}'))),
        ),
      ),
    ));
    await t.pumpAndSettle();
    return on;
  }

  double pageWidth(WidgetTester t) => t.getSize(find.byKey(pageKey)).width;
  double panelWidth(WidgetTester t) => t.getSize(find.byKey(panelKey)).width;

  group('the panel', () {
    testWidgets('closed, the page has all the room', (t) async {
      await pump(t);
      expect(pageWidth(t), 1400);
      expect(find.byKey(panelKey), findsNothing);
    });

    testWidgets('open, it pushes the page over rather than covering it', (t) async {
      final on = await pump(t);
      on.value = true;
      await t.pumpAndSettle();
      expect(pageWidth(t), lessThan(1400));
      final page = t.getRect(find.byKey(pageKey)), panel = t.getRect(find.byKey(panelKey));
      expect(panel.left, greaterThanOrEqualTo(page.right), reason: 'side by side, not on top');
      // The page knows, so it lays itself out for what it really has.
      expect(find.text('${pageWidth(t)}'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('sits inside a tile', (t) async {
      await pump(t, open: true);
      expect(find.ancestor(of: find.byKey(panelKey), matching: find.byType(Tile)), findsOneWidget);
    });

    testWidgets('dragging its edge makes it wider or narrower, and the page gives way', (t) async {
      await pump(t, open: true);
      final panel = panelWidth(t), page = pageWidth(t);
      await t.drag(find.byKey(const ValueKey('assistant-resize')), const Offset(-120, 0), touchSlopX: 0);
      await t.pumpAndSettle();
      expect(panelWidth(t), closeTo(panel + 120, 1));
      expect(pageWidth(t), closeTo(page - 120, 1));
      await t.drag(find.byKey(const ValueKey('assistant-resize')), const Offset(200, 0), touchSlopX: 0);
      await t.pumpAndSettle();
      expect(panelWidth(t), closeTo(panel - 80, 1));
      expect(t.takeException(), isNull);
    });

    testWidgets('can’t be dragged too small, or so big the page disappears', (t) async {
      await pump(t, open: true);
      await t.drag(find.byKey(const ValueKey('assistant-resize')), const Offset(900, 0), touchSlopX: 0);
      await t.pumpAndSettle();
      expect(panelWidth(t), greaterThan(250));
      await t.drag(find.byKey(const ValueKey('assistant-resize')), const Offset(-2000, 0), touchSlopX: 0);
      await t.pumpAndSettle();
      expect(pageWidth(t), greaterThanOrEqualTo(360));
      expect(t.takeException(), isNull);
    });

    testWidgets('remembers how wide you made it', (t) async {
      await pump(t, open: true);
      await t.drag(find.byKey(const ValueKey('assistant-resize')), const Offset(-100, 0), touchSlopX: 0);
      await t.pumpAndSettle();
      final wide = panelWidth(t);
      await t.pumpWidget(const SizedBox());
      await pump(t, open: true);
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 20)));
      await t.pumpAndSettle();
      expect(panelWidth(t), closeTo(wide, 1));
    });

    testWidgets('where it isn’t enabled, opening it changes nothing here', (t) async {
      await pump(t, enabled: false, open: true);
      expect(pageWidth(t), 1400);
      expect(find.byKey(panelKey), findsNothing);
    });

    test('pushes only where the window has room for both', () {
      expect(AssistantSplit.fits(1280), isTrue);
      expect(AssistantSplit.fits(800), isFalse);
    });
  });

  /// As the app puts it all together.
  Future<ValueNotifier<bool>> inApp(WidgetTester t, Widget page, {Size size = const Size(1500, 900), bool arrow = true, EdgeInsets safe = EdgeInsets.zero, AssistantController? controller, double rail = 72}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    t.view.padding = FakeViewPadding(top: safe.top);
    addTearDown(t.view.reset);
    final c = controller ?? AssistantController(ai: _Ai(), calendar: calendar(), context: () async => '');
    final panel = AssistantChat(controller: c, onOpenSettings: () {}, onClose: () => c.panelOpen.value = false);
    final wide = size.width >= 720, pushes = wide && AssistantSplit.fits(size.width);
    final body = PageEnd(end: arrow ? AssistantArrowRoom(open: c.panelOpen) : null, child: page);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(),
      debugShowCheckedModeBanner: false,
      builder: (_, child) => RepaintBoundary(key: const ValueKey('shot'), child: child!),
      home: AssistantOverlay(
        open: c.panelOpen,
        enabled: !pushes,
        arrow: arrow,
        panel: panel,
        child: Scaffold(
          body: wide
              ? Row(children: [
                  Container(width: rail, decoration: const BoxDecoration(border: Border(right: BorderSide(color: AppColors.border)))),
                  Expanded(child: AssistantSplit(open: c.panelOpen, enabled: pushes, panel: panel, child: body)),
                ])
              : SafeArea(bottom: false, child: body),
        ),
      ),
    ));
    await t.pump(const Duration(milliseconds: 400));
    return c.panelOpen;
  }

  group('the arrow', () {
    Finder arrow() => find.byType(AssistantToggle);
    Finder close() => find.byTooltip('Close');

    const pages = <String, Widget>{
      'title': PageHeader(title: 'People'),
      'tabs': _Tabs(),
    };

    for (final size in const [Size(1500, 900), Size(1000, 800), Size(800, 700), Size(360, 740)]) {
      testWidgets('is in the same spot on every page, at ${size.width.toInt()} wide', (t) async {
        final spots = <Rect>[];
        for (final page in [...pages.values, CalendarPage(service: calendar())]) {
          await t.pumpWidget(const SizedBox());
          await inApp(t, page, size: size);
          spots.add(t.getRect(arrow()));
        }
        expect(spots.toSet(), hasLength(1));
        expect(spots.first.right, greaterThan(size.width - 20), reason: 'in the far right corner');
        expect(spots.first.top, lessThan(30));
        expect(t.takeException(), isNull);
      });

      testWidgets('is exactly where the panel’s own arrow closes it from, at ${size.width.toInt()} wide', (t) async {
        final on = await inApp(t, const PageHeader(title: 'People'), size: size);
        final where = t.getCenter(arrow());
        on.value = true;
        await t.pump();
        await t.pump(const Duration(seconds: 1));
        expect(arrow(), findsNothing, reason: 'just the one on the tile while it’s open');
        expect(close(), findsOneWidget);
        expect(t.getCenter(close()), offsetMoreOrLessEquals(where, epsilon: 1));
        await t.tap(close());
        await t.pump();
        await t.pump(const Duration(seconds: 1));
        expect(on.value, isFalse);
        expect(t.getCenter(arrow()), where);
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('allows for a status bar on a phone', (t) async {
      await inApp(t, const PageHeader(title: 'People'), size: const Size(360, 740), safe: const EdgeInsets.only(top: 30));
      expect(t.getTopLeft(arrow()).dy, 40);
    });

    testWidgets('opens the panel, and is plain rather than colored', (t) async {
      final on = await inApp(t, const PageHeader(title: 'People'));
      expect(find.descendant(of: arrow(), matching: find.byType(ShaderMask)), findsNothing);
      await t.tap(arrow());
      await t.pump();
      expect(on.value, isTrue);
    });

    testWidgets('isn’t on the Ask page', (t) async {
      await inApp(t, const SizedBox(), arrow: false);
      expect(arrow(), findsNothing);
    });

    group('never sits on a page’s buttons', () {
      testWidgets('a title row, in a narrow window where it reaches the corner', (t) async {
        await inApp(t, PageHeader(title: 'People', actions: [TextButton(onPressed: () {}, child: const Text('New group'))]), size: const Size(1000, 800));
        expect(t.getTopRight(find.text('New group')).dx, lessThan(t.getTopLeft(arrow()).dx));
      });

      testWidgets('a title row in a column down the middle stays in line with it', (t) async {
        await inApp(
            t,
            Center(child: SizedBox(width: 760, child: PageHeader(title: 'People', actions: [TextButton(onPressed: () {}, child: const Text('New group'))]))),
            size: const Size(1500, 900));
        final button = t.getTopRight(find.ancestor(of: find.text('New group'), matching: find.byType(TextButton)));
        expect(button.dx, closeTo(72 + (1428 + 760) / 2, 1), reason: 'to the column’s edge');
        expect(button.dx, lessThan(t.getTopLeft(arrow()).dx));
      });

      testWidgets('a row of tabs', (t) async {
        await inApp(
            t,
            PageTabsHeader<int>(
              items: const [(0, 'Journal')],
              selected: 0,
              onSelected: (_) {},
              actions: [IconButton(tooltip: 'Search entries', icon: const Icon(Icons.search), onPressed: () {})],
            ));
        expect(t.getTopRight(find.byTooltip('Search entries')).dx, lessThanOrEqualTo(t.getTopLeft(arrow()).dx));
      });

      for (final size in const [Size(1500, 900), Size(1000, 800), Size(800, 700)]) {
        testWidgets('the calendar’s toolbar, at ${size.width.toInt()} wide', (t) async {
          await inApp(t, CalendarPage(service: calendar()), size: size);
          final sync = t.getTopRight(find.byTooltip('Sync with Google now'));
          final mine = t.getRect(arrow());
          expect(sync.dx <= mine.left || sync.dy >= mine.bottom, isTrue, reason: 'beside it, or on the row below');
          expect(t.takeException(), isNull);
        });
      }

      testWidgets('a phone’s calendar toolbar', (t) async {
        await inApp(t, CalendarPage(service: calendar()), size: const Size(360, 740));
        final plus = t.getTopRight(find.byTooltip('New event'));
        expect(plus.dx, lessThanOrEqualTo(t.getTopLeft(arrow()).dx));
        expect(t.takeException(), isNull);
        // Today has moved to the menu, and still works.
        await t.tap(find.text('Week'));
        await t.pumpAndSettle();
        expect(find.text('Today'), findsOneWidget);
        await t.tap(find.text('Today'));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      });
    });

    testWidgets('leaves the room free for the page while the panel’s open', (t) async {
      final on = await inApp(t, PageHeader(title: 'People', actions: [TextButton(onPressed: () {}, child: const Text('New group'))]), size: const Size(1000, 800));
      final before = t.getTopRight(find.text('New group')).dx;
      on.value = true;
      await t.pump();
        await t.pump(const Duration(seconds: 1));
      expect(find.byType(AssistantArrowRoom), findsOneWidget);
      expect(t.getSize(find.byType(AssistantArrowRoom)).width, 0);
      expect(t.getTopRight(find.text('New group')).dx, lessThan(before));
    });
  });

  group('the drag bar', () {
    testWidgets('sits tight between the page and the tile', (t) async {
      final page = GlobalKey();
      final on = await inApp(t, SizedBox.expand(key: page), size: const Size(1440, 900));
      on.value = true;
      await t.pump();
        await t.pump(const Duration(seconds: 1));
      final bar = t.getRect(find.byKey(const ValueKey('assistant-resize')));
      final tile = t.getRect(find.ancestor(of: find.byType(AssistantChat), matching: find.byType(Tile)).first);
      expect(bar.width, 8);
      expect(bar.right, tile.left, reason: 'right up against the tile');
      expect(bar.left, closeTo(t.getRect(find.byKey(page)).right - 6, 1), reason: 'reaching back over the page’s own gap');
    });

    testWidgets('still leaves part of a page’s scrollbar to grab', (t) async {
      final page = GlobalKey();
      final on = await inApp(t, SizedBox.expand(key: page));
      on.value = true;
      await t.pump();
        await t.pump(const Duration(seconds: 1));
      final bar = t.getRect(find.byKey(const ValueKey('assistant-resize')));
      // A scrollbar's thumb runs from 9 to 3 in from the page's edge.
      expect(bar.left, greaterThan(t.getRect(find.byKey(page)).right - 9));
    });
  });

  group('the page beside it', () {
    for (final width in const [1000.0, 1200.0, 1440.0, 1920.0]) {
      testWidgets('the calendar still fits a ${width.toInt()} window, in week and month', (t) async {
        final on = await inApp(t, CalendarPage(service: calendar()), size: Size(width, 900));
        on.value = true;
        await t.pump();
        await t.pump(const Duration(seconds: 1));
        expect(t.takeException(), isNull);
        // In the smallest, the page has narrowed to its compact toolbar: no tabs.
        if (find.text('Month').evaluate().isNotEmpty) {
          await t.tap(find.text('Month'));
          await t.pump();
          await t.pump(const Duration(seconds: 1));
          expect(t.takeException(), isNull);
        }
      });
    }
  });

  group('previews', () {
    for (final (name, open, size) in const [
      ('assistant_closed', false, Size(1440, 900)),
      ('assistant_open', true, Size(1440, 900)),
      ('assistant_open_small', true, Size(1100, 760)),
      ('assistant_phone', false, Size(360, 740)),
    ]) {
      testWidgets(skip: skipPreview, name, (t) async {
        await t.runAsync(loadFonts);
        final on = await inApp(t, CalendarPage(service: calendar()), size: size);
        on.value = open;
        await t.pump();
        await t.pump(const Duration(seconds: 1));
        await t.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
        await t.pump();
        await t.pump(const Duration(seconds: 1));
        await shot(t, name);
        expect(t.takeException(), isNull);
      });
    }

    testWidgets(skip: skipPreview, 'assistant_people', (t) async {
      await t.runAsync(loadFonts);
      await inApp(
          t,
          ListView(padding: const EdgeInsets.fromLTRB(16, 32, 16, 32), children: [
            Center(child: SizedBox(width: 760, child: PageHeader(title: 'People', actions: [FilledButton(onPressed: () {}, child: const Text('New group'))]))),
          ]),
          size: const Size(1440, 500));
      await shot(t, 'assistant_people');
    });
  });
}

class _Tabs extends StatelessWidget {
  const _Tabs();

  @override
  Widget build(BuildContext context) => PageTabsHeader<int>(items: const [(0, 'Journal'), (1, 'Habits')], selected: 0, onSelected: (_) {});
}

class DateFormatMonth {
  static String now() => const ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][DateTime.now().month - 1];
}

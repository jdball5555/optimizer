import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/focus/energy_beam.dart';
import 'package:optimizer/focus/focus_page.dart';
import 'package:optimizer/focus/focus_store.dart';
import 'package:optimizer/theme.dart';

import 'preview/calendar_preview_test.dart' show loadFonts, skipPreview;
import 'preview/pages_preview_test.dart' show shot;

FocusSession session(String state, List<(String, Duration)> marks, {int? minutes = 50, String title = 'Chem lab report'}) {
  final start = DateTime.now().subtract(const Duration(minutes: 40));
  return FocusSession(
    id: 's',
    title: title,
    plannedMinutes: minutes,
    marks: [for (final (what, after) in marks) FocusMark(what, start.add(after))],
    state: state,
  );
}

/// A store that ends sessions without Firestore.
class EndingStore extends FocusStore {
  EndingStore(List<FocusSession> sessions) : super.preview('u', sessions);
  int ended = 0;
  @override
  Future<void> end() async {
    ended++;
    sessions = [];
    notifyListeners();
  }
}

void main() {
  test('pauses don’t count as focus, and every mark is kept', () {
    final s = session('done', [
      ('start', Duration.zero),
      ('pause', const Duration(minutes: 20)),
      ('resume', const Duration(minutes: 25)),
      ('end', const Duration(minutes: 40)),
    ]);
    expect(s.focusedAt(DateTime.now()), const Duration(minutes: 35));
    expect(s.pausedAt(DateTime.now()), const Duration(minutes: 5));
    expect(s.pauses, 1);
    expect(s.marks.map((m) => m.what), ['start', 'pause', 'resume', 'end']);
  });

  test('a paused session stops counting', () {
    final s = session('paused', [('start', Duration.zero), ('pause', const Duration(minutes: 12))]);
    expect(s.focusedAt(DateTime.now().add(const Duration(hours: 1))), const Duration(minutes: 12));
  });

  test('clock formats', () {
    expect(focusClock(const Duration(minutes: 4, seconds: 5)), '4:05');
    expect(focusClock(const Duration(hours: 1, minutes: 4, seconds: 5)), '1:04:05');
    expect(focusShort(const Duration(hours: 2, minutes: 5)), '2h 05m');
  });

  Future<void> shoot(WidgetTester tester, FocusStore store, String name, Size size) async {
    await tester.runAsync(loadFonts);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      debugShowCheckedModeBanner: false,
      home: RepaintBoundary(key: const ValueKey('shot'), child: FocusPage(store: store)),
    ));
    await tester.pump(const Duration(milliseconds: 900));
    await shot(tester, name);
    tester.view.reset();
  }

  final running = session('running', [
    ('start', Duration.zero),
    ('pause', const Duration(minutes: 18)),
    ('resume', const Duration(minutes: 22)),
  ]);
  final done = [
    session('done', [('start', Duration.zero), ('end', const Duration(minutes: 50))], title: 'Essay outline'),
    session('done', [('start', Duration.zero), ('pause', const Duration(minutes: 10)), ('resume', const Duration(minutes: 15)), ('end', const Duration(minutes: 30))], minutes: null, title: 'Problem set 6'),
  ];

  for (final (name, size) in [('phone', const Size(412, 915)), ('desktop', const Size(1400, 950))]) {
    testWidgets(skip: skipPreview, 'focus running $name', (tester) => shoot(tester, FocusStore.preview('u', [running]), 'focus_running_$name', size));
    testWidgets(skip: skipPreview, 'focus start $name', (tester) => shoot(tester, FocusStore.preview('u', done), 'focus_start_$name', size));
  }
  testWidgets(skip: skipPreview, 'focus paused phone', (tester) => shoot(
      tester,
      FocusStore.preview('u', [session('paused', [('start', Duration.zero), ('pause', const Duration(minutes: 31))])]),
      'focus_paused_phone',
      const Size(412, 915)));

  group('the gate', () {
    Future<void> pumpGate(WidgetTester tester, FocusStore store,
        {bool open = false, VoidCallback? onClose, Size size = const Size(1400, 900), bool enabled = true}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: FocusGate(
          store: store,
          open: open,
          enabled: enabled,
          onClose: onClose ?? () {},
          child: const Scaffold(body: Text('the rest of the app')),
        ),
      ));
      await tester.pump();
    }

    final going = session('running', [('start', Duration.zero)]);

    // The beam never stops animating, so pumpAndSettle would wait forever.
    Future<void> settled(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('during a session the app opens on the focus page, with nothing else in reach', (tester) async {
      await pumpGate(tester, EndingStore([going]));
      expect(find.text('Pause'), findsOneWidget);
      expect(find.text('the rest of the app').hitTestable(), findsNothing);
    });

    testWidgets('without premium beta there’s no focus: a session going elsewhere doesn’t take over', (tester) async {
      await pumpGate(tester, EndingStore([going]), open: true, enabled: false);
      expect(find.text('Pause'), findsNothing);
      expect(find.text('the rest of the app').hitTestable(), findsOneWidget);
    });

    testWidgets('with no session, the app opens normally', (tester) async {
      await pumpGate(tester, EndingStore([]));
      expect(find.text('Start focus'), findsNothing);
      expect(find.text('the rest of the app').hitTestable(), findsOneWidget);
    });

    testWidgets('a session started on another device takes over, and ending it gives the app back', (tester) async {
      final store = EndingStore([]);
      await pumpGate(tester, store);
      store.sessions = [going];
      store.notifyListeners();
      await tester.pump();
      expect(find.text('Pause'), findsOneWidget);
      await store.end();
      await tester.pump();
      expect(find.text('the rest of the app').hitTestable(), findsOneWidget);
    });

    testWidgets('the rest of the app stays hidden until it’s known whether a session is going', (tester) async {
      final store = EndingStore([])..loaded = false;
      await pumpGate(tester, store);
      expect(find.text('the rest of the app').hitTestable(), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('the rest of the app').hitTestable(), findsOneWidget);
    });

    for (final (name, back) in <(String, Future<void> Function(WidgetTester))>[
      ('the back arrow', (t) => t.tap(find.byTooltip('Back'))),
      ('the phone or browser back button', (t) async => t.binding.handlePopRoute()),
    ]) {
      testWidgets('$name asks, and only ends focus on yes', (tester) async {
        var closed = 0;
        final store = EndingStore([going]);
        await pumpGate(tester, store, onClose: () => closed++);
        await back(tester);
        await settled(tester);
        expect(find.text('End focus?'), findsOneWidget);
        await tester.tap(find.text('Keep going'));
        await settled(tester);
        expect(store.ended, 0);
        expect(find.text('Pause'), findsOneWidget);

        await back(tester);
        await settled(tester);
        await tester.tap(find.text('End focus'));
        await settled(tester);
        expect(store.ended, 1);
        expect(closed, 1);
        expect(find.text('the rest of the app').hitTestable(), findsOneWidget);
      });
    }

    testWidgets('with no session, back just goes back', (tester) async {
      var closed = 0;
      await pumpGate(tester, EndingStore([]), open: true, onClose: () => closed++);
      expect(find.text('Start focus'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('End focus?'), findsNothing);
      expect(closed, 1);
    });

    testWidgets('keyboard shortcuts underneath don’t fire, and work again afterwards', (tester) async {
      var pressed = 0;
      final store = EndingStore([]);
      Widget app(bool open) => MaterialApp(
            theme: buildTheme(),
            home: FocusGate(
              store: store,
              open: open,
              onClose: () {},
              child: Scaffold(
                body: CallbackShortcuts(
                  bindings: {const SingleActivator(LogicalKeyboardKey.keyC): () => pressed++},
                  child: const Focus(autofocus: true, child: Text('calendar')),
                ),
              ),
            ),
          );
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(false));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      expect(pressed, 1);
      await tester.pumpWidget(app(true));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      expect(pressed, 1);
      await tester.pumpWidget(app(false));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      expect(pressed, 2);
    });

    for (final size in const [Size(1400, 900), Size(1000, 620), Size(900, 520), Size(1920, 1080), Size(412, 915), Size(800, 380)]) {
      final many = session('paused', [
        ('start', Duration.zero),
        for (var i = 1; i < 30; i++) (i.isOdd ? 'pause' : 'resume', Duration(seconds: i)),
      ], title: 'A really long thing to be working on that keeps going and going and going');
      testWidgets('fits ${size.width.toInt()}x${size.height.toInt()}, in a session and starting one', (tester) async {
        await pumpGate(tester, EndingStore([many]), size: size);
        expect(tester.takeException(), isNull);
        await pumpGate(tester, EndingStore(done), open: true, size: size);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a large screen puts the beam beside a panel; a phone stacks them', (tester) async {
      await pumpGate(tester, EndingStore([going]));
      expect(find.text('PAUSES'), findsOneWidget);
      expect(tester.getCenter(find.byType(EnergyBeam)).dx, lessThan(tester.getCenter(find.text('WORKING ON')).dx));
      await pumpGate(tester, EndingStore([going]), size: const Size(412, 915));
      expect(find.text('PAUSES'), findsNothing);
    });
  });
}

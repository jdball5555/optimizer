import 'dart:ui' show PointerDeviceKind;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:optimizer/journal/journal_crypto.dart';
import 'package:optimizer/journal/journal_page.dart';
import 'package:optimizer/journal/journal_store.dart';
import 'package:optimizer/theme.dart';
import 'package:optimizer/util/fields.dart';

import 'phone_layout_test.dart' show habits;
import 'preview/pages_preview_test.dart' show FakeDoc;

JournalEntry _entry(String id, DateTime day, String body, {String? header}) => JournalEntry(FakeDoc(id, {
      'appearsAsDate': DateFormat('yyyy-MM-dd').format(day),
      'timestamp': Timestamp.fromDate(day),
      'content': JournalCrypto.encryptText(body),
      if (header != null) 'header': header,
    }));

/// No Firestore: what's saved is noted, and shows as if it had come back.
class _Store extends JournalStore {
  _Store(List<JournalEntry> list) : super.withEntries('u', list);

  final updates = <({String id, String body, String header, DateTime date})>[];
  final created = <({String body, String header, DateTime? date})>[];
  final deleted = <String>[];

  @override
  Future<String> create({required String body, String header = '', DateTime? date}) async {
    created.add((body: body, header: header, date: date));
    return 'new';
  }

  @override
  Future<void> update(JournalEntry e, {required String body, required String header, required DateTime date}) async {
    updates.add((id: e.id, body: body, header: header, date: date));
  }

  @override
  Future<void> delete(String id) async {
    deleted.add(id);
    entries = entries.where((e) => e.id != id).toList();
    notifyListeners();
  }
}

void main() {
  final today = dayStart(DateTime.now());
  final lastWeek = addDays(today, -7);
  const hint = 'Type header…';
  Finder undo() => find.byTooltip('Undo');
  Finder redo() => find.byTooltip('Redo');
  Finder done() => find.byTooltip('Done');
  Finder tabs() => find.text('Habits');
  bool enabled(WidgetTester t, Finder f) => t.widget<IconButton>(find.ancestor(of: f, matching: find.byType(IconButton)).first).onPressed != null;

  Future<_Store> pump(WidgetTester t, List<JournalEntry> list, {Size size = const Size(412, 915)}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final s = _Store(list);
    await t.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: JournalPage(store: s, habits: habits()))));
    await t.pump(const Duration(milliseconds: 300));
    return s;
  }

  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(seconds: 1));
  }

  group('on a phone', () {
    testWidgets('a new entry has no header line until you ask for one', (t) async {
      await pump(t, [_entry('a', today, 'Hello')]);
      await t.tap(find.text('Add a new entry'));
      await settle(t);
      expect(find.text(hint), findsNothing);
      expect(find.text('Start writing…'), findsOneWidget);
      expect(find.text('Done'), findsNothing, reason: 'the check mark is at the top now');
      expect(t.takeException(), isNull);
    });

    testWidgets('editing an entry with no header has none either', (t) async {
      await pump(t, [_entry('a', today, 'Hello')]);
      await t.tap(find.text('Hello'));
      await settle(t);
      expect(find.text(hint), findsNothing);
    });

    testWidgets('one that has a header shows it', (t) async {
      await pump(t, [_entry('a', today, 'Hello', header: 'Momentum')]);
      await t.tap(find.text('Hello'));
      await settle(t);
      expect(find.widgetWithText(TextField, 'Momentum'), findsOneWidget);
    });

    testWidgets('holding the date while writing offers it, and the line comes up ready to type', (t) async {
      final s = await pump(t, [_entry('a', today, 'Hello')]);
      await t.tap(find.text('Hello'));
      await settle(t);
      await t.longPress(find.text(journalDate(today)));
      await settle(t);
      expect(find.text('Change appear as date'), findsOneWidget);
      await t.tap(find.text('Add header'));
      await settle(t);
      expect(find.text(hint), findsOneWidget);
      final field = find.ancestor(of: find.text(hint), matching: find.byType(TextField));
      expect(t.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      await t.enterText(field, 'Big day');
      await t.tap(done());
      await settle(t);
      expect(s.updates.last.header, 'Big day');
      expect(t.takeException(), isNull);
    });

    testWidgets('holding the date while reading offers it too', (t) async {
      await pump(t, [_entry('a', today, 'Hello')]);
      await t.longPress(find.text(journalDate(today)));
      await settle(t);
      await t.tap(find.text('Add header'));
      await settle(t);
      expect(find.text(hint), findsOneWidget);
      expect(done(), findsOneWidget);
    });

    testWidgets('a header added and left empty goes away again', (t) async {
      await pump(t, [_entry('a', today, 'Hello')]);
      await t.tap(find.text('Add a new entry'));
      await settle(t);
      await t.longPress(find.text(journalDate(today)).last);
      await settle(t);
      await t.tap(find.text('Add header'));
      await settle(t);
      expect(find.text(hint), findsOneWidget);
      await t.tap(done());
      await settle(t);
      expect(find.text(hint), findsNothing);
    });

    testWidgets('while writing: undo, redo and a check mark instead of the tabs', (t) async {
      await pump(t, [_entry('a', today, 'Hello')]);
      expect(tabs(), findsOneWidget);
      expect(done(), findsNothing);
      await t.tap(find.text('Hello'));
      await settle(t);
      expect(tabs(), findsNothing);
      expect(undo(), findsOneWidget);
      expect(redo(), findsOneWidget);
      expect(t.getTopLeft(undo()).dx, lessThan(t.getTopLeft(redo()).dx));
      expect(t.getTopLeft(redo()).dx, lessThan(100), reason: 'top left');
      expect(t.getTopRight(done()).dx, greaterThan(350), reason: 'top right');
      expect(t.getTopLeft(done()).dy, lessThan(40));
      expect(t.takeException(), isNull);
    });

    testWidgets('the check mark saves, closes it and brings the tabs back', (t) async {
      final s = await pump(t, [_entry('a', today, 'Hello')]);
      await t.tap(find.text('Hello'));
      await settle(t);
      await t.enterText(find.byType(TextField), 'Hello there');
      await t.tap(done());
      await settle(t);
      expect(s.updates.single.body, 'Hello there');
      expect(tabs(), findsOneWidget);
      expect(done(), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('the page doesn’t jump when the bar swaps in', (t) async {
      await pump(t, [_entry('a', today, 'Hello')]);
      final before = t.getTopLeft(find.text(journalDate(today))).dy;
      await t.tap(find.text('Hello'));
      await settle(t);
      expect(t.getTopLeft(find.text(journalDate(today))).dy, closeTo(before, 1));
    });

    testWidgets('undo and redo work, and undoing is saved too', (t) async {
      final s = await pump(t, [_entry('a', today, 'Hello')]);
      await t.tap(find.text('Hello'));
      await settle(t);
      expect(enabled(t, undo()), isFalse, reason: 'nothing to undo yet');
      final field = find.byType(TextField);
      await t.enterText(field, 'Hello there');
      await settle(t);
      expect(enabled(t, undo()), isTrue);
      await t.tap(undo());
      await settle(t);
      expect(t.widget<TextField>(field).controller!.text, 'Hello');
      expect(enabled(t, redo()), isTrue);
      await t.tap(redo());
      await settle(t);
      expect(t.widget<TextField>(field).controller!.text, 'Hello there');
      await t.tap(undo());
      await settle(t);
      expect(s.updates.last.body, 'Hello', reason: 'autosaved like typing');
    });

    testWidgets('undo works on whichever field you’re in', (t) async {
      await pump(t, [_entry('a', today, 'Hello', header: 'Momentum')]);
      await t.tap(find.text('Hello'));
      await settle(t);
      final header = find.widgetWithText(TextField, 'Momentum');
      final body = find.widgetWithText(TextField, 'Hello');
      await t.enterText(body, 'Hello there');
      await settle(t);
      await t.tap(header);
      await settle(t);
      await t.enterText(header, 'Momentum!');
      await settle(t);
      await t.tap(undo());
      await settle(t);
      expect(find.widgetWithText(TextField, 'Momentum'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Hello there'), findsOneWidget, reason: 'left alone');
    });

    Future<void> pickDay(WidgetTester t, int day) async {
      await t.tap(find.text('Change appear as date'));
      await settle(t);
      await t.tap(find.text('$day'));
      await t.pump();
      await t.tap(find.text('OK'));
      await settle(t);
    }

    testWidgets('the appear as date can be changed while writing', (t) async {
      final s = await pump(t, [_entry('a', today, 'Hello')]);
      await t.tap(find.text('Hello'));
      await settle(t);
      await t.longPress(find.text(journalDate(today)));
      await settle(t);
      final other = today.day == 15 ? 16 : 15;
      await pickDay(t, other);
      final shown = DateTime(today.year, today.month, other);
      expect(find.text(journalDate(shown)), findsOneWidget);
      await t.tap(done());
      await settle(t);
      expect(sameDay(s.updates.last.date, shown), isTrue);
    });

    testWidgets('and while reading, keeping what’s written', (t) async {
      final s = await pump(t, [_entry('a', today, 'Hello', header: 'Momentum')]);
      await t.longPress(find.text(journalDate(today)));
      await settle(t);
      final other = today.day == 15 ? 16 : 15;
      await pickDay(t, other);
      expect(s.updates.single.body, 'Hello');
      expect(s.updates.single.header, 'Momentum');
      expect(sameDay(s.updates.single.date, DateTime(today.year, today.month, other)), isTrue);
    });

    testWidgets('and on a new entry, before there’s anything saved', (t) async {
      final s = await pump(t, [_entry('a', lastWeek, 'Hello')]);
      await t.tap(find.text('Add a new entry'));
      await settle(t);
      await t.longPress(find.text(journalDate(today)));
      await settle(t);
      expect(find.text('Delete'), findsNothing, reason: 'nothing to delete yet');
      expect(find.text('Edit referenced people'), findsNothing);
      final other = today.day == 15 ? 16 : 15;
      await pickDay(t, other);
      await t.enterText(find.byType(TextField), 'New one');
      await t.tap(done());
      await settle(t);
      expect(sameDay(s.created.single.date!, DateTime(today.year, today.month, other)), isTrue);
    });

    testWidgets('a past entry asks before you edit it', (t) async {
      await pump(t, [_entry('a', lastWeek, 'Old')]);
      await t.tap(find.text('Old'));
      await settle(t);
      expect(find.text('Edit past entry'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await settle(t);
      expect(find.byType(TextField), findsNothing);
      expect(tabs(), findsOneWidget);
    });

    testWidgets('deleting from the menu asks, and closes what’s being written', (t) async {
      final s = await pump(t, [_entry('a', today, 'Hello')]);
      await t.tap(find.text('Hello'));
      await settle(t);
      await t.enterText(find.byType(TextField), 'Hello there');
      await t.longPress(find.text(journalDate(today)));
      await settle(t);
      await t.tap(find.text('Delete'));
      await settle(t);
      expect(s.deleted, isEmpty);
      final saves = s.updates.length;
      await t.tap(find.widgetWithText(FilledButton, 'Delete'));
      await settle(t);
      await t.pump(const Duration(seconds: 2));
      expect(s.deleted, ['a']);
      expect(s.updates, hasLength(saves), reason: 'nothing saved onto what’s gone');
      expect(tabs(), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('a save that fails stays open, rather than losing it', (t) async {
      final s = _Failing([_entry('a', today, 'Hello')]);
      t.view.physicalSize = const Size(412, 915);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: JournalPage(store: s, habits: habits()))));
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.text('Hello'));
      await settle(t);
      await t.enterText(find.byType(TextField), 'Hello there');
      await t.tap(done());
      await settle(t);
      expect(find.text('Couldn’t save'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(done(), findsOneWidget);
    });
  });

  group('on a wide screen', () {
    const wide = Size(1400, 900);

    testWidgets('reading isn’t writing: the tabs stay until you’re in the text', (t) async {
      await pump(t, [_entry('a', today, 'Hello')], size: wide);
      await t.tap(find.text('Hello'));
      await settle(t);
      expect(tabs(), findsOneWidget);
      expect(done(), findsNothing);
      await t.tap(find.widgetWithText(TextField, 'Hello'));
      await settle(t);
      expect(tabs(), findsNothing);
      expect(done(), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('no Add header button or header line by default', (t) async {
      await pump(t, [_entry('a', today, 'Hello')], size: wide);
      await t.tap(find.text('Hello'));
      await settle(t);
      expect(find.text('Add header'), findsNothing);
      expect(find.text(hint), findsNothing);
    });

    for (final open in ['the date', 'More']) {
      testWidgets('$open brings up the menu, to add a header', (t) async {
        await pump(t, [_entry('a', today, 'Hello')], size: wide);
        await t.tap(find.text('Hello'));
        await settle(t);
        await t.tap(open == 'More' ? find.byTooltip('More').last : find.text(journalDate(today)).last);
        await settle(t);
        await t.tap(find.text('Add header'));
        await settle(t);
        expect(find.text(hint), findsOneWidget);
        expect(done(), findsOneWidget);
      });
    }

    testWidgets('the check mark saves and leaves it there to read', (t) async {
      final s = await pump(t, [_entry('a', today, 'Hello')], size: wide);
      await t.tap(find.text('Hello'));
      await settle(t);
      final field = find.widgetWithText(TextField, 'Hello');
      await t.tap(field);
      await settle(t);
      await t.enterText(field, 'Hello there');
      await t.tap(done());
      await settle(t);
      expect(s.updates.single.body, 'Hello there');
      expect(find.widgetWithText(TextField, 'Hello there'), findsOneWidget);
      expect(tabs(), findsOneWidget);
    });

    testWidgets('a new entry left empty closes', (t) async {
      await pump(t, [_entry('a', today, 'Hello')], size: wide);
      await t.tap(find.text('Write'));
      await settle(t);
      expect(done(), findsOneWidget);
      await t.tap(done());
      await settle(t);
      expect(find.text('Pick an entry to read it here.'), findsOneWidget);
    });

    testWidgets('a past entry asks when you go to edit it, and only then', (t) async {
      await pump(t, [_entry('a', lastWeek, 'Old')], size: wide);
      await t.tap(find.text('Old'));
      await settle(t);
      expect(find.text('Edit past entry'), findsNothing, reason: 'just reading');
      final field = find.widgetWithText(TextField, 'Old');
      expect(t.widget<TextField>(field).readOnly, isTrue);
      await t.tap(field);
      await settle(t);
      expect(find.text('Edit past entry'), findsOneWidget);
      await t.tap(find.text('Edit'));
      await settle(t);
      expect(t.widget<TextField>(field).readOnly, isFalse);
      expect(t.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      expect(done(), findsOneWidget);
    });

    testWidgets('with a mouse, the bar’s arrows don’t count as clicking away', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await pump(t, [_entry('a', today, 'Hello')], size: wide);
        await t.tap(find.text('Hello'));
        await settle(t);
        final field = find.widgetWithText(TextField, 'Hello');
        await t.tap(field, kind: PointerDeviceKind.mouse);
        await settle(t);
        await t.enterText(field, 'Hello there');
        await settle(t);
        await t.tap(undo(), kind: PointerDeviceKind.mouse);
        await settle(t);
        expect(find.widgetWithText(TextField, 'Hello'), findsOneWidget);
        expect(done(), findsOneWidget, reason: 'still writing');
        // Clicking anywhere else is.
        await t.tapAt(const Offset(1300, 880), kind: PointerDeviceKind.mouse);
        await settle(t);
        expect(done(), findsNothing);
        expect(tabs(), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}

class _Failing extends _Store {
  _Failing(super.list);

  @override
  Future<void> update(JournalEntry e, {required String body, required String header, required DateTime date}) async => throw Exception('offline');
}

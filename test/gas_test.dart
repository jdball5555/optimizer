import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/networth/finance_store.dart';
import 'package:optimizer/networth/net_worth_page.dart';
import 'package:optimizer/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What's saved goes straight onto the transaction, as Firestore would bring it back.
class _Store extends FinanceStore {
  _Store() : super.offline('u', key: encrypt.Encrypter(encrypt.AES(encrypt.Key.fromLength(32), mode: encrypt.AESMode.cbc)));

  final saved = <({double? miles, double? gallons})>[];
  Object? failure;

  @override
  Future<void> saveGas(Txn t, {double? miles, double? gallons}) async {
    if (failure != null) throw failure!;
    saved.add((miles: miles, gallons: gallons));
    miles == null ? t.data.remove('gasMileage') : t.data['gasMileage'] = miles;
    gallons == null ? t.data.remove('gasGallons') : t.data['gasGallons'] = gallons;
    notifyListeners();
  }

  void fills(List<(double?, double?)> list) {
    setTransactions([
      for (final (i, (miles, gallons)) in list.indexed)
        (
          'tx_$i',
          {
            'transaction_id': '$i',
            'date': '2026-0${i + 1}-15',
            'name': 'Shell $i',
            'amount': 30.0,
            'customCategory': 'Gas',
            if (miles != null) 'gasMileage': miles,
            if (gallons != null) 'gasGallons': gallons,
          },
        ),
    ], merchantCategories: const {});
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // Newest first, as the page shows them, so put back in the order they happened.
  List<GasFill> oldestFirst(_Store s) => s.gasFills.reversed.toList();

  group('miles per gallon', () {
    test('two full readings', () {
      final s = _Store()..fills([(1000, 10), (1300, 10)]);
      expect(oldestFirst(s).map((f) => f.mpg), [null, 30]);
    });

    test('a fill with only gallons is counted in the next reading’s', () {
      final s = _Store()..fills([(1000, 10), (null, 10), (1500, 10)]);
      final f = oldestFirst(s);
      expect(f[1].mpg, isNull);
      expect(f[2].miles, 500);
      expect(f[2].gallonsUsed, 20);
      expect(f[2].mpg, 25, reason: 'not 50, as if the last 10 gallons did all 500 miles');
    });

    test('a fill with only miles has no MPG, but its miles count', () {
      final s = _Store()..fills([(1000, 10), (1300, null)]);
      final f = oldestFirst(s);
      expect(f[1].mpg, isNull);
      expect(f[1].miles, 300);
    });

    test('the next one starts from that reading', () {
      final s = _Store()..fills([(1000, 10), (1300, null), (1600, 10)]);
      expect(oldestFirst(s)[2].mpg, 30);
    });

    test('a fill with nothing in between means nobody knows the gas used', () {
      final s = _Store()..fills([(1000, 10), (null, null), (1500, 10)]);
      final f = oldestFirst(s);
      expect(f[2].mpg, isNull, reason: 'guessing from 10 gallons would say 50');
      expect(f[2].miles, 500);
    });

    test('gallons before the first reading aren’t counted', () {
      final s = _Store()..fills([(null, 10), (1000, 10), (1300, 10)]);
      expect(oldestFirst(s).map((f) => f.mpg), [null, null, 30]);
    });

    test('an odometer that went backwards is no answer, and starts over from there', () {
      final s = _Store()..fills([(1000, 10), (900, 10), (1200, 10)]);
      expect(oldestFirst(s).map((f) => f.mpg), [null, null, 30]);
    });

    test('Asset Track’s 0 for a blank field counts as blank', () {
      final s = _Store()..fills([(1000, 10), (0, 10), (1500, 0), (1800, 10)]);
      final f = oldestFirst(s);
      expect(f[1].txn.gasMiles, isNull);
      expect(f[2].txn.gasGallons, isNull);
      expect(f[2].miles, 500);
      expect(f[2].mpg, isNull, reason: 'its gallons weren’t filled in');
      expect(f[3].mpg, 30);
    });

    test('price per gallon needs only the gallons', () {
      final s = _Store()..fills([(null, 10)]);
      expect(s.gasFills.single.pricePerGallon, 3);
    });
  });

  group('the page', () {
    Future<_Store> pump(WidgetTester t, List<(double?, double?)> fills) async {
      t.view.physicalSize = const Size(1500, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final s = _Store()..fills(fills);
      s.snapshotsLoaded = true;
      await t.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: NetWorthPage(store: s))));
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.text('Gas').first);
      await t.pump(const Duration(milliseconds: 300));
      return s;
    }

    Future<void> open(WidgetTester t, String name) async {
      await t.longPress(find.text(name));
      await t.pumpAndSettle();
      await t.tap(find.text('Odometer & gallons'));
      await t.pumpAndSettle();
    }

    Finder odometer() => find.widgetWithText(TextField, 'Odometer (miles)');
    Finder gallons() => find.widgetWithText(TextField, 'Gallons filled');

    testWidgets('tapping a fill-up opens it, with no hovering or holding needed', (t) async {
      await pump(t, [(null, null)]);
      await t.tap(find.text('Shell 0'));
      await t.pumpAndSettle();
      expect(odometer(), findsOneWidget);
      expect(gallons(), findsOneWidget);
    });

    testWidgets('only the odometer saves', (t) async {
      final s = await pump(t, [(null, null)]);
      await open(t, 'Shell 0');
      await t.enterText(odometer(), '41,200');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(s.saved.single, (miles: 41200, gallons: null));
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('41,200 mi'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('only the gallons saves, and shows its price', (t) async {
      final s = await pump(t, [(null, null)]);
      await open(t, 'Shell 0');
      await t.enterText(gallons(), '10');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(s.saved.single, (miles: null, gallons: 10));
      expect(find.textContaining('10.00 gal'), findsOneWidget);
      expect(find.textContaining('/gal'), findsOneWidget);
    });

    testWidgets('both still saves', (t) async {
      final s = await pump(t, [(null, null)]);
      await open(t, 'Shell 0');
      await t.enterText(odometer(), '1000');
      await t.enterText(gallons(), '10.5');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(s.saved.single, (miles: 1000, gallons: 10.5));
    });

    testWidgets('blanking one clears it and leaves the other', (t) async {
      final s = await pump(t, [(1000, 10)]);
      await open(t, 'Shell 0');
      await t.enterText(gallons(), '');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(s.saved.single, (miles: 1000, gallons: null));
    });

    testWidgets('changing one keeps the other exactly, though it’s shown rounded', (t) async {
      final s = await pump(t, [(1000.6, 10)]);
      await open(t, 'Shell 0');
      await t.enterText(gallons(), '12');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(s.saved.single, (miles: 1000.6, gallons: 12));
    });

    testWidgets('nothing entered: nothing saved, nothing wrong', (t) async {
      final s = await pump(t, [(null, null)]);
      await open(t, 'Shell 0');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(s.saved, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('something that isn’t a number says so, rather than closing and losing it', (t) async {
      final s = await pump(t, [(null, null)]);
      await open(t, 'Shell 0');
      for (final (field, bad, says) in [(odometer(), 'lots', 'The odometer'), (gallons(), '0', 'Gallons')]) {
        await t.enterText(odometer(), '');
        await t.enterText(gallons(), '');
        await t.enterText(field, bad);
        await t.tap(find.text('Save'));
        await t.pump();
        expect(find.textContaining('$says has to be a number'), findsOneWidget);
        expect(find.byType(AlertDialog), findsOneWidget);
      }
      expect(s.saved, isEmpty);
    });

    testWidgets('a failed save says so and keeps what you typed', (t) async {
      final s = await pump(t, [(null, null)]);
      s.failure = Exception('offline');
      await open(t, 'Shell 0');
      await t.enterText(gallons(), '10');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(find.textContaining('Couldn’t save'), findsOneWidget);
      expect(t.widget<TextField>(gallons()).controller!.text, '10');
    });

    testWidgets('the totals add up with only some of it filled in', (t) async {
      await pump(t, [(1000, 10), (null, 10), (1500, 10), (1800, null)]);
      expect(find.text('25.0 mpg'), findsOneWidget, reason: 'average MPG: 500 miles on 20 gallons, not counting the last');
      expect(find.text('800'), findsOneWidget, reason: 'miles tracked: all of them');
      expect(find.text('30.0 gallons'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('only miles logged: still shows how far', (t) async {
      await pump(t, [(1000, null), (1300, null)]);
      expect(find.text('300'), findsOneWidget);
      expect(find.text('Needs odometer readings and gallons'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}

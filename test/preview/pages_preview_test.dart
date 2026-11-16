import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:optimizer/calendar/calendar_models.dart';
import 'package:optimizer/calendar/todos.dart';
import 'package:optimizer/dashboard/dashboard_page.dart';
import 'package:optimizer/journal/journal_crypto.dart';
import 'package:optimizer/journal/journal_page.dart';
import 'package:optimizer/journal/journal_store.dart';
import 'package:optimizer/networth/finance_store.dart';
import 'package:optimizer/networth/net_worth_page.dart';
import 'package:optimizer/theme.dart';
import 'package:optimizer/util/fields.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'calendar_preview_test.dart' show loadFonts, out, skipPreview, FakeService;

// ignore: subtype_of_sealed_class
class FakeDoc implements DocumentSnapshot<Map<String, dynamic>> {
  FakeDoc(this.id, this._data);
  @override
  final String id;
  final Map<String, dynamic> _data;
  @override
  Map<String, dynamic> data() => _data;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class FeedService extends FakeService {
  @override
  Future<List<CalendarEvent>> fetchBetween(DateTime from, DateTime to) async => eventsBetween(from, to);

  // No Firestore in tests: check-offs only change what's shown.
  @override
  Future<void> setTodoDone(Todo t, bool done) async {
    done ? doneTasks.add(t.id) : doneTasks.remove(t.id);
    notifyListeners();
  }
}

Future<void> shot(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
  final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
  final bytes = await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
  File('$out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
}

JournalStore journal() {
  final now = DateTime.now();
  final texts = [
    'Long day but a good one. Finally got the calendar rows working the way I pictured them, and the whole week fits on one screen now.',
    'Ran five miles before class. Legs were heavy for the first two and then it clicked. Need to sleep earlier this week.',
    'Called home. Everyone is doing well and we picked a weekend to visit.',
    'Studied for three hours. Recursion finally makes sense when I draw the call stack.',
    'Quiet Sunday. Cleaned the apartment, meal prepped, read for an hour.',
  ];
  final entries = [
    for (var i = 0; i < 40; i++)
      JournalEntry(FakeDoc('e$i', {
        'appearsAsDate': DateFormat('yyyy-MM-dd').format(addDays(now, -i * 2)),
        'timestamp': Timestamp.fromDate(addDays(now, -i * 2)),
        'content': JournalCrypto.encryptText(texts[i % texts.length] * (1 + i % 3)),
        if (i % 3 == 0) 'header': ['Momentum', 'Recovery week', 'Small wins'][i % 3 == 0 ? (i ~/ 3) % 3 : 0],
        if (i % 4 == 1) 'referencedPeople': [JournalCrypto.encryptText('Mom'), JournalCrypto.encryptText('Alex')],
        if (i % 5 == 0) 'addedContext': [{'content': JournalCrypto.encryptText('Looking back, this was the turning point.'), 'appearsAsDate': '2026-10-01'}],
      })),
  ];
  return JournalStore.withEntries('u', entries);
}

FinanceStore finance() {
  final key = encrypt.Encrypter(encrypt.AES(encrypt.Key.fromLength(32), mode: encrypt.AESMode.cbc));
  final s = FinanceStore.offline('u', key: key);
  final now = DateTime.now();
  final rnd = math.Random(4);
  var nw = 84000.0, aapl = 12000.0, vti = 21000.0, nvda = 6000.0;
  final pts = <NetWorthPoint>[];
  for (var h = 24 * 120; h >= 0; h -= 6) {
    nw += (rnd.nextDouble() - 0.44) * 400;
    aapl *= 1 + (rnd.nextDouble() - 0.48) * 0.01;
    vti *= 1 + (rnd.nextDouble() - 0.47) * 0.006;
    nvda *= 1 + (rnd.nextDouble() - 0.46) * 0.02;
    final iv = encrypt.IV.fromLength(16);
    final payload = jsonEncode({
      'netWorth': nw,
      'accounts': {'Checking': 6200.0, 'Savings': 18000.0, 'Credit card': -1240.0, 'Roth IRA': 31000.0},
      'stocks': {'AAPL': aapl, 'VTI': vti, 'NVDA': nvda},
    });
    pts.add(NetWorthPoint(
      id: 'p$h',
      date: now.subtract(Duration(hours: h)),
      total: nw,
      assets: nw + 1240,
      liabilities: 1240,
      encrypted: (data: key.encrypt(payload, iv: iv).base64, iv: iv.base64),
    ));
  }
  s.points = pts;
  s.cachedPlaid = {'holdings': [{'ticker': 'AAPL', 'quantity': 52}, {'ticker': 'VTI', 'quantity': 71.5}, {'ticker': 'NVDA', 'quantity': 40}]};
  s.accounts = [
    {'name': 'Checking', 'institution_name': 'First Bank', 'type': 'depository', 'balances': {'current': 6200}},
    {'name': 'Savings', 'institution_name': 'Online Bank', 'type': 'depository', 'balances': {'current': 18000}},
    {'name': 'Credit card', 'institution_name': 'First Bank', 'type': 'credit', 'balances': {'current': 1240}},
    {'name': 'Roth IRA', 'institution_name': 'Retirement Co', 'type': 'investment', 'subtype': 'roth', 'balances': {'current': 31000}},
    {'name': 'Brokerage', 'institution_name': 'Brokerage Co', 'type': 'investment', 'balances': {'current': 39000}},
  ];
  final txns = <(String, Map<String, dynamic>)>[];
  final merchants = ['Grocery Mart', 'Shell', 'Chipotle', 'Amazon', 'Spotify', 'Taco Stand', 'Target', 'Exxon'];
  var odo = 41000.0;
  for (var d = 0; d < 200; d++) {
    final date = DateFormat('yyyy-MM-dd').format(addDays(now, -d));
    final m = merchants[d % merchants.length];
    final gas = m == 'Shell' || m == 'Exxon';
    if (gas) odo -= 290;
    txns.add(('tx_$d', {
      'transaction_id': '$d', 'date': date, 'name': m, 'merchant_name': m, 'amount': 8 + rnd.nextDouble() * 70,
      if (gas) ...{'customCategory': 'Gas', 'gasMileage': odo, 'gasGallons': 9 + rnd.nextDouble() * 3},
    }));
    if (d % 14 == 0) txns.add(('pay_$d', {'transaction_id': 'pay$d', 'date': date, 'name': 'Payroll', 'amount': -2100.0, 'customCategory': 'Paycheck'}));
  }
  s.setTransactions(txns, merchantCategories: {'Grocery Mart': 'Groceries', 'Chipotle': 'Food', 'Taco Stand': 'Food', 'Amazon': 'Shopping', 'Target': 'Shopping', 'Spotify': 'Subscriptions'});
  return s;
}

Future<void> pumpPage(WidgetTester tester, Widget child, {Size size = const Size(1600, 940)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(),
    debugShowCheckedModeBanner: false,
    home: RepaintBoundary(key: const ValueKey('shot'), child: Scaffold(body: child)),
  ));
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(skip: skipPreview, 'journal', (tester) async {
    await tester.runAsync(loadFonts);
    final store = journal();
    await pumpPage(tester, JournalPage(store: store));
    await shot(tester, 'journal');
    await tester.tap(find.text(journalDate(store.entries[1].date)).first);
    await tester.pump(const Duration(milliseconds: 200));
    await shot(tester, 'journal_open');
    tester.view.reset();
  });

  testWidgets(skip: skipPreview, 'net worth', (tester) async {
    await tester.runAsync(loadFonts);
    final store = finance();
    await pumpPage(tester, NetWorthPage(store: store));
    await shot(tester, 'nw_overview');
    for (final (tab, name) in [('Spending', 'nw_spending'), ('Investing', 'nw_investing'), ('Gas', 'nw_gas'), ('History', 'nw_history')]) {
      await tester.tap(find.text(tab).first);
      await tester.pump(const Duration(milliseconds: 300));
      if (tab == 'History') {
        await tester.tap(find.byIcon(Icons.expand_more).first);
        await tester.pump(const Duration(milliseconds: 200));
      }
      await shot(tester, name);
    }
    tester.view.reset();
  });

  testWidgets(skip: skipPreview, 'dashboard', (tester) async {
    await tester.runAsync(loadFonts);
    final svc = FeedService();
    svc.accounts.add(GoogleAccount(email: 'me@example.com'));
    final cal = GoogleCalendar(id: 'p', accountEmail: 'me@example.com', name: 'Me', color: const Color(0xFF4285F4), primary: true, accessRole: 'owner');
    svc.calendars.add(cal);
    final today = dayStart(DateTime.now());
    final sunday = addDays(today, -(today.weekday % 7));
    final now = DateTime.now();
    svc.manualTodos = [
      Todo.manual('t1', {'title': 'Problem set 6', 'label': 'MATH 201', 'color': '#F97316', 'due': Timestamp.fromDate(addDays(today, -1)), 'allDay': true}),
      Todo.manual('t2', {'title': 'Lab report draft', 'label': 'CHEM 101', 'color': '#22C55E', 'due': Timestamp.fromDate(today.add(const Duration(hours: 23, minutes: 59))), 'allDay': false}),
      Todo.manual('t3', {'title': 'Call the bank', 'due': Timestamp.fromDate(today), 'allDay': true}),
      Todo.manual('t4', {'title': 'Reading quiz', 'label': 'HIST 101', 'color': '#A855F7', 'due': Timestamp.fromDate(addDays(today, 1)), 'allDay': true}),
    ];
    svc.fake = [
      CalendarEvent(id: 'now', calendar: cal, title: 'Design review', description: '', location: 'Room 204', start: now.subtract(const Duration(minutes: 20)), end: now.add(const Duration(minutes: 40)), allDay: false, color: const Color(0xFFE67C73)),
      CalendarEvent(id: 'next', calendar: cal, title: 'Coffee with Sam', description: '', location: 'Corner Coffee', start: now.add(const Duration(hours: 2)), end: now.add(const Duration(hours: 3)), allDay: false, color: const Color(0xFFF6BF26)),
      CalendarEvent(id: 'ad', calendar: cal, title: 'Mom’s birthday', description: '', location: '', start: today, end: addDays(today, 1), allDay: true, color: const Color(0xFF8E24AA)),
      for (var d = 0; d < 9; d++) ...[
        CalendarEvent(id: 'a$d', calendar: cal, title: 'Standup', description: '', location: '', start: addDays(sunday, d).add(const Duration(hours: 9)), end: addDays(sunday, d).add(const Duration(hours: 10)), allDay: false, color: cal.color),
        CalendarEvent(id: 'b$d', calendar: cal, title: 'Gym', description: '', location: '', start: addDays(sunday, d).add(const Duration(hours: 17)), end: addDays(sunday, d).add(const Duration(hours: 18, minutes: 30)), allDay: false, color: const Color(0xFF33B679)),
      ],
    ];
    await pumpPage(
      tester,
      DashboardPage(uid: 'u', calendar: svc, journal: journal(), finance: finance(), onNavigate: (_) {}),
      size: const Size(1600, 1300),
    );
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 200));
    await shot(tester, 'dashboard');
    tester.view.reset();
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/dashboard/dashboard_page.dart';
import 'package:optimizer/premium/premium_beta.dart';
import 'package:optimizer/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview/pages_preview_test.dart' show journal, finance, FeedService;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // Net worth is a premium beta feature: without it Home keeps only the
  // journal's panel (the saved layout still has the rest).
  for (final money in [true, false]) {
    testWidgets('home ${money ? 'with' : 'without'} premium beta', (t) async {
      t.view.physicalSize = const Size(1440, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: DashboardPage(uid: 'u', calendar: FeedService(), journal: journal(), finance: finance(), onNavigate: (_) {}, money: money),
        ),
      ));
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      await t.pump(const Duration(milliseconds: 200));
      for (final title in ['Net worth', 'Accounts', 'Spending', 'Stocks', 'Gas']) {
        expect(find.text(title), money ? findsWidgets : findsNothing, reason: title);
      }
      expect(find.text('Journal'), findsWidgets);
    });
  }

  test('premium beta is off unless the server switched it on', () {
    expect(PremiumBeta.fixed(false).on, isFalse);
    expect(PremiumBeta.fixed(true).on, isTrue);
  });
}

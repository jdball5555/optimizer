import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/shell/side_nav.dart';
import 'package:optimizer/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'calendar_preview_test.dart' show loadFonts, skipPreview;
import 'pages_preview_test.dart' show shot;

void main() {
  testWidgets(skip: skipPreview, 'side nav, open then folded', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(loadFonts);
    tester.view.physicalSize = const Size(520, 640);
    tester.view.devicePixelRatio = 1;
    const items = <SideNavItem>[
      (icon: Icons.dashboard_outlined, selected: Icons.dashboard, label: 'Home'),
      (icon: Icons.calendar_view_week_outlined, selected: Icons.calendar_view_week, label: 'Calendar'),
      (icon: Icons.menu_book_outlined, selected: Icons.menu_book, label: 'Journal'),
      (icon: Icons.show_chart_outlined, selected: Icons.show_chart, label: 'Net worth'),
      (icon: Icons.auto_awesome_outlined, selected: Icons.auto_awesome, label: 'Ask'),
    ];
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      debugShowCheckedModeBanner: false,
      home: RepaintBoundary(
        key: const ValueKey('shot'),
        child: Scaffold(
          body: Row(children: [
            SideNav(
              items: items,
              selected: 1,
              onSelected: (_) {},
              account: (expanded) =>
                  SideNavAccount(name: 'Alex Rivera', email: 'd@example.com', expanded: expanded, onSettings: () {}, onSignOut: () {}),
            ),
            const Expanded(child: SizedBox()),
          ]),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // The mouse over Journal: its bubble lights up.
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: tester.getCenter(find.text('Journal')));
    await tester.pumpAndSettle();
    await shot(tester, 'side_nav_open');
    await tester.tap(find.byTooltip('Collapse'));
    await tester.pumpAndSettle();
    await shot(tester, 'side_nav_folded');
    await gesture.removePointer();
    tester.view.reset();
  });
}

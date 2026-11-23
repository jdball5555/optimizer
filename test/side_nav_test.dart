import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/shell/side_nav.dart';
import 'package:optimizer/theme.dart';
import 'package:optimizer/widgets/calm_scrollbar.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the side bar has no scrollbars, even clicking its pages', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var page = 0;
    await tester.pumpWidget(StatefulBuilder(
      builder: (context, setState) => MaterialApp(
        theme: buildTheme(),
        scrollBehavior: const CalmScrollBehavior(),
        home: Scaffold(
          body: Row(children: [
            SideNav(
              items: const [
                (icon: Icons.dashboard_outlined, selected: Icons.dashboard, label: 'Home'),
                (icon: Icons.people_outline, selected: Icons.people, label: 'People'),
              ],
              selected: page,
              onSelected: (i) => setState(() => page = i),
              account: (expanded) => SideNavAccount(name: 'D', email: 'd@example.com', expanded: expanded, onSettings: () {}, onSignOut: () {}),
            ),
            // A plain list, to prove lists do get a scrollbar on this platform.
            Expanded(child: ListView(key: const ValueKey('list'), children: const [SizedBox(height: 4000)])),
          ]),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const ValueKey('list')), matching: find.byType(CalmScrollbar)), findsOneWidget);
    expect(find.descendant(of: find.byType(SideNav), matching: find.byType(RawScrollbar)), findsNothing);
    await tester.tap(find.text('People'));
    await tester.pumpAndSettle();
    expect(page, 1);
    expect(find.descendant(of: find.byType(SideNav), matching: find.byType(RawScrollbar)), findsNothing);
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets('on a small screen the ☰ slides the same side bar in over the app, always open', (t) async {
    // Folded on the website: the drawer is open anyway.
    SharedPreferences.setMockInitialValues({'optimizer.sideNavExpanded': false});
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final key = GlobalKey<ScaffoldState>();
    var page = 0;
    await t.pumpWidget(StatefulBuilder(
      builder: (context, setState) => MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          key: key,
          drawer: Drawer(
            width: SideNav.expandedWidth,
            child: SideNav(
              inDrawer: true,
              items: const [
                (icon: Icons.check_circle_outline, selected: Icons.check_circle, label: 'To-dos'),
                (icon: Icons.people_outline, selected: Icons.people, label: 'People'),
              ],
              selected: page,
              onSelected: (i) {
                key.currentState!.closeDrawer();
                setState(() => page = i);
              },
              account: (expanded) => SideNavAccount(name: 'D', email: 'd@example.com', expanded: expanded, onSettings: () {}, onSignOut: () {}),
            ),
          ),
          body: Align(
            alignment: Alignment.topRight,
            child: IconButton(tooltip: 'Menu', icon: const Icon(Icons.menu), onPressed: () => key.currentState!.openDrawer()),
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.byType(SideNav), findsNothing);
    await t.tap(find.byTooltip('Menu'));
    await t.pumpAndSettle();
    expect(t.getSize(find.byType(SideNav)).width, SideNav.expandedWidth);
    expect(find.text('Optimizer'), findsOneWidget);
    expect(find.byTooltip('Collapse'), findsNothing);
    expect(find.byTooltip('Expand'), findsNothing);
    await t.tap(find.text('People'));
    await t.pumpAndSettle();
    expect(page, 1);
    expect(find.byType(SideNav), findsNothing, reason: 'picking a page closes it');
    expect(t.takeException(), isNull);
  });

  group('folding', () {
    Future<void> bar(WidgetTester t, {bool expanded = true}) async {
      SharedPreferences.setMockInitialValues({'optimizer.sideNavExpanded': expanded});
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: Row(children: [
            SideNav(
              items: const [
                (icon: Icons.dashboard_outlined, selected: Icons.dashboard, label: 'Home'),
                (icon: Icons.people_outline, selected: Icons.people, label: 'People'),
              ],
              selected: 0,
              onSelected: (_) {},
              account: (open) => SideNavAccount(name: 'D', email: 'd@example.com', expanded: open, onSettings: () {}, onSignOut: () {}),
            ),
            const Expanded(child: SizedBox()),
          ]),
        ),
      ));
      await t.pumpAndSettle();
    }

    double width(WidgetTester t) => t.getSize(find.byType(SideNav)).width;

    /// The bubble around [what], which is the nearest thing with a border.
    Rect bubbleOf(WidgetTester t, Finder what) => t.getRect(find
        .ancestor(of: what, matching: find.byWidgetPredicate((w) => w is AnimatedContainer && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).borderRadius != null))
        .first);

    testWidgets('folded, each icon is dead center of its highlight', (t) async {
      await bar(t, expanded: false);
      for (final icon in [find.byIcon(Icons.dashboard), find.byIcon(Icons.people_outline), find.byIcon(Icons.keyboard_arrow_right)]) {
        final bubble = bubbleOf(t, icon);
        final at = t.getCenter(icon);
        expect((at.dx - bubble.center.dx).abs(), lessThan(0.01), reason: 'across');
        expect((at.dy - bubble.center.dy).abs(), lessThan(0.01), reason: 'down');
      }
      final avatar = t.getCenter(find.byType(CircleAvatar));
      expect((avatar.dx - bubbleOf(t, find.byType(CircleAvatar)).center.dx).abs(), lessThan(0.01));
      expect((t.getCenter(find.byIcon(Icons.dashboard)).dx - (SideNav.collapsedWidth - 1) / 2).abs(), lessThan(0.01), reason: 'and of the bar');
    });

    testWidgets('open, the icons stay where they were', (t) async {
      await bar(t);
      expect((t.getCenter(find.byIcon(Icons.dashboard)).dx - (SideNav.collapsedWidth - 1) / 2).abs(), lessThan(0.01));
    });

    for (final (name, spot) in [('the version', Alignment.centerLeft), ('the middle', Alignment.center), ('the arrow', Alignment.centerRight)]) {
      testWidgets('open, tapping $name of the bottom rectangle folds it', (t) async {
        await bar(t);
        expect(width(t), SideNav.expandedWidth);
        final bubble = bubbleOf(t, find.byIcon(Icons.keyboard_arrow_left));
        await t.tapAt(spot.withinRect(bubble.deflate(4)));
        await t.pumpAndSettle();
        expect(width(t), SideNav.collapsedWidth);
      });
    }

    testWidgets('the rectangle runs the width of the bar, like the pages', (t) async {
      await bar(t);
      final bubble = bubbleOf(t, find.byIcon(Icons.keyboard_arrow_left));
      final page = bubbleOf(t, find.byIcon(Icons.dashboard));
      expect([bubble.left, bubble.right, bubble.height], [page.left, page.right, page.height]);
    });

    testWidgets('folded, tapping it opens it again', (t) async {
      await bar(t, expanded: false);
      await t.tap(find.byIcon(Icons.keyboard_arrow_right));
      await t.pumpAndSettle();
      expect(width(t), SideNav.expandedWidth);
      expect(t.takeException(), isNull);
    });
  });

  testWidgets('Feedback sits at the bottom of the side bar, above your account', (t) async {
    SharedPreferences.setMockInitialValues({});
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var opened = 0;
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: Row(children: [
          SideNav(
            items: const [(icon: Icons.check_circle_outline, selected: Icons.check_circle, label: 'To-dos')],
            selected: 0,
            onSelected: (_) {},
            onFeedback: () => opened++,
            account: (expanded) => SideNavAccount(name: 'Dana', email: 'd@example.com', expanded: expanded, onSettings: () {}, onSignOut: () {}),
          ),
          const Expanded(child: SizedBox()),
        ]),
      ),
    ));
    await t.pumpAndSettle();
    final feedback = t.getTopLeft(find.text('Feedback'));
    expect(feedback.dy, greaterThan(t.getTopLeft(find.text('To-dos')).dy));
    expect(feedback.dy, lessThan(t.getTopLeft(find.text('Dana')).dy));
    await t.tap(find.text('Feedback'));
    expect(opened, 1);
  });
}

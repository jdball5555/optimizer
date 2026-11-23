import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/premium/premium_beta.dart';
import 'package:optimizer/settings/feedback_page.dart';
import 'package:optimizer/theme.dart';

import 'preview/calendar_preview_test.dart' show loadFonts, skipPreview;
import 'preview/pages_preview_test.dart' show shot;

Future<void> _pump(WidgetTester t, Size size, {bool premium = false, PremiumBeta? beta}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(),
    debugShowCheckedModeBanner: false,
    builder: (_, c) => RepaintBoundary(key: const ValueKey('shot'), child: c!),
    home: FeedbackPage(premium: beta ?? PremiumBeta.fixed(premium)),
  ));
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  for (final size in const [Size(360, 740), Size(1200, 900)]) {
    testWidgets('laid out like Scorecards’ form, ${size.width.toInt()} wide: what, where, details, submit', (t) async {
      await _pump(t, size);
      for (final text in ['WHAT CAN WE HELP WITH?', 'Fix a Problem', 'Suggest an Idea', 'WHERE IS THE PROBLEM?', 'DETAILS', 'SUBMIT FEEDBACK']) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      // No conversation: just the one box to type in.
      expect(find.byType(TextField), findsOneWidget);
      expect(find.textContaining('Reply'), findsNothing);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('the box you type in is one box, with no outline of its own inside the tile', (t) async {
    await _pump(t, const Size(400, 800));
    final d = t.widget<TextField>(find.byType(TextField)).decoration!;
    for (final b in [d.border, d.enabledBorder, d.focusedBorder]) {
      expect((b! as OutlineInputBorder).borderSide, BorderSide.none);
    }
  });

  testWidgets('an idea can be for a new page', (t) async {
    await _pump(t, const Size(400, 900));
    expect(find.text('New Page'), findsNothing);
    await t.tap(find.text('Suggest an Idea'));
    await t.pump();
    expect(find.text('WHERE DOES THIS IDEA GO?'), findsOneWidget);
    expect(find.text('New Page'), findsOneWidget);
  });

  const premiumOnly = ['Home', 'Focus', 'Calendar', 'Trips', 'Journal', 'Habits', 'Net worth', 'Assistant', 'People', 'Notifications'];
  const everyone = ['To-dos', 'Canvas sync', 'Settings', 'Signing in', 'Website'];

  testWidgets('the places are what you have: premium beta’s features only with it, as it changes', (t) async {
    final beta = _Beta();
    await _pump(t, const Size(1200, 1100), beta: beta);
    for (final p in everyone) {
      expect(find.text(p), findsOneWidget, reason: p);
    }
    for (final p in premiumOnly) {
      expect(find.text(p), findsNothing, reason: p);
    }

    beta.set(true);
    await t.pump();
    for (final p in [...everyone, ...premiumOnly]) {
      expect(find.text(p), findsOneWidget, reason: p);
    }

    // Picked, then premium beta goes: back to To-dos, still a choice you have.
    await t.tap(find.text('Calendar'));
    await t.pump();
    beta.set(false);
    await t.pump();
    expect(find.text('Calendar'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('submitting with nothing typed asks for it, and sends nothing', (t) async {
    await _pump(t, const Size(400, 900));
    await t.ensureVisible(find.text('SUBMIT FEEDBACK'));
    await t.tap(find.text('SUBMIT FEEDBACK'));
    await t.pump();
    expect(find.text('Please type your feedback before submitting.'), findsOneWidget);
    expect(find.byType(FeedbackPage), findsOneWidget);
  });

  for (final (name, size) in const [('phone', Size(390, 844)), ('wide', Size(1200, 900))]) {
    testWidgets(skip: skipPreview, 'feedback_$name', (t) async {
      await t.runAsync(loadFonts);
      await _pump(t, size, premium: true);
      await shot(t, 'feedback_$name');
    });
  }
}

/// Premium beta switched on and off by the test.
class _Beta extends PremiumBeta {
  _Beta() : super.fixed(false);

  bool _value = false;

  @override
  bool get on => _value;

  void set(bool v) {
    _value = v;
    notifyListeners();
  }
}

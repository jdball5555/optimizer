import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/theme.dart';
import 'package:optimizer/widgets/tiles.dart';

void main() {
  testWidgets('delete hides until hover and asks before running', (tester) async {
    var deleted = 0;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: Center(
          child: HoverMenu(
            actions: [
              MenuAction(
                label: 'Delete entry',
                icon: Icons.delete_outline,
                onSelected: () => deleted++,
                confirm: ('Delete this entry?', 'Gone for good.', 'Delete'),
              ),
            ],
            child: const SizedBox(width: 300, height: 120, child: Text('An entry')),
          ),
        ),
      ),
    ));

    AnimatedOpacity button() => tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(button().opacity, 0);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('An entry')));
    await tester.pumpAndSettle();
    expect(button().opacity, 1);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete entry'));
    await tester.pumpAndSettle();
    expect(find.text('Delete this entry?'), findsOneWidget);
    expect(deleted, 0);

    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(deleted, 1);
  });
}

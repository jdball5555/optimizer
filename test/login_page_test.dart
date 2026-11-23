import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/app_version.dart';
import 'package:optimizer/auth/login_page.dart';
import 'package:optimizer/theme.dart';

import 'preview/calendar_preview_test.dart' show loadFonts, skipPreview;
import 'preview/pages_preview_test.dart' show shot;

Future<void> _pump(WidgetTester t, Size size) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(),
    debugShowCheckedModeBanner: false,
    builder: (_, c) => RepaintBoundary(key: const ValueKey('shot'), child: c!),
    home: const LoginPage(),
  ));
  await t.pump();
}

void main() {
  testWidgets('sign in, or switch to making an account, with the version underneath', (t) async {
    await _pump(t, const Size(400, 900));
    expect(find.text('Sign in to see your to-dos'), findsOneWidget);
    expect(find.text('Your name'), findsNothing);
    expect(find.text('Forgot password'), findsOneWidget);
    expect(find.text('v$appVersion'), findsOneWidget);

    await t.tap(find.text('New here? Make an account'));
    await t.pump();
    expect(find.text('Create your Optimizer account'), findsOneWidget);
    for (final f in ['Your name', 'Email', 'Choose a password']) {
      expect(find.text(f), findsOneWidget, reason: f);
    }
    expect(find.widgetWithText(FilledButton, 'Create account'), findsOneWidget);
    expect(find.text('Sign up with Google'), findsOneWidget);
    expect(find.text('Forgot password'), findsNothing);

    // Nothing typed: asks for it without calling Firebase.
    await t.tap(find.widgetWithText(FilledButton, 'Create account'));
    await t.pump();
    expect(find.text('Please fill out all fields to create an account.'), findsOneWidget);

    await t.tap(find.text('I already have an account'));
    await t.pump();
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('a wide screen has the pitch beside the form; a phone just the form', (t) async {
    await _pump(t, const Size(1400, 900));
    expect(find.text('Every to-do,\nin order.'), findsOneWidget);
    await _pump(t, const Size(360, 740));
    expect(find.text('Every to-do,\nin order.'), findsNothing);
    expect(t.takeException(), isNull);
  });

  test('Firebase’s errors in plain words', () {
    expect(signUpError(FirebaseAuthException(code: 'email-already-in-use')), 'An account already exists for this email. Try signing in.');
    expect(signInError(FirebaseAuthException(code: 'invalid-credential')), 'Account not found or incorrect password.');
    expect(resetError(FirebaseAuthException(code: 'user-not-found')), 'No account exists with this email address.');
  });

  test('the version shown is the one the website reads (pubspec.yaml, in the web build’s version.json)', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final v = RegExp(r'^version:\s*([0-9.]+)', multiLine: true).firstMatch(pubspec)!.group(1);
    expect(appVersion, v);
  });

  for (final (name, size) in const [('phone', Size(390, 844)), ('wide', Size(1400, 900))]) {
    testWidgets(skip: skipPreview, 'login_$name', (t) async {
      await t.runAsync(loadFonts);
      await _pump(t, size);
      await shot(t, 'login_$name');
    });
  }
}

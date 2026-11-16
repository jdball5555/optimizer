import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../shell/app_shell.dart';
import 'login_page.dart';

/// True while the sign-in page checks a Google sign-in (whether it's a new
/// account, made without an invitation), so the app doesn't open meanwhile.
final signInHold = ValueNotifier(false);

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  // Subscribed once. Making a new stream in build() would send it back to
  // "waiting" on every rebuild, swapping the whole app out for a spinner and
  // closing its stores mid-use.
  final _user = FirebaseAuth.instance.authStateChanges();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: signInHold,
      builder: (context, hold, _) => StreamBuilder<User?>(
      stream: _user,
      initialData: FirebaseAuth.instance.currentUser,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting && snap.data == null) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final user = snap.data;
        if (user == null || hold) return const LoginPage();
        // Keyed by uid so switching accounts rebuilds everything cleanly.
        return AppShell(key: ValueKey(user.uid), user: user);
      },
      ),
    );
  }
}

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../shell/app_shell.dart';
import 'login_page.dart';
import 'profile.dart';

/// True while the sign-in page finishes making an account (setting its
/// name), so the app doesn't open before it knows who you are.
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
    return ListenableBuilder(
      listenable: Listenable.merge([signInHold, profileChanged]),
      builder: (context, _) => StreamBuilder<User?>(
        stream: _user,
        initialData: FirebaseAuth.instance.currentUser,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting && snap.data == null) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          // The freshest copy of the account: the stream's still has the name
          // it had at sign-in (none, for an account just made).
          final user = snap.data == null ? null : (FirebaseAuth.instance.currentUser ?? snap.data);
          if (user == null || signInHold.value) return const LoginPage();
          // Keyed by uid so switching accounts rebuilds everything cleanly.
          return AppShell(key: ValueKey(user.uid), user: user);
        },
      ),
    );
  }
}

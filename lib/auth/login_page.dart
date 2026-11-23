import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../app_version.dart';
import '../theme.dart';
import '../util/analytics.dart';
import '../widgets/logo.dart';
import 'auth_gate.dart';
import 'invite_link.dart';
import 'profile.dart';

/// Sign in, or make an account, with the same Axis accounts Asset Track and
/// Axis Journal use. Laid out like Scorecards' sign-in in Optimizer's
/// colors: the form in a rounded card, with a short pitch beside it on a
/// wide screen.
///
/// Anyone can make an account. It's a regular one: premium beta is only
/// ever switched on from Axis Optic (functions/premium.js). Opened from an
/// invitation link, it says who invited you and starts on making an account.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.wide});

  /// For tests: the wide layout (with the pitch) or not, whatever the width.
  final bool? wide;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  /// Making a new account, rather than signing in.
  bool _creating = pendingInviteToken != null;

  /// From the invitation link: who invited you, to what, at which email.
  ({String fromName, String what, String email})? _invite;

  @override
  void initState() {
    super.initState();
    logPage('Sign in');
    if (pendingInviteToken != null) _readInvite(pendingInviteToken!);
  }

  Future<void> _readInvite(String token) async {
    try {
      final r = (await FirebaseFunctions.instance.httpsCallable('inviteInfo').call({'token': token})).data as Map;
      if (!mounted) return;
      setState(() {
        _invite = (fromName: '${r['fromName'] ?? ''}', what: '${r['what'] ?? ''}', email: '${r['email'] ?? ''}');
        if (_email.text.isEmpty) _email.text = _invite!.email;
      });
    } catch (_) {
      // The form works the same without it.
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  /// A heading and what happened, at the bottom of the screen.
  void _notify(String title, String message, {bool bad = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(bad ? Icons.error_outline : Icons.check_circle_outline, size: 20, color: bad ? AppColors.danger : AppColors.primaryText),
          const SizedBox(width: 12),
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(message),
            ]),
          ),
        ]),
      ));
  }

  // --- Signing in ---
  Future<void> _signIn() async {
    final email = _email.text.trim();
    final password = _password.text.trim();
    if (email.isEmpty || password.isEmpty) {
      _notify('Missing information', 'Please enter both your email and password.', bad: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(email: email, password: password);
    } on FirebaseAuthException catch (e) {
      if (mounted) _notify('Sign in failed', signInError(e), bad: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // --- Making an account ---
  Future<void> _signUp() async {
    final name = _name.text.trim();
    final email = _email.text.trim();
    final password = _password.text.trim();
    if (name.isEmpty || email.isEmpty || password.isEmpty) {
      _notify('Missing information', 'Please fill out all fields to create an account.', bad: true);
      return;
    }
    setState(() => _busy = true);
    // Held until the name is set, so the app opens already knowing it.
    signInHold.value = true;
    try {
      final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(email: email, password: password);
      if (cred.user != null) await saveDisplayName(cred.user!, name);
    } on FirebaseAuthException catch (e) {
      if (mounted) _notify('Sign up failed', signUpError(e), bad: true);
    } finally {
      signInHold.value = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  // --- Forgot password ---
  Future<void> _forgotPassword() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      _notify('Email required', 'Please enter your email address first.', bad: true);
      return;
    }
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (mounted) _notify('Email sent!', 'Password reset email sent! Make sure you check your spam folder.');
    } on FirebaseAuthException catch (e) {
      if (mounted) _notify('Reset failed', resetError(e), bad: true);
    }
  }

  // --- Google ---
  Future<void> _google() async {
    setState(() => _busy = true);
    try {
      final provider = GoogleAuthProvider()
        ..addScope('email')
        ..addScope('profile');
      // A pop-up on the website; Google's own sign-in screen in the apps.
      if (kIsWeb) {
        await FirebaseAuth.instance.signInWithPopup(provider);
      } else {
        await FirebaseAuth.instance.signInWithProvider(provider);
      }
    } on FirebaseAuthException catch (e) {
      // Closing Google's window isn't worth shouting about.
      if (e.code == 'popup-closed-by-user' || e.code == 'cancelled-popup-request' || e.code == 'web-context-canceled') return;
      if (mounted) _notify('Google sign-in failed', e.message ?? 'An error occurred.', bad: true);
    } catch (e) {
      final s = '$e'.toLowerCase();
      if (s.contains('canceled') || s.contains('cancelled')) return;
      if (mounted) _notify('Error', 'An error occurred: $e', bad: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _form(BuildContext context) {
    final theme = Theme.of(context);
    final invite = _invite;
    const spinner = SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2));
    void submit() {
      if (_busy) return;
      _creating ? _signUp() : _signIn();
    }

    // Sized to its content: the card around it hugs the form.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(40, 40, 40, 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: AutofillGroup(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Center(child: OptimizerLogo(size: 56)),
            const SizedBox(height: 12),
            Text('Optimizer', textAlign: TextAlign.center, style: theme.textTheme.headlineMedium?.copyWith(color: AppColors.primaryText)),
            const SizedBox(height: 4),
            Text(
              _creating ? 'Create your Optimizer account' : 'Sign in to see your to-dos',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.secondaryText),
            ),
            if (invite != null) ...[
              const SizedBox(height: 16),
              _InviteNote(fromName: invite.fromName, what: invite.what),
            ],
            const SizedBox(height: 28),
            if (_creating) ...[
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                autofillHints: const [AutofillHints.name],
                decoration: const InputDecoration(labelText: 'Your name'),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              autofillHints: [_creating ? AutofillHints.newPassword : AutofillHints.password],
              decoration: InputDecoration(labelText: _creating ? 'Choose a password' : 'Password'),
              onSubmitted: (_) => submit(),
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: _busy ? null : submit, child: _busy ? spinner : Text(_creating ? 'Create account' : 'Sign in')),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _google,
              icon: const Icon(Icons.account_circle_outlined),
              label: Text(_creating ? 'Sign up with Google' : 'Continue with Google'),
            ),
            if (!_creating) TextButton(onPressed: _busy ? null : _forgotPassword, child: const Text('Forgot password')),
            TextButton(
              onPressed: _busy ? null : () => setState(() => _creating = !_creating),
              child: Text(_creating ? 'I already have an account' : 'New here? Make an account'),
            ),
            // As on Axis Team's sign-in: which version this is.
            const SizedBox(height: 8),
            const Text('v$appVersion', textAlign: TextAlign.center, style: TextStyle(color: AppColors.secondaryText, fontSize: 12)),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = widget.wide ?? MediaQuery.sizeOf(context).width >= 900;
    final card = Padding(
      padding: EdgeInsets.all(wide ? 32 : 16),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppColors.border),
        ),
        child: Builder(builder: _form),
      ),
    );
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: wide
            ? Row(children: [
                const Expanded(child: _Pitch()),
                Expanded(child: Center(child: card)),
              ])
            : Center(child: card),
      ),
    );
  }
}

/// Plain words for what went wrong signing in.
String signInError(FirebaseAuthException e) => switch (e.code) {
      'invalid-email' => 'This email address is not formatted correctly.',
      'user-not-found' => 'No account exists with this email address.',
      'wrong-password' => 'Incorrect password. Please try again.',
      // Sent instead of the two above while email enumeration protection is on.
      'invalid-credential' => 'Account not found or incorrect password.',
      'user-disabled' => 'This account has been disabled.',
      _ => e.message ?? 'An error occurred while signing in.',
    };

/// Plain words for what went wrong making an account.
String signUpError(FirebaseAuthException e) => switch (e.code) {
      'invalid-email' => 'This email address is not formatted correctly.',
      'email-already-in-use' => 'An account already exists for this email. Try signing in.',
      'weak-password' => 'Your password is too weak. Please use a stronger password.',
      _ => e.message ?? 'An error occurred while signing up.',
    };

/// Plain words for what went wrong sending a reset email.
String resetError(FirebaseAuthException e) => switch (e.code) {
      'invalid-email' => 'This email address is not formatted correctly.',
      'user-not-found' => 'No account exists with this email address.',
      _ => e.message ?? 'Failed to send reset email.',
    };

/// Beside the form on a wide screen: what Optimizer is for.
class _Pitch extends StatelessWidget {
  const _Pitch();

  @override
  Widget build(BuildContext context) {
    Widget point(IconData icon, String title, String body) => Padding(
          padding: const EdgeInsets.only(bottom: 22),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: const Color(0x1AFFFFFF), borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: AppColors.primaryText, size: 22),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(color: AppColors.primaryText, fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(body, style: const TextStyle(color: AppColors.secondaryText, fontSize: 14, height: 1.4)),
              ]),
            ),
          ]),
        );

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(56, 32, 32, 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Every to-do,\nin order.',
                style: TextStyle(color: AppColors.primaryText, fontSize: 44, fontWeight: FontWeight.w900, height: 1.1)),
            const SizedBox(height: 16),
            const Text(
              'Optimizer keeps your to-dos and your Canvas assignments in one list, by when they’re due, so nothing sneaks up on you.',
              style: TextStyle(color: AppColors.secondaryText, fontSize: 17, height: 1.5),
            ),
            const SizedBox(height: 36),
            point(Icons.school_outlined, 'Canvas, synced', 'Link your Canvas calendar and every assignment shows up, tagged with its class.'),
            point(Icons.view_column_outlined, 'Your own groups',
                'School, work, errands: one list by due date, a month to check them off, or a column for each.'),
          ]),
        ),
      ),
    );
  }
}

/// "Alex invited you to …" above the form, from an invitation link.
class _InviteNote extends StatelessWidget {
  const _InviteNote({required this.fromName, required this.what});

  final String fromName;
  final String what;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0x14FFFFFF),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x40FFFFFF)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.group_add_outlined, color: AppColors.primaryText, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${fromName.isEmpty ? 'Someone' : fromName} invited you${what.isEmpty ? '' : ' to $what'}. Make an account or sign in to accept.',
              style: const TextStyle(color: AppColors.primaryText, fontSize: 13.5, height: 1.35),
            ),
          ),
        ]),
      );
}

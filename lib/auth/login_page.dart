import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/logo.dart';
import 'auth_gate.dart';
import 'invite_link.dart';
import '../util/analytics.dart';

/// Signs in with the same Firebase Auth users your other Axis apps use.
///
/// Optimizer is invite-only: a new account can only be made from the link in
/// an invitation email (optimizer.axisoptic.com/?invite=…). Opened from one,
/// this page says who invited you and offers to make your account, with an
/// email and password or with Google. Otherwise it's sign-in only.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  /// From the invitation link: who invited you, to what, at which email.
  ({String fromName, String what, String email})? _invite;
  bool _creating = false;

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
        _creating = true;
        _email.text = _invite!.email;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is FirebaseFunctionsException ? (e.message ?? e.code) : '$e');
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on FirebaseAuthException catch (e) {
      setState(() => _error = e.message ?? e.code);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signIn() => _run(() => FirebaseAuth.instance.signInWithEmailAndPassword(email: _email.text.trim(), password: _password.text));

  Future<void> _create() => _run(() async {
        final name = _name.text.trim();
        if (name.isEmpty) throw 'Type your name.';
        if (_password.text.length < 8) throw 'Pick a password of at least 8 characters.';
        // Held until the name is set, so the app opens already knowing it.
        signInHold.value = true;
        try {
          final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(email: _email.text.trim(), password: _password.text);
          await cred.user?.updateDisplayName(name);
          await cred.user?.reload();
        } finally {
          signInHold.value = false;
        }
      });

  /// With Google. Without an invitation, a Google account that would be new
  /// to Axis isn't made: it's undone at once.
  Future<void> _google() => _run(() async {
        signInHold.value = true;
        try {
          final cred = await FirebaseAuth.instance.signInWithPopup(GoogleAuthProvider());
          if (pendingInviteToken == null && (cred.additionalUserInfo?.isNewUser ?? false)) {
            await cred.user?.delete();
            await FirebaseAuth.instance.signOut();
            throw 'Optimizer is invite-only for now. Ask someone on Optimizer to invite you, then use the link in their email.';
          }
        } finally {
          signInHold.value = false;
        }
      });

  Future<void> _reset() => _run(() async {
        final email = _email.text.trim();
        if (email.isEmpty) throw 'Type your email first, then tap “Forgot password”.';
        await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Password reset email sent to $email')));
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final invite = _invite;
    final spinner = const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2));
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: OptimizerLogo(size: 56)),
                  const SizedBox(height: 12),
                  Text('Optimizer', textAlign: TextAlign.center, style: theme.textTheme.headlineMedium),
                  const SizedBox(height: 4),
                  if (invite == null)
                    Text('Sign in with your Axis account',
                        textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.secondaryText))
                  else
                    Text.rich(
                      TextSpan(children: [
                        TextSpan(text: invite.fromName, style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.primaryText)),
                        const TextSpan(text: ' invited you'),
                        if (invite.what.isNotEmpty) ...[
                          const TextSpan(text: ' to '),
                          TextSpan(text: invite.what, style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.primaryText)),
                        ],
                      ]),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge?.copyWith(color: AppColors.secondaryText),
                    ),
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
                    onSubmitted: (_) => _busy ? null : (_creating ? _create() : _signIn()),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: const TextStyle(color: AppColors.danger)),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : (_creating ? _create : _signIn),
                    child: _busy ? spinner : Text(_creating ? 'Create account' : 'Sign in'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _google,
                    icon: const Icon(Icons.account_circle_outlined),
                    label: Text(_creating ? 'Sign up with Google' : 'Continue with Google'),
                  ),
                  // Only from an invitation: switch between making an account and signing in.
                  if (invite != null)
                    TextButton(
                      onPressed: _busy ? null : () => setState(() => _creating = !_creating),
                      child: Text(_creating ? 'I already have an account' : 'Make a new account instead'),
                    )
                  else
                    TextButton(onPressed: _busy ? null : _reset, child: const Text('Forgot password')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

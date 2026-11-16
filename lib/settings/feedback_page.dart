import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../app_version.dart';
import '../theme.dart';
import '../widgets/tiles.dart';

/// Sends a bug or idea to the Axis Optic inbox.
///
/// Optic lives in the Axis Team Firebase project, so tickets go through its
/// `submitAppFeedback` function (axis-team/functions/index.js). It checks
/// this Optimizer sign-in and files the ticket where Optic (and the
/// developers' phones) pick it up.
Future<void> sendOpticFeedback({required bool isBug, required String location, required String message}) async {
  final user = FirebaseAuth.instance.currentUser;
  final token = await user?.getIdToken();
  if (token == null) throw const FeedbackException('Sign in to send feedback.');
  final http.Response res;
  try {
    res = await http
        .post(
          Uri.parse('https://us-central1-project-attendance-app.cloudfunctions.net/submitAppFeedback'),
          headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
          body: jsonEncode({
            'type': isBug ? 'Bug' : 'Improvement',
            'location': location,
            'message': message,
            'submitter_name': (user?.displayName ?? '').trim(),
            'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
            'app_version': appVersion,
          }),
        )
        .timeout(const Duration(seconds: 15));
  } catch (_) {
    throw const FeedbackException('Couldn’t reach Axis Optic. Check your connection and try again.');
  }
  if (res.statusCode == 200) return;
  if (res.statusCode == 429) throw const FeedbackException('Please wait a moment before sending more feedback.');
  String? error;
  try {
    error = (jsonDecode(res.body) as Map)['error'] as String?;
  } catch (_) {}
  throw FeedbackException(error ?? 'Couldn’t send it (HTTP ${res.statusCode}).');
}

class FeedbackException implements Exception {
  const FeedbackException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Report a bug or suggest an improvement (Settings → Send feedback).
class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key, this.premium = false});

  /// Premium beta pages (Net worth, Ask) are offered as places too.
  final bool premium;

  static Future<void> open(BuildContext context, {bool premium = false}) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => FeedbackPage(premium: premium)));

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final _message = TextEditingController();
  bool _bug = true;
  String _location = 'Home';
  bool _sending = false;

  List<String> get _locations => [
        'Home',
        'Calendar',
        'Trips',
        'Journal',
        if (widget.premium) ...['Net worth', 'Ask'],
        'People',
        'Notifications',
        'Settings',
        'Signing in',
        'Something else',
      ];

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _message.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await sendOpticFeedback(isBug: _bug, location: _location, message: text);
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('Thanks! Your feedback was sent.')));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    const note = TextStyle(color: AppColors.secondaryText, fontSize: 12.5);
    return Scaffold(
      appBar: AppBar(title: const Text('Send feedback')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: PillTabs<bool>(
                    items: const [(true, 'Bug'), (false, 'Improvement')],
                    selected: _bug,
                    onSelected: (v) => setState(() => _bug = v),
                  ),
                ),
                const SizedBox(height: 18),
                const Text('Where in Optimizer?', style: note),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final l in _locations)
                    ChoiceChip(
                      label: Text(l),
                      selected: _location == l,
                      onSelected: (_) => setState(() => _location = l),
                    ),
                ]),
                const SizedBox(height: 18),
                Tile(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  child: TextField(
                    controller: _message,
                    minLines: 5,
                    maxLines: 12,
                    maxLength: 4000,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: _bug ? 'What went wrong? What did you expect to happen?' : 'What would make Optimizer better?',
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                const Text('Goes straight to the developer, with your name and email so they can reply.', style: note),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: _sending || _message.text.trim().isEmpty ? null : _send,
                  child: _sending
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Send'),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

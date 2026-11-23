import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../app_version.dart';
import '../premium/premium_beta.dart';
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

/// Report a bug or suggest an idea (Settings → Send feedback), laid out
/// like Scorecards' form in Optimizer's colors: what it's about, where,
/// the details, and Submit. It's one-way: the ticket goes to the developer's
/// Axis Optic inbox, with no conversation here.
class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key, required this.premium});

  /// The places follow it as it changes: premium beta's features only while
  /// it's on.
  final PremiumBeta premium;

  static Future<void> open(BuildContext context, {required PremiumBeta premium}) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => FeedbackPage(premium: premium)));

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final _message = TextEditingController();
  bool _bug = true;
  String _bugLocation = 'To-dos';
  String _ideaLocation = _newPage;
  bool _sending = false;

  static const _newPage = 'New Page';

  /// An idea can be for a page that isn't there yet: first, and bigger.
  static const _featuredIdeas = [_newPage];

  /// What everyone has.
  static const _everyone = ['To-dos', 'Canvas sync', 'Settings', 'Signing in', 'Website'];

  /// Premium beta's features, after To-dos.
  static const _premiumOnly = ['Home', 'Focus', 'Calendar', 'Trips', 'Journal', 'Habits', 'Net worth', 'Assistant', 'People', 'Notifications'];

  List<String> get _locations => widget.premium.on ? [_everyone.first, ..._premiumOnly, ..._everyone.skip(1)] : _everyone;

  /// What's picked, or the first choice if it's gone (premium beta switched off).
  String get _location {
    final options = _bug ? _locations : [..._featuredIdeas, ..._locations];
    final picked = _bug ? _bugLocation : _ideaLocation;
    return options.contains(picked) ? picked : options.first;
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  void _say(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _submit() async {
    final text = _message.text.trim();
    if (text.isEmpty) {
      _say('Please type your feedback before submitting.');
      return;
    }
    setState(() => _sending = true);
    try {
      await sendOpticFeedback(isBug: _bug, location: _location, message: text);
      if (!mounted) return;
      _say('Thank you! Your feedback helps make Optimizer better.');
      Navigator.of(context).pop();
    } on FeedbackException catch (e) {
      if (mounted) _say(e.message);
    } catch (_) {
      if (mounted) _say('Something went wrong. Please check your connection and try again.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.premium, builder: (context, _) => _page(context));

  Widget _page(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        scrolledUnderElevation: 0,
        centerTitle: false,
        title: const Text('Send Feedback', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2, fontSize: 24)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Tile(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const _Label('WHAT CAN WE HELP WITH?'),
                    const SizedBox(height: 16),
                    Row(children: [
                      Expanded(
                        child: _TypeButton(
                          label: 'Fix a Problem',
                          icon: Icons.bug_report_outlined,
                          selected: _bug,
                          onTap: () => setState(() => _bug = true),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _TypeButton(
                          label: 'Suggest an Idea',
                          icon: Icons.lightbulb_outline,
                          selected: !_bug,
                          onTap: () => setState(() => _bug = false),
                        ),
                      ),
                    ]),
                  ]),
                ),
                const SizedBox(height: 24),
                Tile(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _Label(_bug ? 'WHERE IS THE PROBLEM?' : 'WHERE DOES THIS IDEA GO?'),
                    const SizedBox(height: 16),
                    _TileGrid(
                      options: _bug ? _locations : [..._featuredIdeas, ..._locations],
                      big: _featuredIdeas,
                      selected: _location,
                      onSelect: (v) => setState(() => _bug ? _bugLocation = v : _ideaLocation = v),
                    ),
                  ]),
                ),
                const SizedBox(height: 24),
                Tile(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const _Label('DETAILS'),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _message,
                      maxLines: 6,
                      maxLength: 4000,
                      style: const TextStyle(fontSize: 15),
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: _bug ? 'Please describe the issue you encountered...' : 'Please describe your idea or feature request...',
                        counterText: '',
                        filled: true,
                        fillColor: AppColors.background,
                        // One box, no outline: the theme's outlines would draw a
                        // second bubble inside the tile.
                        border: _noLine,
                        enabledBorder: _noLine,
                        focusedBorder: _noLine,
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 32),
                FilledButton(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _sending ? null : _submit,
                  child: _sending
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('SUBMIT FEEDBACK', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  static final _noLine = OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none);
}

/// A section's heading inside its tile.
class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(color: AppColors.secondaryText, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.5));
}

/// The look of a choice: dark until picked, then lit with a white edge.
BoxDecoration _choice(bool selected) => BoxDecoration(
      color: selected ? const Color(0x1AFFFFFF) : AppColors.background,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: selected ? AppColors.primaryText : AppColors.border, width: 1.5),
    );

/// Fix a Problem or Suggest an Idea.
class _TypeButton extends StatelessWidget {
  const _TypeButton({required this.label, required this.icon, required this.selected, required this.onTap});

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: _choice(selected),
            child: Column(children: [
              Icon(icon, size: 28, color: selected ? AppColors.primaryText : AppColors.secondaryText),
              const SizedBox(height: 8),
              Text(label,
                  style: TextStyle(color: selected ? AppColors.primaryText : AppColors.secondaryText, fontWeight: FontWeight.bold, fontSize: 13)),
            ]),
          ),
        ),
      );
}

/// Where in Optimizer: tiles two to a row on a phone, three when wider.
class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.options, required this.big, required this.selected, required this.onSelect});

  final List<String> options;
  final List<String> big;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final cols = c.maxWidth > 560 ? 3 : 2;
        final width = (c.maxWidth - 12 * (cols - 1)) / cols;
        return Wrap(spacing: 12, runSpacing: 12, children: [
          for (final o in options)
            GestureDetector(
              onTap: () => onSelect(o),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: width,
                  padding: EdgeInsets.symmetric(vertical: big.contains(o) ? 18 : 14, horizontal: 8),
                  decoration: _choice(o == selected),
                  child: Text(
                    o,
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: o == selected ? AppColors.primaryText : AppColors.secondaryText, fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
              ),
            ),
        ]);
      });
}

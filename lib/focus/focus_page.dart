import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../theme.dart';
import '../util/fields.dart';
import '../widgets/calm_scrollbar.dart';
import '../widgets/tiles.dart';
import 'energy_beam.dart';
import 'focus_store.dart';

/// "4:05" or "1:04:05".
String focusClock(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// "45m" or "2h 05m".
String focusShort(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60;
  return h > 0 ? '${h}h ${m.toString().padLeft(2, '0')}m' : '${m}m';
}

const _label = TextStyle(color: AppColors.secondaryText, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.4);
const _tabular = [FontFeature.tabularFigures()];

/// Keeps the app on the focus page: [child] (the rest of the app) stays
/// underneath, out of reach, while the page is [open] or a session is going,
/// whichever device started it. At start-up the rest of the app stays hidden
/// until it's known whether one is going (a few seconds at most, if offline).
class FocusGate extends StatefulWidget {
  const FocusGate({super.key, required this.store, required this.open, required this.onClose, required this.child, this.enabled = true});

  final FocusStore store;

  /// Focus is premium beta's: without it, never shown, and nothing waits on
  /// whether a session is going.
  final bool enabled;

  /// Opened from Home, with no session going yet.
  final bool open;
  final VoidCallback onClose;
  final Widget child;

  @override
  State<FocusGate> createState() => _FocusGateState();
}

class _FocusGateState extends State<FocusGate> {
  bool _waited = false;
  Timer? _patience;

  bool get _known => widget.store.loaded || widget.store.error != null || _waited;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_changed);
    if (!_known) {
      _patience = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _waited = true);
      });
    }
  }

  @override
  void dispose() {
    _patience?.cancel();
    widget.store.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.enabled;
    final show = on && (widget.open || widget.store.active != null);
    final waiting = on && !_known;
    return Stack(fit: StackFit.expand, children: [
      ExcludeSemantics(excluding: show || waiting, child: widget.child),
      if (show) FocusPage(store: widget.store, onClose: widget.onClose) else if (waiting) const ColoredBox(color: AppColors.background),
    ]);
  }
}

/// Focus time: pick what you'll work on and for how long, then watch the
/// energy flow while you do. Pauses and resumes are all timestamped. Backing
/// out of a session ends it, after asking. On a large screen the beam fills
/// the page, with everything else in a panel beside it.
class FocusPage extends StatefulWidget {
  const FocusPage({super.key, required this.store, this.onClose});

  final FocusStore store;

  /// Back to the rest of the app.
  final VoidCallback? onClose;

  @override
  State<FocusPage> createState() => _FocusPageState();
}

class _FocusPageState extends State<FocusPage> {
  final _title = TextEditingController();
  int _minutes = 50;
  Timer? _clock;
  String? _celebrated;

  // Keyboard focus stays on this page (no calendar shortcuts from underneath),
  // and goes back where it was afterwards.
  final _scope = FocusScopeNode(debugLabel: 'Focus page');
  FocusNode? _before;

  FocusStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    store.addListener(_changed);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => _changed());
    _before = FocusManager.instance.primaryFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scope.requestFocus();
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    store.removeListener(_changed);
    _title.dispose();
    _scope.dispose();
    if (_before?.context != null) _before!.requestFocus();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final s = store.active;
    final planned = s?.planned;
    if (s == null || planned == null || _celebrated == s.id || s.focusedAt(DateTime.now()) < planned) return;
    _celebrated = s.id;
    HapticFeedback.heavyImpact();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Goal reached: ${focusShort(planned)} of focus${s.title.isEmpty ? '' : ' on ${s.title}'}.'),
    ));
  }

  Future<void> _start() async {
    FocusScope.of(context).unfocus();
    await store.start(_title.text.trim(), minutes: _minutes == 0 ? null : _minutes);
    _title.clear();
  }

  /// The back arrow, the phone's back button, the browser's back button.
  Future<void> _leave() async {
    final s = store.active;
    if (s == null) {
      widget.onClose?.call();
    } else {
      await _end(s);
    }
  }

  /// Ends the session, after asking, and goes back to the app.
  Future<void> _end(FocusSession s) async {
    final focused = s.focusedAt(DateTime.now());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End focus?'),
        content: Text('Leaving ends this session. You focused for ${focusShort(focused)}, and it’s saved with every pause.',
            style: const TextStyle(color: AppColors.secondaryText)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep going')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('End focus')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    // Not waiting for the save: offline, it finishes when you're back online.
    final saving = store.end();
    widget.onClose?.call();
    messenger.showSnackBar(SnackBar(content: Text('Saved ${focusShort(focused)} of focus${s.title.isEmpty ? '' : ' on ${s.title}'}.')));
    try {
      await saving;
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn’t save that session: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = store.active;
    return FocusScope(
      node: _scope,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _leave();
        },
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: SafeArea(
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 16, 0),
                child: Row(children: [
                  if (widget.onClose != null) IconButton(tooltip: 'Back', icon: const Icon(Icons.arrow_back), onPressed: _leave),
                  const SizedBox(width: 8),
                  const Text('FOCUS', style: _label),
                  const Spacer(),
                  if (s != null)
                    Text(s.running ? 'Focusing' : 'Paused',
                        style: TextStyle(color: s.running ? AppColors.primaryText : AppColors.secondaryText, fontSize: 13)),
                ]),
              ),
              Expanded(
                child: LayoutBuilder(builder: (context, c) {
                  final large = c.maxWidth >= 900 && c.maxHeight >= 520;
                  if (s == null) return large ? _startLarge() : _startView();
                  return large ? _sessionLarge(s) : _sessionView(s);
                }),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- while focusing

  Widget _beam(FocusSession s, {bool large = false}) {
    final now = DateTime.now();
    final focused = s.focusedAt(now);
    final planned = s.planned;
    final left = planned == null ? null : planned - focused;
    final small = TextStyle(fontSize: large ? 44 : 34, fontWeight: FontWeight.w700, fontFeatures: _tabular);
    return EnergyBeam(
      running: s.running,
      progress: planned == null ? null : focused.inSeconds / planned.inSeconds,
      top: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(focusClock(focused),
            style: TextStyle(fontSize: large ? 62 : 46, fontWeight: FontWeight.w700, letterSpacing: -1, fontFeatures: _tabular)),
        Text(s.running ? 'FOCUSED' : 'PAUSED', style: _label),
      ]),
      bottom: Column(mainAxisSize: MainAxisSize.min, children: [
        if (left == null) ...[
          Text(focusShort(s.pausedAt(now)), style: small),
          Text(s.pauses == 1 ? '1 PAUSE' : '${s.pauses} PAUSES', style: _label),
        ] else if (left > Duration.zero) ...[
          Text(focusClock(left), style: small),
          Text('OF ${focusShort(planned!).toUpperCase()} TO GO', style: _label),
        ] else ...[
          Text('Done', style: small),
          Text(left.inMinutes.abs() < 1 ? 'GOAL REACHED' : '+${focusShort(-left).toUpperCase()} OVER', style: _label),
        ],
      ]),
    );
  }

  static String _markName(FocusMark m) => switch (m.what) {
        'start' => 'Started',
        'pause' => 'Paused',
        'resume' => 'Resumed',
        _ => 'Ended',
      };

  Widget _pauseButton(FocusSession s) => _Action(
        icon: s.running ? Icons.pause : Icons.play_arrow,
        label: s.running ? 'Pause' : 'Resume',
        onPressed: s.running ? store.pause : store.resume,
      );

  Widget _endButton(FocusSession s) => OutlinedButton.icon(
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16)),
        onPressed: () => _end(s),
        icon: const Icon(Icons.stop, size: 18),
        label: const Text('End'),
      );

  Widget _sessionView(FocusSession s) {
    final t = DateFormat.jm();
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, PageSpace.top(context), 16, 16),
          child: Column(children: [
            if (s.title.isNotEmpty) ...[
              const Text('WORKING ON', style: _label),
              const SizedBox(height: 4),
              Text(s.title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.6, height: 1.15)),
            ],
            Expanded(child: _beam(s)),
            withoutAutoScrollbar(
              context,
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text([for (final m in s.marks) '${_markName(m)} ${t.format(m.at)}'].join('   ·   '),
                    style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5, fontFeatures: _tabular)),
              ),
            ),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _pauseButton(s),
              const SizedBox(width: 12),
              _endButton(s),
            ]),
          ]),
        ),
      ),
    );
  }

  /// The beam filling the page, and beside it what you're on, how it's going,
  /// every timestamp, and the buttons.
  Widget _sessionLarge(FocusSession s) {
    final now = DateTime.now();
    final t = DateFormat.jm();
    final planned = s.planned;
    final left = planned == null ? null : planned - s.focusedAt(now);
    final (goalLabel, goal) = switch (left) {
      null => ('GOAL', 'None'),
      final l when l <= Duration.zero => ('GOAL', 'Reached'),
      final l when s.running => ('DONE BY', t.format(now.add(l))),
      _ => ('GOAL', focusShort(planned!)),
    };
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(child: Padding(padding: const EdgeInsets.all(16), child: _beam(s, large: true))),
      SizedBox(
        width: _panelWidth,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 16, 24, 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('WORKING ON', style: _label),
            const SizedBox(height: 6),
            Text(s.title.isEmpty ? 'Focus' : s.title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -1, height: 1.12)),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(child: _Stat('PAUSED', focusShort(s.pausedAt(now)))),
              const SizedBox(width: 8),
              Expanded(child: _Stat('PAUSES', '${s.pauses}')),
              const SizedBox(width: 8),
              Expanded(child: _Stat(goalLabel, goal)),
            ]),
            const SizedBox(height: 8),
            Expanded(
              child: Tile(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: ListView(children: [
                  for (final m in s.marks)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(children: [
                        Expanded(child: Text(_markName(m), style: const TextStyle(fontWeight: FontWeight.w600))),
                        Text(DateFormat.jms().format(m.at), style: const TextStyle(color: AppColors.secondaryText, fontFeatures: _tabular)),
                      ]),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: _pauseButton(s)),
              const SizedBox(width: 12),
              Expanded(child: _endButton(s)),
            ]),
          ]),
        ),
      ),
    ]);
  }

  // ---------------------------------------------------------------- starting, and what you've done

  static const _panelWidth = 420.0;

  Widget _idleBeam() => EnergyBeam(
        running: false,
        idle: true,
        progress: null,
        top: const Text('You', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        bottom: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_minutes == 0 ? '∞' : focusShort(Duration(minutes: _minutes)), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
          const Text('GOAL', style: _label),
        ]),
      );

  List<Widget> _form() => [
        TextField(
          controller: _title,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (_) => _start(),
          decoration: const InputDecoration(hintText: 'What are you focusing on?', prefixIcon: Icon(Icons.bolt)),
        ),
        const SizedBox(height: 14),
        Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: PillTabs<int>(
              items: const [(25, '25 min'), (50, '50 min'), (90, '90 min'), (0, 'No limit')],
              selected: _minutes,
              onSelected: (m) => setState(() => _minutes = m),
            ),
          ),
        ),
        const SizedBox(height: 18),
      ];

  List<Widget> _recent() {
    final now = DateTime.now();
    final weekStart = addDays(dayStart(now), -(now.weekday % 7));
    final week = store.history.where((s) => !s.started.isBefore(weekStart)).fold(Duration.zero, (sum, s) => sum + s.focusedAt(now));
    return [
      const SizedBox(height: 36),
      Row(children: [
        const Expanded(child: Text('RECENT', style: _label)),
        if (week > Duration.zero) Text('${focusShort(week)} this week', style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
      ]),
      const SizedBox(height: 8),
      if (store.error != null)
        Text('Couldn’t read your focus sessions.\n${store.error}', style: const TextStyle(color: AppColors.danger, fontSize: 12.5))
      else if (store.history.isEmpty)
        const Text('Sessions you finish show up here, with every pause.', style: TextStyle(color: AppColors.secondaryText))
      else
        for (final s in store.history) _HistoryRow(session: s, store: store),
    ];
  }

  Widget _startView() {
    final phone = MediaQuery.sizeOf(context).width < 600;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(padding: EdgeInsets.fromLTRB(16, PageSpace.top(context), 16, 32), children: [
          SizedBox(height: phone ? 300 : 360, child: _idleBeam()),
          const SizedBox(height: 8),
          ..._form(),
          Center(child: _Action(icon: Icons.play_arrow, label: 'Start focus', onPressed: _start)),
          ..._recent(),
        ]),
      ),
    );
  }

  /// The beam filling the page, and beside it the form and your past sessions.
  Widget _startLarge() => Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: Padding(padding: const EdgeInsets.all(16), child: _idleBeam())),
        SizedBox(
          width: _panelWidth,
          child: ListView(padding: const EdgeInsets.fromLTRB(0, 16, 24, 32), children: [
            const Text('Start focusing', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -1, height: 1.12)),
            const SizedBox(height: 20),
            ..._form(),
            _Action(icon: Icons.play_arrow, label: 'Start focus', onPressed: _start),
            ..._recent(),
          ]),
        ),
      ]);
}

/// One number in the panel beside the beam.
class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Tile(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          FittedBox(fit: BoxFit.scaleDown, child: Text(label, style: _label.copyWith(fontSize: 10.5))),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, fontFeatures: _tabular)),
          ),
        ]),
      );
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.session, required this.store});

  final FocusSession session;
  final FocusStore store;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final t = DateFormat.jm();
    final today = dayStart(DateTime.now());
    final day = dayStart(s.started);
    final when = sameDay(day, today)
        ? 'Today'
        : sameDay(day, addDays(today, -1))
            ? 'Yesterday'
            : DateFormat('EEE, MMM d').format(day);
    final focused = s.focusedAt(DateTime.now());
    final hitGoal = s.planned != null && focused >= s.planned!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: HoverMenu(
        top: 8,
        right: 70,
        actions: [
          MenuAction(
            label: 'Delete',
            icon: Icons.delete_outline,
            confirm: ('Delete this session?', 'Its time and pauses are removed from Optimizer.', 'Delete'),
            onSelected: () => store.delete(s),
          ),
        ],
        child: Tile(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          onTap: () => _showMarks(context, s),
          child: Row(children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(shape: BoxShape.circle, color: hitGoal ? Colors.white : AppColors.secondaryText),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.title.isEmpty ? 'Focus' : s.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                Text(
                  [
                    '$when · ${t.format(s.started)} – ${s.ended == null ? '…' : t.format(s.ended!)}',
                    if (s.pauses > 0) s.pauses == 1 ? '1 pause' : '${s.pauses} pauses',
                  ].join(' · '),
                  style: const TextStyle(color: AppColors.secondaryText, fontSize: 12),
                ),
              ]),
            ),
            const SizedBox(width: 10),
            Text(focusShort(focused), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, fontFeatures: _tabular)),
          ]),
        ),
      ),
    );
  }

  /// Every timestamp of a session.
  static void _showMarks(BuildContext context, FocusSession s) {
    final t = DateFormat.jms();
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.title.isEmpty ? 'Focus' : s.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              '${focusShort(s.focusedAt(DateTime.now()))} focused · ${focusShort(s.pausedAt(DateTime.now()))} paused'
              '${s.planned == null ? '' : ' · goal ${focusShort(s.planned!)}'}',
              style: const TextStyle(color: AppColors.secondaryText),
            ),
            const SizedBox(height: 14),
            for (final m in s.marks)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  SizedBox(
                    width: 110,
                    child: Text(t.format(m.at), style: const TextStyle(color: AppColors.secondaryText, fontFeatures: _tabular)),
                  ),
                  Text(
                      switch (m.what) {
                        'start' => 'Started',
                        'pause' => 'Paused',
                        'resume' => 'Resumed',
                        _ => 'Ended',
                      },
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ]),
              ),
          ]),
        ),
      ),
    );
  }
}

/// The big button on the focus page: plain white, like the rest of the app.
class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 16)),
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
      );
}

/// Home's way into focus time. (During a session the app stays on the focus
/// page, so Home never needs to show one going.)
class FocusButton extends StatelessWidget {
  const FocusButton({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), visualDensity: VisualDensity.compact),
        onPressed: onOpen,
        icon: const Icon(Icons.bolt, size: 16),
        label: const Text('Focus', style: TextStyle(fontWeight: FontWeight.w600)),
      );
}

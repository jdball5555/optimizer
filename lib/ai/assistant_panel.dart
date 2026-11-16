import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';
import '../widgets/tiles.dart';
import 'assistant.dart';

/// How far the tile sits in from the window's edges.
const _tileGap = 12.0;

// The panel's header's padding, which places its arrow.
const _headerTop = 10.0;
const _headerRight = 4.0;

/// The arrow that opens the assistant's panel. It stays in one spot in the
/// window's top right corner on every page, exactly where the panel's own arrow
/// closes it from, and it's only there while the panel's closed.
class AssistantToggle extends StatelessWidget {
  const AssistantToggle({super.key, required this.open});

  final ValueNotifier<bool> open;

  /// From the window's top right corner to the arrow, level with the panel's.
  static ({double top, double right}) spot(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context).top;
    // Down through the tile's gap and border, then the header's own padding.
    const inTile = _tileGap + 1 + _headerTop;
    if (AssistantSplit.fits(size.width)) return (top: safe + inTile, right: _tileGap + 1 + _headerRight);
    return (top: safe + (size.width >= 720 ? inTile : _headerTop), right: _headerRight);
  }

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Open the assistant',
        icon: const Icon(Icons.chevron_left),
        onPressed: () => open.value = true,
      );
}

/// What each page's top row leaves empty at its end, so its buttons stop short
/// of the arrow floating there. Nothing's needed while the panel's open.
class AssistantArrowRoom extends StatelessWidget {
  const AssistantArrowRoom({super.key, required this.open});

  final ValueListenable<bool> open;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: open,
        builder: (context, isOpen, _) => SizedBox(width: isOpen ? 0 : (MediaQuery.sizeOf(context).width >= 720 ? 57 : 46)),
      );
}

/// A page with the assistant's panel beside it, in a tile you can drag wider or
/// narrower. Opening it pushes the page over: the page is told it has that much
/// less room, so it lays itself out as it would in a smaller window.
class AssistantSplit extends StatefulWidget {
  const AssistantSplit({super.key, required this.open, required this.enabled, required this.panel, required this.child});

  /// A window with room for both.
  static bool fits(double windowWidth) => windowWidth >= 900;

  final ValueListenable<bool> open;

  /// False: no panel here at all (it covers the page instead, or it's the Ask page).
  final bool enabled;
  final Widget panel;
  final Widget child;

  @override
  State<AssistantSplit> createState() => _AssistantSplitState();
}

class _AssistantSplitState extends State<AssistantSplit> {
  static const _minWidth = 300.0;
  static const _minPage = 360.0;
  static const _widthKey = 'optimizer.assistant.width';
  static const _handle = 8.0;

  /// How far the drag bar reaches back over the page's own gap at its edge,
  /// leaving it most of a scrollbar's width to be grabbed by.
  static const _overlap = 6.0;

  double _width = 400;
  bool _dragging = false;
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    _loadWidth();
  }

  Future<void> _loadWidth() async {
    try {
      final w = (await SharedPreferences.getInstance()).getDouble(_widthKey);
      if (w != null && mounted) setState(() => _width = w);
    } catch (_) {}
  }

  void _saveWidth() {
    SharedPreferences.getInstance().then((p) => p.setDouble(_widthKey, _width), onError: (_) => false);
  }

  Widget _grip(double room) => MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          key: const ValueKey('assistant-resize'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) => setState(() => _dragging = true),
          onHorizontalDragUpdate: (d) => setState(() => _width = (_width - d.delta.dx).clamp(_minWidth, _biggest(room))),
          onHorizontalDragEnd: (_) {
            setState(() => _dragging = false);
            _saveWidth();
          },
          child: SizedBox(
            width: _handle,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 3,
                height: 44,
                decoration: BoxDecoration(
                  color: _dragging || _hover ? AppColors.secondaryText : AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      );

  static double _biggest(double room) => math.max(_minWidth, room - _minPage);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final width = _width.clamp(_minWidth, _biggest(c.maxWidth));
      return ValueListenableBuilder<bool>(
        valueListenable: widget.open,
        builder: (context, isOpen, _) {
          final open = isOpen && widget.enabled;
          return TweenAnimationBuilder<double>(
            tween: Tween(end: open ? width : 0),
            // Dragging, it follows the pointer exactly.
            duration: _dragging ? Duration.zero : const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            child: widget.child,
            builder: (context, shown, page) {
              final media = MediaQuery.of(context);
              final pushed = shown - math.min(shown, _overlap);
              return Stack(children: [
                Positioned.fill(
                  right: pushed,
                  child: MediaQuery(
                    data: media.copyWith(size: Size(media.size.width - pushed, media.size.height)),
                    child: page!,
                  ),
                ),
                if (widget.enabled)
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    width: shown,
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.centerLeft,
                        minWidth: width,
                        maxWidth: width,
                        child: Offstage(
                          offstage: !open && shown == 0,
                          child: IgnorePointer(
                            ignoring: !open,
                            child: ExcludeFocus(
                              excluding: !open,
                              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                                _grip(c.maxWidth),
                                Expanded(
                                  child: Padding(
                                    padding: EdgeInsets.fromLTRB(0, _tileGap + media.padding.top, _tileGap, _tileGap),
                                    child: Tile(padding: EdgeInsets.zero, child: widget.panel),
                                  ),
                                ),
                              ]),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ]);
            },
          );
        },
      );
    });
  }
}

/// Over the whole app: the arrow that opens the panel and, where there isn't
/// room to push the page over (a phone), the panel itself, on top of the page.
class AssistantOverlay extends StatelessWidget {
  const AssistantOverlay({super.key, required this.open, required this.enabled, required this.arrow, required this.panel, required this.child});

  final ValueNotifier<bool> open;

  /// The panel is here rather than beside the page.
  final bool enabled;

  /// False: no arrow at all (the Ask page already is the assistant).
  final bool arrow;
  final Widget panel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: open,
      builder: (context, isOpen, _) {
        final size = MediaQuery.sizeOf(context);
        final width = size.width >= 720 ? math.min(430.0, size.width * 0.9) : size.width;
        final shown = isOpen && enabled;
        final spot = AssistantToggle.spot(context);
        return Stack(children: [
          child,
          if (enabled)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              top: 0,
              bottom: 0,
              right: shown ? 0 : -(width + 24),
              width: width,
              child: IgnorePointer(
                ignoring: !shown,
                child: ExcludeFocus(
                  excluding: !shown,
                  child: Material(
                    color: AppColors.surface,
                    elevation: 18,
                    shadowColor: Colors.black,
                    shape: const Border(left: BorderSide(color: AppColors.border)),
                    child: Padding(
                      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
                      // Its arrow level with the one that opened it.
                      child: SafeArea(
                        left: false,
                        child: Padding(padding: EdgeInsets.only(top: size.width >= 720 ? _tileGap + 1 : 0), child: panel),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (arrow && !isOpen)
            Positioned(
              top: spot.top,
              right: spot.right,
              child: Material(type: MaterialType.transparency, child: AssistantToggle(open: open)),
            ),
        ]);
      },
    );
  }
}

/// The chat itself, in the side panel ([onClose] set) or as the Ask page.
class AssistantChat extends StatefulWidget {
  const AssistantChat({super.key, required this.controller, required this.onOpenSettings, this.onClose});

  final AssistantController controller;
  final VoidCallback onOpenSettings;
  final VoidCallback? onClose;

  @override
  State<AssistantChat> createState() => _AssistantChatState();
}

class _AssistantChatState extends State<AssistantChat> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  int _seen = 0;

  AssistantController get c => widget.controller;

  static const _starters = [
    'Plan the rest of my day around what’s already on my calendar',
    'What’s due this week, and when should I work on each one?',
    'Find time for 3 study sessions this week and add them',
    'Any clashes or overloaded days coming up?',
    'What did I get done this week?',
  ];

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant AssistantChat old) {
    super.didUpdateWidget(old);
    if (old.controller != c) {
      old.controller.removeListener(_changed);
      c.addListener(_changed);
    }
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    final n = c.lines.length + (c.pending == null ? 0 : 1) + (c.busy ? 1 : 0);
    if (n != _seen) {
      _seen = n;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        }
      });
    }
  }

  void _send([String? text]) {
    final q = (text ?? _input.text).trim();
    if (q.isEmpty || c.busy) return;
    _input.clear();
    c.send(q);
  }

  Future<void> _history() async {
    final ai = c.ai;
    await showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (ctx) => ListenableBuilder(
        listenable: ai,
        builder: (ctx, _) => SafeArea(
          child: ai.chats.isEmpty
              ? const Padding(padding: EdgeInsets.all(24), child: Text('No chats yet.', style: TextStyle(color: AppColors.secondaryText)))
              : ListView(shrinkWrap: true, children: [
                  for (final chat in ai.chats)
                    ListTile(
                      title: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(DateFormat('MMM d, h:mm a').format(chat.updated),
                          style: const TextStyle(color: AppColors.secondaryText, fontSize: 12)),
                      trailing: IconButton(
                        tooltip: 'Delete chat',
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: () async {
                          if (await confirmAction(ctx, title: 'Delete this chat?', message: '“${chat.title}” will be removed.')) {
                            await ai.deleteChat(chat);
                            if (chat.id == c.chatId) c.newChat();
                          }
                        },
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        c.openChat(chat);
                      },
                    ),
                ]),
        ),
      ),
    );
  }

  List<Widget> _actions() => [
        IconButton(tooltip: 'Past chats', icon: const Icon(Icons.history), onPressed: c.busy ? null : _history),
        IconButton(tooltip: 'New chat', icon: const Icon(Icons.add_comment_outlined), onPressed: c.busy ? null : c.newChat),
        IconButton(tooltip: 'What it can see and do', icon: const Icon(Icons.tune), onPressed: widget.onOpenSettings),
      ];

  Widget _header() {
    final close = widget.onClose;
    if (close == null) {
      return PageTabsHeader<int>(items: const [(0, 'Ask')], selected: 0, onSelected: (_) {}, actions: _actions());
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, _headerTop, _headerRight, 6),
      child: Row(children: [
        ShaderMask(
          shaderCallback: (r) => Energy.gradient.createShader(r),
          child: const Icon(Icons.auto_awesome, size: 20, color: Colors.white),
        ),
        const SizedBox(width: 10),
        const Expanded(child: Text('Assistant', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
        ..._actions(),
        IconButton(tooltip: 'Close', icon: const Icon(Icons.chevron_right), onPressed: close),
      ]),
    );
  }

  Widget _intro() {
    final ai = c.ai;
    final sees = ai.shared.map((s) => s.label.toLowerCase()).join(', ');
    final can = [for (final a in ai.acts) a.label.replaceFirst('Change your ', '')];
    final does = can.length < 2 ? can.join() : '${can.sublist(0, can.length - 1).join(', ')} and ${can.last}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(
        padding: EdgeInsets.only(top: 8, bottom: 6),
        child: Text('Ask about your time, or have it plan and rearrange things for you.', style: TextStyle(fontSize: 15.5)),
      ),
      Text(
        [
          sees.isEmpty ? 'It can’t see any of your data yet.' : 'It can see your $sees.',
          does.isEmpty ? 'It can’t change anything yet.' : 'It can change your $does${ai.confirmChanges ? ', after checking with you' : ''}.',
        ].join(' '),
        style: const TextStyle(color: AppColors.secondaryText, fontSize: 13.5, height: 1.4),
      ),
      if (ai.acts.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: TextButton.icon(
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            onPressed: widget.onOpenSettings,
            icon: const Icon(Icons.lock_open, size: 16),
            label: const Text('Let it change your calendar, to-dos and trips'),
          ),
        ),
      const SizedBox(height: 12),
      for (final s in _starters)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(alignment: Alignment.centerLeft),
            onPressed: () => _send(s),
            child: Text(s, textAlign: TextAlign.left),
          ),
        ),
    ]);
  }

  Widget _pending(PendingChange p) => Container(
        margin: const EdgeInsets.only(top: 8, bottom: 8),
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Energy.violet.withValues(alpha: 0.6)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Okay to do this?', style: TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
          const SizedBox(height: 4),
          Text(p.text, style: const TextStyle(fontWeight: FontWeight.w600, height: 1.35)),
          const SizedBox(height: 4),
          Wrap(alignment: WrapAlignment.end, children: [
            TextButton(onPressed: () => p.answerWith(false), child: const Text('Skip')),
            TextButton(onPressed: c.approveAll, child: const Text('Yes to all')),
            FilledButton(onPressed: () => p.answerWith(true), child: const Text('Do it')),
          ]),
        ]),
      );

  Widget _line(AssistantLine l) => switch (l.kind) {
        LineKind.user => Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 520),
              margin: const EdgeInsets.only(top: 12, bottom: 6, left: 40),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(18)),
              child: SelectableText(l.text, style: const TextStyle(fontSize: 15, height: 1.4)),
            ),
          ),
        LineKind.reply => Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 8, right: 12),
            child: SelectableText.rich(_markdown(l.text), style: const TextStyle(fontSize: 15, height: 1.5)),
          ),
        LineKind.action => Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  l.changed ? Icons.check_circle : (l.text.startsWith('Skipped') ? Icons.remove_circle_outline : Icons.search),
                  size: 15,
                  color: l.changed ? AppColors.positive : AppColors.secondaryText,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(l.text,
                    style: TextStyle(
                      color: l.changed ? AppColors.primaryText : AppColors.secondaryText,
                      fontSize: 13,
                      height: 1.35,
                    )),
              ),
            ]),
          ),
      };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.ai]),
      builder: (context, _) {
        final p = c.pending;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(),
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              children: [
                if (c.lines.isEmpty && !c.busy) _intro(),
                for (final l in c.lines) _line(l),
                if (p != null) _pending(p),
                if (c.busy && p == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 10),
                    child: Row(children: [
                      SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 10),
                      Text('Working on it…', style: TextStyle(color: AppColors.secondaryText)),
                    ]),
                  ),
                if (c.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: SelectableText(c.error!, style: const TextStyle(color: AppColors.danger)),
                  ),
                if (!c.busy && c.canUndo)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.maybeOf(context);
                        try {
                          await c.undo();
                        } catch (e) {
                          messenger?.showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', ''))));
                        }
                      },
                      icon: const Icon(Icons.undo, size: 18),
                      label: const Text('Undo these changes'),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 2, 6, 2),
              decoration: BoxDecoration(
                color: AppColors.surfaceHigh,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 6,
                    style: const TextStyle(height: 1.5),
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.send,
                    decoration: const InputDecoration(
                      hintText: 'Plan, schedule, ask anything…',
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                IconButton(
                  tooltip: 'Send',
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: c.busy ? null : _send,
                ),
              ]),
            ),
          ),
        ]);
      },
    );
  }

  /// Just enough Markdown for chat answers: headings, bullets and **bold**.
  static TextSpan _markdown(String text) {
    final spans = <InlineSpan>[];
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      var style = const TextStyle();
      final heading = RegExp(r'^#{1,6}\s+').firstMatch(line);
      if (heading != null) {
        line = line.substring(heading.end);
        style = const TextStyle(fontWeight: FontWeight.w700, fontSize: 16.5);
      }
      final bullet = RegExp(r'^(\s*)[-*•]\s+').firstMatch(line);
      if (bullet != null) {
        spans.add(TextSpan(text: '${bullet.group(1)}•  '));
        line = line.substring(bullet.end);
      }
      final parts = line.split('**');
      for (var j = 0; j < parts.length; j++) {
        if (parts[j].isEmpty) continue;
        spans.add(TextSpan(text: parts[j], style: j.isOdd ? style.copyWith(fontWeight: FontWeight.w700) : style));
      }
      if (i < lines.length - 1) spans.add(const TextSpan(text: '\n'));
    }
    return TextSpan(children: spans);
  }
}

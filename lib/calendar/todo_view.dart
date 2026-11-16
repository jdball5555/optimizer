import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import '../util/fields.dart';
import '../widgets/tiles.dart';
import 'calendar_models.dart';
import 'calendar_service.dart';
import 'todos.dart';

/// The calendar's to-do list: everything on your Canvas classes and the
/// to-dos you add, one section per day, with a white line above today (past
/// days, still to do, sit above it). All of it is saved in Firestore: Canvas
/// check-offs and edits in axisCalendar/{uid}/taskStatus (they show on the
/// calendar too), your own to-dos in axisCalendar/{uid}/todos.
class TodoView extends StatefulWidget {
  const TodoView({super.key, required this.service, required this.onAddCanvas});

  final CalendarService service;
  final VoidCallback onAddCanvas;

  @override
  State<TodoView> createState() => _TodoViewState();
}

class _TodoViewState extends State<TodoView> {
  bool _showDone = false;
  final _todayLine = GlobalKey();
  bool _scrolledToToday = false;

  // Checked off just now: they stay where they are, ticked and crossed out,
  // until three seconds after the last tick, then all leave together.
  final _lingering = <String>{};
  bool _leaving = false;
  Timer? _settle;

  CalendarService get svc => widget.service;

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  void _toggle(Todo t) {
    final done = !t.done;
    svc.setTodoDone(t, done);
    setState(() {
      if (done) {
        _lingering.add(t.id);
        _leaving = false;
      } else {
        _lingering.remove(t.id);
      }
    });
    _settle?.cancel();
    if (_lingering.isEmpty) return;
    _settle = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _leaving = true);
      _settle = Timer(const Duration(milliseconds: 280), () {
        if (mounted) {
          setState(() {
            _lingering.clear();
            _leaving = false;
          });
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = dayStart(now);
    final all = svc.todos;
    final open = all.where((t) => !t.done || _lingering.contains(t.id)).toList();
    final done = all.where((t) => t.done && !_lingering.contains(t.id)).toList()
      // Most recently checked off first.
      ..sort((a, b) => (b.doneAt ?? DateTime(1970)).compareTo(a.doneAt ?? DateTime(1970)));

    final byDay = <DateTime, List<Todo>>{};
    for (final t in open.where((t) => t.due != null)) {
      (byDay[dayStart(t.due!)] ??= []).add(t);
    }
    for (final list in byDay.values) {
      list.sort(Todo.byClassThenTitle);
    }
    final past = byDay.keys.where((d) => d.isBefore(today)).toList()..sort();
    final coming = byDay.keys.where((d) => !d.isBefore(today)).toList()..sort();
    final undated = open.where((t) => t.due == null).toList()..sort(Todo.byClassThenTitle);
    final overdue = past.fold<int>(0, (n, d) => n + byDay[d]!.where((t) => !t.done).length);

    // Open on today, with what's overdue just above (scroll up for it).
    if (!_scrolledToToday && past.isNotEmpty) {
      _scrolledToToday = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final c = _todayLine.currentContext;
        if (c != null) Scrollable.ensureVisible(c, alignment: 0.02);
      });
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(2, 4, 11, 32),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (svc.canvasFeeds.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(children: [
                    const Expanded(
                      child:
                          Text('Link Canvas and your assignments show up here too.', style: TextStyle(color: AppColors.secondaryText, fontSize: 13)),
                    ),
                    TextButton.icon(
                      onPressed: widget.onAddCanvas,
                      icon: const Icon(Icons.school_outlined, size: 18),
                      label: const Text('Add Canvas'),
                    ),
                  ]),
                ),
              for (final day in past) _day(_dayName(day, today), DateFormat('EEE, MMM d').format(day), byDay[day]!, late: true),
              _TodayLine(key: _todayLine, overdue: overdue),
              if (coming.isEmpty && undated.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child:
                      Text('Nothing coming up. Tap + to add a to-do.', textAlign: TextAlign.center, style: TextStyle(color: AppColors.secondaryText)),
                ),
              for (final day in coming)
                _day(
                  _dayName(day, today),
                  // "Today  Sat, Oct 31", but "Tuesday  Nov 3".
                  DateFormat(day.isBefore(addDays(today, 2)) ? 'EEE, MMM d' : 'MMM d').format(day),
                  byDay[day]!,
                ),
              if (undated.isNotEmpty) _day('No date', '', undated),
              if (done.isNotEmpty) ...[
                const SizedBox(height: 6),
                TextButton.icon(
                  onPressed: () => setState(() => _showDone = !_showDone),
                  icon: Icon(_showDone ? Icons.expand_less : Icons.expand_more, size: 18),
                  label: Text('Done (${done.length})'),
                  style: TextButton.styleFrom(alignment: Alignment.centerLeft, foregroundColor: AppColors.secondaryText),
                ),
                if (_showDone) _day('Done', 'latest first', done, showDoneAt: true),
              ],
            ]),
          ),
        ),
      ],
    );
  }

  static String _dayName(DateTime day, DateTime today) {
    if (sameDay(day, today)) return 'Today';
    if (sameDay(day, addDays(today, 1))) return 'Tomorrow';
    if (sameDay(day, addDays(today, -1))) return 'Yesterday';
    return DateFormat('EEEE').format(day);
  }

  /// One day's to-dos in a tile of its own, under the day's name and date.
  Widget _day(String name, String detail, List<Todo> tasks, {bool late = false, bool showDoneAt = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16)),
        // On top of the header's fill, so the top corners keep their border too.
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: late ? AppColors.danger.withValues(alpha: 0.4) : AppColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            color: AppColors.surfaceHigh,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(children: [
              Text(name, style: TextStyle(color: late ? AppColors.danger : AppColors.primaryText, fontSize: 15, fontWeight: FontWeight.w700)),
              if (detail.isNotEmpty) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.secondaryText, fontSize: 13),
                  ),
                ),
              ] else
                const Spacer(),
              const SizedBox(width: 8),
              Text('${tasks.length} ${tasks.length == 1 ? 'task' : 'tasks'}', style: const TextStyle(color: AppColors.secondaryText, fontSize: 12)),
            ]),
          ),
          for (var i = 0; i < tasks.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 52),
            _row(tasks[i], showDoneAt: showDoneAt),
          ],
        ]),
      ),
    );
  }

  Widget _row(Todo t, {required bool showDoneAt}) {
    final color = t.color;
    final time = t.due == null ? '' : (t.allDay ? (t.isCanvas ? 'All day' : '') : DateFormat.jm().format(t.due!));
    final when = showDoneAt
        ? [
            if (t.doneAt != null) 'Done ${DateFormat('MMM d, h:mm a').format(t.doneAt!)}',
          ].join()
        : time;
    final leaving = _leaving && _lingering.contains(t.id);

    final row = InkWell(
      onTap: () => _toggle(t),
      onLongPress: () => showTodoOptions(context, svc, t),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 40, 10),
        child: Row(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: t.done ? color : Colors.transparent,
              shape: BoxShape.circle,
              border: Border.all(color: color, width: 2),
            ),
            child: t.done ? Icon(Icons.check, size: 15, color: onColor(color)) : null,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                t.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14.5,
                  color: t.done ? AppColors.secondaryText : AppColors.primaryText,
                  decoration: t.done ? TextDecoration.lineThrough : TextDecoration.none,
                  decorationColor: AppColors.secondaryText,
                ),
              ),
              if (t.label.isNotEmpty || when.isNotEmpty || t.edited) ...[
                const SizedBox(height: 3),
                Row(children: [
                  if (t.label.isNotEmpty) ...[
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(color: color.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(100)),
                        child: Text(
                          t.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Color.lerp(color, Colors.white, 0.35), fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (t.edited) ...[
                    const Tooltip(
                      message: 'Edited by you; no longer updated from Canvas',
                      child: Icon(Icons.edit_outlined, size: 13, color: AppColors.secondaryText),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(when,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.secondaryText, fontSize: 12)),
                  ),
                ]),
              ],
            ]),
          ),
        ]),
      ),
    );

    return AnimatedOpacity(
      opacity: leaving ? 0 : 1,
      duration: const Duration(milliseconds: 260),
      // On the web, the same options are behind ⋯ when you hover.
      child: HoverMenu(
        top: 10,
        right: 8,
        actions: [
          MenuAction(label: 'Options', icon: Icons.tune, onSelected: () => showTodoOptions(context, svc, t)),
        ],
        child: row,
      ),
    );
  }
}

/// The white line above today. What's still to do from past days is above it.
class _TodayLine extends StatelessWidget {
  const _TodayLine({super.key, required this.overdue});

  final int overdue;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 14),
      child: Row(children: [
        const Text('TODAY', style: TextStyle(color: AppColors.primaryText, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.2)),
        const SizedBox(width: 10),
        Expanded(
          child: Container(height: 2, decoration: BoxDecoration(color: AppColors.primaryText, borderRadius: BorderRadius.circular(2))),
        ),
        if (overdue > 0) ...[
          const SizedBox(width: 10),
          Text('$overdue overdue above', style: const TextStyle(color: AppColors.danger, fontSize: 11.5, fontWeight: FontWeight.w600)),
        ],
      ]),
    );
  }
}

/// Long-press (or ⋯) on a to-do: what it is, and what you can do with it.
Future<void> showTodoOptions(BuildContext context, CalendarService svc, Todo t) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.surface,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(t.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          ),
          if (t.due != null && t.isCanvas)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Text(
                '${t.canvas!.assignment ? 'Due ' : ''}${DateFormat('EEE, MMM d').format(t.due!)}${t.allDay ? ' · All day' : ' · ${DateFormat.jm().format(t.due!)}'}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          if (t.canvas?.location.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.place_outlined, size: 16, color: AppColors.secondaryText),
                const SizedBox(width: 6),
                Expanded(child: SelectableText(t.canvas!.location, style: const TextStyle(fontSize: 13))),
              ]),
            ),
          if (t.canvas?.description.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: SingleChildScrollView(child: SelectableText(t.canvas!.description, style: const TextStyle(fontSize: 13.5, height: 1.4))),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Text(
              t.isCanvas
                  ? t.edited
                      ? 'From Canvas (${t.label}), edited by you, so it’s no longer updated from Canvas. '
                          'If Canvas changes it, you’ll get the new version as well.'
                      : 'From Canvas (${t.label}). It updates when your teacher changes it.'
                          '${t.canvas!.updated == null ? '' : ' Last changed ${DateFormat('MMM d, h:mm a').format(t.canvas!.updated!)}.'}'
                  : t.label.isNotEmpty
                      ? 'Your edited copy of a Canvas item (${t.label}).'
                      : 'Your own to-do.',
              style: const TextStyle(color: AppColors.secondaryText, height: 1.35),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Edit'),
            subtitle: t.isCanvas && !t.edited
                ? const Text('Your changes stop it from following Canvas', style: TextStyle(color: AppColors.secondaryText, fontSize: 12))
                : null,
            onTap: () {
              Navigator.pop(ctx);
              showTodoEditor(context, svc, todo: t);
            },
          ),
          ListTile(
            leading: Icon(t.done ? Icons.radio_button_unchecked : Icons.check_circle_outline),
            title: Text(t.done ? 'Mark not done' : 'Mark done'),
            onTap: () {
              Navigator.pop(ctx);
              svc.setTodoDone(t, !t.done);
            },
          ),
          if (t.url != null)
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('Open in Canvas'),
              onTap: () {
                Navigator.pop(ctx);
                launchUrl(Uri.parse(t.url!), mode: LaunchMode.externalApplication);
              },
            ),
          if (t.edited)
            ListTile(
              leading: const Icon(Icons.restore),
              title: const Text('Undo my edit'),
              subtitle: const Text('Back to Canvas’s version, kept up to date again', style: TextStyle(color: AppColors.secondaryText, fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                svc.restoreFromCanvas(t);
              },
            ),
          if (!t.isCanvas)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppColors.danger),
              title: const Text('Delete', style: TextStyle(color: AppColors.danger)),
              onTap: () async {
                Navigator.pop(ctx);
                if (await confirmAction(context, title: 'Delete this to-do?', message: '“${t.title}” will be removed.')) {
                  await svc.deleteTodo(t);
                }
              },
            ),
          const SizedBox(height: 8),
        ]),
      ),
    ),
  );
}

/// The pop-up for adding a to-do, or editing one ([todo]): title, a day,
/// and a time if it has one.
Future<void> showTodoEditor(BuildContext context, CalendarService svc, {Todo? todo}) async {
  final title = TextEditingController(text: todo?.title ?? '');
  DateTime? due = todo?.due;
  var allDay = todo?.allDay ?? true;

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        Future<void> pickDay() async {
          final d = await showDatePicker(context: ctx, initialDate: due ?? DateTime.now(), firstDate: DateTime(2000), lastDate: DateTime(2100));
          if (d == null) return;
          setLocal(() => due = allDay || due == null ? DateTime(d.year, d.month, d.day) : DateTime(d.year, d.month, d.day, due!.hour, due!.minute));
        }

        Future<void> pickTime() async {
          final t = await showTimePicker(
            context: ctx,
            initialTime: due == null || allDay ? const TimeOfDay(hour: 9, minute: 0) : TimeOfDay.fromDateTime(due!),
          );
          if (t == null) return;
          final d = due ?? DateTime.now();
          setLocal(() {
            due = DateTime(d.year, d.month, d.day, t.hour, t.minute);
            allDay = false;
          });
        }

        Future<void> save() async {
          final text = title.text.trim();
          if (text.isEmpty) return;
          if (todo == null) {
            await svc.addTodo(text, due: due, allDay: allDay);
          } else {
            await svc.editTodo(todo, title: text, due: due, allDay: allDay);
          }
          if (ctx.mounted) Navigator.pop(ctx);
        }

        return AlertDialog(
          title: Text(todo == null ? 'New to-do' : 'Edit to-do'),
          content: SizedBox(
            width: 400,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                controller: title,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'To-do'),
                onSubmitted: (_) => save(),
              ),
              const SizedBox(height: 14),
              Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                OutlinedButton.icon(
                  onPressed: pickDay,
                  icon: const Icon(Icons.event_outlined, size: 18),
                  label: Text(due == null ? 'Add a day' : DateFormat('EEE, MMM d').format(due!)),
                ),
                if (due != null)
                  OutlinedButton.icon(
                    onPressed: pickTime,
                    icon: const Icon(Icons.schedule, size: 18),
                    label: Text(allDay ? 'Add a time' : DateFormat.jm().format(due!)),
                  ),
                // An assignment is always due at a time.
                if (due != null && !allDay && todo?.canvas?.assignment != true)
                  TextButton(onPressed: () => setLocal(() => allDay = true), child: const Text('All day')),
                if (due != null && todo?.isCanvas != true) TextButton(onPressed: () => setLocal(() => due = null), child: const Text('No date')),
              ]),
              if (todo?.isCanvas == true && todo?.edited != true) ...[
                const SizedBox(height: 12),
                const Text('Once you change it, Canvas stops updating it. If Canvas changes it later, you’ll get the new version too.',
                    style: TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: save, child: Text(todo == null ? 'Add' : 'Save')),
          ],
        );
      },
    ),
  );
}

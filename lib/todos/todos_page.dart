import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../calendar/calendar_models.dart';
import '../calendar/calendar_service.dart';
import '../calendar/canvas.dart';
import '../calendar/canvas_section.dart';
import '../calendar/month_view.dart';
import '../calendar/todo_view.dart';
import '../calendar/todos.dart';
import '../notifications/notification_service.dart';
import '../theme.dart';
import '../util/fields.dart';
import '../widgets/tiles.dart';

/// The To-dos page, the one page that isn't premium beta. It opens on all
/// your to-dos in one column by when they're due, with a month beside it
/// that shows only to-dos, to check off there too. The View button in the
/// header picks between that, the urgent / important matrix (what's left to
/// do, sorted into four boxes, with the ones not sorted yet in a column beside
/// them to drag in), and your groups side by side as columns (it starts with
/// one, "To-dos"). The + adds to-dos, groups, and Canvas calendars (whose
/// assignments go in a group of their own or one you have, each still tagged
/// with its class). Only Canvas calendars can be synced here; Google Calendar
/// is on the Calendar page.
class TodosPage extends StatefulWidget {
  const TodosPage({super.key, required this.service, this.notifications, this.premium = false});

  final CalendarService service;
  final NotificationService? notifications;

  /// With premium beta the server checks Canvas every minute; without it,
  /// Canvas is checked on opening and with the toolbar's refresh button.
  final bool premium;

  @override
  State<TodosPage> createState() => _TodosPageState();
}

/// The page's views, as the View button lists them. Side by side, [list] is
/// the list and month together; on a phone [month] is a view of its own.
/// The matrix is the list views' place when [CalendarService.todoMatrix] is
/// on, so the choice follows you to other devices (and the calendar's to-do
/// list tags each to-do with its box while it's on).
enum _View { list, month, matrix, groups }

class _TodosPageState extends State<TodosPage> {
  static const _viewKey = 'optimizer.todosView';
  _View _view = _View.list;

  /// The month showing beside the list.
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  /// Groups whose done to-dos are showing.
  final _showDone = <String>{};

  // Checked off just now: they stay where they are, ticked and crossed out,
  // until three seconds after the last tick, then all leave together.
  final _lingering = <String>{};
  bool _leaving = false;
  Timer? _settle;

  CalendarService get svc => widget.service;

  /// Keeps "Updated 3 min ago" current.
  Timer? _tick;

  /// Canvas was checked on opening (without premium beta), once.
  bool _openChecked = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      final v = _View.values.where((v) => v.name == p.getString(_viewKey) && v != _View.matrix).firstOrNull;
      if (v != null && mounted) setState(() => _view = v);
    }, onError: (_) {});
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && svc.canvasFeeds.isNotEmpty) setState(() {});
    });
    svc.addListener(_checkOnOpen);
    _checkOnOpen();
  }

  /// Without premium beta, Canvas is checked when the app opens: as soon as
  /// its calendars are known (unless it was checked in the last few minutes).
  void _checkOnOpen() {
    if (_openChecked || widget.premium || svc.canvasFeeds.isEmpty) return;
    _openChecked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => svc.refreshCanvasIfStale());
  }

  @override
  void dispose() {
    _settle?.cancel();
    _tick?.cancel();
    svc.removeListener(_checkOnOpen);
    super.dispose();
  }

  Future<void> _refresh() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final errors = await svc.refreshCanvas();
      if (errors.isNotEmpty) messenger.showSnackBar(SnackBar(content: Text(errors.join('\n'))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', ''))));
    }
  }

  void _setView(_View v) {
    if (v != _View.groups) {
      final matrix = v == _View.matrix;
      if (svc.todoMatrix != matrix) svc.setTodoMatrix(matrix);
      if (matrix) v = _View.list;
    }
    setState(() => _view = v);
    SharedPreferences.getInstance().then((p) => p.setString(_viewKey, v.name), onError: (_) => false);
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

  bool _open(Todo t) => !t.done || _lingering.contains(t.id);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) {
        // Side by side, the list and month are one view; on a phone, two.
        final split = MediaQuery.sizeOf(context).width >= 900;
        var view = _view;
        if (view != _View.groups && svc.todoMatrix) {
          view = _View.matrix;
        } else if (view == _View.month && split) {
          view = _View.list;
        }
        // The assistant's arrow floats in the top corner: always leave it room
        // here, since this page's buttons run all the way to the right.
        final end = PageEnd.of(context);
        // Every button the page has, together in the middle.
        final narrow = MediaQuery.sizeOf(context).width < 720;
        final toolbar = _Toolbar(children: [
          _ViewButton(selected: view, split: split, onSelected: _setView),
          _AddButton(
            onTodo: () => showTodoEditor(context, svc),
            onGroup: () => _newGroup(context),
            onCanvas: () => showAddCanvasDialog(context, svc, widget.notifications, alerts: widget.premium),
          ),
          if (svc.canvasFeeds.isNotEmpty) _RefreshButton(service: svc, premium: widget.premium, short: narrow, onRefresh: _refresh),
        ]);
        final title = Text('To-dos', maxLines: 1, overflow: TextOverflow.ellipsis, style: pageTitleStyle(context));
        // The title where every page's is, the toolbar in the middle of the
        // whole page (moved over only as far as it must to clear the title),
        // the corner's room for the assistant's arrow last.
        final titleHeight = (TextPainter(
          text: TextSpan(text: 'To-dos', style: pageTitleStyle(context)),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout())
            .height;
        final header = SizedBox(
          height: math.max(titleHeight, _Toolbar.height),
          child: CustomMultiChildLayout(delegate: _HeaderLayout(), children: [
            LayoutId(id: _HeaderPart.start, child: Row(mainAxisSize: MainAxisSize.min, children: [const PageMenuButton(), Flexible(child: title)])),
            LayoutId(id: _HeaderPart.toolbar, child: toolbar),
            LayoutId(id: _HeaderPart.end, child: end ?? const SizedBox.shrink()),
          ]),
        );
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(padding: EdgeInsets.only(top: PageSpace.top(context), bottom: 14), child: header),
          Expanded(
            child: switch (view) {
              _View.groups => _groups(context),
              _View.matrix => _matrix(context),
              _View.list => split ? _overview(context) : _list(),
              _View.month => _monthView(context),
            },
          ),
        ]);
      },
    );
  }

  // ---------------------------------------------------------------- all to-dos

  /// Every to-do by when it's due (the calendar's to-do list), the month beside it.
  Widget _overview(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(width: 420, child: _list()),
        const SizedBox(width: 8),
        Expanded(child: _monthView(context)),
      ]);

  Widget _list() => Padding(padding: const EdgeInsets.only(left: 14), child: TodoView(service: svc));

  /// A month of to-dos only: tick them off on it, tap one for its options,
  /// or a day's space for a new one due then.
  Widget _monthView(BuildContext context) {
    final now = DateTime.now();
    final thisMonth = _month.year == now.year && _month.month == now.month;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Text(DateFormat.yMMMM().format(_month),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          if (!thisMonth) TextButton(onPressed: () => setState(() => _month = DateTime(now.year, now.month)), child: const Text('Today')),
          IconButton(
            tooltip: 'Previous month',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => setState(() => _month = DateTime(_month.year, _month.month - 1)),
          ),
          IconButton(
            tooltip: 'Next month',
            icon: const Icon(Icons.chevron_right),
            onPressed: () => setState(() => _month = DateTime(_month.year, _month.month + 1)),
          ),
        ]),
        const SizedBox(height: 6),
        Expanded(
          child: MonthView(
            month: _month,
            events: [
              for (final t in svc.todos)
                if (todoEvent(t) case final e?) e,
            ],
            onDayTap: (d) => showTodoEditor(context, svc, day: d),
            onEventTap: (e) {
              final t = svc.todos.where((t) => t.id == e.id).firstOrNull;
              if (t != null) showTodoOptions(context, svc, t);
            },
            onTaskTap: (e) => svc.setEventDone(e, !e.done),
          ),
        ),
      ]),
    );
  }

  // ---------------------------------------------------------------- groups

  /// Which group a to-do is in: a Canvas item in its calendar's, yours in
  /// the one you put it in (the main one if that group is gone).
  String _groupOf(Todo t, Set<String> groups) {
    String? id;
    if (t.canvas != null) {
      id = t.canvas!.feed.todoList;
    } else {
      // Your edited copy of a Canvas item stays with Canvas's items.
      id = t.listId ?? (t.fromCanvas != null && svc.canvasFeeds.isNotEmpty ? svc.canvasFeeds.first.todoList : null);
    }
    return id != null && groups.contains(id) ? id : TodoList.mainListId;
  }

  Set<String> get _groupIds => {TodoList.mainListId, for (final l in svc.todoLists) l.id};

  Widget _groups(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    // On a phone a column is nearly the screen, with the next one peeking in.
    final columnWidth = width < 640 ? width - 56 : 320.0;
    final groups = [svc.mainList, ...svc.todoLists];
    final ids = _groupIds;
    final byGroup = {for (final g in groups) g.id: <Todo>[]};
    for (final t in svc.todos) {
      byGroup[_groupOf(t, ids)]!.add(t);
    }
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 0, 4, 16),
      children: [for (final g in groups) _column(context, g, byGroup[g.id]!, columnWidth)],
    );
  }

  Widget _column(BuildContext context, TodoList group, List<Todo> all, double width) {
    final open = all.where(_open).toList()..sort(_byDue);
    final done = all.where((t) => !_open(t)).toList()..sort((a, b) => (b.doneAt ?? DateTime(1970)).compareTo(a.doneAt ?? DateTime(1970)));
    final showDone = _showDone.contains(group.id);
    final feeds = svc.canvasFeedsIn(group.id);
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: SizedBox(
        width: width,
        child: _Panel(
          header: _ColumnHeader(
            icon: feeds.isNotEmpty ? Icons.school_outlined : Icons.checklist,
            title: group.name,
            count: open.where((t) => !t.done).length,
            menu: _groupMenu(context, group, feeds),
          ),
          children: [
            for (final t in open) _row(t),
            if (done.isNotEmpty) ...[
              TextButton.icon(
                onPressed: () => setState(() => showDone ? _showDone.remove(group.id) : _showDone.add(group.id)),
                icon: Icon(showDone ? Icons.expand_less : Icons.expand_more, size: 18),
                label: Text('Done (${done.length})'),
                style: TextButton.styleFrom(alignment: Alignment.centerLeft, foregroundColor: AppColors.secondaryText),
              ),
              if (showDone)
                for (final t in done) _row(t),
            ],
          ],
        ),
      ),
    );
  }

  /// In the matrix ([showGroup]), to-dos from every group are together, and
  /// which box each is in is plain from where it is.
  Widget _row(Todo t, {bool showGroup = false, bool compact = false}) => _TodoRow(
        todo: t,
        svc: svc,
        groupName: showGroup ? _groupName(t) : null,
        showQuadrant: !showGroup,
        compact: compact,
        leaving: _leaving && _lingering.contains(t.id),
        onToggle: () => _toggle(t),
      );

  /// Which group a to-do of yours is in (Canvas items carry their class).
  String? _groupName(Todo t) {
    if (t.isCanvas) return null;
    final id = _groupOf(t, _groupIds);
    for (final (gid, name) in todoListChoices(svc)) {
      if (gid == id) return name;
    }
    return null;
  }

  /// A group's ⋯: rename it, its Canvas calendars' options, delete it.
  Widget _groupMenu(BuildContext context, TodoList g, List<CanvasFeed> feeds) {
    String named(String what, CanvasFeed f) => feeds.length > 1 ? '$what · ${f.name}' : what;
    return PopupMenuButton<(String, CanvasFeed?)>(
      tooltip: 'Group options',
      iconSize: 18,
      icon: const Icon(Icons.more_horiz, color: AppColors.secondaryText),
      onSelected: (v) async {
        final (action, feed) = v;
        final messenger = ScaffoldMessenger.of(context);
        switch (action) {
          case 'rename':
            final name = await _askName(context, title: 'Rename group', initial: g.name);
            if (name != null) await svc.renameTodoList(g, name);
          case 'classes':
            await _classes(context, feed!);
          case 'check':
            try {
              final errors = await svc.refreshCanvas(only: feed);
              messenger.showSnackBar(SnackBar(content: Text(errors.isEmpty ? '${feed!.name} is up to date' : errors.join('\n'))));
            } catch (e) {
              messenger.showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', ''))));
            }
          case 'unlink':
            final a = removeCanvasAction(context, svc, feed!);
            if (await confirmAction(context, title: a.confirm!.$1, message: a.confirm!.$2, action: a.confirm!.$3)) a.onSelected();
          case 'delete':
            final n = svc.manualTodos.where((t) => t.listId == g.id).length;
            if (!context.mounted) return;
            final ok = await confirmAction(
              context,
              title: 'Delete “${g.name}”?',
              message: [
                n == 0 ? 'The group is removed.' : 'The group and its $n ${n == 1 ? 'to-do' : 'to-dos'} are removed.',
                if (feeds.isNotEmpty) 'Its Canvas assignments move to ${svc.mainList.name}.',
              ].join(' '),
            );
            if (ok) await svc.deleteTodoList(g);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: ('rename', null), child: Text('Rename group')),
        for (final f in feeds) ...[
          const PopupMenuDivider(),
          PopupMenuItem(value: ('classes', f), child: Text(named('Classes', f))),
          PopupMenuItem(value: ('check', f), child: Text(named('Check Canvas now', f))),
          PopupMenuItem(value: ('unlink', f), child: Text(named('Remove Canvas calendar', f), style: const TextStyle(color: AppColors.danger))),
        ],
        if (!g.isMain) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(value: ('delete', null), child: Text('Delete group', style: TextStyle(color: AppColors.danger))),
        ],
      ],
    );
  }

  /// A Canvas calendar's classes: each on or off, and its color.
  Future<void> _classes(BuildContext context, CanvasFeed f) => showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(f.name),
          content: SizedBox(
            width: 380,
            child: ListenableBuilder(
              listenable: svc,
              builder: (ctx, _) {
                final classes = svc.canvasCalendars(f);
                if (classes.isEmpty) {
                  return const Text('No classes yet. They show up once Canvas has sent its first items.',
                      style: TextStyle(color: AppColors.secondaryText));
                }
                return Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final c in classes)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: svc.isVisible(c),
                      onChanged: (on) => svc.setVisible(c, on),
                      secondary: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => pickCalendarColor(ctx, svc, c),
                        child: Tooltip(
                          message: 'Change color',
                          child: Container(width: 22, height: 22, decoration: BoxDecoration(color: c.color, shape: BoxShape.circle)),
                        ),
                      ),
                      title: Text(c.name, overflow: TextOverflow.ellipsis),
                    ),
                ]);
              },
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
        ),
      );

  Future<void> _newGroup(BuildContext context) async {
    final name = await _askName(context, title: 'New group', hint: 'e.g. Work, Errands, Home');
    if (name != null) await svc.addTodoList(name);
  }

  // ---------------------------------------------------------------- the matrix

  Widget _matrix(BuildContext context) {
    final open = svc.todos.where(_open).toList()..sort(_byDue);
    final unsorted = [
      for (final t in open)
        if (t.quadrant == null) t
    ];
    Widget box(Quadrant q) => _QuadrantBox(
          quadrant: q,
          todos: [
            for (final t in open)
              if (t.quadrant == q) t
          ],
          svc: svc,
          row: (t) => _draggable(t, _row(t, showGroup: true, compact: true)),
        );
    final grid = Column(children: [
      Expanded(child: Row(children: [Expanded(child: box(Quadrant.doFirst)), const SizedBox(width: 10), Expanded(child: box(Quadrant.schedule))])),
      const SizedBox(height: 10),
      Expanded(child: Row(children: [Expanded(child: box(Quadrant.delegate)), const SizedBox(width: 10), Expanded(child: box(Quadrant.drop))])),
    ]);
    final waiting = DragTarget<Todo>(
      onWillAcceptWithDetails: (d) => d.data.quadrant != null,
      onAcceptWithDetails: (d) => svc.setTodoQuadrant(d.data, null),
      builder: (context, over, _) => _Panel(
        lit: over.isNotEmpty,
        header: _ColumnHeader(icon: Icons.inbox_outlined, title: 'Not sorted', count: unsorted.where((t) => !t.done).length),
        children: [
          if (unsorted.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
              child: Text(_dragHint, style: const TextStyle(color: AppColors.secondaryText, fontSize: 12)),
            ),
          for (final t in unsorted) _draggable(t, _row(t, showGroup: true)),
        ],
      ),
    );
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth >= 760) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(width: 320, child: waiting),
            const SizedBox(width: 12),
            Expanded(child: grid),
          ]),
        );
      }
      // A phone: the boxes on top, so they're in reach while you drag up
      // from the list below.
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Column(children: [
          SizedBox(height: (box.maxHeight * 0.55).clamp(260.0, 520.0), child: grid),
          const SizedBox(height: 10),
          Expanded(child: waiting),
        ]),
      );
    });
  }

  static bool get _touch => defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

  static String get _dragHint => _touch ? 'Press and hold a to-do to drag it into a box.' : 'Drag a to-do into a box.';

  /// [child], draggable into the matrix's boxes: right away with a mouse,
  /// after a press and hold on a touch screen (so the list still scrolls).
  Widget _draggable(Todo t, Widget child) {
    return LayoutBuilder(builder: (context, box) {
      final feedback = Material(
        color: Colors.transparent,
        child: Container(
          width: box.maxWidth,
          decoration: BoxDecoration(
            color: AppColors.surfaceHigh,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
            boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 16, offset: Offset(0, 6))],
          ),
          child: _TodoRow(todo: t, svc: svc, compact: true, onToggle: () {}, menu: false, showQuadrant: false),
        ),
      );
      final dimmed = Opacity(opacity: 0.3, child: child);
      return _touch
          ? LongPressDraggable<Todo>(data: t, feedback: feedback, childWhenDragging: dimmed, child: child)
          : Draggable<Todo>(
              data: t,
              feedback: feedback,
              childWhenDragging: dimmed,
              child: MouseRegion(cursor: SystemMouseCursors.grab, child: child),
            );
    });
  }
}

/// A to-do on the month: a chip on the day it's due, with its circle (and
/// its time, if it has one). Null with no date.
CalendarEvent? todoEvent(Todo t) {
  final due = t.due;
  if (due == null) return null;
  final day = dayStart(due);
  return CalendarEvent(
    id: t.id,
    calendar: t.canvas?.calendar ??
        GoogleCalendar(
            id: 'todos', accountEmail: 'todos', name: t.label.isEmpty ? 'To-dos' : t.label, color: t.color, primary: false, accessRole: 'reader'),
    title: t.allDay ? t.title : '${t.title} · ${DateFormat.jm().format(due)}',
    description: '',
    location: '',
    start: day,
    end: addDays(day, 1),
    allDay: true,
    color: t.color,
    done: t.done,
    due: t.allDay ? null : due,
    task: true,
  );
}

enum _HeaderPart { start, toolbar, end }

/// The header's three parts: the title at the left edge, the corner's room
/// at the right, and the toolbar centered on the whole page, pushed right
/// only as far as it must to clear the title (and no further than the corner).
class _HeaderLayout extends MultiChildLayoutDelegate {
  static const _left = 20.0;
  static const _right = 12.0;
  static const _gap = 12.0;

  @override
  void performLayout(Size size) {
    final end = layoutChild(_HeaderPart.end, BoxConstraints.loose(size));
    final endX = size.width - _right - end.width;
    final to = endX - (end.width > 0 ? 8 : 0);
    // The toolbar first, whole; the title gets what's left (and shortens
    // before a button would be cut off).
    final bar = layoutChild(_HeaderPart.toolbar, BoxConstraints.loose(Size(math.max(0, to - _left), size.height)));
    final start = layoutChild(_HeaderPart.start, BoxConstraints.loose(Size(math.max(0, to - bar.width - _gap - _left), size.height)));
    final from = _left + start.width + _gap;
    final x = (size.width - bar.width) / 2;
    positionChild(_HeaderPart.start, const Offset(_left, 0));
    positionChild(_HeaderPart.toolbar, Offset(x.clamp(from, math.max(from, to - bar.width)), 0));
    positionChild(_HeaderPart.end, Offset(endX, 0));
  }

  @override
  bool shouldRelayout(_HeaderLayout old) => false;
}

/// The page's toolbar: its buttons side by side in a blue-gray pill, the
/// colors of the page's columns, a hairline between buttons.
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.children});

  /// Its buttons' height and its edge.
  static const height = 40.0;

  /// Room either side of a button's icon: a little less on a small phone.
  static double side(BuildContext context) => MediaQuery.sizeOf(context).width < 400 ? 12 : 16;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Material(
        color: AppColors.surfaceHigh,
        shape: const StadiumBorder(side: BorderSide(color: AppColors.border)),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(1),
          child: IntrinsicHeight(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final (i, c) in children.indexed) ...[
                if (i > 0) const VerticalDivider(width: 1, thickness: 1, indent: 9, endIndent: 9, color: AppColors.border),
                Flexible(child: c),
              ],
            ]),
          ),
        ),
      );
}

/// One of the toolbar's buttons: just its icon (its tooltip says what it does).
class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.symmetric(horizontal: _Toolbar.side(context), vertical: 9),
        child: Icon(icon, size: 20),
      );
}

/// The toolbar's refresh: checks Canvas now, and says when it last did
/// ("Updated 3 min ago"; "3m" on a phone). With premium beta Canvas is
/// checked every minute anyway, so it's just the icon. After five refreshes
/// in five minutes it waits, saying until when.
class _RefreshButton extends StatelessWidget {
  const _RefreshButton({required this.service, required this.premium, required this.short, required this.onRefresh});

  final CalendarService service;
  final bool premium;
  final bool short;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final retry = service.canvasRetryAt;
    final waiting = retry != null && retry.isAfter(now);
    final checking = service.canvasChecking;
    final at = service.canvasCheckedAt;
    final label = premium ? null : canvasUpdatedText(at, now, short: short);
    final tip = waiting
        ? 'Refreshed 5 times in 5 minutes. Try again at ${DateFormat.jm().format(retry)}'
        : premium
            ? 'Canvas is checked every minute. Check now'
            : at == null
                ? 'Check Canvas now'
                : 'Canvas updated ${DateFormat(sameDay(at, now) ? 'h:mm a' : 'MMM d, h:mm a').format(at)}. Check now';
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: checking || waiting ? null : onRefresh,
        child: Padding(
          padding: EdgeInsets.fromLTRB(_Toolbar.side(context), 9, label == null ? _Toolbar.side(context) : 18, 9),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            checking
                ? const SizedBox(width: 20, height: 20, child: Padding(padding: EdgeInsets.all(2), child: CircularProgressIndicator(strokeWidth: 2)))
                : Icon(Icons.refresh, size: 20, color: waiting ? AppColors.secondaryText : AppColors.primaryText),
            if (label != null) ...[
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  checking ? (short ? '…' : 'Updating…') : label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

/// "Updated just now", "Updated 3 min ago", "Updated 2 hr ago", "Updated Nov 20";
/// [short]: "now", "3m", "2h", "Nov 20".
String canvasUpdatedText(DateTime? at, DateTime now, {bool short = false}) {
  if (at == null) return short ? 'Never' : 'Not updated yet';
  final d = now.difference(at);
  if (d.inMinutes < 1) return short ? 'now' : 'Updated just now';
  if (d.inHours < 1) return short ? '${d.inMinutes}m' : 'Updated ${d.inMinutes} min ago';
  if (d.inDays < 1) return short ? '${d.inHours}h' : 'Updated ${d.inHours} hr ago';
  final date = DateFormat('MMM d').format(at);
  return short ? date : 'Updated $date';
}

/// The View button: the list and month, the matrix, or the groups. On a
/// phone the list and month are two choices.
class _ViewButton extends StatelessWidget {
  const _ViewButton({required this.selected, required this.split, required this.onSelected});

  final _View selected;
  final bool split;
  final ValueChanged<_View> onSelected;

  IconData icon(_View v) => switch (v) {
        _View.list => split ? Icons.vertical_split_outlined : Icons.view_agenda_outlined,
        _View.month => Icons.calendar_month_outlined,
        _View.matrix => Icons.grid_view,
        _View.groups => Icons.view_column_outlined,
      };

  String label(_View v) => switch (v) {
        _View.list => split ? 'List & calendar' : 'List',
        _View.month => 'Calendar',
        _View.matrix => 'Urgent / important',
        _View.groups => 'Groups',
      };

  @override
  Widget build(BuildContext context) {
    PopupMenuItem<_View> item(_View v, String label, String hint) => PopupMenuItem(
          value: v,
          child: Row(children: [
            Icon(icon(v), size: 19),
            const SizedBox(width: 12),
            Flexible(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(label, overflow: TextOverflow.ellipsis),
                Text(hint, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.secondaryText, fontSize: 12)),
              ]),
            ),
            const SizedBox(width: 12),
            Icon(Icons.check, size: 18, color: v == selected ? null : Colors.transparent),
          ]),
        );
    return PopupMenuButton<_View>(
      tooltip: 'View',
      position: PopupMenuPosition.under,
      onSelected: onSelected,
      itemBuilder: (_) => [
        if (split)
          item(_View.list, label(_View.list), 'Every to-do by due date, with a month')
        else ...[
          item(_View.list, label(_View.list), 'Every to-do by due date'),
          item(_View.month, label(_View.month), 'A month of your to-dos'),
        ],
        item(_View.matrix, label(_View.matrix), 'Sort to-dos into four boxes'),
        item(_View.groups, label(_View.groups), 'Each group in its own column'),
      ],
      child: _ToolbarButton(icon: icon(selected)),
    );
  }
}

/// The page's one +: a to-do, a group, or a Canvas calendar.
class _AddButton extends StatelessWidget {
  const _AddButton({required this.onTodo, required this.onGroup, required this.onCanvas});

  final VoidCallback onTodo;
  final VoidCallback onGroup;
  final VoidCallback onCanvas;

  @override
  Widget build(BuildContext context) {
    PopupMenuItem<VoidCallback> item(VoidCallback value, IconData icon, String label) => PopupMenuItem(
          value: value,
          child: Row(children: [Icon(icon, size: 19), const SizedBox(width: 12), Flexible(child: Text(label, overflow: TextOverflow.ellipsis))]),
        );
    return PopupMenuButton<VoidCallback>(
      tooltip: 'Add',
      position: PopupMenuPosition.under,
      onSelected: (f) => f(),
      child: const _ToolbarButton(icon: Icons.add),
      itemBuilder: (_) => [
        item(onTodo, Icons.add_task, 'New to-do'),
        item(onGroup, Icons.view_column_outlined, 'New group'),
        item(onCanvas, Icons.school_outlined, 'Sync a Canvas calendar'),
      ],
    );
  }
}

/// Soonest first, overdue at the top; no date last. Same time: by class, then A to Z.
int _byDue(Todo a, Todo b) {
  if ((a.due == null) != (b.due == null)) return a.due == null ? 1 : -1;
  final c = a.due == null ? 0 : a.due!.compareTo(b.due!);
  return c != 0 ? c : Todo.byClassThenTitle(a, b);
}

/// "Today · 11:59 PM", "Tomorrow", "Friday", "Dec 3", "Jan 4, 2027".
String todoWhen(Todo t, DateTime now) {
  final due = t.due;
  if (due == null) return '';
  final today = dayStart(now);
  final day = dayStart(due);
  final diff = day.difference(today).inDays;
  final name = switch (diff) {
    0 => 'Today',
    1 => 'Tomorrow',
    -1 => 'Yesterday',
    > 1 && < 7 => DateFormat('EEEE').format(due),
    _ => DateFormat(due.year == now.year ? 'MMM d' : 'MMM d, y').format(due),
  };
  return t.allDay ? name : '$name · ${DateFormat.jm().format(due)}';
}

/// Past its due time (for an all-day one, past its day) and not done.
bool todoLate(Todo t, DateTime now) {
  if (t.done || t.due == null) return false;
  return t.allDay ? dayStart(t.due!).isBefore(dayStart(now)) : t.due!.isBefore(now);
}

/// A column: a rounded panel with its header, and its to-dos scrolling under
/// it. [lit] while a to-do is dragged over it.
class _Panel extends StatelessWidget {
  const _Panel({required this.header, required this.children, this.lit = false, this.empty});

  final Widget header;
  final List<Widget> children;
  final bool lit;

  /// Shown in the middle when there are no [children].
  final String? empty;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        decoration: BoxDecoration(
          color: lit ? AppColors.surfaceHigh : AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: lit ? AppColors.primaryText.withValues(alpha: 0.5) : AppColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          header,
          Expanded(
            child: children.isEmpty && empty != null
                ? Center(child: Text(empty!, style: const TextStyle(color: Color(0x59FFFFFF), fontSize: 12.5)))
                : ListView(padding: const EdgeInsets.only(top: 4, bottom: 10), children: children),
          ),
        ]),
      );
}

class _ColumnHeader extends StatelessWidget {
  const _ColumnHeader({required this.icon, required this.title, required this.count, this.subtitle, this.menu});

  final IconData icon;
  final String title;
  final String? subtitle;
  final int count;
  final Widget? menu;

  @override
  Widget build(BuildContext context) => Container(
        color: AppColors.surfaceHigh,
        constraints: const BoxConstraints(minHeight: 48),
        padding: EdgeInsets.fromLTRB(14, 4, menu == null ? 14 : 4, 4),
        child: Row(children: [
          Icon(icon, size: 17, color: AppColors.secondaryText),
          const SizedBox(width: 8),
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              if (subtitle != null)
                Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.secondaryText, fontSize: 11.5)),
            ]),
          ),
          if (count > 0) ...[
            const SizedBox(width: 6),
            Text('$count', style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5, fontWeight: FontWeight.w600)),
          ],
          if (menu != null) menu!,
        ]),
      );
}

/// One to-do: tick it off by tapping; ⋯ for what else you can do.
class _TodoRow extends StatelessWidget {
  const _TodoRow({
    required this.todo,
    required this.svc,
    required this.onToggle,
    this.groupName,
    this.compact = false,
    this.leaving = false,
    this.menu = true,
    this.showQuadrant = true,
  });

  final Todo todo;
  final CalendarService svc;
  final VoidCallback onToggle;

  /// Which of your groups it's in, where to-dos from several are together.
  final String? groupName;
  final bool compact;
  final bool leaving;
  final bool menu;
  final bool showQuadrant;

  @override
  Widget build(BuildContext context) {
    final t = todo;
    final color = t.color;
    final now = DateTime.now();
    final when = todoWhen(t, now);
    final late = todoLate(t, now);
    final quadrant = svc.todoMatrix && showQuadrant ? t.quadrant : null;
    final hasMeta = t.label.isNotEmpty || groupName != null || when.isNotEmpty || quadrant != null || t.edited;
    return AnimatedOpacity(
      opacity: leaving ? 0 : 1,
      duration: const Duration(milliseconds: 260),
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, compact ? 6 : 8, 2, compact ? 6 : 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: t.done ? color : Colors.transparent,
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 2),
                ),
                child: t.done ? Icon(Icons.check, size: 13, color: onColor(color)) : null,
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  t.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: compact ? 13.5 : 14,
                    color: t.done ? AppColors.secondaryText : AppColors.primaryText,
                    decoration: t.done ? TextDecoration.lineThrough : TextDecoration.none,
                    decorationColor: AppColors.secondaryText,
                  ),
                ),
                if (hasMeta) ...[
                  const SizedBox(height: 4),
                  Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    if (t.label.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(color: color.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(100)),
                        child: Text(t.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Color.lerp(color, Colors.white, 0.35), fontSize: 11, fontWeight: FontWeight.w600)),
                      ),
                    if (groupName != null)
                      Text(groupName!, style: const TextStyle(color: AppColors.secondaryText, fontSize: 11.5, fontWeight: FontWeight.w600)),
                    if (when.isNotEmpty) Text(when, style: TextStyle(color: late ? AppColors.danger : AppColors.secondaryText, fontSize: 12)),
                    if (quadrant != null) QuadrantTag(quadrant),
                    if (t.edited)
                      const Tooltip(
                        message: 'Edited by you; no longer updated from Canvas',
                        child: Icon(Icons.edit_outlined, size: 13, color: AppColors.secondaryText),
                      ),
                  ]),
                ],
              ]),
            ),
            if (menu) TodoMenuButton(service: svc, todo: t) else const SizedBox(width: 12),
          ]),
        ),
      ),
    );
  }
}

/// One box of the matrix, in the same style as every other column: a drop
/// target for to-dos.
class _QuadrantBox extends StatelessWidget {
  const _QuadrantBox({required this.quadrant, required this.todos, required this.svc, required this.row});

  final Quadrant quadrant;
  final List<Todo> todos;
  final CalendarService svc;
  final Widget Function(Todo) row;

  @override
  Widget build(BuildContext context) {
    final q = quadrant;
    return DragTarget<Todo>(
      onWillAcceptWithDetails: (d) => d.data.quadrant != q,
      onAcceptWithDetails: (d) => svc.setTodoQuadrant(d.data, q),
      builder: (context, over, _) => LayoutBuilder(
        // A phone's boxes are narrow: "Important" rather than "Important, not urgent".
        builder: (context, box) => _Panel(
          lit: over.isNotEmpty,
          empty: 'Drag to-dos here',
          header: _ColumnHeader(
            icon: Icons.grid_view,
            title: box.maxWidth < 190 ? q.tag : q.title,
            subtitle: q.hint,
            count: todos.where((t) => !t.done).length,
          ),
          children: [for (final t in todos) row(t)],
        ),
      ),
    );
  }
}

/// Asks for a group's name.
Future<String?> _askName(BuildContext context, {required String title, String initial = '', String? hint}) async {
  final field = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 380,
        child: TextField(
          controller: field,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: 'Name', hintText: hint),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, field.text), child: Text(initial.isEmpty ? 'Add' : 'Save')),
      ],
    ),
  );
  final t = name?.trim() ?? '';
  return t.isEmpty || t == initial ? null : t;
}

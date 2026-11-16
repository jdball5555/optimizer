import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';
import '../util/fields.dart';
import '../notifications/notification_service.dart';
import '../widgets/tiles.dart';
import 'calendar_models.dart';
import 'calendar_service.dart';
import 'canvas_section.dart';
import 'event_editor.dart';
import 'history_page.dart';
import 'flipped_timeline.dart';
import 'month_agenda.dart';
import 'month_view.dart';
import 'own_calendars.dart';
import 'todo_view.dart';
import 'vertical_week.dart';

enum CalView { week, month, todo }

/// How the calendar is laid out on this device: by screen width, or always
/// the phone layout, or always the desktop one (a tablet or a big phone can
/// have the week with hours across). Chosen in Settings; kept on the device.
enum CalendarLayout { auto, phone, desktop }

final calendarLayout = ValueNotifier(CalendarLayout.auto);
const _calendarLayoutKey = 'optimizer.calendar.layoutMode';

Future<void> loadCalendarLayout() async {
  try {
    final v = (await SharedPreferences.getInstance()).getString(_calendarLayoutKey);
    calendarLayout.value = CalendarLayout.values.where((l) => l.name == v).firstOrNull ?? CalendarLayout.auto;
  } catch (_) {}
}

Future<void> setCalendarLayout(CalendarLayout l) async {
  calendarLayout.value = l;
  try {
    await (await SharedPreferences.getInstance()).setString(_calendarLayoutKey, l.name);
  } catch (_) {}
}

/// Why linking a Google account failed, long enough to read (and copy).
void showConnectError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: SelectableText('$e'.replaceFirst('Exception: ', '')),
    duration: const Duration(seconds: 12),
    showCloseIcon: true,
  ));
}

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key, required this.service, this.notifications, this.onOpenTrips});

  final CalendarService service;
  final NotificationService? notifications;

  /// Opens the Trips page, for where the app's own bar has no room for it.
  final VoidCallback? onOpenTrips;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  CalView _view = CalView.week;
  DateTime _anchor = dayStart(DateTime.now());
  double _hourWidth = 96;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  CalendarService get svc => widget.service;

  // On a wide screen the calendars and the to-do list are columns beside
  // the calendar, each shown or hidden from the toolbar (both at once is
  // fine). Narrower, they share the drawer as tabs. Also where all-day events
  // go in the week. All remembered on this device.
  bool _showCalendars = true;
  bool _showTodos = false;
  SidePanel _drawerPanel = SidePanel.calendars;
  bool _allDayColumn = false;
  static const _layoutKey = 'optimizer.calendar.panels';

  Future<void> _loadLayout() async {
    try {
      final v = (await SharedPreferences.getInstance()).getStringList(_layoutKey);
      if (v == null || !mounted) return;
      setState(() {
        _showCalendars = v.contains('calendars');
        _showTodos = v.contains('todos');
        _drawerPanel = v.contains('drawer:todo') ? SidePanel.todo : SidePanel.calendars;
        _allDayColumn = v.contains('allDayColumn');
      });
    } catch (_) {}
  }

  void _setLayout(VoidCallback change) {
    setState(change);
    SharedPreferences.getInstance().then(
        (p) => p.setStringList(_layoutKey, [
              if (_showCalendars) 'calendars',
              if (_showTodos) 'todos',
              if (_drawerPanel == SidePanel.todo) 'drawer:todo',
              if (_allDayColumn) 'allDayColumn',
            ]),
        onError: (_) => false);
  }

  double get _width => MediaQuery.sizeOf(context).width;
  CalendarLayout get _mode => calendarLayout.value;

  /// The phone's one-row toolbar (and its floating undo).
  bool get _phoneBar => _mode == CalendarLayout.phone || (_mode == CalendarLayout.auto && _width < 640);

  /// The phone's week (days across, hours down) and month (dots, then the day's list).
  bool get _phoneViews => _mode == CalendarLayout.phone || (_mode == CalendarLayout.auto && _width < 700);

  /// Room for the calendars and to-do columns beside the calendar.
  bool get _columns => switch (_mode) {
        CalendarLayout.phone => false,
        CalendarLayout.desktop => _width >= 800,
        CalendarLayout.auto => _width >= 1000,
      };

  /// The desktop week, which leaves room for its own scrollbars.
  bool get _weekRows => _view == CalView.week && !_phoneViews;

  void _layoutChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    svc.addListener(_onServiceChange);
    calendarLayout.addListener(_layoutChanged);
    _loadLayout();
    // Defer: loadRange notifies listeners synchronously, which can't happen mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _syncNow() async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await svc.syncNow();
    messenger.showSnackBar(SnackBar(content: Text(result)));
  }

  @override
  void dispose() {
    svc.removeListener(_onServiceChange);
    calendarLayout.removeListener(_layoutChanged);
    super.dispose();
  }

  int _calendarCount = 0;
  void _onServiceChange() {
    // When calendars first arrive (or an account is added), fetch events.
    if (svc.calendars.length != _calendarCount) {
      _calendarCount = svc.calendars.length;
      _load(force: true);
    }
    if (mounted) setState(() {});
  }

  ({DateTime from, DateTime to}) get _range {
    switch (_view) {
      case CalView.week:
      case CalView.todo:
        final start = addDays(_anchor, -(_anchor.weekday % 7)); // Sunday first
        return (from: start, to: addDays(start, 7));
      case CalView.month:
        final start = monthGridStart(_anchor);
        return (from: start, to: addDays(start, 42));
    }
  }

  void _load({bool force = false}) {
    final r = _range;
    svc.loadRange(r.from, r.to, force: force);
  }

  void _go(int dir) {
    setState(() {
      switch (_view) {
        case CalView.week:
        case CalView.todo:
          _anchor = addDays(_anchor, 7 * dir);
        case CalView.month:
          _anchor = DateTime(_anchor.year, _anchor.month + dir, 1);
      }
    });
    _load();
  }

  void _today() {
    setState(() => _anchor = dayStart(DateTime.now()));
    _load();
  }

  void _setView(CalView v) {
    setState(() => _view = v);
    _load();
  }

  void _jumpTo(DateTime d, {CalView? view}) {
    setState(() {
      _anchor = dayStart(d);
      if (view != null) _view = view;
    });
    _load();
  }

  /// Big title, then the smaller line under it.
  (String, String) get _title {
    final r = _range;
    switch (_view) {
      case CalView.month:
        return (DateFormat.MMMM().format(_anchor), '${_anchor.year}');
      case CalView.todo:
        final left = svc.todos.where((t) => !t.done).length;
        return ('To-do', left == 1 ? '1 to do' : '$left to do');
      case CalView.week:
        final last = addDays(r.to, -1);
        final title = r.from.month == last.month ? DateFormat.MMMM().format(r.from) : _monthSpan(r.from, last);
        // In UTC, where every day is 24 hours, so a clock change can't shift it.
        final weekNo = ((DateTime.utc(r.from.year, r.from.month, r.from.day).difference(DateTime.utc(r.from.year)).inDays) / 7).floor() + 1;
        return (title, _weekLine(r.from, last, weekNo));
    }
  }

  String _monthSpan(DateTime from, DateTime last) => '${DateFormat.MMM().format(from)} – ${DateFormat.MMM().format(last)}';

  String _weekLine(DateTime from, DateTime last, int weekNo) =>
      '${DateFormat.MMMd().format(from)} – ${DateFormat.MMMd().format(last)}, ${last.year} · Week $weekNo';

  /// Room for the longest title any month or week can have, so the buttons
  /// after it stay in one place.
  double _headingWidth(BuildContext context, TextStyle title, TextStyle subtitle) {
    final base = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    double width(String text, TextStyle style) {
      final p =
          TextPainter(text: TextSpan(text: text, style: base.merge(style)), textDirection: ui.TextDirection.ltr, textScaler: scaler, maxLines: 1)
            ..layout();
      final w = p.width;
      p.dispose();
      return w;
    }

    var most = 0.0;
    for (var m = 1; m <= 12; m++) {
      final from = DateTime(2000, m, 28), last = DateTime(2000, m + 1, 28);
      most = [most, width(DateFormat.MMMM().format(from), title), width(_monthSpan(from, last), title), width(_weekLine(from, last, 52), subtitle)]
          .reduce(math.max);
    }
    return most.ceilToDouble();
  }

  void _create({DateTime? start, bool allDay = false}) {
    // In the to-do list, + adds a to-do.
    if (_view == CalView.todo && start == null) {
      showTodoEditor(context, svc);
      return;
    }
    var s = start;
    if (s == null) {
      final now = DateTime.now();
      s = DateTime(now.year, now.month, now.day, now.hour + 1);
    }
    showEventEditor(context, svc, start: s, allDay: allDay);
  }

  void _zoom(double factor) => setState(() => _hourWidth = (_hourWidth * factor).clamp(48.0, 320.0));

  @override
  Widget build(BuildContext context) {
    final columns = _columns;
    _Sidebar panel(SidePanel p, {bool tabs = false}) => _Sidebar(
          service: svc,
          notifications: widget.notifications,
          anchor: _anchor,
          // The toolbar has its own sync button except on a phone.
          showSync: _phoneBar,
          onPickDate: (d) => _jumpTo(d),
          panel: p,
          onPanel: tabs ? (p) => _setLayout(() => _drawerPanel = p) : null,
        );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyT): _today,
        const SingleActivator(LogicalKeyboardKey.keyJ): () => _go(1),
        const SingleActivator(LogicalKeyboardKey.keyN): () => _go(1),
        const SingleActivator(LogicalKeyboardKey.keyK): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.keyP): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.keyW): () => _setView(CalView.week),
        const SingleActivator(LogicalKeyboardKey.keyM): () => _setView(CalView.month),
        const SingleActivator(LogicalKeyboardKey.keyC): () => _create(),
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _undo,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undo,
        const SingleActivator(LogicalKeyboardKey.equal): () => _zoom(1.25),
        const SingleActivator(LogicalKeyboardKey.minus): () => _zoom(0.8),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: _scaffoldKey,
          drawer: columns ? null : Drawer(child: SafeArea(child: panel(_drawerPanel, tabs: true))),
          body: Row(
            children: [
              if (columns && _showCalendars) SizedBox(width: 284, child: panel(SidePanel.calendars)),
              if (columns && _showTodos) SizedBox(width: 300, child: panel(SidePanel.todo)),
              Expanded(
                child: Column(
                  children: [
                    _toolbar(context, columns),
                    if (CalendarService.canLinkGoogle && svc.accounts.any((a) => a.isExpired)) _reconnectBanner(context),
                    Expanded(
                      child: Stack(children: [
                        Positioned.fill(
                          child: Padding(
                            // A panel on the left already leaves a gap (its scrollbar's room);
                            // the week's scrollbar has room inside it on the right.
                            padding: _phoneBar
                                ? const EdgeInsets.fromLTRB(4, 0, 6, 4)
                                : EdgeInsets.fromLTRB(columns && (_showCalendars || _showTodos) ? 0 : 12, 0, _weekRows ? 0 : 12, _weekRows ? 0 : 12),
                            child: _body(),
                          ),
                        ),
                        if (_phoneBar && svc.lastChange != null) Positioned(left: 12, bottom: 12, child: _floatingUndo()),
                      ]),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The desktop toolbar: the month (or week) and, beside it, which panels
  /// show; then ‹ Today ›; then Week · Month; then every other button together.
  Widget _toolbar(BuildContext context, bool columns) {
    final (title, subtitle) = _title;
    if (_phoneBar) return _phoneToolbar(title, subtitle);
    return LayoutBuilder(builder: (context, c) {
      final roomy = c.maxWidth >= 1000;
      final titleStyle = pageTitleStyle(context);
      const subtitleStyle = TextStyle(color: AppColors.secondaryText, fontSize: 13);
      final heading = Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!columns)
          IconButton(
            tooltip: 'Calendars and to-do',
            icon: const Icon(Icons.menu),
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          ),
        // The same width whatever it says, up to a third of the bar.
        SizedBox(
          width: math.min(_headingWidth(context, titleStyle, subtitleStyle), math.max(160, c.maxWidth * 0.32)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle),
            const SizedBox(height: 2),
            Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: subtitleStyle),
          ]),
        ),
        if (columns) ...[
          const SizedBox(width: 18),
          _PanelToggles(
            labels: roomy,
            calendars: _showCalendars,
            todos: _showTodos,
            onCalendars: () => _setLayout(() => _showCalendars = !_showCalendars),
            onTodos: () => _setLayout(() => _showTodos = !_showTodos),
          ),
        ],
      ]);
      final pager = Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(100),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(tooltip: 'Previous (K)', icon: const Icon(Icons.chevron_left), onPressed: () => _go(-1)),
          TextButton(onPressed: _today, child: const Text('Today', style: TextStyle(fontWeight: FontWeight.w600))),
          IconButton(tooltip: 'Next (J)', icon: const Icon(Icons.chevron_right), onPressed: () => _go(1)),
        ]),
      );
      final controls = Row(mainAxisSize: MainAxisSize.min, children: [
        pager,
        const SizedBox(width: 10),
        PillTabs<CalView>(
          dense: !roomy,
          items: [
            (CalView.week, 'Week'),
            (CalView.month, 'Month'),
            // On the website the to-do list is a column of its own.
            if (!kIsWeb || _view == CalView.todo) (CalView.todo, 'To-do'),
          ],
          selected: _view,
          onSelected: _setView,
        ),
        const SizedBox(width: 10),
        // Every other button, together.
        if (widget.onOpenTrips != null && _width < 720)
          IconButton(tooltip: 'Trips', icon: const Icon(Icons.flight_takeoff), onPressed: widget.onOpenTrips),
        IconButton(tooltip: 'New event (C)', icon: const Icon(Icons.add), onPressed: () => _create()),
        if (_view == CalView.todo) IconButton(tooltip: 'New to-do', icon: const Icon(Icons.add_task), onPressed: () => showTodoEditor(context, svc)),
        _undoButton(),
        IconButton(tooltip: 'History', icon: const Icon(Icons.history), onPressed: () => showCalendarHistory(context, svc)),
        if (_view == CalView.week)
          IconButton(
            tooltip: _allDayColumn ? 'All-day events under the date' : 'All-day events beside the date',
            isSelected: _allDayColumn,
            icon: const Icon(Icons.view_column_outlined, size: 20),
            selectedIcon: const Icon(Icons.view_column, size: 20),
            onPressed: () => _setLayout(() => _allDayColumn = !_allDayColumn),
          ),
        if (_view == CalView.week && c.maxWidth > 1150) ...[
          IconButton(tooltip: 'Fewer hours (−)', icon: const Icon(Icons.zoom_out, size: 20), onPressed: () => _zoom(0.8)),
          IconButton(tooltip: 'More detail (=)', icon: const Icon(Icons.zoom_in, size: 20), onPressed: () => _zoom(1.25)),
        ],
        IconButton(
          tooltip: 'Sync with Google now',
          icon: svc.syncing
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.sync, size: 20),
          onPressed: svc.syncing ? null : _syncNow,
        ),
      ]);
      // Short of room the buttons shrink a little rather than spill over;
      // narrow, they move to a second row.
      final after = Align(alignment: Alignment.centerLeft, child: FittedBox(fit: BoxFit.scaleDown, child: controls));
      final end = PageEnd.of(context);
      return Padding(
        padding: EdgeInsets.fromLTRB(16, PageSpace.top(context), 16, PageSpace.gap(context) - 10),
        child: c.maxWidth < 760
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: Align(alignment: Alignment.centerLeft, child: FittedBox(fit: BoxFit.scaleDown, child: heading))),
                  if (end != null) end,
                ]),
                const SizedBox(height: 8),
                after,
              ])
            : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                heading,
                const SizedBox(width: 18),
                Expanded(child: after),
                if (end != null) end,
              ]),
      );
    });
  }

  /// One slim row for a phone: the menu, ‹ title ›, Today, the view, +.
  Widget _phoneToolbar(String title, String subtitle) {
    const names = {CalView.week: 'Week', CalView.month: 'Month', CalView.todo: 'To-do'};
    final dated = _view != CalView.todo;
    final end = PageEnd.of(context);
    // No room for it all beside the arrow on a narrow phone: Today goes in the menu.
    final todayInMenu = dated && end != null && _width < 440;
    // A small phone's buttons sit closer, to leave the month's name whole.
    final tight = _width < 400;
    final padding = tight ? EdgeInsets.zero : null;
    final constraints = tight ? const BoxConstraints(minWidth: 34, minHeight: 40) : null;
    final style = tight ? const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap) : null;
    // No room for the year and week number here.
    final r = _range;
    final shortLine = _view == CalView.week ? '${DateFormat.MMMd().format(r.from)} – ${DateFormat.MMMd().format(addDays(r.to, -1))}' : subtitle;
    return Padding(
      padding: EdgeInsets.fromLTRB(2, PageSpace.top(context), 6, 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IconButton(
          tooltip: 'Calendars',
          visualDensity: VisualDensity.compact,
          padding: padding,
          constraints: constraints,
          style: style,
          icon: const Icon(Icons.menu),
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        if (dated) IconButton(visualDensity: VisualDensity.compact, padding: padding, constraints: constraints, style: style, icon: const Icon(Icons.chevron_left), onPressed: () => _go(-1)),
        Expanded(
          // A long month on a small phone gets a little smaller rather than cut off.
          child: Column(crossAxisAlignment: dated ? CrossAxisAlignment.center : CrossAxisAlignment.start, children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(title, maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 19, height: 1.15)),
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(shortLine, maxLines: 1, style: const TextStyle(color: AppColors.secondaryText, fontSize: 11.5)),
            ),
          ]),
        ),
        if (dated) IconButton(visualDensity: VisualDensity.compact, padding: padding, constraints: constraints, style: style, icon: const Icon(Icons.chevron_right), onPressed: () => _go(1)),
        if (dated && !todayInMenu)
          TextButton(
            style: TextButton.styleFrom(minimumSize: Size.zero, padding: const EdgeInsets.symmetric(horizontal: 10)),
            onPressed: _today,
            child: const Text('Today', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        PopupMenuButton<Object>(
          tooltip: 'View',
          initialValue: _view,
          onSelected: (v) => v is CalView
              ? _setView(v)
              : v == 'today'
                  ? _today()
                  : widget.onOpenTrips?.call(),
          itemBuilder: (_) => [
            if (todayInMenu) const PopupMenuItem<Object>(value: 'today', child: Text('Today')),
            for (final v in CalView.values) PopupMenuItem<Object>(value: v, child: Text(names[v]!)),
            if (widget.onOpenTrips != null) const PopupMenuItem<Object>(value: 'trips', child: Text('Trips')),
          ],
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(100),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(names[_view]!, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const Icon(Icons.arrow_drop_down, size: 20),
            ]),
          ),
        ),
        IconButton(
          tooltip: _view == CalView.todo ? 'New to-do' : 'New event',
          visualDensity: VisualDensity.compact,
          padding: padding,
          constraints: constraints,
          style: style,
          icon: const Icon(Icons.add),
          onPressed: () => _create(),
        ),
        if (end != null) end,
      ]),
    );
  }

  Widget _undoButton() {
    final step = svc.lastChange;
    return IconButton(
      tooltip: step == null ? 'Nothing to undo' : 'Undo: ${step.label}',
      icon: const Icon(Icons.undo),
      onPressed: step == null ? null : _undo,
    );
  }

  /// On a phone, where the top row is full: a small Undo button floating at
  /// the bottom left, there only while there's something to undo.
  Widget _floatingUndo() {
    final step = svc.lastChange!;
    return Tooltip(
      message: 'Undo: ${step.label}',
      child: Material(
        color: AppColors.surfaceHigh,
        shape: const StadiumBorder(side: BorderSide(color: Color(0x33FFFFFF))),
        elevation: 6,
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: _undo,
          child: const Padding(
            padding: EdgeInsets.fromLTRB(12, 9, 16, 9),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.undo, size: 18),
              SizedBox(width: 6),
              Text('Undo', style: TextStyle(fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      ),
    );
  }

  /// Reverses your latest change, after asking.
  Future<void> _undo() async {
    final step = svc.lastChange;
    if (step == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Undo this change?'),
        content: Text(step.label, style: const TextStyle(color: AppColors.secondaryText)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Undo')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final done = await svc.undoLast();
      if (done != null) messenger.showSnackBar(SnackBar(content: Text('Undone: $done')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn’t undo: ${'$e'.replaceFirst('Exception: ', '')}')));
    }
  }

  Widget _reconnectBanner(BuildContext context) {
    final expired = svc.accounts.where((a) => a.isExpired).toList();
    return MaterialBanner(
      content: Text(expired.length == 1
          ? 'Connect ${expired.first.email} once more so it stays in sync on all your devices.'
          : 'Connect ${expired.length} accounts once more so they stay in sync on all your devices.'),
      leading: const Icon(Icons.sync_problem),
      actions: [
        for (final a in expired)
          TextButton(
            onPressed: () => _connect(reconnect: a),
            child: Text(expired.length == 1 ? 'Reconnect' : 'Reconnect ${a.email}'),
          ),
      ],
    );
  }

  Future<void> _connect({GoogleAccount? reconnect}) async {
    try {
      await svc.connectAccount(reconnect: reconnect);
    } catch (e) {
      if (mounted) showConnectError(context, e);
    }
  }

  Widget _body() {
    final r = _range;
    final events = svc.eventsBetween(r.from, r.to);

    if (_view == CalView.todo) {
      return TodoView(service: svc, onAddCanvas: () => showAddCanvasDialog(context, svc, widget.notifications));
    }

    if (svc.accounts.isEmpty && svc.canvasFeeds.isEmpty && svc.ownCalendars.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.event_available_outlined, size: 48),
            const SizedBox(height: 12),
            Text(
                CalendarService.canLinkGoogle
                    ? 'Make a calendar of your own, or link a Google account or a Canvas calendar to see them here.'
                    : 'Make a calendar of your own, or add a Canvas calendar here. To add Google Calendar, link it once in Optimizer on the web; from then on it shows up here and stays in sync.',
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center, children: [
              OutlinedButton.icon(
                onPressed: () => showOwnCalendarEditor(context, svc),
                icon: const Icon(Icons.add),
                label: const Text('New calendar'),
              ),
              if (CalendarService.canLinkGoogle)
                FilledButton.icon(
                  onPressed: () => _connect(),
                  icon: const Icon(Icons.add_link),
                  label: const Text('Connect Google Calendar'),
                ),
              OutlinedButton.icon(
                onPressed: () => showAddCanvasDialog(context, svc, widget.notifications),
                icon: const Icon(Icons.school_outlined),
                label: const Text('Add a Canvas calendar link'),
              ),
            ]),
          ],
        ),
      );
    }

    switch (_view) {
      case CalView.month:
        // Too narrow for titles in a grid: dots per day, the chosen day listed below.
        if (_phoneViews) {
          return MonthAgenda(
            month: _anchor,
            events: events,
            onEventTap: (e) => showEventDetails(context, svc, e),
            onTaskTap: (e) => svc.setEventDone(e, !e.done),
            onNewEvent: (d) => _create(start: d, allDay: true),
          );
        }
        return MonthView(
          month: _anchor,
          events: events,
          // A day's empty space: a new all-day event on it.
          onDayTap: (d) => _create(start: d, allDay: true),
          onEventTap: (e) => showEventDetails(context, svc, e),
          onTaskTap: (e) => svc.setEventDone(e, !e.done),
        );
      case CalView.week:
      case CalView.todo: // handled above
        final days = [
          for (var d = r.from; d.isBefore(r.to); d = addDays(d, 1)) d,
        ];
        // Too narrow for hours across (a phone): days across, hours down.
        if (_phoneViews) {
          return VerticalWeek(
            days: days,
            events: events,
            onEventTap: (e) => showEventDetails(context, svc, e),
            onSlotTap: (start, {bool allDay = false}) => _create(start: start, allDay: allDay),
          );
        }
        return FlippedTimeline(
          days: days,
          events: events,
          hourWidth: _hourWidth,
          allDayColumn: _allDayColumn,
          onEventTap: (e) => showEventDetails(context, svc, e),
          onSlotTap: (start, {bool allDay = false}) => _create(start: start, allDay: allDay),
        );
    }
  }
}

/// What the side panel shows.
enum SidePanel { calendars, todo }

/// A side panel: your calendars (with the month to jump around in), or your
/// to-do list. In the drawer, tabs switch between them.
class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.service,
    required this.notifications,
    required this.anchor,
    required this.showSync,
    required this.onPickDate,
    required this.panel,
    this.onPanel,
  });

  final SidePanel panel;

  /// Switches between the two with tabs at the top; null for no tabs (a
  /// column of its own on a wide screen).
  final ValueChanged<SidePanel>? onPanel;

  final CalendarService service;
  final NotificationService? notifications;
  final DateTime anchor;

  /// The small sync line at the bottom, where the toolbar has no sync button.
  final bool showSync;
  final void Function(DateTime) onPickDate;

  Future<void> _connect(BuildContext context, {GoogleAccount? reconnect}) async {
    try {
      await service.connectAccount(reconnect: reconnect);
    } catch (e) {
      if (context.mounted) showConnectError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final onPanel = this.onPanel;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (onPanel == null)
        // Level with the page's title, less the list's own padding.
        SizedBox(height: PageSpace.top(context) - 8)
      else
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 2),
          child: Row(children: [
            // Scrolls sideways rather than squeezing a tab's name, if it's ever that narrow.
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (final (p, label) in const [(SidePanel.calendars, 'Calendars'), (SidePanel.todo, 'To-do')])
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => onPanel(p),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                        child: Text(label,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: panel == p ? AppColors.primaryText : AppColors.secondaryText,
                            )),
                      ),
                    ),
                ]),
              ),
            ),
          ]),
        ),
      Expanded(child: panel == SidePanel.todo ? _todos(context) : _calendars(context)),
    ]);
  }

  Widget _todos(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 6, 11, 4),
          child: OutlinedButton.icon(
            onPressed: () => showTodoEditor(context, service),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New to-do'),
          ),
        ),
        Expanded(child: TodoView(service: service, onAddCanvas: () => showAddCanvasDialog(context, service, notifications))),
      ]);

  Widget _calendars(BuildContext context) {
    final synced = service.lastSynced;
    final storeError = service.store.error;
    return ListView(
      // Room on the right for the scrollbar, in the gap beside the tiles.
      padding: const EdgeInsets.fromLTRB(16, 8, 11, 16),
      children: [
        _MiniMonth(selected: anchor, onPick: onPickDate),
        const SizedBox(height: 18),
        OwnCalendarsSection(
          service: service,
          toggle: (c, more) => _CalendarToggle(service: service, calendar: c, dimmed: false, more: more),
        ),
        const SizedBox(height: 10),
        for (final a in service.accounts) ...[
          Tile(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(
                children: [
                  Expanded(
                    child: Text(a.email,
                        style: const TextStyle(color: AppColors.secondaryText, fontSize: 12, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (a.isExpired && CalendarService.canLinkGoogle)
                    TextButton(onPressed: () => _connect(context, reconnect: a), child: const Text('Reconnect')),
                  PopupMenuButton<String>(
                    tooltip: 'Account options',
                    iconSize: 18,
                    icon: const Icon(Icons.more_horiz, color: AppColors.secondaryText),
                    onSelected: (v) async {
                      if (v != 'remove') return;
                      final ok = await confirmAction(context,
                          title: 'Remove ${a.email}?', message: 'Its calendars stop showing here. Nothing is deleted in Google.', action: 'Remove');
                      if (!ok) return;
                      try {
                        await service.removeAccount(a);
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', ''))));
                        }
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'remove', child: Text('Remove account')),
                    ],
                  ),
                ],
              ),
              if (a.isExpired || a.error != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 4),
                  child: Text(
                    a.isExpired ? (a.error ?? (CalendarService.canLinkGoogle ? 'Not linked yet' : 'Not linked yet: link it on the web')) : a.error!,
                    style: TextStyle(color: a.isExpired ? AppColors.secondaryText : AppColors.danger, fontSize: 11.5, height: 1.35),
                  ),
                ),
              for (final c in service.calendarsFor(a.email))
                _CalendarToggle(
                  service: service,
                  calendar: c,
                  dimmed: a.isExpired,
                  more: [
                    MenuAction(label: 'Change color', icon: Icons.palette_outlined, onSelected: () => pickCalendarColor(context, service, c)),
                  ],
                ),
            ]),
          ),
          const SizedBox(height: 10),
        ],
        if (service.hiddenEventCount > 0) ...[
          Tile(
            padding: const EdgeInsets.fromLTRB(4, 2, 12, 2),
            child: Row(children: [
              Checkbox(value: service.showHiddenEvents, onChanged: (v) => service.setShowHiddenEvents(v ?? false)),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => service.setShowHiddenEvents(!service.showHiddenEvents),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text('Show hidden events (${service.hiddenEventCount})', style: const TextStyle(fontSize: 13.5)),
                  ),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 10),
        ],
        CanvasSection(
          service: service,
          notifications: notifications,
          toggle: (c, more) => _CalendarToggle(service: service, calendar: c, dimmed: false, more: more),
        ),
        OutlinedButton.icon(
          onPressed: () => showCalendarHistory(context, service),
          icon: const Icon(Icons.history, size: 18),
          label: const Text('Calendar history'),
        ),
        const SizedBox(height: 10),
        if (CalendarService.canLinkGoogle) ...[
          OutlinedButton.icon(
            onPressed: () => _connect(context),
            icon: const Icon(Icons.add_link, size: 18),
            label: Text(service.accounts.isEmpty ? 'Connect Google Calendar' : 'Add a Google account'),
          ),
          const SizedBox(height: 8),
        ],
        OutlinedButton.icon(
          onPressed: () => showAddCanvasDialog(context, service, notifications),
          icon: const Icon(Icons.school_outlined, size: 18),
          label: const Text('Add a Canvas calendar link'),
        ),
        if (storeError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Tooltip(
              message: storeError,
              child: const Text(
                'Couldn’t read your calendar from Firebase (axisCalendar). Your Firestore rules may need to allow it.',
                style: TextStyle(color: AppColors.danger, fontSize: 12),
              ),
            ),
          ),
        // Sync, small, at the bottom (on a phone; elsewhere it's in the toolbar). Auto-sync is in Settings.
        if (showSync) ...[
          const SizedBox(height: 10),
          Row(children: [
            IconButton(
              tooltip: 'Sync now',
              visualDensity: VisualDensity.compact,
              onPressed: service.syncing
                  ? null
                  : () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final result = await service.syncNow();
                      messenger.showSnackBar(SnackBar(content: Text(result)));
                    },
              icon: service.syncing
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(storeError == null ? Icons.sync : Icons.sync_problem, size: 18, color: AppColors.secondaryText),
            ),
            Expanded(
              child: Text(
                service.syncing ? 'Syncing…' : (synced == null ? 'Sync now' : 'Synced ${_ago(synced)}'),
                style: const TextStyle(color: AppColors.secondaryText, fontSize: 12),
              ),
            ),
          ]),
        ],
      ],
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 45) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    return 'at ${DateFormat.jm().format(t)}';
  }
}

/// Beside the month in the toolbar: which side panels show, the calendars
/// and the to-do list, each on or off (both at once is fine).
class _PanelToggles extends StatelessWidget {
  const _PanelToggles({
    required this.labels,
    required this.calendars,
    required this.todos,
    required this.onCalendars,
    required this.onTodos,
  });

  /// Room for words beside the icons.
  final bool labels;
  final bool calendars;
  final bool todos;
  final VoidCallback onCalendars;
  final VoidCallback onTodos;

  @override
  Widget build(BuildContext context) {
    Widget chip({required Widget icon, required String label, required String name, required bool on, required VoidCallback onTap}) => Tooltip(
          message: on ? 'Hide $name' : 'Show $name',
          child: InkWell(
            borderRadius: BorderRadius.circular(100),
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: EdgeInsets.symmetric(horizontal: labels ? 12 : 9, vertical: 7),
              decoration: BoxDecoration(
                color: on ? const Color(0x26FFFFFF) : Colors.transparent,
                borderRadius: BorderRadius.circular(100),
              ),
              child: IconTheme(
                data: IconThemeData(size: 18, color: on ? AppColors.primaryText : AppColors.secondaryText),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  icon,
                  if (labels) ...[
                    const SizedBox(width: 6),
                    Text(label,
                        style: TextStyle(color: on ? AppColors.primaryText : AppColors.secondaryText, fontSize: 13, fontWeight: FontWeight.w600)),
                  ],
                ]),
              ),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        // A panel at the left edge.
        chip(
          icon: Transform.flip(flipX: true, child: const Icon(Icons.view_sidebar_outlined)),
          label: 'Calendars',
          name: 'calendars',
          on: calendars,
          onTap: onCalendars,
        ),
        const SizedBox(width: 2),
        chip(icon: const Icon(Icons.checklist), label: 'To-do', name: 'to-do list', on: todos, onTap: onTodos),
      ]),
    );
  }
}

/// A small month to jump around with; the shown week or day is highlighted.
class _MiniMonth extends StatefulWidget {
  const _MiniMonth({required this.selected, required this.onPick});

  final DateTime selected;
  final void Function(DateTime) onPick;

  @override
  State<_MiniMonth> createState() => _MiniMonthState();
}

class _MiniMonthState extends State<_MiniMonth> {
  late DateTime _month = DateTime(widget.selected.year, widget.selected.month);

  @override
  void didUpdateWidget(covariant _MiniMonth old) {
    super.didUpdateWidget(old);
    if (!sameDay(old.selected, widget.selected)) _month = DateTime(widget.selected.year, widget.selected.month);
  }

  @override
  Widget build(BuildContext context) {
    final start = monthGridStart(_month);
    final now = DateTime.now();
    final weekStart = addDays(widget.selected, -(widget.selected.weekday % 7));
    return Tile(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: Text(DateFormat.yMMMM().format(_month),
                style: const TextStyle(color: AppColors.primaryText, fontWeight: FontWeight.w600, fontSize: 14)),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            icon: const Icon(Icons.chevron_left),
            onPressed: () => setState(() => _month = DateTime(_month.year, _month.month - 1)),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            icon: const Icon(Icons.chevron_right),
            onPressed: () => setState(() => _month = DateTime(_month.year, _month.month + 1)),
          ),
        ]),
        Row(children: [
          for (final d in const ['S', 'M', 'T', 'W', 'T', 'F', 'S'])
            Expanded(
              child: Center(
                child: Text(d, style: const TextStyle(color: AppColors.secondaryText, fontSize: 11, fontWeight: FontWeight.w600)),
              ),
            ),
        ]),
        const SizedBox(height: 4),
        for (var w = 0; w < 6; w++)
          Builder(builder: (context) {
            final rowStart = addDays(start, w * 7);
            final inWeek = sameDay(rowStart, weekStart);
            return Container(
              margin: const EdgeInsets.only(bottom: 2),
              decoration: BoxDecoration(
                color: inWeek ? AppColors.faint : null,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: Builder(builder: (context) {
                      final day = addDays(rowStart, i);
                      final isToday = sameDay(day, now);
                      final isSelected = sameDay(day, widget.selected);
                      return InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => widget.onPick(day),
                        child: Container(
                          height: 28,
                          alignment: Alignment.center,
                          decoration: isToday
                              ? BoxDecoration(color: AppColors.primaryText, borderRadius: BorderRadius.circular(8))
                              : isSelected
                                  ? BoxDecoration(border: Border.all(color: const Color(0x66FFFFFF)), borderRadius: BorderRadius.circular(8))
                                  : null,
                          child: Text('${day.day}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: isToday || isSelected ? FontWeight.w700 : FontWeight.w500,
                                color: isToday
                                    ? AppColors.background
                                    : day.month == _month.month
                                        ? AppColors.primaryText
                                        : AppColors.secondaryText.withValues(alpha: 0.5),
                              )),
                        ),
                      );
                    }),
                  ),
              ]),
            );
          }),
      ]),
    );
  }
}

class _CalendarToggle extends StatelessWidget {
  const _CalendarToggle({
    required this.service,
    required this.calendar,
    required this.dimmed,
    this.more = const [],
  });

  final CalendarService service;
  final GoogleCalendar calendar;
  final bool dimmed;

  /// More items for its ⋯ menu.
  final List<MenuAction> more;

  @override
  Widget build(BuildContext context) {
    final on = service.isVisible(calendar);
    return Opacity(
      opacity: dimmed ? 0.5 : 1,
      child: HoverMenu(
        bare: true,
        right: 4,
        actions: [
          MenuAction(label: 'Show only this', icon: Icons.filter_center_focus, onSelected: () => service.showOnly(calendar)),
          ...more,
        ],
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => service.setVisible(calendar, !on),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 8, 40, 8),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: on ? calendar.color : Colors.transparent,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: calendar.color, width: 2),
                  ),
                  child: on ? Icon(Icons.check, size: 11, color: onColor(calendar.color)) : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(calendar.name,
                      overflow: TextOverflow.ellipsis, style: TextStyle(color: on ? AppColors.primaryText : AppColors.secondaryText, fontSize: 13.5)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

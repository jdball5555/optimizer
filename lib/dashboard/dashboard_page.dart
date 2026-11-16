import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../calendar/calendar_models.dart';
import '../calendar/calendar_service.dart';
import '../calendar/event_editor.dart';
import '../calendar/todos.dart';
import '../journal/journal_page.dart';
import '../journal/journal_store.dart';
import '../networth/finance_store.dart';
import '../networth/net_worth_page.dart';
import '../theme.dart';
import '../util/fields.dart';
import '../widgets/tiles.dart';
import '../util/dispose_safe.dart';

/// Every kind of panel that can go under your day. (The day itself, its
/// events and what's due, is always at the top.)
enum PanelKind {
  networth('Net worth', Icons.show_chart, 8, 2),
  accounts('Accounts', Icons.account_balance_outlined, 4, 1),
  spending('Spending', Icons.receipt_long_outlined, 4, 2),
  stocks('Stocks', Icons.candlestick_chart_outlined, 4, 2),
  gas('Gas', Icons.local_gas_station_outlined, 4, 1),
  journal('Journal', Icons.menu_book_outlined, 4, 2);

  const PanelKind(this.title, this.icon, this.width, this.height);
  final String title;
  final IconData icon;

  /// Default size: columns out of 12, and rows.
  final int width;
  final int height;
}

class Panel {
  Panel(this.kind, this.width, this.height);
  final PanelKind kind;
  int width;
  int height;

  static Panel? fromJson(Map m) {
    final kind = PanelKind.values.where((k) => k.name == m['kind']).firstOrNull;
    if (kind == null) return null;
    return Panel(kind, (m['w'] as num? ?? kind.width).toInt().clamp(3, 12), (m['h'] as num? ?? kind.height).toInt().clamp(1, 3));
  }
}

// Sized to pack into full rows of 12.
const _defaultLayout = [
  (PanelKind.networth, 8, 2),
  (PanelKind.spending, 4, 2),
  (PanelKind.stocks, 4, 2),
  (PanelKind.journal, 4, 2),
  (PanelKind.accounts, 4, 1),
  (PanelKind.gas, 4, 1),
];

List<Panel> _defaultPanels() => [for (final (k, w, h) in _defaultLayout) Panel(k, w, h)];

/// Morning, afternoon, evening — and "Up late" from 10 pm to 5 am.
String greetingAt(DateTime now) {
  final h = now.hour;
  if (h >= 5 && h < 12) return 'Good morning';
  if (h >= 12 && h < 17) return 'Good afternoon';
  if (h >= 17 && h < 22) return 'Good evening';
  return 'Up late';
}

/// Home: your day first (what's on now or next, today's schedule and what's
/// due), then panels for your money and journal, so everything can be open
/// at once. A layout saved earlier (optimizer/{uid}) is still used.
class DashboardPage extends StatefulWidget {
  const DashboardPage({
    super.key,
    required this.uid,
    required this.calendar,
    required this.journal,
    required this.finance,
    required this.onNavigate,
    this.account,
    this.focus,
    this.name,
    this.money = true,
  });

  /// The money panels (everything from Asset Track). Off without premium
  /// beta: then only the journal's panel shows. The saved layout keeps them.
  final bool money;

  /// The way into focus time (its clock while one is going), top right.
  final Widget? focus;

  /// Your first name, for the greeting.
  final String? name;

  /// Your profile picture (its menu has Settings), shown top right on a phone.
  final Widget? account;

  final String uid;
  final CalendarService calendar;
  final JournalStore journal;
  final FinanceStore finance;

  /// Opens a page of the app: 1 calendar, 3 journal, 4 net worth.
  final void Function(int page) onNavigate;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  List<Panel> _saved = _defaultPanels();

  /// The panels shown: without [DashboardPage.money], only the journal's.
  List<Panel> get _panels => widget.money
      ? _saved
      : [
          for (final p in _saved)
            if (p.kind == PanelKind.journal) p
        ];
  late final _events = _EventFeed(widget.calendar);

  // Keeps "in 25 min" and the now line current.
  Timer? _tick;

  DocumentReference<Map<String, dynamic>> get _doc => FirebaseFirestore.instance.collection('optimizer').doc(widget.uid);
  String get _localKey => 'optimizer.${widget.uid}.dashboard';

  @override
  void initState() {
    super.initState();
    for (final l in [widget.calendar, widget.journal, widget.finance, _events]) {
      l.addListener(_changed);
    }
    hideAmounts.addListener(_changed);
    _loadLayout();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => _changed());
    if (_panels.any((p) => p.kind == PanelKind.accounts)) widget.finance.loadAccounts();
  }

  @override
  void didUpdateWidget(DashboardPage old) {
    super.didUpdateWidget(old);
    if (widget.money && !old.money && _panels.any((p) => p.kind == PanelKind.accounts)) widget.finance.loadAccounts();
  }

  @override
  void dispose() {
    for (final l in [widget.calendar, widget.journal, widget.finance, _events]) {
      l.removeListener(_changed);
    }
    hideAmounts.removeListener(_changed);
    _tick?.cancel();
    _events.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _loadLayout() async {
    List? raw;
    try {
      raw = (await _doc.get()).data()?['dashboard'] as List?;
    } catch (_) {}
    if (raw == null) {
      try {
        final s = (await SharedPreferences.getInstance()).getString(_localKey);
        if (s != null) raw = jsonDecode(s) as List;
      } catch (_) {}
    }
    final panels = [
      for (final m in raw ?? const [])
        if (m is Map) Panel.fromJson(m)
    ].whereType<Panel>().toList();
    if (panels.isNotEmpty && mounted) setState(() => _saved = panels);
    if (_panels.any((p) => p.kind == PanelKind.accounts)) widget.finance.loadAccounts();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final hello = greetingAt(now);
    final end = PageEnd.of(context);
    final header = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.name == null ? hello : '$hello, ${widget.name}', style: pageTitleStyle(context)),
          const SizedBox(height: 6),
          Text(DateFormat('EEEE, MMMM d').format(now), style: const TextStyle(color: AppColors.secondaryText, fontSize: 13.5)),
        ]),
      ),
      if (widget.focus != null) ...[widget.focus!, const SizedBox(width: 10)],
      if (widget.account != null) ...[const SizedBox(width: 10), widget.account!],
      if (end != null) ...[const SizedBox(width: 8), end],
    ]);

    return LayoutBuilder(builder: (context, c) {
      final phone = c.maxWidth < 600;
      final today = _TodayTile(calendar: widget.calendar, events: _events, onOpen: () => widget.onNavigate(1));
      final due = _DueTile(calendar: widget.calendar, onOpen: () => widget.onNavigate(1));
      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, PageSpace.top(context), 16, 28),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          header,
          SizedBox(height: phone ? 28 : 40),
          if (c.maxWidth >= 900)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _Focus(calendar: widget.calendar, events: _events, big: true)),
              const SizedBox(width: 24),
              _RestOfDay(calendar: widget.calendar, events: _events),
            ])
          else
            _Focus(calendar: widget.calendar, events: _events, big: !phone),
          SizedBox(height: phone ? 30 : 44),
          if (c.maxWidth >= 900)
            IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(flex: 3, child: today),
                const SizedBox(width: 10),
                Expanded(flex: 2, child: due),
              ]),
            )
          else ...[
            today,
            const SizedBox(height: 10),
            due,
          ],
          const SizedBox(height: 10),
          if (phone) ..._phonePanels() else _grid(c.maxWidth - 32),
        ]),
      );
    });
  }

  /// On a phone, one panel under another, each only as tall as what's in it.
  List<Widget> _phonePanels() => [
        for (var i = 0; i < _panels.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SizedBox(height: _phoneHeight(_panels[i].kind), child: _frame(i)),
          ),
      ];

  double _phoneHeight(PanelKind k) {
    const chrome = 70.0; // the panel's title row and padding
    switch (k) {
      case PanelKind.stocks:
        final n = widget.finance.holdings.length;
        return chrome + (n == 0 ? 40 : math.min(n, 6) * 44);
      case PanelKind.networth:
        return 330;
      case PanelKind.spending:
        return 300;
      case PanelKind.journal:
        return 300;
      case PanelKind.accounts:
        return 200;
      case PanelKind.gas:
        return 150;
    }
  }

  /// On a wider screen, the 12-column grid of panels.
  Widget _grid(double width) {
    int span(Panel p) => width < 760 ? 12 : (width < 1150 ? (p.width <= 4 ? 6 : 12) : p.width);
    const gap = 10.0;
    const unit = 210.0;
    final colW = (width - gap * 11) / 12;
    final places = _pack([for (final p in _panels) (span(p), p.height)]);
    var rows = 0;
    for (var i = 0; i < places.length; i++) {
      rows = math.max(rows, places[i].$2 + _panels[i].height);
    }
    return SizedBox(
      height: rows * (unit + gap),
      child: Stack(children: [
        for (var i = 0; i < _panels.length; i++)
          Positioned(
            key: ValueKey(_panels[i].kind),
            left: places[i].$1 * (colW + gap),
            top: places[i].$2 * (unit + gap),
            width: span(_panels[i]) * colW + (span(_panels[i]) - 1) * gap,
            height: _panels[i].height * unit + (_panels[i].height - 1) * gap,
            child: _frame(i),
          ),
      ]),
    );
  }

  /// Places panels on a 12-column grid, each in the first gap it fits, so
  /// the page packs tightly whatever sizes you pick. Returns (column, row).
  static List<(int, int)> _pack(List<(int, int)> sizes) {
    final taken = <List<bool>>[];
    bool free(int c, int r, int w, int h) {
      for (var y = r; y < r + h; y++) {
        while (taken.length <= y) {
          taken.add(List.filled(12, false));
        }
        for (var x = c; x < c + w; x++) {
          if (taken[y][x]) return false;
        }
      }
      return true;
    }

    final out = <(int, int)>[];
    for (final (w, h) in sizes) {
      var placed = false;
      for (var r = 0; !placed; r++) {
        for (var c = 0; c + w <= 12 && !placed; c++) {
          if (!free(c, r, w, h)) continue;
          for (var y = r; y < r + h; y++) {
            for (var x = c; x < c + w; x++) {
              taken[y][x] = true;
            }
          }
          out.add((c, r));
          placed = true;
        }
      }
    }
    return out;
  }

  Widget _frame(int i) {
    final p = _panels[i];
    final page = p.kind == PanelKind.journal ? 3 : 4;
    final body = Tile(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(p.kind.icon, size: 16, color: AppColors.secondaryText),
          const SizedBox(width: 8),
          Expanded(
            child: Text(p.kind.title, style: const TextStyle(color: AppColors.primaryText, fontWeight: FontWeight.w700, fontSize: 14)),
          ),
          IconButton(
            tooltip: 'Open',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            icon: const Icon(Icons.arrow_outward, color: AppColors.secondaryText),
            onPressed: () => widget.onNavigate(page),
          ),
        ]),
        const SizedBox(height: 6),
        Expanded(child: _content(p)),
      ]),
    );
    return body;
  }

  Widget _content(Panel p) {
    switch (p.kind) {
      case PanelKind.networth:
        return _NetWorthPanel(store: widget.finance, rows: p.height);
      case PanelKind.accounts:
        return _AccountsPanel(store: widget.finance);
      case PanelKind.spending:
        return _SpendingPanel(store: widget.finance);
      case PanelKind.stocks:
        return _StocksPanel(store: widget.finance);
      case PanelKind.gas:
        return _GasPanel(store: widget.finance);
      case PanelKind.journal:
        return _JournalPanel(store: widget.journal, onOpen: () => widget.onNavigate(3));
    }
  }
}

// ---------------------------------------------------------------- your day

/// Today's and the next couple of days' events, read for Home on their own
/// so the Calendar page can be on any week. The calendar follows Firestore
/// live, so this just reads again whenever it changes.
class _EventFeed extends ChangeNotifier with DisposeSafe {
  _EventFeed(this.calendar) {
    calendar.addListener(_onCalendar);
    load();
  }

  final CalendarService calendar;
  List<CalendarEvent> events = [];
  bool loaded = false;
  bool _loading = false;

  void _onCalendar() {
    if (!_loading) load();
  }

  Future<void> load() async {
    _loading = true;
    try {
      final today = dayStart(DateTime.now());
      events = await calendar.fetchBetween(today, addDays(today, 3));
      loaded = true;
      notifyListeners();
    } finally {
      _loading = false;
    }
  }

  @override
  void dispose() {
    calendar.removeListener(_onCalendar);
    super.dispose();
  }
}

/// How the day stands right now.
class _Day {
  _Day(List<CalendarEvent> events, this.now) : today = dayStart(now) {
    final tomorrow = addDays(today, 1);
    // A trip's tile runs for days: it's listed with the all-day things, not as "now".
    final timed = events.where((e) => !e.allDay && !e.backdrop).toList()..sort((a, b) => a.start.compareTo(b.start));
    todays = timed.where((e) => e.overlaps(today, tomorrow)).toList();
    allDay = events.where((e) => (e.allDay || e.backdrop) && e.overlaps(today, tomorrow)).toList();
    current = todays.where((e) => !e.start.isAfter(now) && e.end.isAfter(now)).lastOrNull;
    next = todays.where((e) => e.start.isAfter(now)).firstOrNull;
    tomorrows = timed.where((e) => e.overlaps(tomorrow, addDays(tomorrow, 1)) && !e.start.isBefore(tomorrow)).toList();
  }

  final DateTime now;
  final DateTime today;
  late final List<CalendarEvent> todays;
  late final List<CalendarEvent> allDay;
  late final List<CalendarEvent> tomorrows;
  late final CalendarEvent? current;
  late final CalendarEvent? next;

  bool get restIsFree => current == null && next == null;
}

/// "25 min", "1 h 10 min", "3 h".
String _span(Duration d) {
  final m = d.inMinutes;
  if (m < 1) return 'under a minute';
  if (m < 60) return '$m min';
  return m % 60 == 0 ? '${m ~/ 60} h' : '${m ~/ 60} h ${m % 60} min';
}

const _label = TextStyle(color: AppColors.secondaryText, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.4);

/// The one thing that matters right now, big and outside any tile: the
/// event you're in (with how much of it is left), or the next one and how
/// long until it, or that the rest of the day is yours.
class _Focus extends StatelessWidget {
  const _Focus({required this.calendar, required this.events, required this.big});

  final CalendarService calendar;
  final _EventFeed events;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final day = _Day(events.events, DateTime.now());
    final now = day.now;
    final t = DateFormat.jm();
    final e = day.current ?? day.next;

    String label;
    String title;
    String detail = '';
    String? then;
    Color bar = AppColors.faint;
    double? progress;
    if (!events.loaded) {
      label = 'TODAY';
      title = 'Getting your day…';
    } else if (calendar.accounts.isEmpty && calendar.canvasFeeds.isEmpty && calendar.ownCalendars.isEmpty) {
      label = 'TODAY';
      title = 'Your day shows up here';
      detail = 'Link Google Calendar or a Canvas calendar on the Calendar page.';
    } else if (e != null) {
      final inIt = identical(e, day.current);
      label = inIt ? 'NOW · ${_span(e.end.difference(now)).toUpperCase()} LEFT' : 'NEXT · IN ${_span(e.start.difference(now)).toUpperCase()}';
      title = e.shownTitle;
      bar = e.color;
      detail = [
        '${t.format(e.start)} – ${t.format(e.end)}',
        if (e.location.isNotEmpty) e.location,
      ].join(' · ');
      if (inIt) {
        final total = e.end.difference(e.start).inSeconds;
        progress = total <= 0 ? 1.0 : (now.difference(e.start).inSeconds / total).clamp(0.0, 1.0);
        final after = day.next;
        if (after != null) then = 'Then ${after.title} at ${t.format(after.start)}';
      } else {
        then = identical(e, day.todays.first) ? 'Your first event today' : 'Free until then';
      }
    } else {
      label = 'REST OF TODAY';
      title = day.todays.isEmpty ? 'Nothing on your calendar' : 'You’re done for today';
      final first = day.tomorrows.firstOrNull;
      if (first != null) detail = 'Tomorrow starts with ${first.title} at ${t.format(first.start)}';
    }

    final titleStyle = TextStyle(
      color: events.loaded ? AppColors.primaryText : AppColors.secondaryText,
      fontWeight: FontWeight.w800,
      fontSize: big ? 34 : 27,
      letterSpacing: big ? -1.1 : -0.8,
      height: 1.12,
    );
    final body = IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(width: 5, decoration: BoxDecoration(color: bar, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: _label.copyWith(color: e == null ? AppColors.secondaryText : AppColors.primaryText)),
            const SizedBox(height: 6),
            Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: titleStyle),
            if (detail.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(detail, style: const TextStyle(color: AppColors.secondaryText, fontSize: 15, height: 1.35)),
            ],
            if (progress != null) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(value: progress, minHeight: 5, backgroundColor: AppColors.faint, color: bar),
                ),
              ),
            ],
            if (then != null) ...[
              const SizedBox(height: 10),
              Text(then, style: const TextStyle(color: AppColors.primaryText, fontSize: 13.5, fontWeight: FontWeight.w500)),
            ],
          ]),
        ),
      ]),
    );
    if (e == null) return body;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showEventDetails(context, calendar, e),
      child: body,
    );
  }
}

/// Beside the focus on a wide screen: the rest of the day in three numbers.
class _RestOfDay extends StatelessWidget {
  const _RestOfDay({required this.calendar, required this.events});

  final CalendarService calendar;
  final _EventFeed events;

  /// Time not in any event between now and 10 pm.
  static Duration freeLeft(_Day day) {
    final end = DateTime(day.today.year, day.today.month, day.today.day, 22);
    if (!day.now.isBefore(end)) return Duration.zero;
    var free = Duration.zero;
    var at = day.now;
    for (final e in day.todays) {
      if (!e.end.isAfter(at)) continue;
      if (e.start.isAfter(at)) free += (e.start.isBefore(end) ? e.start : end).difference(at);
      if (e.end.isAfter(at)) at = e.end;
      if (!at.isBefore(end)) break;
    }
    if (at.isBefore(end)) free += end.difference(at);
    return free;
  }

  @override
  Widget build(BuildContext context) {
    if (!events.loaded) return const SizedBox.shrink();
    final day = _Day(events.events, DateTime.now());
    final left = day.todays.where((e) => e.start.isAfter(day.now)).length;
    final dueToday = _DueTile.dueSoon(calendar).where((t) => !dayStart(t.due!).isAfter(day.today)).length;
    final free = freeLeft(day);
    Widget stat(String value, String label) => Padding(
          padding: const EdgeInsets.only(left: 36),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.8)),
            const SizedBox(height: 2),
            Text(label, style: _label),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Row(children: [
        stat(free.inMinutes < 60 ? '${free.inMinutes}m' : '${free.inHours}h ${free.inMinutes % 60}m', 'FREE TODAY'),
        stat('$left', left == 1 ? 'EVENT LEFT' : 'EVENTS LEFT'),
        stat('$dueToday', 'DUE TODAY'),
      ]),
    );
  }
}

/// A tile's title row: icon, title, a quiet count, and a way to the full page.
class _TileHead extends StatelessWidget {
  const _TileHead({required this.icon, required this.title, this.count, required this.onOpen});

  final IconData icon;
  final String title;
  final String? count;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, size: 16, color: AppColors.secondaryText),
        const SizedBox(width: 8),
        Text(title, style: const TextStyle(color: AppColors.primaryText, fontWeight: FontWeight.w700, fontSize: 14)),
        if (count != null) Text('  $count', style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
        const Spacer(),
        IconButton(
          tooltip: 'Open',
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          icon: const Icon(Icons.arrow_outward, color: AppColors.secondaryText),
          onPressed: onOpen,
        ),
      ]);
}

/// Today's schedule down a line, with where you are on it marked; once the
/// day is over, tomorrow's first few.
class _TodayTile extends StatelessWidget {
  const _TodayTile({required this.calendar, required this.events, required this.onOpen});

  final CalendarService calendar;
  final _EventFeed events;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final day = _Day(events.events, DateTime.now());
    final now = day.now;
    final rows = <Widget>[];
    for (final e in day.allDay) {
      rows.add(_Stop(time: e.isTrip ? 'Trip' : 'All day', event: e, calendar: calendar, past: false));
    }
    var markerPlaced = false;
    for (final e in day.todays) {
      if (!markerPlaced && e.start.isAfter(now)) {
        rows.add(_NowLine(now));
        markerPlaced = true;
      }
      rows.add(_Stop(time: DateFormat.jm().format(e.start), event: e, calendar: calendar, past: !e.end.isAfter(now)));
    }
    if (!markerPlaced && day.todays.isNotEmpty) rows.add(_NowLine(now));
    if (day.restIsFree && day.tomorrows.isNotEmpty) {
      rows.add(const Padding(padding: EdgeInsets.only(top: 12, bottom: 6), child: Text('TOMORROW', style: _label)));
      for (final e in day.tomorrows.take(3)) {
        rows.add(_Stop(time: DateFormat.jm().format(e.start), event: e, calendar: calendar, past: false));
      }
    }
    final count = day.todays.length + day.allDay.length;
    return Tile(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _TileHead(icon: Icons.schedule, title: 'Today', count: count == 0 ? null : '$count', onOpen: onOpen),
        if (!events.loaded)
          const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
        else if (day.todays.isEmpty && day.allDay.isEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(top: 4, bottom: 4),
            child: Text('Nothing on your calendar today.', style: TextStyle(color: AppColors.secondaryText)),
          ),
          ...rows,
        ] else
          ...rows,
      ]),
    );
  }
}

/// One event on the day's line: its time, a dot in its color, what and where.
class _Stop extends StatelessWidget {
  const _Stop({required this.time, required this.event, required this.calendar, required this.past});

  final String time;
  final CalendarEvent event;
  final CalendarService calendar;
  final bool past;

  @override
  Widget build(BuildContext context) {
    final e = event;
    final sub = [
      if (!e.allDay && !e.backdrop) 'until ${DateFormat.jm().format(e.end)}',
      if (e.location.isNotEmpty) e.location,
    ].join(' · ');
    return Opacity(
      opacity: past ? 0.42 : 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => showEventDetails(context, calendar, e),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 66,
              child: Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(time, style: const TextStyle(color: AppColors.secondaryText, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 10),
              child: Container(width: 9, height: 9, decoration: BoxDecoration(color: e.color, shape: BoxShape.circle)),
            ),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e.shownTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                if (sub.isNotEmpty)
                  Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.secondaryText, fontSize: 12)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Where now falls between the day's events: a white line.
class _NowLine extends StatelessWidget {
  const _NowLine(this.now);

  final DateTime now;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(
            width: 66,
            child: Text(DateFormat.jm().format(now),
                style: const TextStyle(
                    color: AppColors.primaryText, fontSize: 12, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
          ),
          Container(width: 9, height: 9, decoration: const BoxDecoration(color: AppColors.primaryText, shape: BoxShape.circle)),
          Expanded(child: Container(height: 1.5, margin: const EdgeInsets.only(right: 8), color: AppColors.primaryText)),
        ]),
      );
}

/// What's due soon (overdue, today, the next two days), to check off here.
class _DueTile extends StatelessWidget {
  const _DueTile({required this.calendar, required this.onOpen});

  final CalendarService calendar;
  final VoidCallback onOpen;

  static const _shown = 8;

  static List<Todo> dueSoon(CalendarService calendar) {
    final until = addDays(dayStart(DateTime.now()), 3);
    return calendar.todos.where((t) => !t.done && t.due != null && t.due!.isBefore(until)).toList()
      ..sort((a, b) {
        final d = dayStart(a.due!).compareTo(dayStart(b.due!));
        return d != 0 ? d : Todo.byClassThenTitle(a, b);
      });
  }

  void _check(BuildContext context, Todo t) {
    calendar.setTodoDone(t, true);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Checked off ${t.title}'),
      action: SnackBarAction(label: 'Undo', onPressed: () => calendar.setTodoDone(t, false)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final list = dueSoon(calendar);
    final now = DateTime.now();
    final today = dayStart(now);
    String group(Todo t) {
      final d = dayStart(t.due!);
      if (t.allDay ? d.isBefore(today) : t.due!.isBefore(now)) return 'OVERDUE';
      if (sameDay(d, today)) return 'TODAY';
      if (sameDay(d, addDays(today, 1))) return 'TOMORROW';
      return DateFormat('EEEE').format(d).toUpperCase();
    }

    final rows = <Widget>[];
    String? last;
    for (final t in list.take(_shown)) {
      final g = group(t);
      if (g != last) {
        rows.add(Padding(
          padding: EdgeInsets.only(top: last == null ? 2 : 10, bottom: 4),
          child: Text(g, style: _label.copyWith(color: g == 'OVERDUE' ? AppColors.danger : AppColors.secondaryText)),
        ));
        last = g;
      }
      rows.add(InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _check(context, t),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: t.color, width: 2)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                if (t.label.isNotEmpty || !t.allDay)
                  Text(
                    [if (t.label.isNotEmpty) t.label, if (!t.allDay) DateFormat.jm().format(t.due!)].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.secondaryText, fontSize: 12),
                  ),
              ]),
            ),
          ]),
        ),
      ));
    }
    return Tile(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _TileHead(icon: Icons.checklist, title: 'Due', count: list.isEmpty ? null : '${list.length}', onOpen: onOpen),
        if (list.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 4, bottom: 4),
            child: Text('Nothing due in the next few days.', style: TextStyle(color: AppColors.secondaryText)),
          ),
        ...rows,
        if (list.length > _shown)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: onOpen, child: Text('${list.length - _shown} more in To-do')),
          ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- money panels

class _NetWorthPanel extends StatefulWidget {
  const _NetWorthPanel({required this.store, required this.rows});

  final FinanceStore store;
  final int rows;

  @override
  State<_NetWorthPanel> createState() => _NetWorthPanelState();
}

class _NetWorthPanelState extends State<_NetWorthPanel> {
  String _interval = '1M';
  int? _hover;

  @override
  Widget build(BuildContext context) {
    if (widget.store.points.isEmpty) return const _Note('No net worth history yet.');
    if (widget.rows == 1) {
      final latest = widget.store.points.last;
      final day = widget.store.before(const Duration(hours: 23));
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FittedBox(child: Text(money(latest.total), style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w600))),
        if (day != null)
          Text('${signedMoney(latest.total - day.total)} today',
              style: TextStyle(color: changeColor(latest.total - day.total), fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Expanded(child: TileLineChart(values: [for (final p in widget.store.daily.reversed.take(30).toList().reversed) p.total])),
      ]);
    }
    return NetWorthHero(
      store: widget.store,
      interval: _interval,
      hover: _hover,
      compact: true,
      chartHeight: null,
      onInterval: (i) => setState(() {
        _interval = i;
        _hover = null;
      }),
      onHover: (i) => setState(() => _hover = i),
    );
  }
}

class _AccountsPanel extends StatelessWidget {
  const _AccountsPanel({required this.store});

  final FinanceStore store;

  @override
  Widget build(BuildContext context) {
    final accounts = store.accounts;
    if (store.accountsError != null) return const _Note('Couldn’t load accounts from Asset Track.');
    if (accounts == null) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    return ListView(children: [
      for (final g in accountGroups)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            Expanded(child: Text('${g[0].toUpperCase()}${g.substring(1)}', style: const TextStyle(color: AppColors.secondaryText))),
            Text(
              money(accounts.where((a) => accountGroupOf(a) == g).fold<double>(0, (s, a) => s + accountBalance(a))),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ]),
        ),
    ]);
  }
}

class _SpendingPanel extends StatelessWidget {
  const _SpendingPanel({required this.store});

  final FinanceStore store;

  @override
  Widget build(BuildContext context) {
    final month = DateTime(DateTime.now().year, DateTime.now().month);
    final flow = store.cashFlow(month);
    final cats = store.spendingByCategory(month).entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(money(flow.expense), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600)),
      Text('spent in ${DateFormat.MMMM().format(month)} · ${money(flow.income)} in',
          style: const TextStyle(color: AppColors.secondaryText, fontSize: 12)),
      const SizedBox(height: 10),
      Expanded(
        child: ListView(children: [
          for (final e in cats.take(8))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text(e.key, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5))),
                  Text(money(e.value), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 3),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: flow.expense == 0 ? 0 : e.value / flow.expense,
                    minHeight: 4,
                    backgroundColor: AppColors.faint,
                    color: AppColors.primaryText,
                  ),
                ),
              ]),
            ),
        ]),
      ),
    ]);
  }
}

class _StocksPanel extends StatelessWidget {
  const _StocksPanel({required this.store});

  final FinanceStore store;

  @override
  Widget build(BuildContext context) {
    final holdings = store.holdings;
    if (holdings.isEmpty) return const _Note('No stocks in your recent snapshots.');
    return ListView(children: [
      for (final h in holdings)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            SizedBox(width: 64, child: Text(h.ticker, style: const TextStyle(fontWeight: FontWeight.w700))),
            Expanded(child: SizedBox(height: 22, child: TileLineChart(values: h.history))),
            const SizedBox(width: 10),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(money(h.value), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              if (h.dayPct != null)
                Text('${h.dayPct! >= 0 ? '+' : ''}${h.dayPct!.toStringAsFixed(2)}%', style: TextStyle(color: changeColor(h.dayPct!), fontSize: 11.5)),
            ]),
          ]),
        ),
    ]);
  }
}

class _GasPanel extends StatelessWidget {
  const _GasPanel({required this.store});

  final FinanceStore store;

  @override
  Widget build(BuildContext context) {
    final fills = store.gasFills;
    if (fills.isEmpty) return const _Note('No gas fill-ups yet.');
    final mpg = fills.where((f) => f.mpg != null).firstOrNull?.mpg;
    final ppg = fills.where((f) => f.pricePerGallon != null).firstOrNull?.pricePerGallon;
    return Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const StatLabel('Last MPG'),
          FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(mpg == null ? '—' : mpg.toStringAsFixed(1), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600))),
        ]),
      ),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const StatLabel('Per gallon'),
          FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(ppg == null ? '—' : money(ppg), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600))),
        ]),
      ),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const StatLabel('Last fill'),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(fills.first.txn.date == null ? '—' : DateFormat.MMMd().format(fills.first.txn.date!),
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
    ]);
  }
}

// ---------------------------------------------------------------- journal panels

class _JournalPanel extends StatelessWidget {
  const _JournalPanel({required this.store, required this.onOpen});

  final JournalStore store;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    if (!store.loaded) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    if (store.entries.isEmpty) return const _Note('No entries yet.');
    return ListView(children: [
      for (final e in store.entries.take(12))
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Flexible(
                  child: Text(journalDate(e.date),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                ),
                if (e.people.isNotEmpty) ...[const SizedBox(width: 6), PeopleBadge(people: e.people, date: e.date)],
              ]),
              if (e.header.isNotEmpty)
                Text(e.header,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.secondaryText, fontStyle: FontStyle.italic, fontSize: 12.5)),
              Text(e.body.replaceAll(RegExp(r'\s+'), ' '),
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xBFFFFFFF), fontSize: 12.5)),
            ]),
          ),
        ),
    ]);
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Center(child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.secondaryText)));
}

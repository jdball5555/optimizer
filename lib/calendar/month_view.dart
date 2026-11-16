import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme.dart';
import '../util/fields.dart';
import 'calendar_models.dart';

/// First day shown in a Sunday-first month grid.
DateTime monthGridStart(DateTime anyDayInMonth) {
  final first = DateTime(anyDayInMonth.year, anyDayInMonth.month, 1);
  return addDays(first, -(first.weekday % 7));
}

/// The order of a day in the month: all-day events, then tasks with no time,
/// then everything with a time by when it starts or is due.
int compareMonthEntries(CalendarEvent a, CalendarEvent b) {
  int rank(CalendarEvent e) => !e.allDay || e.due != null ? 2 : (e.isTask ? 1 : 0);
  final r = rank(a).compareTo(rank(b));
  if (r != 0) return r;
  if (rank(a) == 2) {
    final t = (a.due ?? a.start).compareTo(b.due ?? b.start);
    if (t != 0) return t;
  }
  return compareAllDay(a, b);
}

/// An entry in a week of the month: its row, across days [first] to [last] (0–6).
class MonthEntry {
  const MonthEntry(this.event, this.row, this.first, this.last);

  final CalendarEvent event;
  final int row;
  final int first;
  final int last;
}

class MonthWeekLayout {
  const MonthWeekLayout(this.entries, this.days, this.more);

  final List<MonthEntry> entries;

  /// Everything on each day, shown or not.
  final List<List<CalendarEvent>> days;

  /// How many of each day's didn't fit. A day with any gives its last row to
  /// saying so.
  final List<int> more;
}

/// Places a week's events in [rows] rows. Something running across days keeps
/// one row on all of them and takes it only on those days: every other day's
/// events start at the top.
MonthWeekLayout layoutMonthWeek(List<DateTime> week, List<CalendarEvent> events, int rows) {
  List<int> daysOf(CalendarEvent e) => [
        for (var d = 0; d < 7; d++)
          if (e.overlaps(dayStart(week[d]), addDays(week[d], 1))) d
      ];

  final across = <CalendarEvent>[];
  final single = [for (var d = 0; d < 7; d++) <CalendarEvent>[]];
  for (final e in events) {
    final on = daysOf(e);
    if (on.isEmpty) continue;
    if (e.backdrop || e.spansDays) {
      across.add(e);
    } else {
      single[on.first].add(e);
    }
  }
  across.sort((a, b) {
    final s = a.start.compareTo(b.start);
    return s != 0 ? s : b.end.compareTo(a.end);
  });

  // Each takes the first row free on all its days.
  final taken = [for (var d = 0; d < 7; d++) <int>{}];
  final rowOf = <CalendarEvent, int>{};
  for (final e in across) {
    final on = daysOf(e);
    var row = 0;
    while (on.any((d) => taken[d].contains(row))) {
      row++;
    }
    rowOf[e] = row;
    for (final d in on) {
      taken[d].add(row);
    }
  }

  final entries = <MonthEntry>[];
  final more = List.filled(7, 0);
  final limit = List.filled(7, rows);
  for (var d = 0; d < 7; d++) {
    single[d].sort(compareMonthEntries);
    // The free rows, top down, as many as this day's own events need.
    final free = <int>[];
    for (var row = 0; free.length < single[d].length; row++) {
      if (!taken[d].contains(row)) free.add(row);
    }
    final lowest = [...taken[d], ...free].fold(-1, math.max);
    if (lowest >= rows) limit[d] = math.max(0, rows - 1);
    for (final (n, e) in single[d].indexed) {
      if (free[n] < limit[d]) {
        entries.add(MonthEntry(e, free[n], d, d));
      } else {
        more[d]++;
      }
    }
    more[d] += taken[d].where((row) => row >= limit[d]).length;
  }

  // Shown as one piece wherever the days in a row have room for it.
  for (final e in across) {
    final row = rowOf[e]!;
    int? from;
    final on = daysOf(e);
    for (final d in on) {
      if (row < limit[d]) from ??= d;
      if (from != null && (row >= limit[d] || d == on.last)) {
        entries.add(MonthEntry(e, row, from, row < limit[d] ? d : d - 1));
        from = null;
      }
    }
  }

  return MonthWeekLayout(
      entries,
      [
        for (var d = 0; d < 7; d++) [...across.where((e) => daysOf(e).contains(d)), ...single[d]]
      ],
      more);
}

/// A full day, or something running behind the whole day, is solid. Anything
/// with its own times, or to be checked off, is faded.
bool monthEntrySolid(CalendarEvent e) => !e.isTask && (e.allDay || e.backdrop);

/// An entry's color, over the page. A hidden event's color is already faint.
Color monthEntryFill(CalendarEvent e) {
  final strength = monthEntrySolid(e) ? (e.done ? 0.4 : 1.0) : 0.22;
  return Color.alphaBlend(e.color.withValues(alpha: e.color.a * strength), AppColors.background);
}

/// An entry's title. A task's circle says whether it's done, so no ✓ as well.
String monthEntryTitle(CalendarEvent e) => e.isTask ? e.shownTitle.replaceFirst(RegExp('^✓ '), '') : e.shownTitle;

/// A task's circle: hollow, then filled and checked once it's done. It takes
/// the taps across its [width], leaving the rest of the entry to open it.
class TaskCircle extends StatelessWidget {
  const TaskCircle({super.key, required this.event, required this.size, required this.width, this.onTap});

  final CalendarEvent event;
  final double size;
  final double width;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = event.color;
    return Tooltip(
      message: event.done ? 'Mark not done' : 'Mark done',
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: width,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: event.done ? color : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 1.5),
              ),
              child: event.done ? Icon(Icons.check, size: size - 3, color: onColor(color)) : null,
            ),
          ),
        ),
      ),
    );
  }
}

const _line = BorderSide(color: AppColors.border);

/// The month as one grid: the days are divided by thin lines, so nearly all of
/// it is left for what's on them.
class MonthView extends StatelessWidget {
  const MonthView({
    super.key,
    required this.month,
    required this.events,
    required this.onDayTap,
    required this.onEventTap,
    this.onTaskTap,
  });

  final DateTime month;
  final List<CalendarEvent> events;
  final void Function(DateTime) onDayTap;
  final void Function(CalendarEvent) onEventTap;

  /// A task's circle: checks it off, or back on.
  final void Function(CalendarEvent)? onTaskTap;

  @override
  Widget build(BuildContext context) {
    final start = monthGridStart(month);
    final days = [for (var i = 0; i < 42; i++) addDays(start, i)];
    // Drop the last row when the month doesn't reach it.
    final weeks = days[35].month == month.month ? 6 : 5;

    return Column(
      children: [
        SizedBox(
          height: 22,
          child: Row(
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(
                      DateFormat.E().format(days[i]),
                      style: const TextStyle(color: AppColors.secondaryText, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
            ],
          ),
        ),
        for (var w = 0; w < weeks; w++) Expanded(child: _week(context, [for (var d = 0; d < 7; d++) days[w * 7 + d]])),
      ],
    );
  }

  Widget _week(BuildContext context, List<DateTime> week) {
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    final dateH = 23 * scale, rowH = 20 * scale, entryH = 18 * scale;
    return LayoutBuilder(builder: (context, c) {
      final rows = math.max(1, ((c.maxHeight - dateH) / rowH).floor());
      final layout = layoutMonthWeek(week, events, rows);
      final cell = c.maxWidth / 7;
      return ClipRect(
        child: Stack(children: [
          Positioned.fill(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var d = 0; d < 7; d++) Expanded(child: _day(week[d], scale, divided: d > 0)),
              ],
            ),
          ),
          for (final p in layout.entries)
            Positioned(
              left: p.first * cell + (_startsAt(p, week) ? 2 : 0),
              width: (p.last - p.first + 1) * cell - (_startsAt(p, week) ? 2 : 0) - (_endsAt(p, week) ? 2 : 0),
              top: dateH + p.row * rowH,
              height: entryH,
              child: _entry(p, week),
            ),
          for (var d = 0; d < 7; d++)
            if (layout.more[d] > 0)
              Positioned(
                left: d * cell + 2,
                width: cell - 4,
                top: dateH + (rows - 1) * rowH,
                height: entryH,
                child: _more(context, week[d], layout.more[d], layout.days[d]),
              ),
        ]),
      );
    });
  }

  bool _startsAt(MonthEntry p, List<DateTime> week) => sameDay(p.event.start, week[p.first]);

  bool _endsAt(MonthEntry p, List<DateTime> week) => sameDay(p.event.end.subtract(const Duration(microseconds: 1)), week[p.last]);

  /// A day's own space: its date, and tapping anywhere empty adds to it.
  Widget _day(DateTime day, double scale, {required bool divided}) {
    final inMonth = day.month == month.month;
    final isToday = sameDay(day, DateTime.now());
    return DecoratedBox(
      decoration: BoxDecoration(border: Border(top: _line, left: divided ? _line : BorderSide.none)),
      child: InkWell(
        onTap: () => onDayTap(day),
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(3, 2, 0, 0),
            // No Container.alignment here: it would stretch the badge across the day.
            child: Container(
              height: 19 * scale,
              constraints: BoxConstraints(minWidth: 19 * scale),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: isToday ? BoxDecoration(color: AppColors.primaryText, borderRadius: BorderRadius.circular(6)) : null,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  day.day == 1 ? DateFormat.MMMd().format(day) : '${day.day}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isToday ? AppColors.background : (inMonth ? AppColors.primaryText : AppColors.secondaryText.withValues(alpha: 0.6)),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _entry(MonthEntry p, List<DateTime> week) {
    final e = p.event;
    final solid = monthEntrySolid(e);
    final fill = monthEntryFill(e);
    final ink = !solid
        ? (e.done ? AppColors.secondaryText : AppColors.primaryText)
        : (ThemeData.estimateBrightnessForColor(fill) == Brightness.dark ? AppColors.primaryText : AppColors.background);
    final starts = _startsAt(p, week);
    const round = Radius.circular(4);
    return Material(
      color: fill,
      borderRadius: BorderRadius.horizontal(left: starts ? round : Radius.zero, right: _endsAt(p, week) ? round : Radius.zero),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onEventTap(e),
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (e.isTask)
            TaskCircle(event: e, size: 12, width: 18, onTap: onTaskTap == null ? null : () => onTaskTap!(e))
          else if (!solid && starts)
            Container(width: 3, color: e.color),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(left: e.isTask ? 1 : 5),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  e.allDay || e.backdrop || !starts ? monthEntryTitle(e) : '${DateFormat('h:mm').format(e.start)}  ${monthEntryTitle(e)}',
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: ink,
                    fontSize: 11,
                    fontWeight: solid ? FontWeight.w700 : FontWeight.w500,
                    decoration: e.done ? TextDecoration.lineThrough : null,
                    decorationColor: ink,
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _more(BuildContext context, DateTime day, int count, List<CalendarEvent> all) => Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () => _showDay(context, day, all),
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.only(left: 5),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('+$count more',
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.secondaryText, fontSize: 11, fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      );

  /// Everything on a day, each one opening as it does on the grid.
  Future<void> _showDay(BuildContext context, DateTime day, List<CalendarEvent> all) {
    // The dialog holds its own copy, so a task checked off here shows it at once.
    final shown = [...all];
    return showDialog<void>(
      context: context,
      builder: (dialog) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 6),
              child: Row(children: [
                Expanded(
                  child: Text(DateFormat('EEEE, MMMM d').format(day), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                ),
                IconButton(tooltip: 'Close', icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(dialog)),
              ]),
            ),
            Flexible(
              child: StatefulBuilder(
                builder: (_, setList) => ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 12),
                  children: [
                    for (final (i, e) in shown.indexed)
                      InkWell(
                        onTap: () {
                          Navigator.pop(dialog);
                          onEventTap(e);
                        },
                        child: Row(children: [
                          if (e.isTask)
                            SizedBox(
                              height: 48,
                              child: TaskCircle(
                                event: e,
                                size: 18,
                                width: 48,
                                onTap: onTaskTap == null
                                    ? null
                                    : () {
                                        onTaskTap!(e);
                                        setList(() => shown[i] = e.copyWith(done: !e.done));
                                      },
                              ),
                            )
                          else
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 7, 10, 7),
                              child: Container(
                                width: 4,
                                height: 34,
                                decoration: BoxDecoration(color: e.color, borderRadius: BorderRadius.circular(2)),
                              ),
                            ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(right: 20),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(monthEntryTitle(e),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: e.done ? AppColors.secondaryText : AppColors.primaryText,
                                      decoration: e.done ? TextDecoration.lineThrough : null,
                                      decorationColor: AppColors.secondaryText,
                                    )),
                                Text(_when(e), maxLines: 1, style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
                              ]),
                            ),
                          ),
                        ]),
                      ),
                  ],
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  String _when(CalendarEvent e) {
    if (e.spansDays) return '${DateFormat.MMMd().format(e.start)} – ${DateFormat.MMMd().format(e.end.subtract(const Duration(microseconds: 1)))}';
    if (e.allDay) return 'All day';
    return '${DateFormat.jm().format(e.start)} – ${DateFormat.jm().format(e.end)}';
  }
}

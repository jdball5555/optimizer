import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme.dart';
import '../util/fields.dart';
import 'calendar_models.dart';
import 'month_view.dart';

/// The month on a phone, where a grid of tiny cells can't hold titles: each
/// day shows a dot per event (in its calendar's color), and the day you tap
/// is listed in full underneath.
class MonthAgenda extends StatefulWidget {
  const MonthAgenda({super.key, required this.month, required this.events, required this.onEventTap, this.onTaskTap, required this.onNewEvent});

  final DateTime month;
  final List<CalendarEvent> events;
  final void Function(CalendarEvent) onEventTap;

  /// A task's circle: checks it off, or back on.
  final void Function(CalendarEvent)? onTaskTap;

  /// A new event on a day: double-tap it, or tap an empty day's list.
  final void Function(DateTime) onNewEvent;

  @override
  State<MonthAgenda> createState() => _MonthAgendaState();
}

class _MonthAgendaState extends State<MonthAgenda> {
  late DateTime _selected = _initial();

  DateTime _initial() {
    final now = DateTime.now();
    return now.year == widget.month.year && now.month == widget.month.month ? dayStart(now) : DateTime(widget.month.year, widget.month.month);
  }

  @override
  void didUpdateWidget(covariant MonthAgenda old) {
    super.didUpdateWidget(old);
    if (old.month.year != widget.month.year || old.month.month != widget.month.month) _selected = _initial();
  }

  List<CalendarEvent> _on(DateTime day) => widget.events.where((e) => e.overlaps(dayStart(day), addDays(day, 1))).toList()..sort(compareMonthEntries);

  @override
  Widget build(BuildContext context) {
    final start = monthGridStart(widget.month);
    final weeks = addDays(start, 35).month == widget.month.month ? 6 : 5;
    final now = DateTime.now();
    final dayEvents = _on(_selected);
    final t = DateFormat.jm();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        for (final d in const ['S', 'M', 'T', 'W', 'T', 'F', 'S'])
          Expanded(
            child: Center(
              child: Text(d, style: const TextStyle(color: AppColors.secondaryText, fontSize: 11, fontWeight: FontWeight.w600)),
            ),
          ),
      ]),
      const SizedBox(height: 4),
      for (var w = 0; w < weeks; w++)
        Row(children: [
          for (var i = 0; i < 7; i++)
            Expanded(
              child: Builder(builder: (context) {
                final day = addDays(start, w * 7 + i);
                final inMonth = day.month == widget.month.month;
                final isToday = sameDay(day, now);
                final selected = sameDay(day, _selected);
                final events = _on(day);
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _selected = day),
                  onDoubleTap: () => widget.onNewEvent(day),
                  child: Container(
                    height: 50,
                    margin: const EdgeInsets.all(1.5),
                    decoration: BoxDecoration(
                      color: selected ? AppColors.surfaceHigh : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      border: selected ? Border.all(color: const Color(0x55FFFFFF)) : null,
                    ),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Container(
                        width: 28,
                        height: 24,
                        alignment: Alignment.center,
                        decoration: isToday ? BoxDecoration(color: AppColors.primaryText, borderRadius: BorderRadius.circular(8)) : null,
                        child: Text('${day.day}',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: isToday
                                  ? AppColors.background
                                  : (inMonth ? AppColors.primaryText : AppColors.secondaryText.withValues(alpha: 0.45)),
                            )),
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        height: 6,
                        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          for (final e in events.take(4))
                            Container(
                              width: 6,
                              height: 6,
                              margin: const EdgeInsets.symmetric(horizontal: 1),
                              decoration: BoxDecoration(
                                color: inMonth ? e.color : e.color.withValues(alpha: 0.4),
                                shape: BoxShape.circle,
                              ),
                            ),
                        ]),
                      ),
                    ]),
                  ),
                );
              }),
            ),
        ]),
      const Divider(height: 20),
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Text(DateFormat('EEEE, MMMM d').format(_selected), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      ),
      Expanded(
        child: dayEvents.isEmpty
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => widget.onNewEvent(_selected),
                child: const Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('Nothing on this day. Tap to add an event.', style: TextStyle(color: AppColors.secondaryText)),
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
                children: [
                  for (final e in dayEvents)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Material(
                        color: Color.alphaBlend(e.color.withValues(alpha: 0.16), AppColors.surface),
                        borderRadius: BorderRadius.circular(12),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => widget.onEventTap(e),
                          child: IntrinsicHeight(
                            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              if (e.isTask)
                                TaskCircle(event: e, size: 22, width: 46, onTap: widget.onTaskTap == null ? null : () => widget.onTaskTap!(e))
                              else
                                Container(width: 4, color: e.color),
                              Expanded(
                                child: Padding(
                                  padding: EdgeInsets.fromLTRB(e.isTask ? 0 : 12, 10, 12, 10),
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(monthEntryTitle(e),
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14.5,
                                          color: e.done ? AppColors.secondaryText : null,
                                          decoration: e.done ? TextDecoration.lineThrough : null,
                                          decorationColor: AppColors.secondaryText,
                                        )),
                                    const SizedBox(height: 2),
                                    Text(
                                      [
                                        e.allDay
                                            ? 'All day'
                                            : e.spansDays
                                                ? '${DateFormat.MMMd().format(e.start)} – ${DateFormat.MMMd().format(e.end.subtract(const Duration(microseconds: 1)))}'
                                                : '${t.format(e.start)} – ${t.format(e.end)}',
                                        if (e.location.isNotEmpty) e.location,
                                        e.calendar.name,
                                      ].join(' · '),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: AppColors.secondaryText, fontSize: 12),
                                    ),
                                  ]),
                                ),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    ]);
  }
}

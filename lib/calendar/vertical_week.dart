import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme.dart';
import '../util/fields.dart';
import 'calendar_models.dart';
import 'flipped_timeline.dart';
import 'timeline_layout.dart';

/// The week the usual way up, for phones and narrow panels: each day is a
/// column and the hours run down, so all seven days fit across the screen.
/// Overlaps follow the same rules as the sideways view (timeline_layout.dart),
/// turned on their side.
class VerticalWeek extends StatefulWidget {
  const VerticalWeek({
    super.key,
    required this.days,
    required this.events,
    required this.onEventTap,
    this.onSlotTap,
    this.hourHeight = 52,
  });

  final List<DateTime> days;
  final List<CalendarEvent> events;
  final double hourHeight;
  final void Function(CalendarEvent) onEventTap;
  final void Function(DateTime start, {bool allDay})? onSlotTap;

  @override
  State<VerticalWeek> createState() => _VerticalWeekState();
}

class _VerticalWeekState extends State<VerticalWeek> {
  /// The event under the mouse, if any.
  String? _hovered;

  static const _axis = 30.0;

  /// A title's size in the narrow columns of a whole week.
  static const _titleSize = 12.0;

  /// However short it is, tall enough for a line of its title.
  static const _minTile = 17.0;

  // A single day has the whole width, so its all-day events get real chips.
  bool get _oneDay => widget.days.length == 1;
  double get _chip => _oneDay ? 28 : 18;
  int get _maxChips => _oneDay ? 4 : 2;

  final _scroll = ScrollController();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToMorning());
  }

  @override
  void didUpdateWidget(covariant VerticalWeek old) {
    super.didUpdateWidget(old);
    if (!sameDay(old.days.first, widget.days.first)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToMorning());
    }
  }

  void _scrollToMorning() {
    if (!_scroll.hasClients) return;
    final now = DateTime.now();
    final hour = widget.days.any((d) => sameDay(d, now)) ? math.max(0, now.hour - 1) : 7;
    _scroll.jumpTo((hour * widget.hourHeight).clamp(0.0, _scroll.position.maxScrollExtent));
  }

  @override
  void dispose() {
    _tick?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final allDay = [
      for (final d in widget.days) widget.events.where((e) => e.allDay && e.overlaps(dayStart(d), addDays(d, 1))).toList()..sort(compareAllDay),
    ];
    final chipRows = allDay.fold<int>(0, (m, l) => math.max(m, math.min(l.length, _maxChips + 1)));

    return Column(children: [
      // One slim line per day: "Mon 27", today in a white pill.
      Row(children: [
        const SizedBox(width: _axis),
        for (final d in widget.days)
          Expanded(
            child: GestureDetector(
              onTap: widget.onSlotTap == null ? null : () => widget.onSlotTap!(dayStart(d), allDay: true),
              child: Column(children: [
                Text(DateFormat.E().format(d).substring(0, widget.days.length > 3 ? 1 : 3),
                    style: const TextStyle(color: AppColors.secondaryText, fontSize: 11, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Container(
                  width: 28,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: sameDay(d, now) ? BoxDecoration(color: AppColors.primaryText, borderRadius: BorderRadius.circular(8)) : null,
                  child: Text('${d.day}',
                      style: TextStyle(
                        color: sameDay(d, now) ? AppColors.background : AppColors.primaryText,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      )),
                ),
              ]),
            ),
          ),
      ]),
      if (chipRows > 0) ...[
        const SizedBox(height: 4),
        SizedBox(
          height: chipRows * (_chip + 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(width: _axis),
            for (var i = 0; i < widget.days.length; i++)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: _oneDay ? 4 : 1),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (final e in allDay[i].take(allDay[i].length > _maxChips + 1 ? _maxChips : _maxChips + 1))
                      Padding(padding: const EdgeInsets.only(bottom: 2), child: _block(e, height: _chip)),
                    if (allDay[i].length > _maxChips + 1)
                      SizedBox(
                        height: _chip,
                        child: Center(
                          child: Text(_oneDay ? '+${allDay[i].length - _maxChips} more' : '+${allDay[i].length - _maxChips}',
                              style: const TextStyle(color: AppColors.secondaryText, fontSize: 11.5, fontWeight: FontWeight.w700)),
                        ),
                      ),
                  ]),
                ),
              ),
          ]),
        ),
      ],
      const SizedBox(height: 4),
      const Divider(height: 1),
      Expanded(
        child: SingleChildScrollView(
          controller: _scroll,
          child: SizedBox(
            height: 24 * widget.hourHeight,
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(width: _axis, child: _hours()),
              for (final d in widget.days) Expanded(child: _day(d, now)),
            ]),
          ),
        ),
      ),
    ]);
  }

  Widget _hours() {
    String label(int h) => h == 0 ? '' : (h == 12 ? '12p' : (h < 12 ? '${h}a' : '${h - 12}p'));
    return Stack(children: [
      for (var h = 1; h < 24; h++)
        Positioned(
          top: h * widget.hourHeight - 7,
          right: 4,
          child: Text(label(h), style: const TextStyle(color: AppColors.secondaryText, fontSize: 11)),
        ),
    ]);
  }

  Widget _day(DateTime day, DateTime now) {
    final from = dayStart(day);
    final to = addDays(day, 1);
    return LayoutBuilder(builder: (context, c) {
      final items = [
        for (final e in widget.events)
          if (!e.allDay && e.overlaps(from, to)) TimelineItem(e, e.start.isBefore(from) ? from : e.start, e.end.isAfter(to) ? to : e.end),
      ];
      // A backdrop (a trip's tile) runs behind the rest.
      final back = items.where((i) => i.value.backdrop).toList();
      final front = items.where((i) => !i.value.backdrop).toList();
      // Laid out sideways, then turned: the row's "height" is this column's width.
      for (final group in [back, front]) {
        layoutTimeline(group, dayStart: from, hourWidth: widget.hourHeight, height: c.maxWidth, pad: 1, laneGap: 1, textZone: 17);
      }
      final isToday = sameDay(day, now);
      final nowY = clockHours(now, from) * widget.hourHeight;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: widget.onSlotTap == null
            ? null
            : (d) {
                final minutes = (d.localPosition.dy / widget.hourHeight * 60 / 30).floor() * 30;
                widget.onSlotTap!(DateTime(day.year, day.month, day.day, 0, minutes));
              },
        child: Stack(children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _Grid(widget.hourHeight, isToday ? const Color(0x0DFFFFFF) : null),
            ),
          ),
          for (final i in back)
            Positioned(
              top: i.rect.left,
              left: i.rect.top,
              width: i.rect.height,
              height: i.rect.width,
              child: _tile(i.value, top: i.rect.left, height: i.rect.width),
            ),
          for (final i in front)
            Positioned(
              top: i.rect.left,
              left: i.rect.top,
              width: i.rect.height,
              height: math.max(i.rect.width, _minTile),
              child: MouseRegion(
                onEnter: (_) => setState(() => _hovered = i.value.key),
                onExit: (_) {
                  if (_hovered == i.value.key) setState(() => _hovered = null);
                },
                child: _block(i.value, height: math.max(i.rect.width, _minTile), textHeight: math.max(i.labelWidth, _minTile)),
              ),
            ),
          for (final i in front)
            if (i.value.key == _hovered && titleCutOff(i.value.shownTitle, i.rect.height, compact: true))
              tinyTitleBanner(i.value,
                  left: i.rect.top,
                  top: i.rect.left,
                  room: c.maxWidth,
                  tileWidth: i.rect.height,
                  // This view's tiles are plainer than the week's.
                  fill: Color.alphaBlend(i.value.color.withValues(alpha: i.value.allDay ? 0.4 : 0.32), AppColors.surface),
                  edge: i.value.color.withValues(alpha: 0.6),
                  edgeWidth: 0.8,
                  radius: 4,
                  bar: 0,
                  textSize: 12.5,
                  textPad: 4),
          if (isToday)
            Positioned(
              top: nowY - 1,
              left: 0,
              right: 0,
              child: IgnorePointer(child: Container(height: 2, color: AppColors.primaryText)),
            ),
        ]),
      );
    });
  }

  /// A backdrop: its title stays in sight as the day scrolls.
  Widget _tile(CalendarEvent e, {required double top, required double height}) => Material(
        color: Color.alphaBlend(e.color.withValues(alpha: 0.22), AppColors.surface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4), side: BorderSide(color: e.color.withValues(alpha: 0.6), width: 0.8)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => widget.onEventTap(e),
          child: Align(
            alignment: Alignment.topLeft,
            child: AnimatedBuilder(
              animation: _scroll,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(3, 3, 2, 3),
                child: Text(e.shownTitle,
                    maxLines: 4,
                    overflow: TextOverflow.clip,
                    style: const TextStyle(color: AppColors.primaryText, fontSize: _titleSize, fontWeight: FontWeight.w600, height: 1.15)),
              ),
              builder: (context, child) => Transform.translate(
                offset: Offset(0, ((_scroll.hasClients ? _scroll.offset : 0.0) - top).clamp(0.0, math.max(0.0, height - 56))),
                child: child,
              ),
            ),
          ),
        ),
      );

  /// A narrow event: as many lines of its title as fit, then the time. The
  /// title stays one readable size and wraps: it's never shrunk to fit.
  Widget _block(CalendarEvent e, {required double height, double? textHeight}) {
    final room = (textHeight ?? height) - 4;
    final big = _oneDay;
    final lineHeight = big ? 15.0 : _titleSize * 1.15;
    final titleLines = math.max(1, (room / lineHeight).floor());
    final showTime = !e.allDay && room >= lineHeight * 2 + 13;
    return Material(
      color: Color.alphaBlend(e.color.withValues(alpha: e.allDay ? 0.4 : 0.32), AppColors.surface),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: e.color.withValues(alpha: 0.6), width: 0.8),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => widget.onEventTap(e),
        child: SizedBox(
          height: height,
          child: Padding(
            padding: EdgeInsets.fromLTRB(big ? 8 : 3, big ? 4 : 2, 1, 1),
            child: Column(
                mainAxisSize: MainAxisSize.max,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: e.allDay && big ? MainAxisAlignment.center : MainAxisAlignment.start,
                children: [
                  Flexible(
                    child: Text(e.shownTitle,
                        maxLines: showTime ? titleLines - 1 : titleLines,
                        overflow: TextOverflow.clip,
                        style: TextStyle(
                          color: e.done ? AppColors.secondaryText : AppColors.primaryText,
                          fontSize: big ? 13 : _titleSize,
                          fontWeight: FontWeight.w600,
                          height: 1.15,
                          decoration: e.done ? TextDecoration.lineThrough : null,
                          decorationColor: AppColors.secondaryText,
                        )),
                  ),
                  if (showTime)
                    Text(DateFormat('h:mm').format(e.start),
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: const TextStyle(color: AppColors.secondaryText, fontSize: 10.5, height: 1.2)),
                ]),
          ),
        ),
      ),
    );
  }
}

class _Grid extends CustomPainter {
  _Grid(this.hourHeight, this.fill);

  final double hourHeight;
  final Color? fill;

  @override
  void paint(Canvas canvas, Size size) {
    if (fill != null) canvas.drawRect(Offset.zero & size, Paint()..color = fill!);
    final line = Paint()
      ..color = const Color(0x17FFFFFF)
      ..strokeWidth = 1;
    for (var h = 1; h < 24; h++) {
      canvas.drawLine(Offset(0, h * hourHeight), Offset(size.width, h * hourHeight), line);
    }
    canvas.drawLine(Offset.zero, Offset(0, size.height), line);
  }

  @override
  bool shouldRepaint(covariant _Grid old) => old.hourHeight != hourHeight || old.fill != fill;
}

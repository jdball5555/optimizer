import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui show TextDirection;
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme.dart';
import '../util/fields.dart';
import 'calendar_models.dart';
import 'timeline_layout.dart';
import '../widgets/calm_scrollbar.dart';

/// The week (or day) turned on its side: hours run left → right across the
/// top and each day is a row, so a week reads top-to-bottom like lines in a
/// book. The days share the page's height. An event fills its row top to
/// bottom; events that start together split it into lanes, and one that
/// starts later is drawn on top, past the others' titles (timeline_layout.dart).
class FlippedTimeline extends StatefulWidget {
  const FlippedTimeline({
    super.key,
    required this.days,
    required this.events,
    required this.hourWidth,
    required this.onEventTap,
    this.onSlotTap,
    this.compact = false,
    this.allDayColumn = false,
  });

  /// All-day events beside the date (to its left, in the same tile) rather
  /// than under it, so they have the day's full height to stack in; the
  /// weekday goes under the date to keep the tile narrow.
  final bool allDayColumn;

  final List<DateTime> days;
  final List<CalendarEvent> events;
  final double hourWidth;
  final void Function(CalendarEvent) onEventTap;
  final void Function(DateTime start, {bool allDay})? onSlotTap;

  /// Smaller labels and rows, for a dashboard panel.
  final bool compact;

  @override
  State<FlippedTimeline> createState() => _FlippedTimelineState();
}

class _Row {
  _Row(this.day, this.allDay, this.items);
  final DateTime day;
  final List<CalendarEvent> allDay;
  final List<TimelineItem<CalendarEvent>> items;
}

class _FlippedTimelineState extends State<FlippedTimeline> {
  double get _labelWidth => widget.compact ? (widget.allDayColumn ? 200 : 120) : (widget.allDayColumn ? 290 : 184);
  static const _headerHeight = 30.0;
  static const _scrollRoom = 11.0;
  double get _rowGap => widget.compact ? 4 : 6;
  double get _allDayChip => widget.compact ? 22 : 30;

  /// Rows always share the height; only below this do they stop shrinking
  /// (and the page scrolls).
  double get _minRow => widget.compact ? 34 : 64;

  /// The event under the mouse, drawn on top and opened out to full size.
  String? _hovered;

  final _hBody = ScrollController();
  final _hHeader = ScrollController();
  final _v = ScrollController();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _hBody.addListener(() {
      if (_hHeader.hasClients) _hHeader.jumpTo(_hBody.offset);
    });
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToWorkingHours());
  }

  @override
  void didUpdateWidget(covariant FlippedTimeline old) {
    super.didUpdateWidget(old);
    if (old.hourWidth != widget.hourWidth && _hBody.hasClients) {
      // Keep the same time of day under the left edge while zooming.
      final hourAtLeft = _hBody.offset / old.hourWidth;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_hBody.hasClients) return;
        _hBody.jumpTo((hourAtLeft * widget.hourWidth).clamp(0.0, _hBody.position.maxScrollExtent));
      });
    } else if (!sameDay(old.days.first, widget.days.first)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToWorkingHours());
    }
  }

  void _scrollToWorkingHours() {
    if (!_hBody.hasClients) return;
    final now = DateTime.now();
    final showsToday = widget.days.any((d) => sameDay(d, now));
    final hour = showsToday ? math.max(0, now.hour - 2) : 7;
    _hBody.jumpTo((hour * widget.hourWidth).clamp(0.0, _hBody.position.maxScrollExtent));
  }

  @override
  void dispose() {
    _tick?.cancel();
    _hBody.dispose();
    _hHeader.dispose();
    _v.dispose();
    super.dispose();
  }

  _Row _sortDay(DateTime day) {
    final from = dayStart(day);
    final to = addDays(day, 1);
    final allDay = <CalendarEvent>[];
    final items = <TimelineItem<CalendarEvent>>[];
    for (final e in widget.events) {
      if (!e.overlaps(from, to)) continue;
      if (e.allDay) {
        allDay.add(e);
      } else {
        items.add(TimelineItem(e, e.start.isBefore(from) ? from : e.start, e.end.isAfter(to) ? to : e.end));
      }
    }
    return _Row(day, allDay..sort(compareAllDay), items);
  }

  @override
  Widget build(BuildContext context) {
    final rows = [for (final d in widget.days) _sortDay(d)];
    final width = 24 * widget.hourWidth;
    // Let a mouse drag pan the hours sideways, like a touch screen.
    final dragAnything = ScrollConfiguration.of(context).copyWith(dragDevices: PointerDeviceKind.values.toSet());

    return LayoutBuilder(builder: (context, c) {
      // The days split the height evenly; a busy day packs its events and
      // all-day chips into its share rather than pushing the week off screen.
      final available = c.maxHeight - _headerHeight - 8 - _scrollRoom;
      final share = rows.isEmpty ? _minRow : (available - _rowGap * (rows.length - 1)) / rows.length;
      final height = share.isFinite ? math.max(_minRow, share) : _minRow;
      final heights = [for (final _ in rows) height];

      return Column(
        children: [
          SizedBox(
            height: _headerHeight,
            child: Padding(
              // Lined up with the rows below, which leave room for the scrollbar.
              padding: const EdgeInsets.only(right: _scrollRoom),
              child: Row(
                children: [
                  SizedBox(
                    width: _labelWidth,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(
                        DateTime.now().timeZoneName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.secondaryText, fontSize: 11),
                      ),
                    ),
                  ),
                  Expanded(
                    child: withoutAutoScrollbar(
                      context,
                      SingleChildScrollView(
                        controller: _hHeader,
                        scrollDirection: Axis.horizontal,
                        physics: const NeverScrollableScrollPhysics(),
                        child: SizedBox(width: width, child: _hourHeader()),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            // The app-wide scroll behavior gives it its scrollbar (CalmScrollbar).
            child: SingleChildScrollView(
              controller: _v,
              // Room for the scrollbars (down the right, across the bottom)
              // beside the rows rather than over them.
              padding: const EdgeInsets.only(right: _scrollRoom),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: _labelWidth,
                    child: Column(children: [
                      for (var i = 0; i < rows.length; i++)
                        Padding(
                          padding: EdgeInsets.only(bottom: i == rows.length - 1 ? 0 : _rowGap, right: 6),
                          child: _dayLabel(rows[i], heights[i], first: i == 0),
                        ),
                    ]),
                  ),
                  Expanded(
                    child: ScrollConfiguration(
                      behavior: dragAnything,
                      child: SingleChildScrollView(
                        controller: _hBody,
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.only(bottom: _scrollRoom),
                        child: SizedBox(
                          width: width,
                          child: Column(children: [
                            for (var i = 0; i < rows.length; i++)
                              Padding(
                                padding: EdgeInsets.only(bottom: i == rows.length - 1 ? 0 : _rowGap),
                                child: _dayTimeline(rows[i], heights[i], width),
                              ),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    });
  }

  Widget _hourHeader() {
    final now = DateTime.now();
    final showsToday = widget.days.any((d) => sameDay(d, now));
    String label(int h) => h == 0
        ? '12am'
        : h == 12
            ? 'noon'
            : h < 12
                ? '${h}am'
                : '${h - 12}pm';
    final nowX = (now.hour + now.minute / 60) * widget.hourWidth;
    return Stack(clipBehavior: Clip.none, children: [
      for (var h = 0; h < 24; h++)
        Positioned(
          left: h * widget.hourWidth + 6,
          top: 8,
          child: Text(
            label(h),
            style: TextStyle(
              color: showsToday && h == now.hour ? AppColors.primaryText : AppColors.secondaryText,
              fontSize: 11,
              fontWeight: showsToday && h == now.hour ? FontWeight.w700 : FontWeight.w500,
              letterSpacing: 0.2,
            ),
          ),
        ),
      if (showsToday)
        Positioned(
          left: nowX - 24,
          top: 4,
          child: Container(
            width: 48,
            padding: const EdgeInsets.symmetric(vertical: 3),
            decoration: BoxDecoration(color: AppColors.primaryText, borderRadius: BorderRadius.circular(100)),
            child: Text(
              DateFormat('h:mm').format(now),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.background, fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
        ),
    ]);
  }

  Widget _dayLabel(_Row r, double height, {required bool first}) {
    if (widget.allDayColumn) return _dayTile(r, height);
    final now = DateTime.now();
    final isToday = sameDay(r.day, now);
    final relative = isToday
        ? 'Today'
        : sameDay(r.day, addDays(now, 1))
            ? 'Tomorrow'
            : sameDay(r.day, addDays(now, -1))
                ? 'Yesterday'
                : (first || r.day.day == 1)
                    ? DateFormat('MMMM').format(r.day)
                    : null;
    final textScale = MediaQuery.textScalerOf(context).scale(1.0);
    final big = widget.compact ? 18.0 : 24.0;

    // Measured by hand from the row's height so nothing ever spills out:
    // the date, then as many whole all-day chips as fit, then "+N more".
    const gap = 4.0;
    final padTop = widget.compact ? 4.0 : 9.0;
    final padBottom = widget.compact ? 4.0 : 6.0;
    final dateH = (widget.compact ? big * 1.3 : (relative != null ? math.max(big * 1.45, 34.0) : big * 1.3)) * textScale;
    final afterDate = widget.compact ? 3.0 : 7.0;
    final room = height - padTop - padBottom - 2 /* border */ - dateH - afterDate;
    final n = r.allDay.length;
    final chipH = (n > 1 ? ((room - gap) / 2).clamp(18.0, _allDayChip) : math.min(_allDayChip, room)).floorToDouble();
    final slots = chipH < 16 ? 0 : ((room + gap) / (chipH + gap)).floor();
    final shown = n <= slots ? n : math.max(0, slots - 1);
    final hidden = n - shown;
    // No room even for "+N more" under the date: show the count beside it.
    final countBeside = hidden > 0 && slots == 0;

    final more = TextButton(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.centerLeft,
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: () => _showAllDay(r),
      child: Text(countBeside ? '+$hidden' : '+$hidden more',
          style: const TextStyle(color: AppColors.secondaryText, fontSize: 12, fontWeight: FontWeight.w600)),
    );

    return Container(
      height: height,
      padding: EdgeInsets.fromLTRB(10, padTop, 8, padBottom),
      decoration: BoxDecoration(
        color: isToday ? AppColors.surfaceHigh : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isToday ? const Color(0x40FFFFFF) : AppColors.border),
      ),
      child: ClipRect(
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: dateH,
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: widget.onSlotTap == null ? null : () => widget.onSlotTap!(dayStart(r.day), allDay: true),
                  child: Row(
                    children: [
                      Container(
                        constraints: BoxConstraints(minWidth: big * 1.55),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        alignment: Alignment.center,
                        decoration: isToday ? BoxDecoration(color: AppColors.primaryText, borderRadius: BorderRadius.circular(9)) : null,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '${r.day.day}',
                            style: TextStyle(
                              color: isToday ? AppColors.background : AppColors.primaryText,
                              fontSize: big,
                              fontWeight: FontWeight.w700,
                              height: 1.2,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                DateFormat(widget.compact ? 'EEE' : 'EEEE').format(r.day),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: AppColors.primaryText,
                                  fontSize: widget.compact ? 12 : 14,
                                  fontWeight: FontWeight.w600,
                                  height: 1.15,
                                ),
                              ),
                              if (relative != null && !widget.compact)
                                Text(relative,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: AppColors.secondaryText, fontSize: 11.5, height: 1.2)),
                            ],
                          ),
                        ),
                      ),
                      if (countBeside) more,
                    ],
                  ),
                ),
              ),
              if (shown > 0 || (hidden > 0 && !countBeside)) SizedBox(height: afterDate),
              for (var i = 0; i < shown; i++) ...[
                if (i > 0) const SizedBox(height: gap),
                SizedBox(height: chipH, child: EventBlock(event: r.allDay[i], onTap: widget.onEventTap, compact: widget.compact)),
              ],
              if (hidden > 0 && !countBeside) ...[
                if (shown > 0) const SizedBox(height: gap),
                SizedBox(height: chipH, child: more),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The day's tile with its all-day events on the left, stacked the full
  /// height of the row, and the date on the right with the weekday under it.
  Widget _dayTile(_Row r, double height) {
    final now = DateTime.now();
    final isToday = sameDay(r.day, now);
    const gap = 3.0;
    const pad = 6.0;
    final room = height - pad * 2 - 2 /* border */;
    final n = r.allDay.length;
    final chipH = n == 0 ? 26.0 : ((room - gap * (n - 1)) / n).clamp(18.0, 28.0).floorToDouble();
    final slots = ((room + gap) / (chipH + gap)).floor();
    final shown = n <= slots ? n : math.max(0, slots - 1);
    final hidden = n - shown;
    final big = widget.compact ? 18.0 : 22.0;
    void addAllDay() => widget.onSlotTap?.call(dayStart(r.day), allDay: true);

    return Container(
      height: height,
      padding: const EdgeInsets.fromLTRB(pad, pad, 4, pad),
      decoration: BoxDecoration(
        color: isToday ? AppColors.surfaceHigh : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isToday ? const Color(0x40FFFFFF) : AppColors.border),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onSlotTap == null ? null : addAllDay,
            child: ClipRect(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var i = 0; i < shown; i++) ...[
                  if (i > 0) const SizedBox(height: gap),
                  SizedBox(height: chipH, child: EventBlock(event: r.allDay[i], onTap: widget.onEventTap, compact: widget.compact)),
                ],
                if (hidden > 0) ...[
                  if (shown > 0) const SizedBox(height: gap),
                  SizedBox(
                    height: chipH,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        alignment: Alignment.centerLeft,
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => _showAllDay(r),
                      child: Text('+$hidden more', style: const TextStyle(color: AppColors.secondaryText, fontSize: 12, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ]),
            ),
          ),
        ),
        // The date, the weekday under it.
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: widget.onSlotTap == null ? null : addAllDay,
          child: SizedBox(
            width: widget.compact ? 44 : 56,
            // Shrinks to fit a short row rather than spilling out of it.
            child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.topCenter,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    constraints: BoxConstraints(minWidth: big * 1.55),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    alignment: Alignment.center,
                    decoration: isToday ? BoxDecoration(color: AppColors.primaryText, borderRadius: BorderRadius.circular(9)) : null,
                    child: Text(
                      '${r.day.day}',
                      style: TextStyle(
                        color: isToday ? AppColors.background : AppColors.primaryText,
                        fontSize: big,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    DateFormat('EEE').format(r.day),
                    maxLines: 1,
                    style: TextStyle(color: isToday ? AppColors.primaryText : AppColors.secondaryText, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ])),
          ),
        ),
      ]),
    );
  }

  void _showAllDay(_Row r) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(DateFormat('EEEE, MMMM d').format(r.day)),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final e in r.allDay)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: SizedBox(
                    height: 34,
                    child: EventBlock(
                        event: e,
                        onTap: (e) {
                          Navigator.pop(ctx);
                          widget.onEventTap(e);
                        }),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  /// The day's event blocks, laid out by [layoutTimeline].
  List<Widget> _events(_Row r, double height, double width) {
    // A backdrop (a trip's tile) runs behind the rest, which lay out as if it
    // weren't there.
    final back = r.items.where((i) => i.value.backdrop).toList();
    final front = r.items.where((i) => !i.value.backdrop).toList();
    layoutTimeline(front, dayStart: dayStart(r.day), hourWidth: widget.hourWidth, height: height);
    layoutTimeline(back, dayStart: dayStart(r.day), hourWidth: widget.hourWidth, height: height);
    final key = '${r.day.millisecondsSinceEpoch}';
    final hovered = front.where((i) => '$key|${i.value.id}' == _hovered).firstOrNull;
    return [
      for (final i in back)
        Positioned.fromRect(
          key: ValueKey('$key|${i.value.id}'),
          rect: i.rect,
          child: EventBlock(
            event: i.value,
            onTap: widget.onEventTap,
            compact: widget.compact,
            labelWidth: math.min(i.rect.width, 280),
            stick: _hBody,
            stickFrom: i.rect.left,
          ),
        ),
      // Hovering only lights one up. It stays in its place in the stack, so an
      // event inside a bigger one can always be reached.
      for (final i in front)
        Builder(
            key: ValueKey('$key|${i.value.id}'),
            builder: (context) {
              final id = '$key|${i.value.id}';
              final open = identical(i, hovered);
              return Positioned.fromRect(
                rect: i.rect,
                child: MouseRegion(
                  onEnter: (_) => setState(() => _hovered = id),
                  onExit: (_) {
                    if (_hovered == id) setState(() => _hovered = null);
                  },
                  child: EventBlock(
                    event: i.value,
                    onTap: widget.onEventTap,
                    compact: widget.compact,
                    raised: i.depth > 0 || back.isNotEmpty,
                    open: open,
                    labelWidth: open ? null : i.labelWidth,
                  ),
                ),
              );
            }),
      if (hovered != null && titleCutOff(hovered.value.shownTitle, math.min(hovered.rect.width, hovered.labelWidth), compact: widget.compact))
        tinyTitleBanner(hovered.value,
            left: hovered.rect.left,
            top: hovered.rect.top,
            tileWidth: hovered.rect.width,
            fill: eventFill(hovered.value, open: true),
            edge: eventHoverEdge(hovered.value),
            radius: widget.compact ? 6 : 9,
            bar: widget.compact ? 3 : 4,
            textSize: widget.compact ? 11.5 : 13,
            textPad: widget.compact ? 5 : 7,
            // To what's in view, as the hours scroll sideways.
            room: _hBody.positions.length == 1 ? math.min(width, _hBody.offset + _hBody.position.viewportDimension) : width),
    ];
  }

  Widget _dayTimeline(_Row r, double height, double width) {
    final now = DateTime.now();
    final isToday = sameDay(r.day, now);
    final from = dayStart(r.day);
    double x(DateTime t) => clockHours(t, from) * widget.hourWidth;
    final weekend = r.day.weekday >= DateTime.saturday;

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: widget.onSlotTap == null
            ? null
            : (d) {
                final minutes = (d.localPosition.dx / widget.hourWidth * 60 / 30).floor() * 30;
                widget.onSlotTap!(DateTime(r.day.year, r.day.month, r.day.day, 0, minutes));
              },
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _GridPainter(
                    hourWidth: widget.hourWidth,
                    fill: isToday ? AppColors.surfaceHigh : (weekend ? const Color(0xFF0B1019) : AppColors.surface),
                    pastUntil: isToday ? x(now) : (r.day.isBefore(dayStart(now)) ? width : 0),
                  ),
                ),
              ),
              ..._events(r, height, width),
              if (isToday)
                Positioned(
                  left: x(now) - 1,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Container(
                      width: 2,
                      decoration: const BoxDecoration(
                        color: AppColors.primaryText,
                        boxShadow: [BoxShadow(color: Color(0x80FFFFFF), blurRadius: 6)],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// An event on the timeline: a tinted block with a solid edge in the event's
/// color. Shows as much as its size allows — title, then time, then place.
///
/// A [labelWidth] narrower than the block stops the label before whatever is
/// drawn on top of it.
/// An event tile's color, a little brighter when [open] (hovered).
Color eventFill(CalendarEvent e, {bool open = false}) => Color.alphaBlend(e.color.withValues(alpha: open ? 0.4 : 0.28), AppColors.surface);

/// A hovered tile's edge: its own color, a little stronger.
Color eventHoverEdge(CalendarEvent e) => e.color.withValues(alpha: 0.7);

/// Narrower than this, a tile is showing a few letters at most.
const _tinyTile = 64.0;

/// A tiny tile, [visible] wide, can't show its [title].
bool titleCutOff(String title, double visible, {bool compact = false}) {
  if (visible >= _tinyTile) return false;
  final room = visible - (compact ? 13 : 18);
  return room < _titleWidth(title, compact ? 11.5 : 13);
}

double _titleWidth(String title, double size) {
  final p = TextPainter(
    text: TextSpan(text: title, style: TextStyle(fontSize: size, fontWeight: FontWeight.w600)),
    textDirection: ui.TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final width = p.width;
  p.dispose();
  return width;
}

/// A tiny tile, reaching out along its top while you're on it, to show its
/// name: the tile's own fill, edge and title, with no line where the two meet.
/// It ignores the mouse, so whatever's under it can still be reached.
Widget tinyTitleBanner(
  CalendarEvent e, {
  required double left,
  required double top,
  required double room,
  required double tileWidth,
  required Color fill,
  required Color edge,
  double edgeWidth = 1,
  double radius = 9,
  double bar = 4,
  double textSize = 13,
  double textPad = 7,
}) {
  const height = 22.0, most = 320.0;
  final title = _titleWidth(e.shownTitle, textSize);
  var width = math.min(math.min(title + bar + textPad * 2 + 2, most), room);
  var from = left;
  // No room to reach right: it reaches left instead, ending where the tile
  // does, with the name before the tile.
  if (left + width > room) {
    width = math.min(math.min(title + tileWidth + textPad * 2 + 2, most), room);
    from = math.max(0.0, left + tileWidth - width);
  }
  final under = left - from;
  final nameFirst = under > 0 && under >= width - under - tileWidth;
  final corner = Radius.circular(radius), square = Radius.zero;
  final shape = BorderRadius.only(
    topLeft: corner,
    topRight: corner,
    // Square where the tile carries on below.
    bottomLeft: under <= 0 ? square : corner,
    bottomRight: under + tileWidth >= width ? square : corner,
  );
  return Positioned(
    left: from,
    top: top,
    width: width,
    height: height,
    child: IgnorePointer(
      child: Stack(key: const ValueKey('tiny-title'), children: [
        Positioned.fill(
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(color: fill, borderRadius: shape),
            // Over what's inside, as a tile's edge is.
            foregroundDecoration: BoxDecoration(border: Border.all(color: edge, width: edgeWidth), borderRadius: shape),
            child: Stack(children: [
              // Exactly where the tile's own strip is, so the two are one.
              if (bar > 0) Positioned(left: under, width: bar, top: 0, bottom: 0, child: ColoredBox(color: e.color)),
              Positioned(
                left: nameFirst ? textPad : under + bar + textPad,
                right: nameFirst ? width - under + 2 : 2,
                top: 0,
                bottom: 0,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(e.shownTitle,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: AppColors.primaryText, fontSize: textSize, fontWeight: FontWeight.w600, height: 1.2)),
                ),
              ),
            ]),
          ),
        ),
        // Opens the bottom edge where it meets the tile, to read as one shape.
        Positioned(
          left: under + math.max(bar, edgeWidth),
          width: math.max(0, tileWidth - edgeWidth - math.max(bar, edgeWidth)),
          bottom: 0,
          height: edgeWidth + 0.5,
          child: ColoredBox(color: fill),
        ),
      ]),
    ),
  );
}

class EventBlock extends StatelessWidget {
  const EventBlock({
    super.key,
    required this.event,
    required this.onTap,
    this.compact = false,
    this.raised = false,
    this.open = false,
    this.labelWidth,
    this.stick,
    this.stickFrom = 0,
  });

  /// A block too long to see all of: its title stays in sight as the hours
  /// scroll sideways. [stickFrom] is where the block starts.
  final ScrollController? stick;
  final double stickFrom;

  final CalendarEvent event;
  final void Function(CalendarEvent) onTap;
  final bool compact;

  /// Drawn over other events: an outline in the page color and a shadow.
  final bool raised;

  /// Hovered: a little brighter.
  final bool open;
  final double? labelWidth;

  @override
  Widget build(BuildContext context) {
    final t = DateFormat.jm();
    final time = event.allDay
        ? 'All day'
        : event.spansDays
            ? '${DateFormat.MMMd().format(event.start)} – ${DateFormat.MMMd().format(event.end.subtract(const Duration(microseconds: 1)))}'
            : '${t.format(event.start)} – ${t.format(event.end)}';
    // Past events look just like ones to come.
    final fill = eventFill(event, open: open);
    final radius = BorderRadius.circular(compact ? 6 : 9);
    final bar = compact ? 3.0 : 4.0;

    return _block(fill, radius, bar, time);
  }

  Widget _block(Color fill, BorderRadius radius, double bar, String time) {
    return Opacity(
      opacity: 1,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: raised ? [BoxShadow(color: const Color(0xCC000000), blurRadius: 8, offset: const Offset(0, 2))] : null,
        ),
        child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(
              color: open ? eventHoverEdge(event) : (raised ? AppColors.background : event.color.withValues(alpha: 0.35)),
              width: raised && !open ? 1.5 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => onTap(event),
            child: LayoutBuilder(builder: (context, c) {
              final background = Container(color: fill);
              if (c.maxWidth < 22) {
                return Stack(
                    fit: StackFit.expand,
                    children: [background, Align(alignment: Alignment.centerLeft, child: Container(width: bar, color: event.color))]);
              }

              // Add lines only while they fit: title, then time, then place.
              final textScale = MediaQuery.textScalerOf(context).scale(1.0);
              final titleSize = compact ? 11.5 : 13.0;
              final smallSize = compact ? 10.5 : 11.5;
              final titleH = (titleSize * 1.25 * textScale).ceilToDouble() + 1;
              final smallH = (smallSize * 1.35 * textScale).ceilToDouble() + 1;
              final pad = c.maxHeight >= titleH + 10 ? 5.0 : 0.0;
              final room = c.maxHeight - pad * 2;
              final titleLines = room >= titleH * 2 + smallH * 2 && c.maxWidth > 90 ? 2 : 1;
              final showTime = !event.allDay && room >= titleH * titleLines + smallH;
              final showPlace = event.location.isNotEmpty && room >= titleH * titleLines + smallH * (showTime ? 2 : 1);
              final textWidth = math.max(0.0, math.min(labelWidth ?? c.maxWidth, c.maxWidth) - bar - (compact ? 10 : 14));
              if (c.maxWidth < 22 || room <= 0 || textWidth <= 0) {
                return Stack(
                    fit: StackFit.expand,
                    children: [background, Align(alignment: Alignment.centerLeft, child: Container(width: bar, color: event.color))]);
              }

              return Stack(fit: StackFit.expand, children: [
                background,
                Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Container(width: bar, color: event.color),
                  _Sticky(
                    scroll: stick,
                    from: stickFrom,
                    room: math.max(0.0, c.maxWidth - textWidth - bar - (compact ? 10 : 14)),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 7, vertical: pad),
                      child: SizedBox(
                        width: textWidth,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: c.maxHeight < 46 ? Alignment.centerLeft : Alignment.topLeft,
                          child: SizedBox(
                            width: textWidth,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  event.shownTitle,
                                  maxLines: titleLines,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: event.done ? AppColors.secondaryText : AppColors.primaryText,
                                    fontSize: titleSize,
                                    fontWeight: FontWeight.w600,
                                    height: 1.2,
                                    decoration: event.done ? TextDecoration.lineThrough : null,
                                    decorationColor: AppColors.secondaryText,
                                  ),
                                ),
                                if (showTime)
                                  Text(time,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(color: AppColors.secondaryText, fontSize: smallSize, height: 1.3)),
                                if (showPlace)
                                  Text(event.location,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(color: AppColors.secondaryText, fontSize: smallSize, height: 1.3)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ]),
              ]);
            }),
          ),
        ),
      ),
    );
  }
}

/// Keeps a block's title in sight while the hours scroll sideways.
class _Sticky extends StatelessWidget {
  const _Sticky({required this.scroll, required this.from, required this.room, required this.child});

  final ScrollController? scroll;
  final double from;
  final double room;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final s = scroll;
    if (s == null) return child;
    return AnimatedBuilder(
      animation: s,
      child: child,
      builder: (context, child) => Transform.translate(
        offset: Offset(((s.hasClients ? s.offset : 0.0) - from).clamp(0.0, room), 0),
        child: child,
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({required this.hourWidth, required this.fill, required this.pastUntil});

  final double hourWidth;
  final Color fill;

  /// Everything left of this x is in the past and is shaded.
  final double pastUntil;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = fill);
    if (pastUntil > 0) {
      canvas.drawRect(Rect.fromLTWH(0, 0, math.min(pastUntil, size.width), size.height), Paint()..color = const Color(0x33000000));
    }
    final hour = Paint()
      ..color = const Color(0x17FFFFFF)
      ..strokeWidth = 1;
    final half = Paint()
      ..color = const Color(0x0AFFFFFF)
      ..strokeWidth = 1;
    for (var h = 1; h < 24; h++) {
      final x = h * hourWidth;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), hour);
    }
    for (var h = 0; h < 24; h++) {
      final x = h * hourWidth + hourWidth / 2;
      for (var y = 4.0; y < size.height; y += 6) {
        canvas.drawLine(Offset(x, y), Offset(x, math.min(size.height, y + 2)), half);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) => old.hourWidth != hourWidth || old.fill != fill || old.pastUntil != pastUntil;
}

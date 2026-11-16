import 'dart:math';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../calendar/calendar_models.dart';
import '../theme.dart';
import '../util/fields.dart';
import 'trip_models.dart';
import 'trip_zones.dart';

const _hourHeight = 46.0, _gutter = 48.0, _gap = 6.0, _minDay = 136.0, _ribbon = 26.0, _shortest = 26.0;

/// The minutes of the day a tile takes up at its shortest, so short ones can
/// be read and don't sit on top of each other.
const _shortestMinutes = _shortest / _hourHeight * 60;

/// Part of something on one day. A drive past midnight has one on each.
class _Piece {
  _Piece(this.event, this.from, this.to);

  final CalendarEvent event;
  final int from;
  final int to;
  int lane = 0;
  int lanes = 1;

  int get end => max(to, from + _shortestMinutes.ceil());
}

/// Sets side by side whatever happens at the same time.
void _setLanes(List<_Piece> pieces) {
  pieces.sort((a, b) => a.from.compareTo(b.from));
  var group = <_Piece>[];
  final ends = <int>[];
  var until = -1;
  void close() {
    final count = ends.length;
    for (final p in group) {
      p.lanes = count;
    }
    group = [];
    ends.clear();
  }

  for (final p in pieces) {
    if (group.isNotEmpty && p.from >= until) close();
    final free = ends.indexWhere((e) => e <= p.from);
    if (free < 0) {
      ends.add(p.end);
      p.lane = ends.length - 1;
    } else {
      ends[free] = p.end;
      p.lane = free;
    }
    group.add(p);
    until = max(until, p.end);
  }
  close();
}

/// A trip's own calendar: a panel for each day, with only the hours that
/// matter. Stays and rental cars run across the top as ribbons, because they last the whole
/// time. Clicking an empty spot adds something at that time. Every day runs on
/// the clock where you are that day, and says which that is.
class TripBoard extends StatefulWidget {
  const TripBoard({super.key, required this.trip, required this.onOpen, required this.onSlot});

  final Trip trip;
  final void Function(String id) onOpen;
  final void Function(DateTime start) onSlot;

  @override
  State<TripBoard> createState() => _TripBoardState();
}

class _TripBoardState extends State<TripBoard> {
  final _across = ScrollController();
  final _acrossTop = ScrollController();

  @override
  void initState() {
    super.initState();
    _across.addListener(() {
      if (_acrossTop.hasClients) _acrossTop.jumpTo(_across.offset);
    });
  }

  @override
  void dispose() {
    _across.dispose();
    _acrossTop.dispose();
    super.dispose();
  }

  static TripItemKind _kindOf(CalendarEvent e) => TripItemKind.values.byName(e.calendar.id);

  /// These last too long to be tiles, so they run across the top.
  static bool _isRibbon(CalendarEvent e) => _kindOf(e).hasTwoEnds;

  /// Each event from when the clock where it starts says it does, for as long
  /// as it really takes. Past midnight, it carries on to the next day.
  List<List<_Piece>> _pieces(List<DateTime> days, List<CalendarEvent> events) {
    final out = [for (final _ in days) <_Piece>[]];
    for (final e in events) {
      final wall = wallOf(e.start, widget.trip.zones[e.id]!.$1);
      var n = days.indexWhere((d) => sameDay(d, wall));
      if (n < 0) continue;
      var from = wall.hour * 60 + wall.minute;
      var left = e.end.difference(e.start).inMinutes;
      while (left > 0 && n < days.length) {
        final take = min(left, 1440 - from);
        out[n].add(_Piece(e, from, from + take));
        left -= take;
        from = 0;
        n++;
      }
    }
    return out;
  }

  /// The clock on [day], and on it by the end if you change zones that day: "CST to PST".
  String _zonesOn(DateTime day) {
    final noon = DateTime.utc(day.year, day.month, day.day, 12);
    final (morning, night) = widget.trip.zonesOn(day);
    final a = zoneLabel(fromWall(noon, morning), morning), b = zoneLabel(fromWall(noon, night), night);
    return a == b ? a : '$a to $b';
  }

  String _times(CalendarEvent e) {
    final (start, end) = widget.trip.zones[e.id]!;
    // Only just a time, whatever size its tile is to be read.
    if (widget.trip.items.where((i) => i.id == e.id).firstOrNull?.oneTime == true) return clockIn(e.start, start);
    return '${clockIn(e.start, start)} – ${clockIn(e.end, end)}';
  }

  @override
  Widget build(BuildContext context) {
    final days = widget.trip.days;
    final events = widget.trip.itemEvents;
    final stays = events.where(_isRibbon).toList()..sort((a, b) => a.start.compareTo(b.start));
    final timed = events.where((e) => !_isRibbon(e)).toList();
    final pieces = _pieces(days, timed);
    for (final p in pieces) {
      _setLanes(p.where((x) => !x.event.backdrop).toList());
    }
    // Waking hours, and whatever's planned outside them.
    final flat = pieces.expand((p) => p);
    final firstHour = flat.isEmpty ? 7 : min(7, flat.map((p) => p.from).reduce(min) ~/ 60);
    final lastHour = flat.isEmpty ? 22 : max(22, (flat.map((p) => p.end).reduce(max) / 60).ceil()).clamp(0, 24);
    final height = (lastHour - firstHour) * _hourHeight;

    return LayoutBuilder(builder: (context, c) {
      final room = c.maxWidth - _gutter;
      final width = max(_minDay, (room - _gap * (days.length - 1)) / days.length);
      final total = width * days.length + _gap * (days.length - 1);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const SizedBox(width: _gutter),
          Expanded(
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: SingleChildScrollView(
                controller: _acrossTop,
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                child: SizedBox(
                  width: total,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      for (final (n, d) in days.indexed) ...[
                        if (n > 0) const SizedBox(width: _gap),
                        SizedBox(width: width, child: _DayHeading(day: d, zones: _zonesOn(d))),
                      ],
                    ]),
                    if (stays.isNotEmpty) _ribbons(stays, days, width, total),
                  ]),
                ),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Expanded(
          child: SingleChildScrollView(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: _gutter, height: height, child: _HourLabels(first: firstHour, last: lastHour)),
              Expanded(
                child: SingleChildScrollView(
                  controller: _across,
                  scrollDirection: Axis.horizontal,
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final (n, d) in days.indexed) ...[
                      if (n > 0) const SizedBox(width: _gap),
                      _dayPanel(d, pieces[n], width, height, firstHour),
                    ],
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ]);
    });
  }

  Widget _ribbons(List<CalendarEvent> stays, List<DateTime> days, double width, double total) {
    double x(DateTime wall) {
      final n = days.indexWhere((d) => sameDay(d, wall));
      if (n < 0) return wall.isBefore(days.first) ? 0 : total;
      return n * (width + _gap) + (wall.hour * 60 + wall.minute) / 1440 * width;
    }

    double startOf(CalendarEvent s) => x(wallOf(s.start, widget.trip.zones[s.id]!.$1));
    double endOf(CalendarEvent s) => x(wallOf(s.end, widget.trip.zones[s.id]!.$2));

    final lanes = <double>[];
    final placed = <(CalendarEvent, int)>[];
    for (final s in stays) {
      final free = lanes.indexWhere((e) => e <= startOf(s));
      final lane = free < 0 ? lanes.length : free;
      if (free < 0) lanes.add(0);
      lanes[lane] = endOf(s);
      placed.add((s, lane));
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        height: lanes.length * (_ribbon + 4) - 4,
        child: Stack(children: [
          for (final (s, lane) in placed)
            Positioned(
              left: startOf(s),
              top: lane * (_ribbon + 4),
              height: _ribbon,
              width: max(_ribbon * 2, endOf(s) - startOf(s)),
              child: _Tinted(
                color: s.color,
                radius: _ribbon / 2,
                tooltip: '${s.title}: ${_times(s)}',
                onTap: () => widget.onOpen(s.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(children: [
                    Icon(_kindOf(s).icon, size: 14, color: s.color),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text(s.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
                  ]),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _dayPanel(DateTime day, List<_Piece> pieces, double width, double height, int firstHour) {
    double top(int minutes) => (minutes - firstHour * 60) / 60 * _hourHeight;
    final behind = pieces.where((p) => p.event.backdrop).toList();
    final over = pieces.where((p) => !p.event.backdrop).toList();
    final hours = height / _hourHeight;

    Widget tile(_Piece p, double left, double right) {
      final h = max(_shortest, (p.to - p.from) / 60 * _hourHeight);
      return Positioned(
          top: top(p.from) + 1,
          left: left,
          right: right,
          height: h - 2,
          child: _Tile(event: p.event, times: _times(p.event), height: h - 2, onTap: () => widget.onOpen(p.event.id)));
    }

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
      foregroundDecoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        Positioned.fill(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                final minutes = d.localPosition.dy / _hourHeight * 60 + firstHour * 60;
                widget.onSlot(DateTime(day.year, day.month, day.day, 0, minutes ~/ 30 * 30));
              },
              child: CustomPaint(painter: _HourLines(hours.round())),
            ),
          ),
        ),
        for (final p in behind) tile(p, 4, 4),
        for (final p in over)
          () {
            // Over a drive, its stops leave the drive showing down one side.
            final edge = behind.any((b) => b.from < p.to && p.from < b.to) ? 18.0 : 4.0;
            final each = (width - edge - 4) / p.lanes;
            return tile(p, edge + p.lane * each, 4 + (p.lanes - p.lane - 1) * each);
          }(),
      ]),
    );
  }
}

class _DayHeading extends StatelessWidget {
  const _DayHeading({required this.day, required this.zones});

  final DateTime day;
  final String zones;

  @override
  Widget build(BuildContext context) {
    final today = sameDay(day, DateTime.now());
    return Padding(
      padding: const EdgeInsets.only(left: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          today ? 'TODAY' : DateFormat('EEE').format(day).toUpperCase(),
          style: const TextStyle(color: AppColors.secondaryText, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.1),
        ),
        const SizedBox(height: 1),
        Text(DateFormat('MMM d').format(day), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        Text(zones,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.secondaryText, fontSize: 11, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class _HourLabels extends StatelessWidget {
  const _HourLabels({required this.first, required this.last});

  final int first;
  final int last;

  @override
  Widget build(BuildContext context) => Stack(clipBehavior: Clip.none, children: [
        for (var h = first + 1; h < last; h++)
          Positioned(
            top: (h - first) * _hourHeight - 7,
            right: 8,
            child: Text(DateFormat('h a').format(DateTime(2000, 1, 1, h)), style: const TextStyle(color: AppColors.secondaryText, fontSize: 10.5)),
          ),
      ]);
}

class _HourLines extends CustomPainter {
  const _HourLines(this.hours);

  final int hours;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()..color = AppColors.faint;
    for (var h = 1; h < hours; h++) {
      canvas.drawLine(Offset(0, h * _hourHeight), Offset(size.width, h * _hourHeight), line);
    }
  }

  @override
  bool shouldRepaint(_HourLines old) => old.hours != hours;
}

/// Something's color, as a soft fill. Hovering brightens it; it never grows.
class _Tinted extends StatelessWidget {
  const _Tinted({required this.color, required this.radius, required this.onTap, required this.child, this.tooltip});

  final Color color;
  final double radius;
  final VoidCallback onTap;
  final Widget child;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final body = Material(
      color: Color.alphaBlend(color.withValues(alpha: 0.36), AppColors.surface),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: BorderSide(color: color.withValues(alpha: 0.8))),
      child: InkWell(onTap: onTap, hoverColor: const Color(0x14FFFFFF), child: child),
    );
    return tooltip == null ? body : Tooltip(message: tooltip!, child: body);
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.event, required this.times, required this.height, required this.onTap});

  final CalendarEvent event;
  final String times;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final kind = TripItemKind.values.byName(event.calendar.id);
    final showTime = height >= 42;
    final lines = ((height - 8 - (showTime ? 30 : 0)) / 16).floor().clamp(1, 4);
    return _Tinted(
      color: event.color,
      radius: 9,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 6, 0),
        // Whatever doesn't fit a short tile is cut off by it.
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minHeight: 0,
          maxHeight: double.infinity,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 1, right: 5), child: Icon(kind.icon, size: 13, color: event.color)),
              Expanded(
                child: Text(event.title,
                    maxLines: lines,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, height: 1.25)),
              ),
            ]),
            if (showTime)
              Text(times, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 11, height: 1.35)),
          ]),
        ),
      ),
    );
  }
}

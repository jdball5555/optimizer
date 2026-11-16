import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme.dart';
import 'trip_models.dart';
import 'trip_schedule.dart';
import 'trip_zones.dart';

const _timeWidth = 92.0, _railWidth = 30.0;

/// Where the dots sit, level with the first line of a title.
const _eventDotY = 14.0, _stopDotY = 11.0;

/// The trip day by day. Each day has its own line: when each thing starts on
/// the left, a dot on the line, and briefly what it is on the right. The day
/// it's under is the day where it happens.
class TripItinerary extends StatelessWidget {
  const TripItinerary({super.key, required this.trip, required this.onOpen, required this.empty});

  final Trip trip;
  final void Function(String id) onOpen;

  /// What to show with nothing planned yet.
  final Widget empty;

  Widget _row(ScheduleRow row, _Line line) => switch (row) {
        ScheduleEvent(:final entry) => _EventRow(
            entry: entry,
            up: line.up,
            down: line.down,
            tight: entry.part == TripPart.whole && entry.item.stops.isNotEmpty,
            onTap: () => onOpen(entry.item.id)),
        ScheduleStop(:final drive, :final n, :final stop, :final last) =>
          _StopRow(stop: stop, down: line.down, lastStop: last, onTap: () => onOpen('${drive.id}#$n')),
        ScheduleZoneChange() => _ZoneRow(change: row, line: line),
      };

  @override
  Widget build(BuildContext context) {
    if (trip.items.isEmpty) return empty;
    final rows = <Widget>[];
    for (final (d, day) in tripSchedule(trip).indexed) {
      rows.add(_DayHeading(day: day.day, number: day.number, first: d == 0));
      // The line runs from the day's first dot to its last, and no further.
      final first = day.rows.indexWhere((r) => r.dot), last = day.rows.lastIndexWhere((r) => r.dot);
      for (final (m, r) in day.rows.indexed) {
        rows.add(_row(r, (up: m > first && m <= last, down: m >= first && m < last)));
      }
    }
    return ListView(padding: const EdgeInsets.fromLTRB(8, 4, 16, 32), children: rows);
  }
}

typedef _Line = ({bool up, bool down});

/// Just the date, large, with room around it. The day's line starts below.
class _DayHeading extends StatelessWidget {
  const _DayHeading({required this.day, required this.number, required this.first});

  final DateTime day;
  final int number;
  final bool first;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(12, first ? 2 : 34, 8, 16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Flexible(
            child: Text(DateFormat('EEEE, MMMM d').format(day),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
          ),
          const SizedBox(width: 10),
          Text('Day $number', style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5, fontWeight: FontWeight.w600)),
        ]),
      );
}

/// Where the clocks change: from here on, times are in the new zone.
class _ZoneRow extends StatelessWidget {
  const _ZoneRow({required this.change, required this.line});

  final ScheduleZoneChange change;
  final _Line line;

  @override
  Widget build(BuildContext context) => Stack(children: [
        Positioned(left: _timeWidth, width: _railWidth, top: 0, bottom: 0, child: CustomPaint(painter: _Rail(up: line.up, down: line.down))),
        Padding(
          padding: const EdgeInsets.fromLTRB(_timeWidth + _railWidth + 6, 0, 8, 30),
          child: Row(children: [
            const Icon(Icons.schedule, size: 13, color: AppColors.primaryText),
            const SizedBox(width: 6),
            Expanded(child: Text(change.text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
          ]),
        ),
      ]);
}

const _quiet = TextStyle(color: AppColors.secondaryText, fontSize: 12.5, height: 1.4);

class _EventRow extends StatelessWidget {
  const _EventRow({required this.entry, required this.up, required this.down, required this.tight, required this.onTap});

  final TripEntry entry;
  final bool up;
  final bool down;

  /// Stops follow it, close under it.
  final bool tight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = entry, i = e.item;
    final places = e.places;
    final time = inZone(e.moment, e.zone);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Stack(children: [
        Positioned(
          left: _timeWidth,
          width: _railWidth,
          top: 0,
          bottom: 0,
          child: CustomPaint(painter: _Rail(up: up, down: down, dot: i.kind.color, dotSize: 14, dotY: _eventDotY)),
        ),
        Padding(
          padding: EdgeInsets.only(top: 2, bottom: tight ? 14 : 30),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: _timeWidth,
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      DateFormat.jm().format(time),
                      maxLines: 1,
                      style: const TextStyle(
                          color: AppColors.primaryText, fontSize: 13, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                  ),
                ),
                // The same quiet text as beside the line, tucked up against it.
                Text(zoneLabel(e.moment, e.zone), maxLines: 1, style: _quiet),
              ]),
            ),
            const SizedBox(width: _railWidth + 6),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e.title,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, height: 1.3)),
                if (places.isNotEmpty)
                  Text.rich(
                    TextSpan(children: [
                      for (final (n, p) in places.indexed) ...[
                        if (n > 0)
                          const WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: 5),
                              child: Icon(Icons.arrow_forward, size: 12, color: AppColors.secondaryText),
                            ),
                          ),
                        TextSpan(text: p),
                      ],
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _quiet,
                  ),
                Text(e.when, maxLines: 2, style: _quiet),
                if (e.duration != null) Text(e.duration!, maxLines: 2, style: _quiet),
              ]),
            ),
            const SizedBox(width: 8),
          ]),
        ),
      ]),
    );
  }
}

/// A stop on a drive: a small dot and no time of its own, part of the drive.
class _StopRow extends StatelessWidget {
  const _StopRow({required this.stop, required this.down, required this.lastStop, required this.onTap});

  final DriveStop stop;
  final bool down;
  final bool lastStop;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Stack(children: [
          Positioned(
            left: _timeWidth,
            width: _railWidth,
            top: 0,
            bottom: 0,
            child: CustomPaint(painter: _Rail(up: true, down: down, dot: TripItemKind.commute.color, dotSize: 7, dotY: _stopDotY)),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(_timeWidth + _railWidth + 6, 2, 8, lastStop ? 30 : 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
              Flexible(
                child: Text(stop.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, height: 1.3)),
              ),
              const SizedBox(width: 8),
              Text('${tripMinutes(stop.minutes)} stop', style: _quiet),
            ]),
          ),
        ]),
      );
}

/// The line, softly glowing, and a dot on it if this row has one.
class _Rail extends CustomPainter {
  const _Rail({required this.up, required this.down, this.dot, this.dotSize, this.dotY = 0});

  final bool up;
  final bool down;
  final Color? dot;
  final double? dotSize;
  final double dotY;

  static final _glow = Paint()
    ..color = Energy.white.withValues(alpha: 0.32)
    ..strokeWidth = 3.5
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
  static final _line = Paint()
    ..color = Energy.white
    ..strokeWidth = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    final y = dotSize == null ? size.height / 2 : dotY;
    void stretch(double a, double b) {
      canvas.drawLine(Offset(x, a), Offset(x, b), _glow);
      canvas.drawLine(Offset(x, a), Offset(x, b), _line);
    }

    if (up) stretch(0, y);
    if (down) stretch(y, size.height);
    final radius = dotSize, color = dot;
    if (radius != null && color != null) {
      canvas.drawCircle(
          Offset(x, y),
          radius / 2 + 2,
          Paint()
            ..color = color.withValues(alpha: 0.6)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
      canvas.drawCircle(Offset(x, y), radius / 2, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_Rail old) => old.up != up || old.down != down || old.dot != dot || old.dotSize != dotSize || old.dotY != dotY;
}

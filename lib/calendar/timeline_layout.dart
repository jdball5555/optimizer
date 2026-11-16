import 'dart:math' as math;
import 'dart:ui' show Rect;

import '../util/fields.dart';

/// One event's place in a day row of the sideways timeline.
class TimelineItem<T> {
  TimelineItem(this.value, this.start, this.end);

  final T value;
  final DateTime start;
  final DateTime end;

  /// 0 sits on the row; 1 is drawn on top of a depth-0 event, and so on.
  int depth = 0;
  int lane = 0;

  /// Lanes in this item's group at its depth: it gets 1/lanes of the height.
  int lanes = 1;

  /// Where the block is drawn, inside the row.
  Rect rect = Rect.zero;

  /// How wide its label may be: less than the block when an event on top
  /// starts inside it, so the label is never hidden under it.
  double labelWidth = 0;

  /// The end it's drawn to: a short event is drawn at least [minWidth] long
  /// so its title can be read, and takes up that much room in the layout.
  late DateTime shownEnd;
}

/// Lays out one day's timed events, the way a week view does with columns,
/// turned sideways: events that start close together split the row's height
/// into lanes; an event that starts well after another one (at least
/// [textZone] pixels later) is drawn on top of it instead, past its title,
/// spanning the full height. Labels never run under a block drawn on top.
/// Every event is drawn exactly as long as it is, so its ends line up with
/// the hours (a very short one is a sliver; hovering opens it out).
void layoutTimeline<T>(
  List<TimelineItem<T>> items, {
  required DateTime dayStart,
  required double hourWidth,
  required double height,
  double pad = 5,
  double laneGap = 4,
  double textZone = 110,
}) {
  double x(DateTime t) => clockHours(t, dayStart) * hourWidth;
  final dayEnd = addDays(dayStart, 1);
  for (final s in items) {
    s.shownEnd = s.end.isAfter(dayEnd) ? dayEnd : s.end;
  }
  bool overlap(TimelineItem a, TimelineItem b) => a.start.isBefore(b.shownEnd) && b.start.isBefore(a.shownEnd);

  items.sort((a, b) {
    final c = a.start.compareTo(b.start);
    return c != 0 ? c : b.end.compareTo(a.end);
  });

  // Depth: on top of anything it starts far enough after; level with
  // anything it starts close to (they need to sit side by side).
  for (var i = 0; i < items.length; i++) {
    final s = items[i];
    var depth = 0;
    for (var j = 0; j < i; j++) {
      final e = items[j];
      if (!overlap(e, s)) continue;
      final gap = x(s.start) - x(e.start);
      depth = math.max(depth, gap >= textZone ? e.depth + 1 : e.depth);
    }
    s.depth = depth;
  }

  // Lanes, separately at each depth: overlapping events form a group that
  // splits the height into as many lanes as it needs.
  final maxDepth = items.fold<int>(0, (m, s) => math.max(m, s.depth));
  for (var d = 0; d <= maxDepth; d++) {
    var group = <TimelineItem<T>>[];
    var laneEnds = <DateTime>[];
    DateTime? groupEnd;
    void close() {
      for (final s in group) {
        s.lanes = laneEnds.length;
      }
      group = [];
      laneEnds = [];
      groupEnd = null;
    }

    for (final s in items.where((s) => s.depth == d)) {
      if (groupEnd != null && !s.start.isBefore(groupEnd!)) close();
      var lane = laneEnds.indexWhere((end) => !end.isAfter(s.start));
      if (lane == -1) {
        lane = laneEnds.length;
        laneEnds.add(s.shownEnd);
      } else {
        laneEnds[lane] = s.shownEnd;
      }
      s.lane = lane;
      group.add(s);
      if (groupEnd == null || s.shownEnd.isAfter(groupEnd!)) groupEnd = s.shownEnd;
    }
    if (group.isNotEmpty) close();
  }

  for (final s in items) {
    // Blocks on top are inset a little so the one underneath still shows.
    final inset = pad + math.min(s.depth, 3) * 3.0;
    final avail = math.max(8.0, height - inset * 2);
    final laneH = math.max(6.0, (avail - (s.lanes - 1) * laneGap) / s.lanes);
    final width = math.max(3.0, x(s.shownEnd) - x(s.start) - 3);
    s.rect = Rect.fromLTWH(x(s.start) + 1.5, inset + s.lane * (laneH + laneGap), width, laneH);
    s.labelWidth = s.rect.width;
  }

  bool sameBand(Rect a, Rect b) => a.top < b.bottom - 0.5 && b.top < a.bottom - 0.5;
  // Cut a label short where a block on top of it begins.
  for (final s in items) {
    for (final e in items) {
      if (e.depth <= s.depth || !sameBand(e.rect, s.rect)) continue;
      if (e.rect.left >= s.rect.left && e.rect.left < s.rect.right) {
        s.labelWidth = math.min(s.labelWidth, e.rect.left - s.rect.left - 4);
      }
    }
  }
}

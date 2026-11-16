import '../util/fields.dart';
import 'trip_models.dart';
import 'trip_zones.dart';

// The order a trip happens in, day by day: what the itinerary and the PDF both show.

/// A stay or a rental car has two moments that matter, each on its own day:
/// checking in and out, picking up and dropping off.
enum TripPart { whole, begins, ends }

/// One event on the trip's line.
class TripEntry {
  const TripEntry(this.item, this.part, this.moment, this.zone, this.endZone);

  final TripItem item;
  final TripPart part;
  final DateTime moment;
  final String zone;
  final String endZone;

  DateTime get day => dayStart(inZone(moment, zone));

  String get title {
    final number = '${item.flight?['number'] ?? ''}';
    return item.kind == TripItemKind.flight && number.isNotEmpty ? number : item.title;
  }

  /// When: from when to when, or which end of a stay or rental this is.
  String get when {
    final at = clockIn(moment, zone);
    final stay = item.kind == TripItemKind.stay;
    return switch (part) {
      TripPart.whole => _range(item.start, zone, item.end.isAfter(item.start) ? item.end : item.start, endZone),
      TripPart.begins => '${stay ? 'Check in' : 'Pick up'} at $at',
      TripPart.ends => '${stay ? 'Check out' : 'Drop off'} at $at',
    };
  }

  /// How long the whole journey takes, stops and all. Only for getting
  /// somewhere: how long dinner is, you can see from its times.
  String? get duration {
    final i = item;
    if (part != TripPart.whole || !i.isTravel || !i.end.isAfter(i.start)) return null;
    final stopping = i.stops.fold<int>(0, (n, s) => n + s.minutes);
    final total = 'Total ${tripMinutes(i.end.difference(i.start).inMinutes)}';
    return stopping > 0 ? '$total, including ${tripMinutes(stopping)} of stops' : total;
  }

  /// Where it is, or where you're going from and to, by name.
  List<String> get places => [for (final p in fullPlaces) _named(p)].where((p) => p.isNotEmpty).toList();

  /// The same, with the full addresses.
  List<String> get fullPlaces {
    final i = item;
    switch (i.kind) {
      case TripItemKind.flight:
        return [i.departure.code, i.arrival.code].where((c) => c.isNotEmpty).toList();
      case TripItemKind.commute:
      case TripItemKind.travel:
        return ['${i.commute?['from'] ?? ''}', '${i.commute?['to'] ?? i.location}'].where((p) => p.isNotEmpty).toList();
      case TripItemKind.rental:
        final where = '${i.commute?[part == TripPart.ends ? 'to' : 'from'] ?? i.location}';
        return [if (where.isNotEmpty) where];
      case TripItemKind.stay:
      case TripItemKind.food:
      case TripItemKind.activity:
        return [if (i.location.isNotEmpty) i.location];
    }
  }

  String _named(String place) {
    if (item.kind == TripItemKind.flight) return place;
    final name = placeName(place);
    // Named after the place: the rest of the address says something new.
    return name == item.title ? place.substring(name.length).replaceFirst(RegExp(r'^[,\s]+'), '') : name;
  }
}

/// From when to when, each with its own time zone.
String _range(DateTime start, String startZone, DateTime end, String endZone) {
  if (start == end) return clockIn(start, startZone);
  final sameDate = sameDay(inZone(start, startZone), inZone(end, endZone));
  return sameDate ? '${clockIn(start, startZone)} – ${clockIn(end, endZone)}' : '${dayClockIn(start, startZone)} – ${dayClockIn(end, endZone)}';
}

/// Something on a day's line.
sealed class ScheduleRow {
  const ScheduleRow();

  /// It's a dot on the line, rather than a note beside it.
  bool get dot => true;
}

class ScheduleEvent extends ScheduleRow {
  const ScheduleEvent(this.entry);

  final TripEntry entry;
}

/// A stop on a drive: no time of its own, part of the drive.
class ScheduleStop extends ScheduleRow {
  const ScheduleStop(this.drive, this.n, this.stop, {required this.last});

  final TripItem drive;
  final int n;
  final DriveStop stop;

  /// The drive's last stop.
  final bool last;
}

/// Where the clocks change: from here on, times are in the new zone.
class ScheduleZoneChange extends ScheduleRow {
  const ScheduleZoneChange(this.moment, this.from, this.to);

  final DateTime moment;
  final String from;
  final String to;

  @override
  bool get dot => false;

  String get text {
    final change = zoneOffset(moment, to) - zoneOffset(moment, from);
    return 'Now on ${zoneLabel(moment, to)} · ${tripMinutes(change.inMinutes.abs())} ${change.isNegative ? 'earlier' : 'later'}';
  }
}

class ScheduleDay {
  const ScheduleDay(this.day, this.number, this.rows);

  final DateTime day;

  /// Day 1 is the trip's first.
  final int number;
  final List<ScheduleRow> rows;
}

List<TripEntry> _entries(Trip trip) {
  final made = <TripEntry>[];
  for (final i in trip.items) {
    final (start, end) = trip.zones[i.id]!;
    if (i.kind.hasTwoEnds && i.end.isAfter(i.start)) {
      made
        ..add(TripEntry(i, TripPart.begins, i.start, start, end))
        ..add(TripEntry(i, TripPart.ends, i.end, end, end));
    } else {
      made.add(TripEntry(i, TripPart.whole, i.start, start, end));
    }
  }
  // By day first, so a day never comes up twice when two places' dates differ.
  final order = made.indexed.toList()
    ..sort((a, b) {
      var c = a.$2.day.compareTo(b.$2.day);
      if (c == 0) c = a.$2.moment.compareTo(b.$2.moment);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
  return [for (final e in order) e.$2];
}

DateTime _utcDay(DateTime d) => DateTime.utc(d.year, d.month, d.day);

/// The trip day by day.
List<ScheduleDay> tripSchedule(Trip trip) {
  final all = _entries(trip);
  final days = <ScheduleDay>[];
  String? here;
  var n = 0;
  while (n < all.length) {
    final day = all[n].day;
    final rows = <ScheduleRow>[];

    void zoneChange(String to, DateTime moment) {
      final from = here;
      here = to;
      if (from != null && zoneOffset(moment, from) != zoneOffset(moment, to)) rows.add(ScheduleZoneChange(moment, from, to));
    }

    for (; n < all.length && all[n].day == day; n++) {
      final e = all[n], i = e.item;
      // Dropping off a car or checking out doesn't move you anywhere.
      if (e.part != TripPart.ends) zoneChange(e.zone, e.moment);
      rows.add(ScheduleEvent(e));
      if (e.part == TripPart.whole) {
        final stops = i.stops;
        for (final (m, s) in stops.indexed) {
          rows.add(ScheduleStop(i, m, s, last: m == stops.length - 1));
        }
        if (i.isTravel) zoneChange(e.endZone, i.end.isAfter(i.start) ? i.end : i.start);
      }
    }
    days.add(ScheduleDay(day, _utcDay(day).difference(_utcDay(all.first.day)).inDays + 1, rows));
  }
  return days;
}

import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest.dart' as data;
import 'package:timezone/timezone.dart' as tz;

// A time zone here is its IANA name, like America/Chicago. An empty one means
// this device's own clock: what's left when nothing better is known.
//
// A "wall clock" is what a clock on the wall there says: its fields are what
// count, not the moment it happens to be on this device. Those are held in UTC
// DateTimes, whose fields are never moved by this device's daylight saving.

/// This device's zone, once [loadDeviceZone] has found it.
String deviceZone = '';

Future<void> loadDeviceZone() async {
  try {
    deviceZone = (await FlutterTimezone.getLocalTimezone()).identifier;
  } catch (_) {
    // The device's clock still works, just without a name for it.
  }
}

bool _loaded = false;

tz.Location? _location(String zone) {
  if (zone.isEmpty) return null;
  if (!_loaded) {
    data.initializeTimeZones();
    _loaded = true;
  }
  try {
    return tz.getLocation(zone);
  } catch (_) {
    return null;
  }
}

/// Every zone there is, by name.
List<String> allZones() {
  _location('UTC');
  return tz.timeZoneDatabase.locations.keys.toList()..sort();
}

/// [moment] as the clock in [zone] shows it.
DateTime inZone(DateTime moment, String zone) {
  final l = _location(zone);
  return l == null ? moment.toLocal() : tz.TZDateTime.from(moment, l);
}

/// What a clock in [zone] says at [moment].
DateTime wallOf(DateTime moment, String zone) {
  final t = inZone(moment, zone);
  return DateTime.utc(t.year, t.month, t.day, t.hour, t.minute);
}

/// The moment a clock in [zone] says [wall].
DateTime fromWall(DateTime wall, String zone) {
  final l = _location(zone);
  if (l == null) return DateTime(wall.year, wall.month, wall.day, wall.hour, wall.minute);
  final t = tz.TZDateTime(l, wall.year, wall.month, wall.day, wall.hour, wall.minute);
  return DateTime.fromMillisecondsSinceEpoch(t.millisecondsSinceEpoch);
}

Duration zoneOffset(DateTime moment, String zone) => inZone(moment, zone).timeZoneOffset;

/// The short name for [zone] at [moment]: PST, or GMT+4 where there isn't one.
String zoneLabel(DateTime moment, String zone) {
  final t = inZone(moment, zone);
  final name = t.timeZoneName;
  if (name.isNotEmpty && !name.startsWith(RegExp(r'[+\-\d]')) && name.length <= 5) return name;
  final o = t.timeZoneOffset;
  final minutes = o.inMinutes.abs() % 60;
  return 'GMT${o.isNegative ? '-' : '+'}${o.inHours.abs()}${minutes == 0 ? '' : ':${'$minutes'.padLeft(2, '0')}'}';
}

/// "8:05 AM CST".
String clockIn(DateTime moment, String zone) => '${DateFormat.jm().format(inZone(moment, zone))} ${zoneLabel(moment, zone)}';

/// "Nov 6, 8:05 AM CST".
String dayClockIn(DateTime moment, String zone) => '${DateFormat('MMM d, h:mm a').format(inZone(moment, zone))} ${zoneLabel(moment, zone)}';

import 'package:cloud_firestore/cloud_firestore.dart';

/// Returns the first key from [names] that exists (non-null) in [data].
String? firstKey(Map<String, dynamic> data, List<String> names) {
  for (final n in names) {
    if (data[n] != null) return n;
  }
  return null;
}

DateTime? asDate(dynamic v) {
  if (v == null) return null;
  if (v is Timestamp) return v.toDate();
  if (v is DateTime) return v;
  if (v is int) {
    // Seconds vs milliseconds.
    return DateTime.fromMillisecondsSinceEpoch(v < 100000000000 ? v * 1000 : v);
  }
  if (v is String) return DateTime.tryParse(v);
  if (v is Map && v['seconds'] is int) {
    return DateTime.fromMillisecondsSinceEpoch((v['seconds'] as int) * 1000);
  }
  return null;
}

double? asDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.replaceAll(RegExp(r'[^0-9.\-]'), ''));
  return null;
}

DateTime dayStart(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);
/// Where [t] falls on [day]'s clock, in hours from 0 to 24. By the clock on
/// the wall rather than time since midnight, so on the days the clocks change
/// (23 or 25 hours long) a 9 am event still sits at the 9 am line.
double clockHours(DateTime t, DateTime day) {
  final from = dayStart(day);
  if (!t.isAfter(from)) return 0;
  if (!t.isBefore(addDays(from, 1))) return 24;
  return t.hour + t.minute / 60 + t.second / 3600;
}

bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

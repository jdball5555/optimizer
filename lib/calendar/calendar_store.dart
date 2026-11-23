import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/painting.dart';

import 'calendar_models.dart';

/// Optimizer's own calendar section in Firestore:
///
///   axisCalendar/{uid}               settings: linked accounts, their calendars, hidden
///                                    calendars, auto-sync
///   axisCalendar/{uid}/events/{id}   every Google event from 6 weeks back to 6 months ahead
///
/// The server (functions/google.js) keeps both up to date with Google, so
/// the app only reads them, and other Axis apps can read your calendar
/// without talking to Google.
class CalendarStore {
  CalendarStore(this.uid);

  final String uid;

  /// Last Firestore failure (usually a missing security rule), for the sidebar.
  String? error;

  DocumentReference<Map<String, dynamic>> get doc => FirebaseFirestore.instance.collection('axisCalendar').doc(uid);
  CollectionReference<Map<String, dynamic>> get _events => doc.collection('events');

  Future<void> _save(Map<String, dynamic> fields) async {
    try {
      await doc.set({...fields, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      error = null;
    } catch (e) {
      error = '$e';
    }
  }

  Future<void> saveHidden(List<String> hidden) => _save({'hiddenCalendars': hidden});

  /// A color for a Google calendar in Optimizer only (Google keeps its own).
  Future<void> saveCalendarColor(String calendarKey, String hex) => _save({
        'calendarColors': {calendarKey: hex},
      });

  /// On: once an event is over, the server leaves it as it was, whatever
  /// happens to it in Google.
  Future<void> saveKeepPast(bool on) => _save({'keepPast': on});

  /// The To-dos page's choices: todoMatrix, todoMainList.
  Future<void> saveTodoSettings(Map<String, dynamic> fields) => _save(fields);

  /// Off stops the server checking Google every minute (Sync still works).
  Future<void> saveAutoSync(bool on) => _save({'autoSync': on});

  /// The calendar list, as the server last read it from Google, in the
  /// colors you picked here.
  static List<GoogleCalendar> calendarsFrom(Map<String, dynamic> settings) {
    final picked = (settings['calendarColors'] as Map?) ?? const {};
    return [
      for (final c in (settings['calendars'] as List? ?? const []))
        if (c is Map && c['id'] is String && c['account'] is String)
          GoogleCalendar(
            id: c['id'] as String,
            accountEmail: c['account'] as String,
            name: '${c['name'] ?? c['id']}',
            color: readableColor(parseHexColor((picked['${c['account']}|${c['id']}'] ?? c['color']) as String?, const Color(0xFF4285F4))),
            primary: c['primary'] == true,
            accessRole: '${c['accessRole'] ?? 'reader'}',
          ),
    ];
  }

  // Look back a little for events that started before the range but run into it.
  Query<Map<String, dynamic>> _between(DateTime from, DateTime to) => _events
      .where('start', isGreaterThanOrEqualTo: Timestamp.fromDate(from.subtract(const Duration(days: 14))))
      .where('start', isLessThan: Timestamp.fromDate(to));

  /// The stored events of [from, to) as they change, by document id.
  Stream<Map<String, Map<String, dynamic>>> watch(DateTime from, DateTime to) =>
      _between(from, to).snapshots().map((s) => {for (final d in s.docs) d.id: d.data()});

  /// Events from the stored copy that overlap [from, to), read once.
  Future<List<CalendarEvent>> loadEvents(DateTime from, DateTime to, Map<String, GoogleCalendar> calendars) async {
    try {
      final snap = await _between(from, to).get();
      error = null;
      return eventsFrom({for (final d in snap.docs) d.id: d.data()}, calendars).where((e) => e.overlaps(from, to)).toList();
    } catch (e) {
      error = '$e';
      return [];
    }
  }

  /// The events among [docs] whose calendar is in [calendars].
  static List<CalendarEvent> eventsFrom(Map<String, Map<String, dynamic>> docs, Map<String, GoogleCalendar> calendars) => [
        for (final d in docs.entries)
          if (calendars[d.value['calendarKey']] case final cal?)
            if (_fromDoc(d.key, d.value, cal) case final e?) e,
      ];

  static CalendarEvent? _fromDoc(String id, Map<String, dynamic> d, GoogleCalendar cal) {
    final allDay = d['allDay'] == true;
    // All-day events carry their days, so they land on the right day whatever
    // this device's time zone.
    final start = (allDay ? _day(d['date']) : null) ?? (d['start'] as Timestamp?)?.toDate();
    final end = (allDay ? _day(d['endDate']) : null) ?? (d['end'] as Timestamp?)?.toDate();
    if (start == null || end == null) return null;
    return CalendarEvent(
      id: '${d['eventId'] ?? id}',
      calendar: cal,
      title: '${d['title'] ?? '(No title)'}',
      description: '${d['description'] ?? ''}',
      location: '${d['location'] ?? ''}',
      start: start,
      end: end,
      allDay: allDay,
      // Its own color if it has one, otherwise its calendar's (as you colored it).
      color: readableColor(googleEventColors[d['colorId']] ?? cal.color),
      colorId: d['colorId'] as String?,
      htmlLink: d['htmlLink'] as String?,
      recurring: d['recurring'] == true,
    );
  }

  static DateTime? _day(Object? ymd) {
    final p = '${ymd ?? ''}'.split('-').map(int.tryParse).toList();
    if (p.length != 3 || p.contains(null)) return null;
    return DateTime(p[0]!, p[1]!, p[2]!);
  }
}

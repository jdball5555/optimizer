import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

import '../util/fields.dart';
import 'calendar_models.dart';

/// How long a change stays in your history.
const historyDays = 30;

/// One change you made to your calendar, with what it takes to put it back
/// (axisCalendar/{uid}/history). Older than [historyDays], it's cleared away.
class HistoryEntry {
  HistoryEntry({
    required this.id,
    required this.at,
    required this.action,
    required this.title,
    this.google = false,
    this.before,
    this.after,
    this.editBefore,
    this.reverted = false,
  });

  factory HistoryEntry.fromDoc(String id, Map<String, dynamic> d) => HistoryEntry(
        id: id,
        at: asDate(d['at']) ?? DateTime.now(),
        action: HistoryAction.values.where((a) => a.name == d['action']).firstOrNull ?? HistoryAction.changed,
        title: '${d['title'] ?? ''}',
        google: d['google'] == true,
        before: d['before'] is Map ? Map<String, dynamic>.from(d['before'] as Map) : null,
        after: d['after'] is Map ? Map<String, dynamic>.from(d['after'] as Map) : null,
        editBefore: d['editBefore'] is Map ? Map<String, dynamic>.from(d['editBefore'] as Map) : null,
        reverted: d['reverted'] == true,
      );

  final String id;
  final DateTime at;
  final HistoryAction action;
  final String title;

  /// It changed Google Calendar too, not just Optimizer.
  final bool google;

  /// The event before and after, as [snapshotOf] wrote them.
  final Map<String, dynamic>? before;
  final Map<String, dynamic>? after;

  /// The version kept only in Optimizer before this, if there was one.
  final Map<String, dynamic>? editBefore;
  bool reverted;

  Map<String, dynamic> toJson() => {
        'at': Timestamp.fromDate(at),
        'action': action.name,
        'title': title,
        'google': google,
        if (before != null) 'before': before,
        if (after != null) 'after': after,
        if (editBefore != null) 'editBefore': editBefore,
        'reverted': reverted,
      };

  String get label => switch (action) {
        HistoryAction.added => 'Added',
        HistoryAction.changed => 'Changed',
        HistoryAction.deleted => 'Deleted',
        HistoryAction.removed => 'Deleted',
        HistoryAction.keptHere => 'Changed in Optimizer',
        HistoryAction.wentBack => 'Went back to Google’s version',
        HistoryAction.hid => 'Hidden',
        HistoryAction.showed => 'Shown again',
      };

  /// What's different, in a few words each.
  List<String> get details {
    final a = before, b = after;
    if (a == null || b == null) {
      final only = b ?? a;
      return only == null ? const [] : [whenOf(only)];
    }
    return [
      if (a['title'] != b['title']) 'Name: ${a['title']} to ${b['title']}',
      if (whenOf(a) != whenOf(b)) 'When: ${whenOf(a)} to ${whenOf(b)}',
      if (a['location'] != b['location']) (('${b['location'] ?? ''}').isEmpty ? 'Location removed' : 'Location: ${b['location']}'),
      if (a['description'] != b['description']) 'Description changed',
      if (a['colorId'] != b['colorId']) 'Color changed',
      if (a['calendarKey'] != b['calendarKey']) 'Moved to another calendar',
    ];
  }

  /// What reverting does, to say before you do.
  String get revertWarning => google
      ? 'This also changes it in Google Calendar, whatever has happened to it since.'
      : 'This changes it in Optimizer only. Google Calendar stays as it is.';
}

enum HistoryAction { added, changed, deleted, removed, keptHere, wentBack, hid, showed }

/// An event as it was, to keep in the history.
Map<String, dynamic> snapshotOf(CalendarEvent e) => {
      'calendarKey': e.calendar.key,
      'eventId': e.id,
      'title': e.title,
      'description': e.description,
      'location': e.location,
      'start': e.start.millisecondsSinceEpoch,
      'end': e.end.millisecondsSinceEpoch,
      'allDay': e.allDay,
      'colorId': e.colorId,
    };

/// "Nov 3, 9:00 AM – 10:00 AM".
String whenOf(Map<String, dynamic> s) {
  final start = DateTime.fromMillisecondsSinceEpoch((s['start'] as num?)?.toInt() ?? 0);
  final end = DateTime.fromMillisecondsSinceEpoch((s['end'] as num?)?.toInt() ?? 0);
  final day = DateFormat('MMM d'), time = DateFormat.jm();
  if (s['allDay'] == true) return '${day.format(start)}, all day';
  return sameDay(start, end)
      ? '${day.format(start)}, ${time.format(start)} – ${time.format(end)}'
      : '${day.format(start)}, ${time.format(start)} – ${day.format(end)}, ${time.format(end)}';
}

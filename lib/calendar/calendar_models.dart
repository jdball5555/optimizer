import 'package:flutter/material.dart';

import '../util/fields.dart';

/// A linked Google account. The server holds its sign-in and keeps its
/// calendars in sync; this is what it reports (axisCalendar/{uid}.googleLinks).
class GoogleAccount {
  GoogleAccount({required this.email, this.linked = true, this.error, this.lastSync});

  factory GoogleAccount.fromLink(String email, Object? link) {
    final m = link is Map ? link : const {};
    return GoogleAccount(
      email: email,
      linked: m['linked'] == true,
      error: m['error'] as String?,
      lastSync: asDate(m['lastSync']),
    );
  }

  final String email;

  /// Whether the server can reach this account. Accounts linked before the
  /// server did the syncing need connecting once more.
  final bool linked;

  /// What went wrong last time, if anything.
  final String? error;
  final DateTime? lastSync;

  bool get isExpired => !linked;
}

/// The pretend account of the calendar that trips' tiles belong to.
const tripsAccount = 'trips';

/// The pretend account of the calendars you make in Optimizer. They're not
/// synced with anything.
const ownAccount = 'optimizer';

class GoogleCalendar {
  GoogleCalendar({
    required this.id,
    required this.accountEmail,
    required this.name,
    required this.color,
    required this.primary,
    required this.accessRole,
  });

  final String id;
  final String accountEmail;
  final String name;
  final Color color;
  final bool primary;
  final String accessRole;

  /// The same calendar can be visible from two accounts, so key by both.
  String get key => '$accountEmail|$id';
  bool get canWrite => accessRole == 'owner' || accessRole == 'writer';

  /// Made in Optimizer, and kept only there.
  bool get isOwn => accountEmail == ownAccount;

  /// Where it comes from, as shown beside its name.
  String get source => isOwn ? 'Optimizer' : accountEmail;
}

class CalendarEvent {
  CalendarEvent({
    required this.id,
    required this.calendar,
    required this.title,
    required this.description,
    required this.location,
    required this.start,
    required this.end,
    required this.allDay,
    required this.color,
    this.colorId,
    this.htmlLink,
    this.recurring = false,
    this.localEdit = false,
    this.done = false,
    this.backdrop = false,
    this.due,
    this.task = false,
  });

  final String id;
  final GoogleCalendar calendar;
  final String title;
  final String description;
  final String location;
  final DateTime start;

  /// Exclusive. For all-day events this is midnight of the day after.
  final DateTime end;
  final bool allDay;
  final Color color;
  final String? colorId;
  final String? htmlLink;
  final bool recurring;

  /// Changed in Optimizer only, so it's different from Google Calendar's.
  final bool localEdit;

  /// A Canvas item you've checked off: drawn crossed out, at the bottom of its day.
  final bool done;

  /// Runs behind everything else on the calendar rather than sharing the
  /// space with it (a trip's tile; a stay during a trip).
  final bool backdrop;

  /// When something due at a moment is due. It shows as an all-day chip, so
  /// [start] is only the start of its day.
  final DateTime? due;

  bool get isTrip => calendar.accountEmail == tripsAccount;

  /// A to-do of your own shown on a calendar (the To-dos page's month), drawn
  /// like a Canvas item, with a circle to check it off.
  final bool task;

  /// A Canvas item, or a to-do: every one is also on the to-do list, to be checked off.
  bool get isTask => task || calendar.accountEmail == 'canvas';

  /// Runs past midnight into another day.
  bool get spansDays {
    final last = end.subtract(const Duration(microseconds: 1));
    return start.year != last.year || start.month != last.month || start.day != last.day;
  }

  /// Identifies it across fetches: the same event always has the same key.
  String get key => '${calendar.key}|$id';

  /// The title as shown: a ✎ in front when it's been changed only here.
  String get shownTitle => localEdit ? '✎ $title' : title;

  bool overlaps(DateTime from, DateTime to) => start.isBefore(to) && end.isAfter(from);

  CalendarEvent copyWith({
    String? title,
    String? description,
    String? location,
    DateTime? start,
    DateTime? end,
    bool? allDay,
    Color? color,
    String? colorId,
    bool? localEdit,
    bool? done,
  }) =>
      CalendarEvent(
        id: id,
        calendar: calendar,
        title: title ?? this.title,
        description: description ?? this.description,
        location: location ?? this.location,
        start: start ?? this.start,
        end: end ?? this.end,
        allDay: allDay ?? this.allDay,
        color: color ?? this.color,
        colorId: colorId ?? this.colorId,
        htmlLink: htmlLink,
        recurring: recurring,
        localEdit: localEdit ?? this.localEdit,
        done: done ?? this.done,
        backdrop: backdrop,
        due: due,
        task: task,
      );
}

/// The order of a day's all-day events: your own events first, then Canvas
/// items by class and then name (as in the to-do list), and anything checked
/// off at the very bottom.
int compareAllDay(CalendarEvent a, CalendarEvent b) {
  int rank(CalendarEvent e) => e.done ? 2 : (e.calendar.accountEmail == 'canvas' ? 1 : 0);
  final r = rank(a).compareTo(rank(b));
  if (r != 0) return r;
  if (rank(a) == 0) {
    final s = a.start.compareTo(b.start);
    if (s != 0) return s;
  } else {
    final c = a.calendar.name.toLowerCase().compareTo(b.calendar.name.toLowerCase());
    if (c != 0) return c;
  }
  return a.title.toLowerCase().compareTo(b.title.toLowerCase());
}

/// What the editor dialog hands back to the service.
class EventDraft {
  EventDraft({
    required this.calendarKey,
    required this.title,
    required this.start,
    required this.end,
    required this.allDay,
    this.description = '',
    this.location = '',
    this.colorId,
    List<String>? guests,
    this.guestsCanSeeList = true,
  }) : guests = guests ?? [];

  String calendarKey;
  String title;
  DateTime start;
  DateTime end;
  bool allDay;
  String description;
  String location;
  String? colorId;

  /// Emails invited to the event (through Optimizer).
  List<String> guests;
  bool guestsCanSeeList;
}

/// Google Calendar's fixed event color palette (colorId → color).
const googleEventColors = <String, Color>{
  '1': Color(0xFF7986CB), // Lavender
  '2': Color(0xFF33B679), // Sage
  '3': Color(0xFF8E24AA), // Grape
  '4': Color(0xFFE67C73), // Flamingo
  '5': Color(0xFFF6BF26), // Banana
  '6': Color(0xFFF4511E), // Tangerine
  '7': Color(0xFF039BE5), // Peacock
  '8': Color(0xFF616161), // Graphite
  '9': Color(0xFF3F51B5), // Blueberry
  '10': Color(0xFF0B8043), // Basil
  '11': Color(0xFFD50000), // Tomato
};

Color parseHexColor(String? hex, Color fallback) {
  if (hex == null) return fallback;
  final h = hex.replaceFirst('#', '');
  final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
  return v == null ? fallback : Color(v);
}

Color onColor(Color c) => c.computeLuminance() > 0.55 ? Colors.black87 : Colors.white;

/// Google picks calendar colors for a white page. On Optimizer's black one a
/// very dark color (a pure-black calendar, say) disappears, so lift anything
/// too dark toward white until it stands out.
Color readableColor(Color c) {
  var out = c;
  for (var t = 0.1; out.computeLuminance() < 0.12 && t <= 1.0; t += 0.1) {
    out = Color.lerp(c, Colors.white, t)!;
  }
  return out;
}

String colorToHex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

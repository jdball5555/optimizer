import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../util/fields.dart';
import 'calendar_models.dart';

/// Canvas calendars are listed under this "account" in the sidebar.
const canvasAccount = 'canvas';

/// Colors handed to a group's classes, in order, as each first appears.
const canvasPalette = [
  Color(0xFFF97316),
  Color(0xFF22C55E),
  Color(0xFFA855F7),
  Color(0xFFEAB308),
  Color(0xFF06B6D4),
  Color(0xFFEC4899),
  Color(0xFF84CC16),
  Color(0xFF3B82F6),
  Color(0xFFEF4444),
  Color(0xFF14B8A6),
  Color(0xFFF59E0B),
  Color(0xFF8B5CF6),
];

/// What a class is called when Canvas doesn't say (items with no [COURSE]).
const otherCourse = 'Other';

/// A Canvas calendar feed (axisCalendar/{uid}/canvasFeeds/{id}): a group you
/// name when you add it, split into one calendar per class. Optimizer's
/// Cloud Functions download it every minute and keep its items in
/// axisCalendar/{uid}/canvasItems.
class CanvasFeed {
  CanvasFeed(this.id, Map<String, dynamic> d)
      : name = '${d['name'] ?? 'Canvas'}',
        courseColors = {
          for (final e in ((d['courseColors'] as Map?) ?? const {}).entries)
            '${e.key}': readableColor(parseHexColor('${e.value}', canvasPalette.first)),
        },
        url = '${d['url'] ?? ''}',
        color = readableColor(parseHexColor(d['color'] as String?, const Color(0xFFF97316))),
        notifyNew = d['notifyNew'] != false,
        notifyChanges = d['notifyChanges'] != false,
        itemCount = (d['itemCount'] as num?)?.toInt(),
        lastChecked = asDate(d['lastChecked']),
        lastError = d['lastError'] as String?,
        todoList = d['todoList'] as String?;

  final String id;
  final String name;
  final String url;
  final Color color;
  final bool notifyNew;
  final bool notifyChanges;
  final int? itemCount;
  final DateTime? lastChecked;
  final String? lastError;

  /// The To-dos page group its items are in (a todoLists id, or '' for the
  /// main one). Set by the app; the server only ever updates other fields.
  /// Null on a calendar linked before groups.
  final String? todoList;

  /// Each class's color, by course (as saved on the feed).
  final Map<String, Color> courseColors;

  bool get notifies => notifyNew || notifyChanges;

  /// One class of this group, shown and toggled like any other calendar; read-only.
  GoogleCalendar calendarFor(String course) => _calendars.putIfAbsent(
        course,
        () => GoogleCalendar(
          id: '$id::$course',
          accountEmail: canvasAccount,
          name: course,
          color: courseColors[course] ?? color,
          primary: false,
          accessRole: 'reader',
        ),
      );
  final _calendars = <String, GoogleCalendar>{};
}

String courseOf(Map<String, dynamic> d) {
  final c = '${d['course'] ?? ''}'.trim();
  return c.isEmpty ? otherCourse : c;
}

/// When a Canvas item is due. Canvas treats an assignment due at exactly
/// 11:59 PM as "all day" and its feed then sends only the date, so a date with
/// no time on an assignment means 11:59 PM. (An all-day calendar event, like
/// "No class", really has no time: this is the start of its day.)
DateTime? canvasDue(Map<String, dynamic> d) {
  if (d['allDay'] != true) return asDate(d['start'])?.toLocal();
  final s = d['date'] is String ? DateTime.tryParse(d['date'] as String) : null;
  if (s == null) return null;
  return d['task'] == true ? DateTime(s.year, s.month, s.day, 23, 59) : DateTime(s.year, s.month, s.day);
}

/// A Canvas item as a calendar event. Assignments are due at an instant, so
/// they show as all-day chips on the day they're due, with the time in the
/// title.
CalendarEvent? canvasEvent(String id, Map<String, dynamic> d, GoogleCalendar cal, {bool done = false}) {
  final title = '${done ? '✓ ' : ''}${d['title'] ?? '(No title)'}';
  final task = d['task'] == true;
  final updated = asDate(d['canvasUpdated'])?.toLocal();
  final dateOnly = d['allDay'] == true;
  DateTime start;
  DateTime end;
  var allDay = dateOnly && !task;
  var shown = title;
  DateTime? due;
  if (allDay) {
    final s = d['date'] is String ? DateTime.tryParse(d['date'] as String) : null;
    if (s == null) return null;
    start = DateTime(s.year, s.month, s.day);
    final e = d['endDate'] is String ? DateTime.tryParse(d['endDate'] as String) : null;
    end = e == null ? addDays(start, 1) : DateTime(e.year, e.month, e.day);
  } else {
    final s = canvasDue(d);
    if (s == null) return null;
    start = s;
    end = dateOnly ? s : (asDate(d['end']) ?? s).toLocal();
    if (!end.isAfter(start)) {
      // Due at a moment: a chip on that day, "Essay 2 · 11:59 PM".
      allDay = true;
      shown = '$title · ${DateFormat.jm().format(start)}';
      due = start;
      start = dayStart(start);
      end = addDays(start, 1);
    }
  }
  if (!end.isAfter(start)) end = addDays(start, 1);
  final description = '${d['description'] ?? ''}';
  return CalendarEvent(
    id: id,
    calendar: cal,
    title: shown,
    description: [
      if (task) 'Due ${DateFormat('EEE, MMM d · h:mm a').format(canvasDue(d) ?? start)}',
      if (description.isNotEmpty) description,
      if (updated != null) 'Updated in Canvas ${DateFormat('MMM d, h:mm a').format(updated)}',
    ].join('\n\n'),
    location: '${d['location'] ?? ''}',
    start: start,
    end: end,
    allDay: allDay,
    color: cal.color,
    done: done,
    due: due,
    htmlLink: (d['url'] as String?)?.isNotEmpty == true ? canvasItemLink(d['url'] as String) : null,
  );
}

/// A Canvas item as shown: Canvas's own fields, or your edit of them.
typedef CanvasItem = ({String id, Map<String, dynamic> data, Map<String, dynamic> source, bool edited});

/// What identifies a Canvas item's version: its title and due time. If
/// either changes in Canvas after you've edited it, it's a new version.
String canvasDueKey(Map<String, dynamic> d) => d['allDay'] == true ? 'd:${d['date']}' : 't:${(d['start'] as Timestamp?)?.millisecondsSinceEpoch}';

/// [d] with your edit ([override]: title, due, allDay) applied.
Map<String, dynamic> withOverride(Map<String, dynamic> d, Map<String, dynamic> override) {
  final out = {...d, 'title': override['title'] ?? d['title']};
  final due = asDate(override['due']);
  if (due != null) {
    if (override['allDay'] == true) {
      final day = DateTime(due.year, due.month, due.day);
      String ymd(DateTime t) => '${t.year}-${'${t.month}'.padLeft(2, '0')}-${'${t.day}'.padLeft(2, '0')}';
      out
        ..['allDay'] = true
        ..['date'] = ymd(day)
        ..['endDate'] = ymd(addDays(day, 1));
    } else {
      out
        ..['allDay'] = false
        ..['start'] = Timestamp.fromDate(due)
        ..['end'] = Timestamp.fromDate(due);
    }
  }
  return out;
}

/// Items as calendar events, skipping feeds that are gone. Checked-off
/// items ([done]) get a ✓ in front.
List<CalendarEvent> canvasEvents(List<CanvasItem> items, Map<String, CanvasFeed> feeds, Set<String> done) => [
      for (final i in items)
        if (feeds[i.data['feedId']] case final feed?)
          if (canvasEvent(i.id, i.data, feed.calendarFor(courseOf(i.data)), done: done.contains(i.id)) case final e?) e,
    ];

List<CanvasTask> canvasTasksFrom(List<CanvasItem> items, Map<String, CanvasFeed> feeds) => [
      for (final i in items)
        if (feeds[i.data['feedId']] case final feed?)
          if (CanvasTask.from(i.id, i.data, feed, edited: i.edited, source: i.source) case final t?) t,
    ]..sort((a, b) => a.due.compareTo(b.due));

/// Something on a Canvas calendar, as a to-do. Every Canvas item counts:
/// assignments, quizzes and dated course events alike.
class CanvasTask {
  CanvasTask({
    required this.id,
    required this.feed,
    required this.calendar,
    required this.title,
    required this.course,
    required this.due,
    required this.allDay,
    this.url,
    this.edited = false,
    this.source = const {},
    this.assignment = false,
    this.description = '',
    this.location = '',
    this.updated,
  });

  final String id;
  final CanvasFeed feed;

  /// You've changed it; it's no longer updated from Canvas.
  final bool edited;

  /// Canvas's own fields, as they are now (before any edit of yours).
  final Map<String, dynamic> source;

  /// Its class's calendar: color and on/off.
  final GoogleCalendar calendar;
  final String title;
  final String course;

  /// Local time; for an all-day item, the start of its day.
  final DateTime due;
  final bool allDay;
  final String? url;

  /// An assignment, quiz or discussion, as opposed to a calendar event: it's
  /// always due at a time.
  final bool assignment;
  final String description;
  final String location;

  /// When it last changed in Canvas.
  final DateTime? updated;

  static CanvasTask? from(String id, Map<String, dynamic> d, CanvasFeed feed, {bool edited = false, Map<String, dynamic> source = const {}}) {
    final due = canvasDue(d);
    if (due == null) return null;
    final assignment = d['task'] == true;
    final url = d['url'] as String?;
    return CanvasTask(
      id: id,
      feed: feed,
      calendar: feed.calendarFor(courseOf(d)),
      title: '${d['title'] ?? '(No title)'}',
      course: '${d['course'] ?? ''}',
      due: due,
      allDay: d['allDay'] == true && !assignment,
      url: url?.isNotEmpty == true ? canvasItemLink(url!) : null,
      edited: edited,
      source: source,
      assignment: assignment,
      description: '${d['description'] ?? ''}',
      location: '${d['location'] ?? ''}',
      updated: asDate(d['canvasUpdated'])?.toLocal(),
    );
  }
}

/// Canvas's feed links point at the calendar (…/calendar?include_contexts=
/// course_123#assignment_456). This turns them into the assignment's own
/// page, …/courses/123/assignments/456 (quizzes and discussions are
/// assignments too, and Canvas sends those links on to them).
String canvasItemLink(String url) {
  final u = Uri.tryParse(url);
  if (u == null || !u.hasAuthority) return url;
  final course = RegExp(r'course_(\d+)').firstMatch(u.queryParameters['include_contexts'] ?? '')?.group(1);
  final assignment = RegExp(r'^assignment_(\d+)$').firstMatch(u.fragment)?.group(1);
  if (course != null && assignment != null) return 'https://${u.authority}/courses/$course/assignments/$assignment';
  final event = RegExp(r'^calendar_event_(\d+)$').firstMatch(u.fragment)?.group(1);
  if (event != null) {
    return 'https://${u.authority}/calendar?event_id=$event${course == null ? '' : '&include_contexts=course_$course'}';
  }
  return url;
}

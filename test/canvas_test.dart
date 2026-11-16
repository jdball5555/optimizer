import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:optimizer/calendar/canvas.dart';
import 'package:optimizer/calendar/canvas_section.dart';

void main() {
  final feed = CanvasFeed('f1', {'name': 'Fall classes', 'color': '#22C55E'});

  test('an assignment due at a moment is a chip on its due day, with the time in the title', () {
    final due = DateTime(2026, 11, 7, 23, 59);
    final e = canvasEvent('i1', {
      'feedId': 'f1', 'title': 'Essay 2', 'course': 'ENGL 101', 'task': true, 'allDay': false,
      'start': Timestamp.fromDate(due), 'end': Timestamp.fromDate(due), 'url': 'https://x.instructure.com/a',
    }, feed.calendarFor('ENGL 101'))!;
    expect(e.allDay, isTrue);
    expect(e.start, DateTime(2026, 11, 7));
    expect(e.title, 'Essay 2 · ${DateFormat.jm().format(due)}');
    expect(e.due, due);
    expect(e.location, isEmpty);
    expect(e.description, startsWith('Due Sat, Nov 7'));
    expect(e.htmlLink, 'https://x.instructure.com/a');
    expect(e.calendar.canWrite, isFalse);
  });

  test('a Canvas event with a real length stays a timed event', () {
    final s = DateTime(2026, 11, 12, 14), en = DateTime(2026, 11, 12, 15, 30);
    final e = canvasEvent('i2', {'title': 'Review session', 'allDay': false, 'start': Timestamp.fromDate(s), 'end': Timestamp.fromDate(en)}, feed.calendarFor('BIO 110'))!;
    expect([e.allDay, e.start, e.end], [false, s, en]);
  });

  test('all-day items use their local date', () {
    final e = canvasEvent('i3', {'title': 'No class', 'allDay': true, 'date': '2026-11-10', 'endDate': '2026-11-11'}, feed.calendarFor('BIO 110'))!;
    expect([e.allDay, e.start, e.end], [true, DateTime(2026, 11, 10), DateTime(2026, 11, 11)]);
  });

  group('an assignment with only a date is due at 11:59 PM', () {
    // What the server stores for Canvas's "all day": the date, and midnight UTC for queries.
    Map<String, dynamic> dateOnly({bool task = true}) => {
          'feedId': 'f1', 'title': 'Lab 4', 'course': 'BIO 110', 'task': task, 'allDay': true, 'date': '2026-11-15', 'endDate': '2026-11-16',
          'start': Timestamp.fromDate(DateTime.utc(2026, 11, 15)), 'end': Timestamp.fromDate(DateTime.utc(2026, 11, 16)),
        };
    final due = DateTime(2026, 11, 15, 23, 59);

    test('on the calendar, the same as one with a time', () {
      final e = canvasEvent('i', dateOnly(), feed.calendarFor('BIO 110'))!;
      expect(e.title, 'Lab 4 · ${DateFormat.jm().format(due)}');
      expect([e.allDay, e.start, e.end], [true, DateTime(2026, 11, 15), DateTime(2026, 11, 16)]);
      // Not midnight UTC, which is the evening before in the US.
      expect(e.description, startsWith('Due ${DateFormat('EEE, MMM d · h:mm a').format(due)}'));
    });

    test('on the to-do list', () {
      final t = CanvasTask.from('i', dateOnly(), feed)!;
      expect([t.due, t.allDay, t.assignment], [due, false, true]);
    });

    test('a calendar event like "No class" really is all day', () {
      final t = CanvasTask.from('i', dateOnly(task: false), feed)!;
      expect([t.due, t.allDay], [DateTime(2026, 11, 15), true]);
      final e = canvasEvent('i', dateOnly(task: false), feed.calendarFor('BIO 110'))!;
      expect(e.title, 'Lab 4');
      expect(e.due, isNull);
    });

    test('your edit of its day keeps the time', () {
      final edited = withOverride(dateOnly(), {'title': 'Lab 4', 'due': Timestamp.fromDate(DateTime(2026, 11, 20)), 'allDay': true});
      expect(CanvasTask.from('i', edited, feed)!.due, DateTime(2026, 11, 20, 23, 59));
    });
  });

  test('everything in the feed shows up: location, description, when it last changed', () {
    final s = DateTime(2026, 12, 1, 9), en = DateTime(2026, 12, 1, 10);
    final d = {
      'title': 'Office hours', 'course': 'BIO 110', 'kind': 'event', 'task': false, 'allDay': false, 'start': Timestamp.fromDate(s), 'end': Timestamp.fromDate(en),
      'location': 'Science Hall 102', 'description': 'Bring your lab notebook', 'canvasUpdated': Timestamp.fromDate(DateTime(2026, 11, 1, 12)),
    };
    final e = canvasEvent('i', d, feed.calendarFor('BIO 110'))!;
    expect(e.location, 'Science Hall 102');
    expect(e.description, contains('Bring your lab notebook'));
    expect(e.description, contains('Updated in Canvas Nov 1'));
    final t = CanvasTask.from('i', d, feed)!;
    expect([t.location, t.description, t.updated], ['Science Hall 102', 'Bring your lab notebook', DateTime(2026, 11, 1, 12)]);
  });

  test('feed links are recognized', () {
    expect(looksLikeCanvasFeed('https://canvas.example.edu/feeds/calendars/user_abc123XYZ.ics'), isTrue);
    expect(looksLikeCanvasFeed('webcal://school.instructure.com/feeds/calendars/user_A1-b.ics'), isTrue);
    expect(looksLikeCanvasFeed('https://canvas.example.edu/calendar'), isFalse);
  });

  test('a group splits into one calendar per class, with Other for items without a class', () {
    final g = CanvasFeed('g1', {'name': 'Fall 2026', 'courseColors': {'ENGL 101': '#22C55E'}});
    final a = CanvasTask.from('a', {'title': 'Essay', 'course': 'ENGL 101', 'allDay': true, 'date': '2026-11-02'}, g)!;
    final b = CanvasTask.from('b', {'title': 'Reading', 'course': '', 'allDay': true, 'date': '2026-11-02'}, g)!;
    expect(a.calendar.name, 'ENGL 101');
    expect(a.calendar.color, const Color(0xFF22C55E));
    expect(b.calendar.name, otherCourse);
    expect(a.calendar.key, isNot(b.calendar.key));
    // Same class, same calendar object, so on/off and color apply to all its items.
    expect(identical(g.calendarFor('ENGL 101'), a.calendar), isTrue);
  });
}

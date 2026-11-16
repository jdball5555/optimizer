import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/calendar/calendar_service.dart';
import 'package:optimizer/calendar/canvas.dart';
import 'package:optimizer/calendar/todos.dart';
import 'package:optimizer/dashboard/dashboard_page.dart';

class _CheckingService extends CalendarService {
  _CheckingService() : super('test');
  final checked = <(String, bool)>[];
  @override
  Future<void> setTodoDone(Todo t, bool done) async => checked.add((t.id, done));
}

void main() {
  test('a task checked off on the calendar is checked off as its to-do', () async {
    final feed = CanvasFeed('f', {'name': 'Fall', 'courseColors': {}});
    final day = DateTime(2026, 11, 3);
    final svc = _CheckingService();
    svc.canvasTasks = [
      CanvasTask(id: 'i1', feed: feed, calendar: feed.calendarFor('BIO'), title: 'Lab', course: 'BIO', due: day, allDay: true),
    ];
    final event = canvasEvent('i1', {'title': 'Lab', 'allDay': true, 'date': '2026-11-03', 'endDate': '2026-11-04'}, feed.calendarFor('BIO'))!;
    await svc.setEventDone(event, true);
    expect(svc.checked, [('i1', true)]);
  });

  test('Canvas feed links go to the assignment itself', () {
    expect(canvasItemLink('https://school.instructure.com/calendar?include_contexts=course_123&month=11#assignment_456'),
        'https://school.instructure.com/courses/123/assignments/456');
    expect(canvasItemLink('https://canvas.example.edu/calendar?include_contexts=course_9#calendar_event_77'),
        'https://canvas.example.edu/calendar?event_id=77&include_contexts=course_9');
    expect(canvasItemLink('https://example.com/other'), 'https://example.com/other');
  });

  test('same-day to-dos: by class, then A to Z, your own last', () {
    final feed = CanvasFeed('f', {'name': 'Fall', 'courseColors': {}});
    final day = DateTime(2026, 11, 3);
    Todo canvas(String course, String title) => Todo.canvas(
        CanvasTask(id: '$course$title', feed: feed, calendar: feed.calendarFor(course), title: title, course: course, due: day, allDay: true),
        done: false);
    final list = [
      canvas('MATH 151', 'Problem set 6'),
      Todo.manual('m', {'title': 'Buy notebook', 'allDay': true}),
      canvas('BIO 110', 'quiz 4'),
      canvas('BIO 110', 'Lab report'),
      canvas('ENGL 101', 'Essay'),
    ]..sort(Todo.byClassThenTitle);
    expect([for (final t in list) t.title], ['Lab report', 'quiz 4', 'Essay', 'Problem set 6', 'Buy notebook']);
  });

  test('greetings, including up late', () {
    expect(greetingAt(DateTime(2026, 11, 1, 8)), 'Good morning');
    expect(greetingAt(DateTime(2026, 11, 1, 14)), 'Good afternoon');
    expect(greetingAt(DateTime(2026, 11, 1, 19)), 'Good evening');
    expect(greetingAt(DateTime(2026, 11, 1, 23, 30)), 'Up late');
    expect(greetingAt(DateTime(2026, 11, 1, 2)), 'Up late');
  });
}

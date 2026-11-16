import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/util/fields.dart';
import 'package:optimizer/calendar/timeline_layout.dart';

final day = DateTime(2026, 10, 27);
TimelineItem<String> item(String name, double startHour, double hours) => TimelineItem(
      name,
      day.add(Duration(minutes: (startHour * 60).round())),
      day.add(Duration(minutes: ((startHour + hours) * 60).round())),
    );

void main() {
  const hourWidth = 96.0, height = 120.0;
  void run(List<TimelineItem<String>> items) =>
      layoutTimeline(items, dayStart: day, hourWidth: hourWidth, height: height);

  test('a lone event fills the row', () {
    final a = item('a', 9, 1);
    run([a]);
    expect(a.depth, 0);
    expect(a.rect.height, greaterThan(height - 12));
  });

  test('two long events side by side, a later third goes on top of both without covering their titles', () {
    final a = item('a', 9, 6), b = item('b', 9, 6), c = item('c', 12, 1);
    run([a, b, c]);
    expect([a.depth, b.depth], [0, 0]);
    expect(a.lanes, 2);
    expect(c.depth, 1);
    // c spans (almost) the full height, across both lanes.
    expect(c.rect.top, lessThan(a.rect.bottom));
    expect(c.rect.bottom, greaterThan(b.rect.top));
    // Their labels stop before c begins.
    expect(a.rect.left + a.labelWidth, lessThanOrEqualTo(c.rect.left));
    expect(b.rect.left + b.labelWidth, lessThanOrEqualTo(c.rect.left));
  });

  test('events that start close together share the height instead of covering each other', () {
    final a = item('a', 9, 2), b = item('b', 9.5, 2);
    run([a, b]);
    expect(a.depth, b.depth);
    expect(a.lanes, 2);
    expect(a.rect.overlaps(b.rect), isFalse);
  });

  test('every event ends exactly at its end time, however short', () {
    for (final (start, hours) in [(10.0, 0.25), (9.0, 0.5), (14.0, 1.0), (16.0, 2.5)]) {
      final e = item('e', start, hours);
      run([e]);
      // 1.5 px in from each end, so neighbours have a hairline between them.
      expect(e.rect.left, closeTo(start * hourWidth + 1.5, 0.01));
      expect(e.rect.right, closeTo((start + hours) * hourWidth - 1.5, 0.01));
    }
  });

  test('back-to-back short events sit side by side without overlapping', () {
    final a = item('a', 10, 0.25), b = item('b', 10.25, 0.25);
    run([a, b]);
    expect(a.rect.overlaps(b.rect), isFalse);
    expect(b.rect.left, greaterThan(a.rect.right));
  });

  test('a short event just before midnight stays inside the day', () {
    final late = item('late', 23.9, 0.1);
    run([late]);
    expect(late.rect.right, lessThanOrEqualTo(24 * hourWidth));
  });

  // Nov 1 2026 is 25 hours long in the US (clocks went back at 2 am).
  test('on the day the clocks change, events still sit at their clock time', () {
    final day = DateTime(2026, 11, 1);
    expect(clockHours(DateTime(2026, 11, 1, 9), day), 9);
    expect(clockHours(DateTime(2026, 11, 1, 23, 30), day), 23.5);
    expect(clockHours(DateTime(2026, 11, 2), day), 24);
    final items = [TimelineItem('late', DateTime(2026, 11, 1, 23), DateTime(2026, 11, 2))];
    layoutTimeline(items, dayStart: day, hourWidth: 100, height: 60);
    expect(items.single.shownEnd, DateTime(2026, 11, 2)); // not cut off at 11 pm
  });
}

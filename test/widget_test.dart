import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/calendar/month_view.dart';

void main() {
  test('month grid starts on a Sunday', () {
    final start = monthGridStart(DateTime(2026, 10, 15));
    expect(start, DateTime(2026, 9, 27));
    expect(start.weekday, DateTime.sunday);
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'preview/calendar_preview_test.dart' show FakeService;

void main() {
  test('a calendar load that finishes after sign-out is dropped, not an error', () async {
    final svc = FakeService();
    var heard = 0;
    svc.addListener(() => heard++);
    // Something still in flight when the app closes the service…
    final late = Future<void>.delayed(const Duration(milliseconds: 10), svc.notifyListeners);
    svc.dispose();
    // …finishing afterwards used to throw "A CalendarService was used after being disposed".
    await late;
    expect(heard, 0);
    expect(svc.disposed, isTrue);
    svc.dispose(); // closing twice is harmless too
  });
}

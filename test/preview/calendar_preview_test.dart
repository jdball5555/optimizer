import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/calendar/calendar_models.dart';
import 'package:optimizer/calendar/calendar_page.dart';
import 'package:optimizer/calendar/calendar_service.dart';
import 'package:optimizer/theme.dart';
import 'package:optimizer/util/fields.dart';

// Renders pages with sample data to PNGs, for eyeballing the design:
//   PREVIEW_OUT=/some/folder flutter test test/preview
// Skipped in a normal `flutter test`.
final out = Platform.environment['PREVIEW_OUT'] ?? '';
final skipPreview = out.isEmpty;
final fonts = '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';

Future<void> loadFonts() async {
  Future<ByteData> f(String n) async => ByteData.sublistView(File('$fonts/$n').readAsBytesSync());
  final roboto = FontLoader('Roboto')
    ..addFont(f('Roboto-Regular.ttf'))
    ..addFont(f('Roboto-Medium.ttf'))
    ..addFont(f('Roboto-Bold.ttf'))
    ..addFont(f('Roboto-Italic.ttf'));
  await roboto.load();
  await (FontLoader('MaterialIcons')..addFont(f('MaterialIcons-Regular.otf'))).load();
}

class FakeService extends CalendarService {
  FakeService() : super('preview');
  List<CalendarEvent> fake = [];
  @override
  List<CalendarEvent> eventsBetween(DateTime from, DateTime to) => fake.where((e) => e.overlaps(from, to)).toList();
  @override
  Future<void> loadRange(DateTime from, DateTime to, {bool force = false, bool quiet = false}) async {}
}

Future<void> shot(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
  final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
  final bytes = await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
  File('$out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  testWidgets(skip: skipPreview, 'calendar preview', (tester) async {
    await tester.runAsync(loadFonts);
    tester.view.physicalSize = const Size(1600, 940);
    tester.view.devicePixelRatio = 1;
    final svc = FakeService();
    svc.accounts.add(GoogleAccount(email: 'alex@example.com'));
    GoogleCalendar cal(String id, String name, int color) => GoogleCalendar(
        id: id, accountEmail: 'alex@example.com', name: name, color: readableColor(Color(color)), primary: id == 'p', accessRole: 'owner');
    final me = cal('p', 'Alex', 0xFF4285F4), work = cal('w', 'Work', 0xFF000000), gym = cal('g', 'Gym', 0xFF33B679), school = cal('s', 'School', 0xFFE67C73);
    svc.calendars.addAll([me, work, gym, school]);
    final today = dayStart(DateTime.now());
    final sunday = addDays(today, -(today.weekday % 7));
    CalendarEvent ev(GoogleCalendar c, int day, double h, double len, String t, {bool allDay = false, String loc = ''}) {
      final s = addDays(sunday, day).add(Duration(minutes: (h * 60).round()));
      return CalendarEvent(id: '$t$day$h', calendar: c, title: t, description: '', location: loc, start: allDay ? addDays(sunday, day) : s,
          end: allDay ? addDays(sunday, day + 1) : s.add(Duration(minutes: (len * 60).round())), allDay: allDay, color: c.color);
    }
    CalendarEvent canvas(String course, int color, int day, String title, {bool done = false}) {
      final c = GoogleCalendar(id: 'f::$course', accountEmail: 'canvas', name: course, color: Color(color), primary: false, accessRole: 'reader');
      return CalendarEvent(id: '$course$title', calendar: c, title: '${done ? '✓ ' : ''}$title', description: '', location: course,
          start: addDays(sunday, day), end: addDays(sunday, day + 1), allDay: true, color: c.color, done: done);
    }
    svc.fake = [
      ev(work, 1, 9, 1, 'Standup', loc: 'Zoom'), ev(work, 1, 10.5, 2, 'Design review'), ev(school, 1, 11, 1.5, 'CS 102'),
      ev(gym, 1, 17, 1, 'Lift'), ev(me, 1, 0, 0, 'Mom’s birthday', allDay: true),
      ev(work, 2, 8.5, 0.5, 'Email'), ev(school, 2, 13, 3, 'Lab', loc: 'Science Hall 340'),
      ev(work, 3, 9, 1, 'Standup'), ev(work, 3, 9.5, 1, '1:1 with Sam'), ev(work, 3, 10, 1, 'Planning'), ev(gym, 3, 18, 1.5, 'Run'),
      ev(me, 4, 12, 1, 'Lunch with Alex', loc: 'Taco Stand'), ev(school, 4, 14, 2, 'Study group'),
      ev(work, 5, 9, 8, 'Offsite', loc: 'HQ'), ev(me, 5, 0, 0, 'Payday', allDay: true), ev(me, 5, 0, 0, 'Trip', allDay: true),
      ev(gym, 6, 10, 1.5, 'Long run'), ev(me, 0, 19, 2, 'Dinner'),
      ev(work, 0, 13, 6, 'Shift A'), ev(school, 0, 13, 6, 'Shift B'), ev(me, 0, 15, 1, 'Call with Dad'),
      ev(me, 0, 20.5, 0.25, 'Take meds'), ev(gym, 0, 21, 0.5, 'Stretch'), ev(work, 0, 22, 0.25, 'Pack bag'),
      ev(me, 5, 0, 0, 'Halloween party', allDay: true), ev(school, 5, 0, 0, 'Quiz due', allDay: true),
      // Canvas items on Friday: after your own, by class then name; checked off last.
      canvas('ENGL 101', 0xFFA855F7, 5, 'Essay 2'), canvas('BIO 110', 0xFF22C55E, 5, 'Lab 7 prelab'),
      canvas('BIO 110', 0xFF22C55E, 5, 'Quiz 4', done: true), canvas('BIO 110', 0xFF22C55E, 5, 'Chapter 9 reading'),
    ];
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      debugShowCheckedModeBanner: false,
      home: RepaintBoundary(key: const ValueKey('shot'), child: CalendarPage(service: svc)),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await shot(tester, 'week');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump(const Duration(milliseconds: 100));
    await shot(tester, 'month');
    await tester.tap(find.text('Week').last);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byTooltip('All-day events beside the date'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byTooltip('Show to-do list'));
    await tester.pump(const Duration(milliseconds: 300));
    await shot(tester, 'week_allday_todo');
    await tester.tap(find.byTooltip('All-day events under the date'));
    await tester.tap(find.byTooltip('Hide to-do list'));
    await tester.pump(const Duration(milliseconds: 100));
    tester.view.reset();
  });
}

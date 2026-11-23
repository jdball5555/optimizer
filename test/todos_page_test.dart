import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/calendar/canvas.dart';
import 'package:optimizer/calendar/canvas_section.dart';
import 'package:optimizer/calendar/month_view.dart';
import 'package:optimizer/calendar/todo_view.dart';
import 'package:optimizer/calendar/todos.dart';
import 'package:optimizer/shell/side_nav.dart';
import 'package:optimizer/theme.dart';
import 'package:optimizer/todos/todos_page.dart';
import 'package:optimizer/widgets/tiles.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview/calendar_preview_test.dart' show loadFonts, skipPreview;
import 'preview/pages_preview_test.dart' show FeedService, shot;

/// No Firestore: sorting into the matrix only changes what's shown.
class _Service extends FeedService {
  final sorted = <(String, Quadrant?)>[];
  final checked = <(String, bool)>[];
  var refreshes = 0;

  @override
  Future<List<String>> refreshCanvas({CanvasFeed? only}) async {
    refreshes++;
    return const [];
  }

  @override
  Future<void> setTodoDone(Todo t, bool done) async {
    checked.add((t.id, done));
    return super.setTodoDone(t, done);
  }

  @override
  Future<void> setTodoMatrix(bool on) async {
    todoMatrix = on;
    notifyListeners();
  }

  @override
  Future<void> setTodoQuadrant(Todo t, Quadrant? q) async {
    sorted.add((t.id, q));
    manualTodos = [
      for (final m in manualTodos)
        m.id == t.id ? Todo.manual(m.id, {'title': m.title, 'allDay': true, 'listId': m.listId, if (q != null) 'quadrant': q.key}) : m,
    ];
    notifyListeners();
  }
}

_Service _service({bool canvas = true, bool matrix = false}) {
  final svc = _Service();
  final now = DateTime.now();
  if (canvas) {
    final feed = CanvasFeed('f', {'name': 'Fall 2026', 'courseColors': {}, 'todoList': 'school'});
    svc.canvasFeeds.add(feed);
    svc.canvasTasks = [
      CanvasTask(
          id: 'c1',
          feed: feed,
          calendar: feed.calendarFor('BIO 110'),
          title: 'Lab report',
          course: 'BIO 110',
          due: DateTime(now.year, now.month, now.day, 23, 59),
          allDay: false,
          assignment: true),
    ];
  }
  svc.todoLists = [
    if (canvas) TodoList('school', {'name': 'School', 'order': 0}),
    TodoList('w', {'name': 'Work', 'order': 1}),
  ];
  svc.manualTodos = [
    Todo.manual('m1', {'title': 'Buy notebook', 'allDay': true}),
    Todo.manual('m2', {'title': 'Send invoice', 'allDay': true, 'listId': 'w', 'quadrant': 'urgentImportant'}),
  ];
  svc.todoMatrix = matrix;
  return svc;
}

Future<void> _pump(WidgetTester t, Widget page, {Size size = const Size(1400, 900)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: page)));
  await t.pump(const Duration(milliseconds: 200));
}

/// Picks [label] from the View button's menu.
Future<void> _view(WidgetTester t, String label) async {
  await t.tap(find.byTooltip('View'));
  await t.pumpAndSettle();
  await t.tap(find.text(label).last); // the menu's, if a box has the same name
  await t.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Groups: a column for the main group and each group you made, Canvas in the one it was put in', (t) async {
    await _pump(t, TodosPage(service: _service()));
    await _view(t, 'Groups');
    for (final title in ['To-dos', 'School', 'Work']) {
      expect(find.text(title), findsWidgets, reason: title);
    }
    // Each to-do is in its own list's column.
    Finder inColumn(String column, String todo) => find.descendant(
        of: find.ancestor(of: find.text(column), matching: find.byWidgetPredicate((w) => w is SizedBox && w.width == 320)).first,
        matching: find.text(todo));
    expect(inColumn('School', 'Lab report'), findsOneWidget);
    expect(inColumn('To-dos', 'Buy notebook'), findsOneWidget);
    expect(inColumn('Work', 'Send invoice'), findsOneWidget);
    expect(find.text('Urgent / important'), findsNothing, reason: 'the matrix is off');
    expect(t.takeException(), isNull);
  });

  testWidgets('the first time: all to-dos and a month, then a toolbar in the middle; Groups shows one blank group', (t) async {
    await _pump(t, TodosPage(service: _Service()));
    expect(find.byType(TodoView), findsOneWidget);
    expect(find.byType(MonthView), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byTooltip('Options'), findsNothing, reason: 'the View button replaced it');
    for (final gone in ['Add a to-do', 'New list', 'New group', 'Link Canvas', 'Add Canvas', 'School', 'Groups']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    // The toolbar, in the middle of the title's row: the view it's on, then New.
    final title = t.getRect(find.text('To-dos'));
    final view = t.getRect(find.byTooltip('View'));
    final add = t.getRect(find.byTooltip('Add'));
    expect(find.text('List & calendar'), findsNothing, reason: 'icons only');
    expect(find.byIcon(Icons.vertical_split_outlined), findsOneWidget, reason: 'the view it’s on');
    expect(view.left, greaterThan(title.right));
    expect(add.left, greaterThan(view.right - 1));
    expect((view.left + add.right) / 2, moreOrLessEquals(1400 / 2, epsilon: 12), reason: 'in the middle');
    expect(view.center.dy, moreOrLessEquals(title.center.dy, epsilon: 6));

    // Three views.
    await t.tap(find.byTooltip('View'));
    await t.pumpAndSettle();
    for (final item in ['Urgent / important', 'Groups']) {
      expect(find.text(item), findsOneWidget, reason: item);
    }
    expect(find.text('List & calendar'), findsOneWidget);
    await t.tap(find.text('Groups'));
    await t.pumpAndSettle();
    expect(find.text('To-dos'), findsNWidgets(2), reason: 'the title and the group');
    expect(find.byType(MonthView), findsNothing);

    // The + offers a to-do, a group, or a Canvas calendar.
    await t.tap(find.byIcon(Icons.add));
    await t.pumpAndSettle();
    for (final item in ['New to-do', 'New group', 'Sync a Canvas calendar']) {
      expect(find.text(item), findsOneWidget, reason: item);
    }
    await t.tapAt(const Offset(5, 500));
    await t.pumpAndSettle();
  });

  testWidgets('picking the matrix view switches the matrix on (and the list and calendar, off)', (t) async {
    final svc = _service();
    await _pump(t, TodosPage(service: svc));
    await _view(t, 'Urgent / important');
    expect(svc.todoMatrix, isTrue);
    expect(find.text('Not sorted'), findsOneWidget);
    expect(find.byType(MonthView), findsNothing);
    await _view(t, 'Groups');
    expect(svc.todoMatrix, isTrue, reason: 'groups leave it as it was');
    await _view(t, 'List & calendar');
    expect(svc.todoMatrix, isFalse);
    expect(find.byType(MonthView), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('the buttons leave room for the assistant’s arrow, however wide', (t) async {
    const arrow = ValueKey('arrow');
    await _pump(t, PageEnd(end: const SizedBox(key: arrow, width: 57, height: 40), child: TodosPage(service: FeedService())));
    expect(find.byKey(arrow), findsOneWidget);
    expect(t.getRect(find.byTooltip('Add')).right, lessThanOrEqualTo(t.getRect(find.byKey(arrow)).left));
  });

  test('a Canvas calendar not in a group you have is in the main one', () {
    final svc = _service();
    expect([for (final f in svc.canvasFeedsIn('school')) f.id], ['f']);
    svc.canvasFeeds[0] = CanvasFeed('f', {'name': 'Fall 2026', 'todoList': 'gone'});
    expect(svc.canvasFeedsIn('school'), isEmpty);
    expect([for (final f in svc.canvasFeedsIn(TodoList.mainListId)) f.id], ['f']);
  });

  testWidgets('the matrix: four boxes, and what’s not sorted yet beside them to drag in', (t) async {
    final svc = _service(matrix: true);
    await _pump(t, TodosPage(service: svc));
    for (final q in Quadrant.values) {
      expect(find.text(q.title), findsOneWidget, reason: q.title);
    }
    expect(find.text('Not sorted'), findsOneWidget);
    // Already sorted: in its box, not in the waiting column.
    expect(find.text('Send invoice'), findsOneWidget);

    // Tests run as a touch screen: press and hold, then drag.
    final drag = await t.startGesture(t.getCenter(find.text('Buy notebook')));
    await t.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await drag.moveBy(const Offset(20, 0));
    await t.pump();
    await drag.moveTo(t.getCenter(find.text(Quadrant.schedule.title)));
    await t.pump();
    await drag.up();
    await t.pump(const Duration(milliseconds: 200));
    expect(svc.sorted, [('m1', Quadrant.schedule)]);
    expect(t.takeException(), isNull);
  });

  testWidgets('the month shows only to-dos, to check off there', (t) async {
    final svc = _service();
    await _pump(t, TodosPage(service: svc));
    final month = find.byType(MonthView);
    expect(find.descendant(of: month, matching: find.textContaining('Lab report')), findsOneWidget);
    final circle = find.descendant(of: month, matching: find.byType(TaskCircle));
    expect(circle, findsOneWidget, reason: 'only the one with a date');
    await t.tap(circle);
    await t.pump();
    expect(svc.checked, [('c1', true)]);
    expect(t.takeException(), isNull);
  });

  test('a to-do on the month: the day it’s due, with its time', () {
    final e = todoEvent(Todo.manual('m', {'title': 'Call', 'allDay': false, 'due': DateTime(2026, 12, 3, 15)}))!;
    expect([e.start, e.isTask, e.title], [DateTime(2026, 12, 3), true, 'Call · ${DateFormat.jm().format(DateTime(2026, 12, 3, 15))}']);
    expect(todoEvent(Todo.manual('n', {'title': 'Someday'})), isNull);
  });

  testWidgets('a to-do’s ⋯ shows what you can do right away, no second panel', (t) async {
    final svc = _service(matrix: true);
    await _pump(t, TodosPage(service: svc));
    // In the matrix: the row's ⋯.
    final row = find.ancestor(of: find.text('Buy notebook'), matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_TodoRow'));
    await t.tap(find.descendant(of: row, matching: find.byTooltip('Options')));
    await t.pumpAndSettle();
    for (final item in ['Edit', 'Mark done', 'Delete']) {
      expect(find.text(item), findsOneWidget, reason: item);
    }
    expect(find.text(Quadrant.schedule.title), findsNWidgets(2), reason: 'its box, and the menu item to move it there');
    expect(find.byType(BottomSheet), findsNothing);
    await t.tap(find.text(Quadrant.schedule.title).last);
    await t.pumpAndSettle();
    expect(svc.sorted, [('m1', Quadrant.schedule)]);

    // In the list: its ⋯ shows on hover, or a long press.
    await _view(t, 'List & calendar');
    await t.longPress(find.descendant(of: find.byType(TodoView), matching: find.text('Lab report')));
    await t.pumpAndSettle();
    for (final item in ['Edit', 'Mark done', 'Details']) {
      expect(find.text(item), findsOneWidget, reason: item);
    }
    expect(find.text('Options'), findsNothing);
    expect(find.text('Delete'), findsNothing, reason: 'Canvas items aren’t yours to delete');
  });

  testWidgets('the matrix takes the month’s place', (t) async {
    await _pump(t, TodosPage(service: _service(matrix: true)));
    expect(find.byType(MonthView), findsNothing);
    expect(find.text('Not sorted'), findsOneWidget);
  });

  for (final size in const [Size(412, 915), Size(360, 700)]) {
    testWidgets('fits a phone, ${size.width.toInt()} wide: list, month, groups and matrix', (t) async {
      await _pump(t, TodosPage(service: _service()), size: size);
      expect(find.byType(TodoView), findsOneWidget);
      expect(find.byType(MonthView), findsNothing, reason: 'a view of its own on a phone');
      await t.tap(find.byTooltip('View'));
      await t.pumpAndSettle();
      expect(find.text('List'), findsOneWidget);
      await t.tapAt(const Offset(5, 600));
      await t.pumpAndSettle();
      await _view(t, 'Calendar');
      expect(find.byType(MonthView), findsOneWidget);
      expect(find.byType(TodoView), findsNothing);
      await _view(t, 'Groups');
      expect(t.takeException(), isNull);

      await _pump(t, TodosPage(service: _service(matrix: true)), size: size);
      // Groups is remembered from above: back to the matrix.
      await _view(t, 'Urgent / important');
      expect(find.text('Not sorted'), findsOneWidget);
      expect(find.text(Quadrant.schedule.tag), findsOneWidget, reason: 'short names in narrow boxes');
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('the calendar’s to-do list stays by date, tagged with each box', (t) async {
    final svc = _service(matrix: true);
    await _pump(t, TodoView(service: svc, onAddCanvas: () {}));
    expect(find.text('Send invoice'), findsOneWidget);
    expect(find.byType(QuadrantTag), findsOneWidget);
    expect(find.text(Quadrant.doFirst.tag), findsOneWidget);

    svc.todoMatrix = false;
    await _pump(t, TodoView(service: svc, onAddCanvas: () {}));
    expect(find.byType(QuadrantTag), findsNothing);
  });

  test('only Canvas calendar links can be added; Google Calendar ones are told why', () {
    expect(looksLikeCanvasFeed('https://school.instructure.com/feeds/calendars/user_abc123.ics'), isTrue);
    for (final google in [
      'https://calendar.google.com/calendar/ical/me%40gmail.com/private-abc/basic.ics',
      'https://calendar.google.com/calendar/u/0/r',
      'webcal://calendar.google.com/calendar/ical/x/public/basic.ics',
    ]) {
      expect(looksLikeCanvasFeed(google), isFalse, reason: google);
      expect(looksLikeGoogleCalendar(google), isTrue, reason: google);
    }
    expect(looksLikeGoogleCalendar('https://school.instructure.com/feeds/calendars/user_abc123.ics'), isFalse);
  });

  test('a to-do keeps its list and box', () {
    final t = Todo.manual('x', {'title': 'A', 'listId': 'w', 'quadrant': 'neither'});
    expect(t.listId, 'w');
    expect(t.quadrant, Quadrant.drop);
    expect(Todo.manual('y', {'title': 'B'}).quadrant, isNull);
  });

  testWidgets('the side bar sets a group of pages apart with lines', (t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: Row(children: [
          SideNav(
            items: const [
              (icon: Icons.check_circle_outline, selected: Icons.check_circle, label: 'To-dos'),
              (icon: Icons.settings_outlined, selected: Icons.settings, label: 'Settings'),
              (icon: Icons.dashboard_outlined, selected: Icons.dashboard, label: 'Home'),
            ],
            linesBefore: const {2, 3},
            selected: 0,
            onSelected: (_) {},
            account: (open) => SideNavAccount(name: 'D', email: 'd@example.com', expanded: open, onSettings: () {}, onSignOut: () {}),
          ),
          const Expanded(child: SizedBox()),
        ]),
      ),
    ));
    await t.pumpAndSettle();
    final lines = find.descendant(of: find.byType(SideNav), matching: find.byType(Divider));
    expect(lines, findsNWidgets(2));
    final y = [for (var i = 0; i < 2; i++) t.getCenter(lines.at(i)).dy];
    expect(y.first, greaterThan(t.getCenter(find.text('Settings')).dy));
    expect(y.first, lessThan(t.getCenter(find.text('Home')).dy));
    expect(y.last, greaterThan(t.getCenter(find.text('Home')).dy));
  });

  for (final (name, size) in const [('wide', Size(1500, 900)), ('phone', Size(390, 844)), ('small', Size(360, 740))]) {
    testWidgets(skip: skipPreview, 'todos_$name', (t) async {
      await t.runAsync(loadFonts);
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      for (final (shotName, matrix, tab) in [
        ('all', false, null),
        ('month', false, 'Calendar'),
        ('groups', false, 'Groups'),
        ('matrix', true, null)
      ]) {
        await t.pumpWidget(MaterialApp(
          theme: buildTheme(),
          debugShowCheckedModeBanner: false,
          builder: (_, c) => RepaintBoundary(key: const ValueKey('shot'), child: c!),
          home: Scaffold(body: SafeArea(child: TodosPage(service: _service(matrix: matrix)))),
        ));
        await t.pump(const Duration(milliseconds: 300));
        if (tab != null) {
          await t.tap(find.byTooltip('View'));
          await t.pumpAndSettle();
          if (find.text(tab).evaluate().isNotEmpty) {
            await t.tap(find.text(tab));
          } else {
            await t.tapAt(const Offset(5, 600));
          }
          await t.pumpAndSettle();
        }
        await shot(t, 'todos_${name}_$shotName');
      }
      t.view.reset();
    });
  }

  group('the toolbar', () {
    testWidgets('centered on the whole page, however long the space beside the title', (t) async {
      for (final width in [1400.0, 900.0, 720.0]) {
        await _pump(t, TodosPage(service: _Service()), size: Size(width, 900));
        final bar = t.getRect(find.ancestor(of: find.byTooltip('View'), matching: find.byType(Material)).first);
        expect(bar.center.dx, moreOrLessEquals(width / 2, epsilon: 1), reason: '$width wide');
      }
    });

    testWidgets('on a small phone it moves over just enough to clear the title', (t) async {
      await t.runAsync(loadFonts); // the real font: the test one's letters are much wider
      await _pump(t, PageMenu(open: () {}, child: TodosPage(service: _service())), size: const Size(360, 740));
      final title = t.getRect(find.text('To-dos').first);
      final bar = t.getRect(find.byTooltip('View'));
      expect(bar.left, greaterThan(title.right + 8));
      // With Canvas linked, its refresh (and when) fits too, the title whole.
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(t.renderObject<RenderParagraph>(find.text('To-dos').first).didExceedMaxLines, isFalse);
      expect(t.takeException(), isNull);
    });

    testWidgets('without premium beta: Canvas checked on opening, a refresh button saying when', (t) async {
      final svc = _service();
      svc.canvasFeeds[0] = CanvasFeed('f', {
        'name': 'Fall 2026',
        'todoList': 'school',
        'lastChecked': Timestamp.fromDate(DateTime.now().subtract(const Duration(minutes: 12))),
      });
      await _pump(t, TodosPage(service: svc));
      expect(svc.refreshes, 1, reason: 'checked twelve minutes ago: checked again on opening');
      expect(find.text('Updated 12 min ago'), findsOneWidget);
      await t.tap(find.byIcon(Icons.refresh));
      await t.pump();
      expect(svc.refreshes, 2);
    });

    testWidgets('checked a moment ago: opening doesn’t check again', (t) async {
      final svc = _service();
      svc.canvasFeeds[0] = CanvasFeed('f', {'name': 'Fall 2026', 'todoList': 'school', 'lastChecked': Timestamp.now()});
      await _pump(t, TodosPage(service: svc));
      expect(svc.refreshes, 0);
      expect(find.text('Updated just now'), findsOneWidget);
    });

    testWidgets('with premium beta the server checks every minute: no check on opening, just the icon', (t) async {
      final svc = _service();
      await _pump(t, TodosPage(service: svc, premium: true));
      expect(svc.refreshes, 0);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(find.textContaining('Updated'), findsNothing);
    });

    testWidgets('after five refreshes in five minutes it waits, saying until when', (t) async {
      final svc = _service();
      svc.canvasRetryAt = DateTime.now().add(const Duration(minutes: 3));
      await _pump(t, TodosPage(service: svc, premium: true));
      await t.tap(find.byIcon(Icons.refresh));
      await t.pump();
      expect(svc.refreshes, 0);
      expect(find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('Refreshed 5 times in 5 minutes')), findsOneWidget);
    });
  });

  test('when Canvas was last updated, in words', () {
    final now = DateTime(2026, 11, 23, 15);
    expect(canvasUpdatedText(null, now), 'Not updated yet');
    expect(canvasUpdatedText(now.subtract(const Duration(seconds: 20)), now), 'Updated just now');
    expect(canvasUpdatedText(now.subtract(const Duration(minutes: 3)), now), 'Updated 3 min ago');
    expect(canvasUpdatedText(now.subtract(const Duration(minutes: 3)), now, short: true), '3m');
    expect(canvasUpdatedText(now.subtract(const Duration(hours: 2)), now, short: true), '2h');
    expect(canvasUpdatedText(DateTime(2026, 11, 20), now), 'Updated Nov 20');
  });
}

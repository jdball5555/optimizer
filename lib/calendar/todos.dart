import 'package:flutter/material.dart';

import '../theme.dart';
import '../util/fields.dart';
import 'calendar_models.dart';
import 'canvas.dart';

/// One line of the to-do list: either something from a Canvas class, or a
/// to-do you added yourself (axisCalendar/{uid}/todos/{id}).
class Todo {
  Todo.canvas(CanvasTask t, {required this.done, this.doneAt, this.quadrant})
      : id = t.id,
        listId = null,
        fromCanvas = null,
        edited = t.edited,
        title = t.title,
        label = t.calendar.name,
        color = t.calendar.color,
        due = t.due,
        allDay = t.allDay,
        url = t.url,
        canvas = t;

  Todo.manual(this.id, Map<String, dynamic> d)
      : title = '${d['title'] ?? ''}',
        // An edited Canvas item that Canvas later changed keeps its class.
        label = '${d['label'] ?? ''}',
        color = d['color'] is String ? readableColor(parseHexColor(d['color'] as String, AppColors.primaryText)) : AppColors.primaryText,
        due = asDate(d['due']),
        allDay = d['allDay'] != false,
        url = d['url'] as String?,
        done = d['done'] == true,
        doneAt = asDate(d['doneAt']),
        listId = d['listId'] as String?,
        quadrant = Quadrant.parse(d['quadrant']),
        fromCanvas = d['fromCanvas'] as String?,
        edited = false,
        canvas = null;

  final String id;
  final String title;

  /// The class, for Canvas items; empty for your own.
  final String label;
  final Color color;

  /// Local time; the start of the day when [allDay]. Null: no date.
  final DateTime? due;
  final bool allDay;
  final String? url;
  final bool done;

  /// When you checked it off.
  final DateTime? doneAt;

  /// A Canvas item you've changed (so Canvas no longer updates it).
  final bool edited;

  /// The Canvas item behind it, if any.
  final CanvasTask? canvas;

  /// Your own to-do's group (axisCalendar/{uid}/todoLists/{id}). Null: the
  /// main one. Canvas items are in the group their calendar was put in.
  final String? listId;

  /// Where it sits in the urgent / important matrix; null: not sorted yet.
  final Quadrant? quadrant;

  /// For your edited copy of a Canvas item, the item it came from.
  final String? fromCanvas;

  bool get isCanvas => canvas != null;

  /// Same day: by class, then A to Z (your own to-dos after the classes).
  static int byClassThenTitle(Todo a, Todo b) {
    if (a.label.isEmpty != b.label.isEmpty) return a.label.isEmpty ? 1 : -1;
    final c = a.label.toLowerCase().compareTo(b.label.toLowerCase());
    return c != 0 ? c : a.title.toLowerCase().compareTo(b.title.toLowerCase());
  }
}

/// The four boxes of the urgent / important (Eisenhower) matrix.
enum Quadrant {
  doFirst('urgentImportant', 'Urgent & important', 'Do it now', 'Urgent + important'),
  schedule('important', 'Important, not urgent', 'Plan a time for it', 'Important'),
  delegate('urgent', 'Urgent, not important', 'Hand it off or keep it quick', 'Urgent'),
  drop('neither', 'Not urgent or important', 'Drop it, or do it last', 'Neither');

  const Quadrant(this.key, this.title, this.hint, this.tag);

  /// As saved in Firestore.
  final String key;
  final String title;

  /// What to do with what's in it.
  final String hint;

  /// The short label on a to-do.
  final String tag;

  static Quadrant? parse(Object? key) => values.where((q) => q.key == key).firstOrNull;
}

/// A group of to-dos you made (axisCalendar/{uid}/todoLists/{id}): a column
/// on the To-dos page. A Canvas calendar's items go in the group it was put
/// in ([CanvasFeed.todoList]), its own or one shared with your to-dos.
class TodoList {
  TodoList(this.id, Map<String, dynamic> d)
      : name = '${d['name'] ?? 'List'}',
        order = (d['order'] as num?)?.toDouble() ?? 0;

  const TodoList.main(this.name)
      : id = mainListId,
        order = -1;

  final String id;
  final String name;
  final double order;

  bool get isMain => id == mainListId;

  /// The group your to-dos go in unless you pick another: to-dos with no list.
  static const mainListId = '';
}

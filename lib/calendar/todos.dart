import 'package:flutter/material.dart';

import '../theme.dart';
import '../util/fields.dart';
import 'calendar_models.dart';
import 'canvas.dart';

/// One line of the to-do list: either something from a Canvas class, or a
/// to-do you added yourself (axisCalendar/{uid}/todos/{id}).
class Todo {
  Todo.canvas(CanvasTask t, {required this.done, this.doneAt})
      : id = t.id,
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

  bool get isCanvas => canvas != null;

  /// Same day: by class, then A to Z (your own to-dos after the classes).
  static int byClassThenTitle(Todo a, Todo b) {
    if (a.label.isEmpty != b.label.isEmpty) return a.label.isEmpty ? 1 : -1;
    final c = a.label.toLowerCase().compareTo(b.label.toLowerCase());
    return c != 0 ? c : a.title.toLowerCase().compareTo(b.title.toLowerCase());
  }
}

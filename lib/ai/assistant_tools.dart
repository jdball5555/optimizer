import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../calendar/calendar_models.dart';
import '../calendar/calendar_service.dart';
import '../calendar/canvas_section.dart' show calendarColorChoices;
import '../calendar/todos.dart';
import '../trips/trip_models.dart';
import '../trips/trip_store.dart';
import '../trips/trip_zones.dart';
import '../util/fields.dart';
import 'ai_service.dart';

/// What a tool gave back: [result] goes to Gemini, [note] (if any) shows in the chat.
typedef ToolRun = ({Map<String, dynamic> result, String? note, bool changed});

/// The pages the assistant can open.
const assistantPages = ['todos', 'home', 'calendar', 'trips', 'journal', 'net_worth', 'people', 'settings'];

/// The assistant's hands: tools Gemini may call, each run here in the app on
/// your own data, through the same code the app's buttons use (so changes
/// land in undo and in your calendar's history). Which ones it gets depends
/// on what you've allowed in Settings → Assistant.
class AssistantTools {
  AssistantTools({required this.ai, required this.calendar, this.trips, required this.confirm, this.navigate});

  final AiService ai;
  final CalendarService calendar;
  final TripStore? trips;

  /// Asks you before a change, when you've asked for that. True to go ahead.
  final Future<bool> Function(String change) confirm;
  final void Function(String page)? navigate;

  // Short ids handed to Gemini ("e12", "t3", "c2", "v1", "i4") for things it has seen.
  final _tripIds = <String, String>{};
  final _tripItems = <String, ({String trip, String item})>{};
  final _events = <String, CalendarEvent>{};
  final _eventIds = <String, String>{};
  final _todos = <String, Todo>{};
  final _todoIds = <String, String>{};
  final _calendars = <String, String>{};

  static final _out = DateFormat("yyyy-MM-dd'T'HH:mm");
  static final _ymd = DateFormat('yyyy-MM-dd');
  static final _say = DateFormat('EEE MMM d, h:mm a');
  static final _sayDay = DateFormat('EEE MMM d');

  bool get _seeCalendar => ai.shared.contains(AiShare.calendar);
  bool get _seeTodos => ai.shared.contains(AiShare.todos);
  bool get _editCalendar => ai.acts.contains(AiAct.calendar);
  bool get _editTodos => ai.acts.contains(AiAct.todos);
  bool get _editTrips => ai.acts.contains(AiAct.trips);

  // ---------------------------------------------------------------- what Gemini is offered

  static Map<String, dynamic> _str(String d, {List<String>? oneOf}) =>
      {'type': 'STRING', 'description': d, if (oneOf != null) ...{'format': 'enum', 'enum': oneOf}};
  static Map<String, dynamic> _bool(String d) => {'type': 'BOOLEAN', 'description': d};
  static Map<String, dynamic> _int(String d) => {'type': 'INTEGER', 'description': d};
  static Map<String, dynamic> _fn(String name, String description, Map<String, dynamic> props,
          [List<String> required = const []]) =>
      {
        'name': name,
        'description': description,
        // Gemini wants no parameters at all, rather than an empty object.
        if (props.isNotEmpty)
          'parameters': {
            'type': 'OBJECT',
            'properties': props,
            if (required.isNotEmpty) 'required': required,
          },
      };

  static const _when = 'Local time as YYYY-MM-DDTHH:MM (no time zone), or YYYY-MM-DD for all-day.';

  static final _itemFields = <String, Map<String, dynamic>>{
    'kind': _str(
      'What it is: flight, commute (a drive), travel (train, bus, ferry...), stay, rental (a rental car), food or activity.',
      oneOf: [for (final k in TripItemKind.values) k.name],
    ),
    'title': _str('Its name. Needed for stay, food and activity; flights, drives and travel name themselves.'),
    'start': _str('When it starts, on the clock at that place, YYYY-MM-DDTHH:MM. Takeoff, check-in or pickup.'),
    'end': _str('When it ends, on the clock where it ends, YYYY-MM-DDTHH:MM. Landing, check-out or drop-off. '
        'Needed for flight, travel, stay and rental; a drive’s is worked out if left out.'),
    'location': _str('Where: the place’s name and address. A rental’s pickup.'),
    'from': _str('Flight, commute or travel: where it leaves from (for a flight, the airport code).'),
    'to': _str('Flight, commute or travel: where it’s going (for a flight, the airport code). A rental’s drop-off, if different.'),
    'how': _str('Travel only: train, bus, ferry...'),
    'flight_number': _str('Flight only, like AA 123.'),
    'airline': _str('Flight only.'),
    'car': _str('Rental only: the car or company.'),
    'confirmation': _str('Confirmation number.'),
    'notes': _str('Notes.'),
  };

  List<Map<String, dynamic>> declarations() => [
        if (_seeCalendar || _editCalendar) ...[
          _fn('get_events', 'Lists calendar events between two dates (inclusive), with ids to change them by.', {
            'start_date': _str('First day, YYYY-MM-DD.'),
            'end_date': _str('Last day, YYYY-MM-DD.'),
            'query': _str('Optional words to match in the title, location or calendar.'),
          }, ['start_date', 'end_date']),
          _fn('find_free_time', 'Finds open stretches between events, for scheduling and planning.', {
            'start_date': _str('First day, YYYY-MM-DD.'),
            'end_date': _str('Last day, YYYY-MM-DD.'),
            'min_minutes': _int('Shortest gap worth listing, in minutes (default 30).'),
            'day_start': _str('Earliest time to count each day, HH:MM (default 08:00).'),
            'day_end': _str('Latest time to count each day, HH:MM (default 22:00).'),
          }, ['start_date', 'end_date']),
          _fn('list_calendars', 'Lists the calendars, which ones can be edited, and their ids.', {}),
        ],
        if (_editCalendar) ...[
          _fn('create_event', 'Adds an event to a calendar.', {
            'title': _str('What it is.'),
            'start': _str(_when),
            'end': _str('$_when For all-day events, the last day (inclusive). Defaults to 1 hour, or 1 day.'),
            'all_day': _bool('True for an all-day event.'),
            'calendar_id': _str('From list_calendars. Defaults to their main calendar.'),
            'location': _str('Where.'),
            'description': _str('Notes.'),
          }, ['title', 'start']),
          _fn('update_event', 'Changes an event (move it, rename it, ...). Only the fields given change.', {
            'event_id': _str('From get_events.'),
            'title': _str('New title.'),
            'start': _str(_when),
            'end': _str(_when),
            'all_day': _bool('Make it all-day (true) or timed (false).'),
            'calendar_id': _str('Move it to this calendar.'),
            'location': _str('New location.'),
            'description': _str('New notes.'),
          }, ['event_id']),
          _fn('delete_event', 'Deletes an event. A Google event is deleted from Google Calendar too, unless only_in_optimizer is set.', {
            'event_id': _str('From get_events.'),
            'only_in_optimizer': _bool('Google events only: leave it in Google Calendar and just take it off Optimizer. '
                'The only way to remove one from a calendar that can’t be edited.'),
          }, ['event_id']),
          _fn('create_calendar', 'Makes a new calendar in Optimizer. It isn’t synced with Google or anything else.', {
            'name': _str('What to call it.'),
            'color': _str('Optional color, as #RRGGBB.'),
          }, ['name']),
          _fn('update_calendar', 'Renames or recolors one of the calendars made in Optimizer (optimizer_only in list_calendars).', {
            'calendar_id': _str('From list_calendars.'),
            'name': _str('New name.'),
            'color': _str('New color, as #RRGGBB.'),
          }, ['calendar_id']),
          _fn('delete_calendar', 'Deletes a calendar made in Optimizer (optimizer_only in list_calendars) and every event on it. They’re always asked first.',
              {'calendar_id': _str('From list_calendars.')}, ['calendar_id']),
        ],
        if (_seeTodos || _editTodos)
          _fn('get_todos', 'Lists to-dos (their own and Canvas assignments), with ids to change them by.', {
            'include_done': _bool('Also list ones checked off in the last two weeks.'),
          }),
        if (_editTodos) ...[
          _fn('add_todo', 'Adds a to-do.', {
            'title': _str('What to do.'),
            'due': _str('When it’s due. $_when Leave out for no date.'),
          }, ['title']),
          _fn('update_todo', 'Changes a to-do’s title or due date.', {
            'todo_id': _str('From get_todos.'),
            'title': _str('New title.'),
            'due': _str('New due date. $_when'),
            'clear_due': _bool('True to remove its due date.'),
          }, ['todo_id']),
          _fn('complete_todo', 'Checks a to-do off, or back on.', {
            'todo_id': _str('From get_todos.'),
            'done': _bool('True when it’s done (default), false to uncheck.'),
          }, ['todo_id']),
          _fn('delete_todo', 'Deletes one of their own to-dos (not a Canvas assignment).',
              {'todo_id': _str('From get_todos.')}, ['todo_id']),
        ],
        if (trips != null && (_seeCalendar || _editTrips)) ...[
          _fn('get_trips', 'Lists their trips and everything on each, with ids to change them by.', {
            'query': _str('Optional words to match in the title or destination.'),
            'include_past': _bool('Also list trips that are over.'),
          }),
          _fn('open_trip', 'Opens a trip on the Trips page for them.', {'trip_id': _str('From get_trips.')}, ['trip_id']),
        ],
        if (trips != null && _editTrips) ...[
          _fn('create_trip', 'Makes a new trip. Then add what’s on it with add_trip_item.', {
            'title': _str('What to call it.'),
            'destination': _str('Where to.'),
            'start_date': _str('First day, YYYY-MM-DD.'),
            'end_date': _str('Last day, YYYY-MM-DD.'),
            'how': _str('How they’re getting there.', oneOf: [for (final h in TripHow.values) h.name]),
            'notes': _str('Notes for the whole trip.'),
          }, ['title', 'start_date', 'end_date']),
          _fn('update_trip', 'Changes a trip’s details. Only the fields given change.', {
            'trip_id': _str('From get_trips.'),
            'title': _str('New title.'),
            'destination': _str('New destination.'),
            'start_date': _str('New first day, YYYY-MM-DD.'),
            'end_date': _str('New last day, YYYY-MM-DD.'),
            'notes': _str('New notes for the whole trip.'),
          }, ['trip_id']),
          _fn('add_trip_item', 'Adds something to a trip.', {'trip_id': _str('From get_trips.'), ..._itemFields}, ['trip_id', 'kind', 'start']),
          _fn('update_trip_item', 'Changes something on a trip. Only the fields given change. Moving its start keeps its length.',
              {'item_id': _str('From get_trips.'), ..._itemFields}..remove('kind'), ['item_id']),
          _fn('remove_trip_item', 'Takes something off a trip.', {'item_id': _str('From get_trips.')}, ['item_id']),
          _fn('delete_trip', 'Deletes a whole trip and everything on it, or leaves one someone shared with them. They’re always asked first.',
              {'trip_id': _str('From get_trips.')}, ['trip_id']),
        ],
        _fn('open_page', 'Opens a page of the app for them.', {'page': _str('Which page.', oneOf: assistantPages)}, ['page']),
      ];

  /// For the instructions: what it can't do, so it can say how to allow it.
  String limits() {
    final off = [
      for (final s in AiShare.values)
        if (!ai.shared.contains(s)) 'reading their ${s.label.toLowerCase()}',
      for (final a in AiAct.values)
        if (!ai.acts.contains(a)) a.label.toLowerCase(),
    ];
    return off.isEmpty
        ? 'Everything is allowed.'
        : 'Not allowed right now: ${off.join('; ')}. These are switched on in Settings → Assistant.';
  }

  // ---------------------------------------------------------------- running them

  Future<ToolRun> run(String name, Map<String, dynamic> a) async {
    try {
      return switch (name) {
        'get_events' => await _getEvents(a),
        'find_free_time' => await _freeTime(a),
        'list_calendars' => _listCalendars(),
        'create_event' => await _createEvent(a),
        'update_event' => await _updateEvent(a),
        'delete_event' => await _deleteEvent(a),
        'create_calendar' => await _createCalendar(a),
        'update_calendar' => await _updateCalendar(a),
        'delete_calendar' => await _deleteCalendar(a),
        'get_todos' => _getTodos(a),
        'add_todo' => await _addTodo(a),
        'update_todo' => await _updateTodo(a),
        'complete_todo' => await _completeTodo(a),
        'delete_todo' => await _deleteTodo(a),
        'get_trips' => _getTrips(a),
        'open_trip' => _openTrip(a),
        'create_trip' => await _createTrip(a),
        'update_trip' => await _updateTrip(a),
        'add_trip_item' => await _addTripItem(a),
        'update_trip_item' => await _updateTripItem(a),
        'remove_trip_item' => await _removeTripItem(a),
        'delete_trip' => await _deleteTrip(a),
        'open_page' => _openPage(a),
        _ => _fail('There’s no tool called $name.'),
      };
    } catch (e) {
      final msg = '$e'.replaceFirst('Exception: ', '');
      return (result: {'error': msg}, note: 'Couldn’t finish that: $msg', changed: false);
    }
  }

  static ToolRun _fail(String why) => (result: {'error': why}, note: null, changed: false);
  static ToolRun _read(Map<String, dynamic> r, String note) => (result: r, note: note, changed: false);
  static ToolRun _skipped(String what) =>
      (result: {'skipped': 'They chose not to make this change.'}, note: 'Skipped: $what', changed: false);

  static String? _s(Map<String, dynamic> a, String k) {
    final v = a[k];
    if (v == null) return null;
    final s = '$v'.trim();
    return s.isEmpty ? null : s;
  }

  static bool? _b(Map<String, dynamic> a, String k) {
    final v = a[k];
    if (v is bool) return v;
    if (v is String) {
      if (v.toLowerCase() == 'true') return true;
      if (v.toLowerCase() == 'false') return false;
    }
    return null;
  }

  /// "2026-11-06T14:00" or "2026-11-06" in local time (an offset, if given, is honored).
  static DateTime? _time(String? s) {
    if (s == null) return null;
    final d = DateTime.tryParse(s);
    if (d == null) return null;
    return d.isUtc ? d.toLocal() : d;
  }

  static bool _dateOnly(String? s) => s != null && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s);

  static ({int h, int m}) _hm(String? s, int hour) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(s ?? '');
    if (m == null) return (h: hour, m: 0);
    return (h: int.parse(m.group(1)!).clamp(0, 24), m: int.parse(m.group(2)!).clamp(0, 59));
  }

  ({DateTime from, DateTime to})? _days(Map<String, dynamic> a) {
    final first = _time(_s(a, 'start_date'));
    final last = _time(_s(a, 'end_date')) ?? first;
    if (first == null || last == null) return null;
    final from = dayStart(first);
    var to = addDays(dayStart(last), 1);
    // At most about a year at once.
    if (to.difference(from).inDays > 370) to = addDays(from, 370);
    return to.isAfter(from) ? (from: from, to: to) : null;
  }

  /// For tests: an event's id, as get_events would hand it to Gemini.
  @visibleForTesting
  String debugIdOf(CalendarEvent e) => _eventId(e);

  String _eventId(CalendarEvent e) {
    final id = _eventIds.putIfAbsent(e.key, () => 'e${_eventIds.length + 1}');
    _events[id] = e;
    return id;
  }

  String _todoId(Todo t) {
    final id = _todoIds.putIfAbsent(t.id, () => 't${_todoIds.length + 1}');
    _todos[id] = t;
    return id;
  }

  String _calendarId(GoogleCalendar c) {
    for (final e in _calendars.entries) {
      if (e.value == c.key) return e.key;
    }
    final id = 'c${_calendars.length + 1}';
    _calendars[id] = c.key;
    return id;
  }

  GoogleCalendar? _calendarFor(String? id) {
    if (id == null) return null;
    final key = _calendars[id];
    if (key != null) return calendar.calendarByKey(key);
    // Gemini used a name instead of an id.
    final lower = id.toLowerCase();
    return calendar.writableCalendars.where((c) => c.name.toLowerCase() == lower).firstOrNull;
  }

  String _describeTime(DateTime start, DateTime end, bool allDay) {
    if (allDay) {
      final last = addDays(end, -1);
      return sameDay(start, last) ? '${_sayDay.format(start)}, all day' : '${_sayDay.format(start)} – ${_sayDay.format(last)}';
    }
    return '${_say.format(start)} – ${DateFormat.jm().format(end)}';
  }

  /// Start and (exclusive) end from what Gemini sent, falling back to the old ones.
  ({DateTime start, DateTime end, bool allDay})? _span(String? startS, String? endS, bool? allDayArg,
      {DateTime? oldStart, DateTime? oldEnd, bool oldAllDay = false}) {
    final allDay = allDayArg ?? (startS != null ? _dateOnly(startS) : oldAllDay);
    var start = _time(startS) ?? oldStart;
    if (start == null) return null;
    final length = (oldStart != null && oldEnd != null) ? oldEnd.difference(oldStart) : null;
    var end = _time(endS);
    if (allDay) {
      start = dayStart(start);
      if (end != null) {
        end = addDays(dayStart(end), 1);
      } else if (length != null && oldAllDay) {
        end = start.add(length);
      } else {
        end = addDays(start, 1);
      }
      if (!end.isAfter(start)) end = addDays(start, 1);
    } else {
      // Moving a timed event keeps its length, like dragging it.
      end ??= (length != null && !oldAllDay) ? start.add(length) : start.add(const Duration(hours: 1));
      if (!end.isAfter(start)) return null;
    }
    return (start: start, end: end, allDay: allDay);
  }

  // ---------------------------------------------------------------- calendar

  Map<String, dynamic> _eventJson(CalendarEvent e) => {
        'id': _eventId(e),
        'title': e.title,
        if (e.allDay) ...{
          'all_day': true,
          'start': _ymd.format(e.start),
          'end': _ymd.format(addDays(e.end, -1)),
        } else ...{
          'start': _out.format(e.start),
          'end': _out.format(e.end),
        },
        'weekday': DateFormat('EEE').format(e.start),
        'calendar': e.calendar.name,
        if (e.location.isNotEmpty) 'location': e.location,
        if (e.description.isNotEmpty)
          'notes': e.description.length > 300 ? '${e.description.substring(0, 300)}…' : e.description,
        if (!calendar.canEdit(e.calendar)) 'read_only': true,
      };

  Future<ToolRun> _getEvents(Map<String, dynamic> a) async {
    if (!_seeCalendar) return _fail('Reading the calendar is switched off.');
    final r = _days(a);
    if (r == null) return _fail('Give start_date and end_date as YYYY-MM-DD.');
    final q = _s(a, 'query')?.toLowerCase();
    var list = await calendar.fetchBetween(r.from, r.to);
    if (q != null) {
      list = list.where((e) => '${e.title} ${e.location} ${e.calendar.name}'.toLowerCase().contains(q)).toList();
    }
    final shown = list.take(400).toList();
    return _read({
      'events': [for (final e in shown) _eventJson(e)],
      if (list.length > shown.length) 'note': 'Only the first ${shown.length} of ${list.length} are listed; ask for fewer days.',
    }, 'Looked at your calendar, ${_sayDay.format(r.from)} – ${_sayDay.format(addDays(r.to, -1))}');
  }

  Future<ToolRun> _freeTime(Map<String, dynamic> a) async {
    if (!_seeCalendar) return _fail('Reading the calendar is switched off.');
    final r = _days(a);
    if (r == null) return _fail('Give start_date and end_date as YYYY-MM-DD.');
    final rawMin = a['min_minutes'];
    final min = (rawMin is num ? rawMin.toInt() : 30).clamp(5, 24 * 60);
    final ds = _hm(_s(a, 'day_start'), 8);
    final de = _hm(_s(a, 'day_end'), 22);
    final events = (await calendar.fetchBetween(r.from, r.to)).where((e) => !e.allDay).toList()
      ..sort((x, y) => x.start.compareTo(y.start));
    final now = DateTime.now();
    final slots = <Map<String, dynamic>>[];
    void add(DateTime from, DateTime to) {
      final minutes = to.difference(from).inMinutes;
      if (minutes >= min) slots.add({'start': _out.format(from), 'end': _out.format(to), 'minutes': minutes});
    }

    for (var day = r.from; day.isBefore(r.to); day = addDays(day, 1)) {
      var cursor = DateTime(day.year, day.month, day.day, ds.h, ds.m);
      final end = DateTime(day.year, day.month, day.day, de.h, de.m);
      if (!end.isAfter(now)) continue;
      if (cursor.isBefore(now)) cursor = now;
      for (final e in events) {
        if (!e.end.isAfter(cursor) || !e.start.isBefore(end)) continue;
        if (e.start.isAfter(cursor)) add(cursor, e.start);
        if (e.end.isAfter(cursor)) cursor = e.end;
      }
      if (end.isAfter(cursor)) add(cursor, end);
    }
    return _read({'free': slots.take(300).toList()}, 'Checked your free time');
  }

  ToolRun _listCalendars() {
    final all = [...calendar.ownCalendars, ...calendar.calendars.where(calendar.canEdit), ...calendar.calendars.where((c) => !calendar.canEdit(c))];
    final main = calendar.defaultCalendar;
    return _read({
      'calendars': [
        for (final c in all)
          {
            'id': _calendarId(c),
            'name': c.name,
            if (c.isOwn) 'optimizer_only': true else 'account': c.accountEmail,
            'editable': calendar.canEdit(c),
            if (main?.key == c.key) 'default': true,
            if (!calendar.isVisible(c)) 'hidden_in_app': true,
          },
      ],
    }, 'Looked at your calendars');
  }

  static Color? _color(String? s) => s != null && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(s) ? parseHexColor(s, Colors.white) : null;

  Future<ToolRun> _createCalendar(Map<String, dynamic> a) async {
    if (!_editCalendar) return _fail('Changing the calendar is switched off.');
    final name = _s(a, 'name');
    if (name == null) return _fail('Give the calendar a name.');
    final same = calendar.ownCalendars.where((c) => c.name.toLowerCase() == name.toLowerCase()).firstOrNull;
    if (same != null) return _fail('There’s already a calendar called ${same.name}, with id ${_calendarId(same)}.');
    final colorS = _s(a, 'color');
    final color = _color(colorS);
    if (colorS != null && color == null) return _fail('Give the color as #RRGGBB.');
    final used = {for (final c in calendar.ownCalendars) c.color.toARGB32()};
    final what = 'Add calendar “$name”';
    if (ai.confirmChanges && !await confirm(what)) return _skipped(what);
    final made = await calendar.createOwnCalendar(
        name, color ?? calendarColorChoices.firstWhere((c) => !used.contains(c.toARGB32()), orElse: () => calendarColorChoices.first));
    return (result: {'ok': true, 'calendar_id': _calendarId(made)}, note: 'Added calendar “$name”', changed: true);
  }

  Future<ToolRun> _updateCalendar(Map<String, dynamic> a) async {
    if (!_editCalendar) return _fail('Changing the calendar is switched off.');
    final c = _calendarFor(_s(a, 'calendar_id'));
    if (c == null) return _fail('Unknown calendar_id. Call list_calendars first and use an id from it.');
    if (!c.isOwn) return _fail('${c.name} is synced from elsewhere. Only calendars made in Optimizer can be changed.');
    final name = _s(a, 'name');
    final colorS = _s(a, 'color');
    final color = _color(colorS);
    if (colorS != null && color == null) return _fail('Give the color as #RRGGBB.');
    final parts = [
      if (name != null && name != c.name) 'rename to “$name”',
      if (color != null) 'new color',
    ];
    if (parts.isEmpty) return _fail('Give a new name or color.');
    final summary = parts.join(', ');
    if (ai.confirmChanges && !await confirm('Change calendar “${c.name}”: $summary')) return _skipped('Change calendar “${c.name}”');
    await calendar.updateOwnCalendar(c, name: name, color: color);
    return (result: {'ok': true}, note: 'Changed calendar “${c.name}”: $summary', changed: true);
  }

  // A whole calendar can take a lot with it, so this one always asks.
  Future<ToolRun> _deleteCalendar(Map<String, dynamic> a) async {
    if (!_editCalendar) return _fail('Changing the calendar is switched off.');
    final c = _calendarFor(_s(a, 'calendar_id'));
    if (c == null) return _fail('Unknown calendar_id. Call list_calendars first and use an id from it.');
    if (!c.isOwn) return _fail('${c.name} is synced from elsewhere. Only calendars made in Optimizer can be deleted.');
    final n = calendar.ownEventCount(c);
    final what = 'Delete calendar “${c.name}”${n == 0 ? '' : ' and the ${n == 1 ? 'event' : '$n events'} on it'}';
    if (!await confirm(what)) return _skipped(what);
    await calendar.deleteOwnCalendar(c);
    return (result: {'ok': true}, note: 'Deleted calendar “${c.name}”', changed: true);
  }

  Future<ToolRun> _createEvent(Map<String, dynamic> a) async {
    if (!_editCalendar) return _fail('Changing the calendar is switched off.');
    final title = _s(a, 'title') ?? 'New event';
    final span = _span(_s(a, 'start'), _s(a, 'end'), _b(a, 'all_day'));
    if (span == null) return _fail('Give a start (and an end after it).');
    final cal = _calendarFor(_s(a, 'calendar_id')) ?? calendar.defaultCalendar;
    if (cal == null) return _fail('No calendar they can edit is linked to Optimizer.');
    if (!calendar.canEdit(cal)) return _fail('${cal.name} can’t be edited.');
    final when = _describeTime(span.start, span.end, span.allDay);
    final what = 'Add “$title” · $when · ${cal.name}';
    if (ai.confirmChanges && !await confirm(what)) return _skipped(what);
    await calendar.saveEvent(EventDraft(
      calendarKey: cal.key,
      title: title,
      start: span.start,
      end: span.end,
      allDay: span.allDay,
      location: _s(a, 'location') ?? '',
      description: _s(a, 'description') ?? '',
    ));
    return (result: {'ok': true, 'calendar': cal.name}, note: 'Added “$title” · $when', changed: true);
  }

  Future<ToolRun> _updateEvent(Map<String, dynamic> a) async {
    if (!_editCalendar) return _fail('Changing the calendar is switched off.');
    final id = _s(a, 'event_id') ?? '';
    final e = _events[id];
    if (e == null) return _fail('Unknown event_id. Call get_events first and use an id from it.');
    if (!calendar.canEdit(e.calendar)) return _fail('“${e.title}” is on ${e.calendar.name}, which can’t be edited.');
    final moving = _s(a, 'start') != null || _s(a, 'end') != null || _b(a, 'all_day') != null;
    final span = moving
        ? _span(_s(a, 'start'), _s(a, 'end'), _b(a, 'all_day'), oldStart: e.start, oldEnd: e.end, oldAllDay: e.allDay)
        : (start: e.start, end: e.end, allDay: e.allDay);
    if (span == null) return _fail('The new end has to be after the start.');
    final cal = _calendarFor(_s(a, 'calendar_id')) ?? e.calendar;
    if (!calendar.canEdit(cal)) return _fail('${cal.name} can’t be edited.');
    final title = _s(a, 'title') ?? e.title;
    final changes = [
      if (title != e.title) 'rename to “$title”',
      if (moving) 'move to ${_describeTime(span.start, span.end, span.allDay)}',
      if (cal.key != e.calendar.key) 'move to ${cal.name}',
      if (a.containsKey('location')) 'new location',
      if (a.containsKey('description')) 'new notes',
    ];
    final summary = changes.isEmpty ? 'no changes' : changes.join(', ');
    if (ai.confirmChanges && !await confirm('Change “${e.title}”: $summary')) return _skipped('Change “${e.title}”');
    await calendar.saveEvent(
      EventDraft(
        calendarKey: cal.key,
        title: title,
        start: span.start,
        end: span.end,
        allDay: span.allDay,
        location: a.containsKey('location') ? (_s(a, 'location') ?? '') : e.location,
        description: a.containsKey('description') ? (_s(a, 'description') ?? '') : e.description,
        colorId: e.colorId,
      ),
      original: e,
    );
    _events.remove(id);
    return (
      result: {'ok': true, 'note': 'Call get_events again before changing this event again.'},
      note: 'Changed “${e.title}”: $summary',
      changed: true,
    );
  }

  Future<ToolRun> _deleteEvent(Map<String, dynamic> a) async {
    if (!_editCalendar) return _fail('Changing the calendar is switched off.');
    final id = _s(a, 'event_id') ?? '';
    final e = _events[id];
    if (e == null) return _fail('Unknown event_id. Call get_events first and use an id from it.');
    if (e.isTrip) return _fail('“${e.title}” is a trip. Use delete_trip.');
    final google = !e.calendar.isOwn && !e.isTask && calendar.inviteFor(e) == null;
    final here = google && (_b(a, 'only_in_optimizer') ?? false);
    if (!here && !calendar.canEdit(e.calendar)) {
      return _fail('“${e.title}” is on ${e.calendar.name}, which can’t be edited.'
          '${google ? ' It can only be taken off Optimizer, with only_in_optimizer.' : ''}');
    }
    final when = _describeTime(e.start, e.end, e.allDay);
    final what = here
        ? 'Take “${e.title}” off Optimizer · $when (it stays in Google Calendar)'
        : 'Delete “${e.title}”${google ? ' from Google Calendar' : ''} · $when';
    if (ai.confirmChanges && !await confirm(what)) return _skipped(what);
    await (here ? calendar.removeEventHere(e) : calendar.deleteEvent(e));
    _events.remove(id);
    return (result: {'ok': true}, note: here ? 'Took “${e.title}” off Optimizer' : 'Deleted “${e.title}”', changed: true);
  }

  // ---------------------------------------------------------------- to-dos

  Map<String, dynamic> _todoJson(Todo t) => {
        'id': _todoId(t),
        'title': t.title,
        if (t.due != null) 'due': t.allDay ? _ymd.format(t.due!) : _out.format(t.due!),
        if (t.label.isNotEmpty) 'class': t.label,
        if (t.canvas != null) 'canvas': true,
        'done': t.done,
        if (t.doneAt != null) 'done_at': _out.format(t.doneAt!),
      };

  ToolRun _getTodos(Map<String, dynamic> a) {
    if (!_seeTodos) return _fail('Reading to-dos is switched off.');
    final withDone = _b(a, 'include_done') ?? false;
    final since = addDays(dayStart(DateTime.now()), -14);
    final list = calendar.todos
        .where((t) => !t.done || (withDone && t.doneAt != null && t.doneAt!.isAfter(since)))
        .toList()
      ..sort((x, y) => (x.due ?? DateTime(2100)).compareTo(y.due ?? DateTime(2100)));
    return _read({
      'todos': [for (final t in list.take(300)) _todoJson(t)],
    }, 'Looked at your to-dos');
  }

  Todo? _todo(Map<String, dynamic> a) {
    final t = _todos[_s(a, 'todo_id') ?? ''];
    if (t == null) return null;
    // The latest version of it, if it changed since.
    return calendar.todos.where((x) => x.id == t.id).firstOrNull ?? t;
  }

  String _due(DateTime d, bool allDay) => allDay ? _sayDay.format(d) : _say.format(d);

  Future<ToolRun> _addTodo(Map<String, dynamic> a) async {
    if (!_editTodos) return _fail('Changing to-dos is switched off.');
    final title = _s(a, 'title');
    if (title == null) return _fail('Give a title.');
    final dueS = _s(a, 'due');
    final due = _time(dueS);
    final allDay = due == null || _dateOnly(dueS);
    final when = due == null ? '' : ' · due ${_due(due, allDay)}';
    final what = 'Add to-do “$title”$when';
    if (ai.confirmChanges && !await confirm(what)) return _skipped(what);
    await calendar.addTodo(title, due: due == null ? null : (allDay ? dayStart(due) : due), allDay: allDay);
    return (result: {'ok': true}, note: 'Added to-do “$title”$when', changed: true);
  }

  Future<ToolRun> _updateTodo(Map<String, dynamic> a) async {
    if (!_editTodos) return _fail('Changing to-dos is switched off.');
    final t = _todo(a);
    if (t == null) return _fail('Unknown todo_id. Call get_todos first and use an id from it.');
    final title = _s(a, 'title') ?? t.title;
    final dueS = _s(a, 'due');
    final clear = _b(a, 'clear_due') ?? false;
    final newDue = clear ? null : (_time(dueS) ?? t.due);
    final allDay = dueS != null ? _dateOnly(dueS) : t.allDay;
    final parts = [
      if (title != t.title) 'rename to “$title”',
      if (clear) 'no due date' else if (dueS != null && newDue != null) 'due ${_due(newDue, allDay)}',
    ];
    final summary = parts.isEmpty ? 'no changes' : parts.join(', ');
    if (ai.confirmChanges && !await confirm('Change to-do “${t.title}”: $summary')) return _skipped('Change “${t.title}”');
    await calendar.editTodo(t, title: title, due: newDue == null ? null : (allDay ? dayStart(newDue) : newDue), allDay: allDay);
    return (result: {'ok': true}, note: 'Changed to-do “${t.title}”: $summary', changed: true);
  }

  Future<ToolRun> _completeTodo(Map<String, dynamic> a) async {
    if (!_editTodos) return _fail('Changing to-dos is switched off.');
    final t = _todo(a);
    if (t == null) return _fail('Unknown todo_id. Call get_todos first and use an id from it.');
    final done = _b(a, 'done') ?? true;
    final what = '${done ? 'Check off' : 'Uncheck'} “${t.title}”';
    if (ai.confirmChanges && !await confirm(what)) return _skipped(what);
    await calendar.setTodoDone(t, done);
    return (result: {'ok': true}, note: '${done ? 'Checked off' : 'Unchecked'} “${t.title}”', changed: true);
  }

  Future<ToolRun> _deleteTodo(Map<String, dynamic> a) async {
    if (!_editTodos) return _fail('Changing to-dos is switched off.');
    final t = _todo(a);
    if (t == null) return _fail('Unknown todo_id. Call get_todos first and use an id from it.');
    if (t.canvas != null) return _fail('Canvas assignments can’t be deleted. Check it off instead.');
    final what = 'Delete to-do “${t.title}”';
    if (ai.confirmChanges && !await confirm(what)) return _skipped(what);
    await calendar.deleteTodo(t);
    return (result: {'ok': true}, note: 'Deleted to-do “${t.title}”', changed: true);
  }

  // ---------------------------------------------------------------- trips

  String _tripId(Trip t) => _tripIds.putIfAbsent(t.id, () => 'v${_tripIds.length + 1}');

  String _tripItemId(Trip t, TripItem i) {
    for (final e in _tripItems.entries) {
      if (e.value.trip == t.id && e.value.item == i.id) return e.key;
    }
    final id = 'i${_tripItems.length + 1}';
    _tripItems[id] = (trip: t.id, item: i.id);
    return id;
  }

  Trip? _trip(Map<String, dynamic> a) {
    final said = _s(a, 'trip_id');
    if (said == null) return null;
    final all = trips?.trips ?? const <Trip>[];
    for (final e in _tripIds.entries) {
      if (e.value == said) return all.where((t) => t.id == e.key).firstOrNull;
    }
    // Gemini used a name instead of an id.
    final lower = said.toLowerCase();
    return all.where((t) => t.title.toLowerCase() == lower).firstOrNull;
  }

  ({Trip trip, TripItem item})? _tripItem(Map<String, dynamic> a) {
    final at = _tripItems[_s(a, 'item_id') ?? ''];
    final t = trips?.trips.where((t) => t.id == at?.trip).firstOrNull;
    final i = t?.items.where((i) => i.id == at?.item).firstOrNull;
    return t == null || i == null ? null : (trip: t, item: i);
  }

  Map<String, dynamic> _tripJson(Trip t) {
    final zones = t.zones;
    return {
      'id': _tripId(t),
      'title': t.title,
      if (t.destination.isNotEmpty) 'destination': t.destination,
      'start_date': _ymd.format(t.firstDay),
      'end_date': _ymd.format(t.lastDay),
      if (t.notes.isNotEmpty) 'notes': t.notes,
      if (t.links.isNotEmpty) 'links': [for (final l in t.links) l.url],
      if (t.isShared) 'shared_by': t.ownerName.isEmpty ? t.ownerEmail : t.ownerName,
      if (!t.canEdit) 'read_only': true,
      if (t.people.isNotEmpty) 'shared_with': [for (final p in t.people) p.shown],
      'items': [
        for (final i in t.items)
          {
            'id': _tripItemId(t, i),
            'kind': i.kind.name,
            'title': i.title,
            'start': _out.format(wallOf(i.start, zones[i.id]!.$1)),
            if (!i.oneTime) 'end': _out.format(wallOf(i.end, zones[i.id]!.$2)),
            if (zones[i.id]!.$1.isNotEmpty) 'time_zone': zones[i.id]!.$1,
            if (i.kind == TripItemKind.flight) ...{
              'from': i.departure.code,
              'to': i.arrival.code,
              if ('${i.flight?['number'] ?? ''}'.isNotEmpty) 'flight_number': i.flight!['number'],
              if ('${i.flight?['airline'] ?? ''}'.isNotEmpty) 'airline': i.flight!['airline'],
            } else if (i.commute != null) ...{
              if ('${i.commute!['from'] ?? ''}'.isNotEmpty) 'from': i.commute!['from'],
              if ('${i.commute!['to'] ?? ''}'.isNotEmpty) 'to': i.commute!['to'],
              if ('${i.commute!['how'] ?? ''}'.isNotEmpty) 'how': i.commute!['how'],
              if ('${i.commute!['car'] ?? ''}'.isNotEmpty) 'car': i.commute!['car'],
            },
            if (i.location.isNotEmpty) 'location': i.location,
            if (i.confirmation.isNotEmpty) 'confirmation': i.confirmation,
            if (i.notes.isNotEmpty) 'notes': i.notes,
            if (!t.canEditItem(i)) 'read_only': true,
          },
      ],
    };
  }

  ToolRun _getTrips(Map<String, dynamic> a) {
    if (!_seeCalendar && !_editTrips) return _fail('Reading trips is switched off.');
    final today = dayStart(DateTime.now());
    final past = _b(a, 'include_past') ?? false;
    final q = _s(a, 'query')?.toLowerCase();
    final list = trips!.trips
        .where((t) => past || !t.lastDay.isBefore(today))
        .where((t) => q == null || '${t.title} ${t.destination}'.toLowerCase().contains(q))
        .toList();
    return _read({
      'trips': [for (final t in list.take(40)) _tripJson(t)],
    }, 'Looked at your trips');
  }

  ToolRun _openTrip(Map<String, dynamic> a) {
    if (!_seeCalendar && !_editTrips) return _fail('Reading trips is switched off.');
    final t = _trip(a);
    final go = navigate;
    if (t == null) return _fail('Unknown trip_id. Call get_trips first and use an id from it.');
    if (go == null) return _fail('Can’t open pages from here.');
    trips!.open(t.id);
    go('trips');
    return (result: {'ok': true}, note: 'Opened ${t.title}', changed: false);
  }

  /// The first and last days from what Gemini sent, falling back to the old ones.
  ({DateTime start, DateTime end})? _tripDays(Map<String, dynamic> a, {DateTime? oldStart, DateTime? oldEnd}) {
    final first = _time(_s(a, 'start_date')) ?? oldStart;
    final last = _time(_s(a, 'end_date')) ?? oldEnd;
    if (first == null || last == null || dayStart(last).isBefore(dayStart(first))) return null;
    return (start: dayStart(first), end: dayStart(last));
  }

  String _sayDays(DateTime first, DateTime last) => '${_sayDay.format(first)} – ${_sayDay.format(last)}';

  Future<ToolRun> _createTrip(Map<String, dynamic> a) async {
    if (!_editTrips) return _fail('Changing trips is switched off.');
    final store = trips!;
    final title = _s(a, 'title');
    if (title == null) return _fail('Give the trip a title.');
    final days = _tripDays(a);
    if (days == null) return _fail('Give start_date and end_date as YYYY-MM-DD, the end not before the start.');
    final trip = Trip(
      id: store.newId(),
      title: title,
      destination: _s(a, 'destination') ?? '',
      how: TripHow.values.where((h) => h.name == _s(a, 'how')).firstOrNull,
      notes: _s(a, 'notes') ?? '',
      zone: deviceZone,
      start: days.start,
      end: days.end,
      color: tripColors[store.trips.length % tripColors.length],
    );
    final what = 'Add trip “$title” · ${_sayDays(days.start, days.end)}';
    if (ai.confirmChanges && !await confirm(what)) return _skipped(what);
    calendar.noteChange('Added trip “$title”', () => store.delete(trip));
    await store.save(trip);
    return (result: {'ok': true, 'trip_id': _tripId(trip)}, note: 'Added trip “$title” · ${_sayDays(days.start, days.end)}', changed: true);
  }

  Future<ToolRun> _updateTrip(Map<String, dynamic> a) async {
    if (!_editTrips) return _fail('Changing trips is switched off.');
    final t = _trip(a);
    if (t == null) return _fail('Unknown trip_id. Call get_trips first and use an id from it.');
    if (!t.canEdit) return _fail('“${t.title}” is shared with them to view only.');
    final days = _tripDays(a, oldStart: t.start, oldEnd: t.end);
    if (days == null) return _fail('The last day can’t be before the first.');
    final title = _s(a, 'title') ?? t.title;
    final moved = !sameDay(days.start, t.start) || !sameDay(days.end, t.end);
    final parts = [
      if (title != t.title) 'rename to “$title”',
      if (moved) 'days to ${_sayDays(days.start, days.end)}',
      if (a.containsKey('destination')) 'new destination',
      if (a.containsKey('notes')) 'new notes',
    ];
    if (parts.isEmpty) return _fail('Give something to change.');
    final summary = parts.join(', ');
    if (ai.confirmChanges && !await confirm('Change trip “${t.title}”: $summary')) return _skipped('Change trip “${t.title}”');
    calendar.noteChange('Changed trip “${t.title}”', () => trips!.save(t));
    await trips!.save(t.copyWith(
      title: title,
      destination: a.containsKey('destination') ? (_s(a, 'destination') ?? '') : null,
      notes: a.containsKey('notes') ? (_s(a, 'notes') ?? '') : null,
      start: days.start,
      end: days.end,
    ));
    return (result: {'ok': true}, note: 'Changed trip “${t.title}”: $summary', changed: true);
  }

  /// Something on trip [t] from what Gemini sent, as the trip editors build it,
  /// falling back to [old]'s. Null item: [error] says why.
  Future<({TripItem? item, String? error})> _buildTripItem(Trip t, TripItemKind kind, Map<String, dynamic> a, TripItem? old) async {
    ({TripItem? item, String? error}) no(String why) => (item: null, error: why);
    String field(String k, String was) => a.containsKey(k) ? (_s(a, k) ?? '') : was;
    final was = old?.commute ?? const <String, dynamic>{};
    final isFlight = kind == TripItemKind.flight, isRental = kind == TripItemKind.rental;
    final goes = isFlight || kind == TripItemKind.commute || kind == TripItemKind.travel;

    var from = field('from', isFlight ? (old?.departure.code ?? '') : '${was['from'] ?? ''}');
    var to = field('to', isFlight ? (old?.arrival.code ?? '') : '${was['to'] ?? ''}');
    if (isFlight) {
      from = from.toUpperCase();
      to = to.toUpperCase();
    }
    final location = field('location', old?.location ?? '');
    if (goes && (from.isEmpty || to.isEmpty)) return no('Give from and to.');

    // Where each end is, looked up only if it's somewhere new.
    Future<String> zoneOf(String place, String wasPlace, String wasZone) async {
      if (place.isEmpty) return '';
      if (old != null && place == wasPlace) return wasZone;
      return await trips!.placeZone(isFlight ? '$place airport' : place) ?? '';
    }

    final startPlace = goes ? from : location;
    final endPlace = goes ? to : (isRental ? (to.isEmpty ? location : to) : '');
    final zone = await zoneOf(startPlace, goes ? (isFlight ? old?.departure.code ?? '' : '${was['from'] ?? ''}') : old?.location ?? '', old?.zone ?? '');
    final endZone = await zoneOf(endPlace, isFlight ? old?.arrival.code ?? '' : '${was['to'] ?? ''}', old?.endZone ?? '');

    DateTime? at(String? s, String inZone) {
      final d = s != null && s.contains('T') ? DateTime.tryParse(s) : null;
      if (d == null) return null;
      final wall = DateTime.utc(d.year, d.month, d.day, d.hour, d.minute);
      return inZone.isNotEmpty ? fromWall(wall, inZone) : t.momentOf(wall, except: old?.id);
    }

    final startS = _s(a, 'start'), endS = _s(a, 'end');
    final start = startS != null ? at(startS, zone) : old?.start;
    if (start == null) return no('Give a start as YYYY-MM-DDTHH:MM.');
    var end = endS != null ? at(endS, endZone.isNotEmpty ? endZone : zone) : (old == null ? null : start.add(old.end.difference(old.start)));
    if (endS != null && end == null) return no('Give the end as YYYY-MM-DDTHH:MM.');

    // A drive with no end: as long as Google says it takes.
    int? googleMeters;
    var fromGoogle = was['fromGoogle'] == true && endS == null && old != null;
    if (kind == TripItemKind.commute && end == null) {
      try {
        final r = await trips!.commuteTime(from: from, to: to, mode: 'DRIVE', leaveAt: start);
        final minutes = r['minutes'];
        if (minutes is num) {
          end = start.add(Duration(minutes: minutes.round()));
          googleMeters = (r['meters'] as num?)?.toInt();
          fromGoogle = true;
        }
      } catch (_) {
        // Asked for below.
      }
      if (end == null) return no('Couldn’t work out how long that drive takes. Give an end.');
    }
    if (end == null) {
      if (goes || kind.hasTwoEnds) return no('Give an end as well.');
      end = start;
    }
    if (kind.hasTwoEnds || goes ? !end.isAfter(start) : end.isBefore(start)) return no('It has to end after it starts.');

    final based = old?.movedTo(start, end);
    final onMapFrom = from.isEmpty || zone.isNotEmpty, onMapTo = endPlace.isEmpty || endZone.isNotEmpty;
    final number = field('flight_number', '${old?.flight?['number'] ?? ''}').toUpperCase();
    final how = field('how', '${was['how'] ?? ''}');
    final said = _s(a, 'title');
    String? title = said;
    Map<String, dynamic>? flight, commute;
    switch (kind) {
      case TripItemKind.flight:
        Map<String, dynamic> flightEnd(Object? before, String code, DateTime when, String z) {
          final m = before is Map ? Map<String, dynamic>.from(before) : <String, dynamic>{};
          final same = FlightEnd(m).time == when;
          return {
            ...m,
            'iata': code,
            'timeZone': z,
            if ('${m['iata'] ?? ''}' != code) 'name': '',
            if (!same) ...{'scheduled': when.millisecondsSinceEpoch, 'revised': null, 'scheduledLocal': null, 'revisedLocal': null},
          };
        }
        title = [if (number.isNotEmpty) number, '$from – $to'].join(' · ');
        flight = {
          ...?old?.flight,
          'lookedUp': old?.flight?['lookedUp'] ?? false,
          'number': number,
          'airline': field('airline', '${old?.flight?['airline'] ?? ''}'),
          'departure': flightEnd(old?.flight?['departure'], from, start, zone),
          'arrival': flightEnd(old?.flight?['arrival'], to, end, endZone),
        };
      case TripItemKind.commute:
        title = said ?? 'Drive to ${placeName(to)}';
        commute = {
          ...?based?.commute,
          'from': from,
          'to': to,
          if (!onMapFrom) 'fromOnMap': false,
          if (!onMapTo) 'toOnMap': false,
          'mode': was['mode'] ?? 'DRIVE',
          'minutes': end.difference(start).inMinutes,
          'meters': googleMeters ?? (fromGoogle ? was['meters'] : null),
          'predicted': false,
          'fromGoogle': fromGoogle,
          'timing': was['timing'] ?? 'leave',
        };
      case TripItemKind.travel:
        if (how.isEmpty) return no('Say how they’re traveling: train, bus, ferry...');
        title = said ?? '$how to ${placeName(to)}';
        commute = {
          'from': from,
          'to': to,
          'how': how,
          if (!onMapFrom) 'fromOnMap': false,
          if (!onMapTo) 'toOnMap': false,
        };
      case TripItemKind.rental:
        title = said ?? old?.title ?? 'Rental car';
        final car = field('car', '${was['car'] ?? ''}');
        final dropOff = to.isEmpty ? location : to;
        commute = {
          'from': location,
          'to': dropOff,
          if (location.isNotEmpty && zone.isEmpty) 'fromOnMap': false,
          if (dropOff.isNotEmpty && endZone.isEmpty) 'toOnMap': false,
          if (car.isNotEmpty) 'car': car,
        };
      case TripItemKind.stay:
      case TripItemKind.food:
      case TripItemKind.activity:
        title = said ?? old?.title;
        if (title == null) return no('Give it a title.');
    }

    return (
      item: TripItem(
        id: old?.id ?? '${DateTime.now().microsecondsSinceEpoch}',
        kind: kind,
        title: title,
        start: start,
        end: end,
        location: goes && !isFlight ? to : (isFlight ? old?.location ?? '' : location),
        notes: field('notes', old?.notes ?? ''),
        confirmation: field('confirmation', old?.confirmation ?? ''),
        flight: flight,
        commute: commute,
        zone: zone,
        endZone: endZone,
        onMap: goes || location.isEmpty || zone.isNotEmpty,
        access: old?.access ?? const {},
        myRole: old?.myRole,
        canSee: old?.canSee ?? const [],
      ),
      error: null,
    );
  }

  String _sayItem(TripItem i, Trip t) {
    final z = t.copyWith(items: [...t.items.where((x) => x.id != i.id), i]).zones[i.id]!;
    return i.oneTime
        ? _say.format(inZone(i.start, z.$1))
        : '${_say.format(inZone(i.start, z.$1))} – ${_say.format(inZone(i.end, z.$2))}';
  }

  Future<ToolRun> _addTripItem(Map<String, dynamic> a) async {
    if (!_editTrips) return _fail('Changing trips is switched off.');
    final t = _trip(a);
    if (t == null) return _fail('Unknown trip_id. Call get_trips first and use an id from it.');
    if (!t.canEdit) return _fail('“${t.title}” is shared with them to view only.');
    final kind = TripItemKind.values.where((k) => k.name == _s(a, 'kind')).firstOrNull;
    if (kind == null) return _fail('Give a kind: ${TripItemKind.values.map((k) => k.name).join(', ')}.');
    final built = await _buildTripItem(t, kind, a, null);
    final item = built.item;
    if (item == null) return _fail(built.error!);
    final what = 'Add “${item.title}” to ${t.title} · ${_sayItem(item, t)}';
    if (ai.confirmChanges && !await confirm(what)) return _skipped(what);
    calendar.noteChange('Added “${item.title}” to ${t.title}', () => t.isShared ? trips!.deleteItem(_latest(t), item) : trips!.save(t));
    await trips!.saveItem(t, item);
    return (result: {'ok': true, 'item_id': _tripItemId(t, item)}, note: 'Added “${item.title}” to ${t.title} · ${_sayItem(item, t)}', changed: true);
  }

  Trip _latest(Trip t) => trips!.trips.where((x) => x.id == t.id).firstOrNull ?? t;

  Future<ToolRun> _updateTripItem(Map<String, dynamic> a) async {
    if (!_editTrips) return _fail('Changing trips is switched off.');
    final found = _tripItem(a);
    if (found == null) return _fail('Unknown item_id. Call get_trips first and use an id from it.');
    final (:trip, :item) = found;
    if (!trip.canEditItem(item)) return _fail('“${item.title}” is shared with them to view only.');
    final built = await _buildTripItem(trip, item.kind, a, item);
    final changed = built.item;
    if (changed == null) return _fail(built.error!);
    final what = 'Change “${item.title}” on ${trip.title} · ${_sayItem(changed, trip)}';
    if (ai.confirmChanges && !await confirm(what)) return _skipped('Change “${item.title}”');
    calendar.noteChange('Changed “${item.title}” on ${trip.title}', () => trip.isShared ? trips!.saveItem(_latest(trip), item) : trips!.save(trip));
    await trips!.saveItem(trip, changed);
    return (result: {'ok': true}, note: 'Changed “${item.title}” on ${trip.title} · ${_sayItem(changed, trip)}', changed: true);
  }

  Future<ToolRun> _removeTripItem(Map<String, dynamic> a) async {
    if (!_editTrips) return _fail('Changing trips is switched off.');
    final found = _tripItem(a);
    if (found == null) return _fail('Unknown item_id. Call get_trips first and use an id from it.');
    final (:trip, :item) = found;
    if (!trip.canEditItem(item)) return _fail('“${item.title}” is shared with them to view only.');
    final what = 'Take “${item.title}” off ${trip.title}';
    if (ai.confirmChanges && !await confirm(what)) return _skipped(what);
    calendar.noteChange('Took “${item.title}” off ${trip.title}', () => trip.isShared ? trips!.saveItem(_latest(trip), item) : trips!.save(trip));
    await trips!.deleteItem(trip, item);
    return (result: {'ok': true}, note: 'Took “${item.title}” off ${trip.title}', changed: true);
  }

  // A whole trip can take a lot with it, so this one always asks.
  Future<ToolRun> _deleteTrip(Map<String, dynamic> a) async {
    if (!_editTrips) return _fail('Changing trips is switched off.');
    final t = _trip(a);
    if (t == null) return _fail('Unknown trip_id. Call get_trips first and use an id from it.');
    final things = t.items.length;
    final what = t.isShared
        ? 'Leave “${t.title}”, shared by ${t.ownerName.isEmpty ? t.ownerEmail : t.ownerName}. This can’t be undone: they’d have to share it again'
        : 'Delete trip “${t.title}”${things == 0 ? '' : ' and the ${things == 1 ? 'thing' : '$things things'} on it'}'
            '${t.people.isEmpty ? '' : ', for everyone it’s shared with too'}';
    if (!await confirm(what)) return _skipped(what);
    // Yours can be put back, shared as it was. One you were given can't: it isn't yours to make again.
    if (!t.isShared) {
      calendar.noteChange('Deleted trip “${t.title}”', () async {
        await trips!.save(t.copyWith(people: const []));
        if (t.people.isNotEmpty) await trips!.setTripPeople(t, t.people);
      });
    }
    await trips!.delete(t);
    return (
      result: {'ok': true},
      note: t.isShared ? 'Left “${t.title}”' : 'Deleted trip “${t.title}”',
      changed: true,
    );
  }

  // ---------------------------------------------------------------- the app

  ToolRun _openPage(Map<String, dynamic> a) {
    final page = _s(a, 'page');
    final go = navigate;
    if (page == null || !assistantPages.contains(page) || go == null) return _fail('Unknown page.');
    go(page);
    return (result: {'ok': true}, note: 'Opened ${page.replaceAll('_', ' ')}', changed: false);
  }
}

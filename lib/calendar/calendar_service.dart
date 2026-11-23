import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../util/fields.dart';
import 'calendar_history.dart';
import 'calendar_models.dart';
import 'calendar_store.dart';
import 'canvas.dart';
import 'todos.dart';
import '../people/invites.dart';
import '../people/people_service.dart';
import '../trips/trip_models.dart';
import 'google_token.dart';
import '../util/dispose_safe.dart';

/// Your Google calendars and Canvas calendar feeds, in one place.
///
/// Google Calendar is synced by the server (functions/google.js): it holds a
/// lasting sign-in for each linked account, checks Google every minute and
/// keeps axisCalendar/{uid}/events up to date. Every device, the Android app
/// included, just listens to that, and changes go back to Google through the
/// server too. Only linking an account needs the browser, for Google's
/// sign-in popup.
///
/// Calendars you make here ([ownCalendars]) never go near Google: they and
/// their events are kept in axisCalendar/{uid}/ownCalendars and …/ownEvents.
class CalendarService extends ChangeNotifier with DisposeSafe {
  CalendarService(this.ownerUid);

  /// The Axis (Firebase) user — linked accounts and toggles are saved per user.
  final String ownerUid;

  final List<GoogleAccount> accounts = [];
  final List<GoogleCalendar> calendars = [];
  final Set<String> _hidden = {};
  final List<CalendarEvent> _events = [];

  bool loading = false;
  String? lastError;

  /// When the server last checked Google.
  DateTime? lastSynced;

  /// The server checks Google every minute (and the app does when you come
  /// back to it). Saved in Firestore, since the server needs to know.
  bool autoSync = true;
  bool syncing = false;

  /// Past events are kept as they were, even if changed or deleted in Google.
  bool keepPast = false;

  /// New calendars whose past events wait for your answer (keepPast on), by
  /// calendar key as stored ('/' as '_').
  List<String> pastPending = [];

  Future<void> setKeepPast(bool on) {
    keepPast = on;
    notifyListeners();
    return store.saveKeepPast(on);
  }

  /// The calendar a [pastPending] key stands for.
  GoogleCalendar? pendingCalendar(String key) => calendars.where((c) => c.key.replaceAll('/', '_') == key).firstOrNull;

  /// Your answer for a new calendar's past events. Returns how many were saved.
  Future<int> resolvePast(String key, {required bool keep}) async {
    pastPending = [...pastPending]..remove(key);
    notifyListeners();
    final r = await callServer('resolvePastEvents', {'calendarKey': key, 'keep': keep});
    return ((r is Map ? r['saved'] : null) as num? ?? 0).toInt();
  }

  Future<void> setAutoSync(bool on) {
    autoSync = on;
    notifyListeners();
    return store.saveAutoSync(on);
  }

  /// Everything, now: the server checks Google, and Canvas.
  Future<String> syncNow() async {
    syncing = true;
    notifyListeners();
    try {
      final problems = await Future.wait<List<String>>([
        _syncGoogle(),
        if (canvasFeeds.isNotEmpty) refreshCanvas().catchError((Object e) => ['$e']),
      ]);
      final errors = problems.expand((x) => x).toList();
      lastError = errors.isEmpty ? null : errors.join('\n');
      return lastError ?? 'Up to date';
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  /// Asks the server to check Google now ([from]/[to]: also a span outside
  /// the usual window). Returns any problems.
  Future<List<String>> _syncGoogle({DateTime? from, DateTime? to}) async {
    if (accounts.every((a) => !a.linked)) return const [];
    try {
      final r = await callServer('syncGoogleNow', {
        if (from != null) 'from': from.millisecondsSinceEpoch,
        if (to != null) 'to': to.millisecondsSinceEpoch,
      });
      return [for (final e in ((r as Map)['errors'] as List? ?? const [])) '$e'];
    } catch (e) {
      return ['$e'.replaceFirst('Exception: ', '')];
    }
  }

  @protected
  Future<Object?> callServer(String name, Map<String, dynamic> data) async {
    try {
      return (await FirebaseFunctions.instance.httpsCallable(name, options: HttpsCallableOptions(timeout: const Duration(minutes: 2))).call(data))
          .data;
    } catch (e) {
      throw Exception(_callError(e));
    }
  }

  DateTime? _lastResumeSync;

  void _onResume() {
    // Coming back to the app: check Google straight away rather than waiting
    // for the server's next minute.
    final now = DateTime.now();
    if (!autoSync || (_lastResumeSync != null && now.difference(_lastResumeSync!) < const Duration(seconds: 30))) return;
    _lastResumeSync = now;
    unawaited(_syncGoogle());
  }

  /// Optimizer's Firestore copy of settings and events (axisCalendar/{uid}).
  late final store = CalendarStore(ownerUid);

  String get _hiddenKey => 'optimizer.$ownerUid.hiddenCalendars';

  /// Whether Google accounts can be linked from here (Google's sign-in
  /// popup is web-only for now). Editing works everywhere.
  static bool get canLinkGoogle => debugCanLinkGoogle ?? kIsWeb;

  @visibleForTesting
  static bool? debugCanLinkGoogle;

  // ---------------------------------------------------------------- Canvas

  final List<CanvasFeed> canvasFeeds = [];
  List<CalendarEvent> _canvasEvents = [];

  /// Every Canvas item as a to-do, soonest first.
  List<CanvasTask> canvasTasks = [];

  /// Checked-off Canvas to-dos (axisCalendar/{uid}/taskStatus/{itemId}), kept
  /// apart from canvasItems, which the Cloud Functions rewrite.
  final Set<String> doneTasks = {};

  /// When each Canvas to-do was checked off.
  final Map<String, DateTime?> _doneAt = {};

  /// Your edits to Canvas to-dos, by item: {override: {title, due, allDay},
  /// base: {title, dueKey}}, where base is how Canvas had it when you edited.
  final Map<String, Map<String, dynamic>> _edits = {};

  /// To-dos you added yourself (axisCalendar/{uid}/todos).
  List<Todo> manualTodos = [];

  /// Where each Canvas to-do sits in the urgent / important matrix.
  final Map<String, Quadrant> _quadrants = {};

  /// The lists you made, in order (axisCalendar/{uid}/todoLists). The main
  /// list ([mainList]) isn't one of them.
  List<TodoList> todoLists = [];

  /// The list a to-do goes in unless you pick another. Renamable (saved in
  /// settings as todoMainList).
  TodoList get mainList => TodoList.main(_mainListName.isEmpty ? 'To-dos' : _mainListName);
  String _mainListName = '';

  /// The To-dos page sorts what's left into urgent / important (saved in
  /// settings as todoMatrix, so the calendar shows the same on every device).
  bool todoMatrix = false;

  /// The to-do list: Canvas items from classes that are switched on, and
  /// your own.
  List<Todo> get todos => [
        for (final t in canvasTasks)
          if (isVisible(t.calendar)) Todo.canvas(t, done: doneTasks.contains(t.id), doneAt: _doneAt[t.id], quadrant: _quadrants[t.id]),
        ...manualTodos,
      ];
  QuerySnapshot<Map<String, dynamic>>? _canvasItems;
  String? canvasError;
  final List<StreamSubscription> _subs = [];

  DocumentReference<Map<String, dynamic>> get _root => FirebaseFirestore.instance.collection('axisCalendar').doc(ownerUid);

  // ---------------------------------------------------------------- guests and invitations
  //
  // The server (functions/people.js) keeps your copies up to date: the
  // invitations you've been sent (optimizer/{uid}/invites), shown on your
  // calendar, and the guest lists of your own events (…/sentEvents).

  static const invitesAccount = 'invites';
  static final invitesCalendar = GoogleCalendar(
      id: 'invites', accountEmail: invitesAccount, name: 'Invitations', color: const Color(0xFF5EEAD4), primary: false, accessRole: 'reader');

  /// Your groups, for inviting a whole group to an event (set by the app).
  PeopleService? people;

  // ---- Trips: one big tile each; what's on them stays on the Trips page.

  List<Trip> trips = [];
  List<CalendarEvent> _tripTiles = [];

  /// Opens a trip on the Trips page (set by the app).
  void Function(String tripId)? onOpenTrip;

  void setTrips(List<Trip> list) {
    trips = list;
    _tripTiles = [for (final t in list) t.tile];
    notifyListeners();
  }

  /// Invitations to you, by id.
  final Map<String, Invite> invites = {};

  /// Your events' guest lists, by event key.
  final Map<String, EventGuests> _sent = {};
  List<CalendarEvent> _inviteEvents = [];

  /// Invitations waiting for your answer, newest first.
  List<Invite> get pendingInvites =>
      invites.values.where((i) => i.pending).toList()..sort((a, b) => (b.createdAt ?? DateTime(2000)).compareTo(a.createdAt ?? DateTime(2000)));

  EventGuests? guestsOf(CalendarEvent e) => _sent[e.key];
  Invite? inviteFor(CalendarEvent e) => e.calendar.accountEmail == invitesAccount ? invites[e.id] : null;

  void _listenPeople() {
    final mine = FirebaseFirestore.instance.collection('optimizer').doc(ownerUid);
    _subs.add(mine.collection('invites').snapshots().listen((s) {
      invites
        ..clear()
        ..addAll({for (final d in s.docs) d.id: Invite(d.id, d.data())});
      // Events you're invited to show on your calendar, unless you declined.
      _inviteEvents = [
        for (final i in invites.values)
          if (i.isEvent && i.status != 'declined' && i.start != null)
            CalendarEvent(
              id: i.id,
              calendar: invitesCalendar,
              title: i.pending ? 'Invited: ${i.title}' : i.title,
              description: '${i.event!['description'] ?? ''}',
              location: '${i.event!['location'] ?? ''}',
              start: i.allDay ? dayStart(i.start!.toUtc().copyWith(isUtc: false)) : i.start!,
              end: i.allDay ? dayStart(i.end!.toUtc().copyWith(isUtc: false)) : i.end!,
              allDay: i.allDay,
              color: invitesCalendar.color,
            ),
      ];
      notifyListeners();
    }, onError: (_) {}));
    _subs.add(mine.collection('sentEvents').snapshots().listen((s) {
      _sent
        ..clear()
        ..addAll({for (final d in s.docs) '${d.data()['eventKey']}': EventGuests(d.data())});
      notifyListeners();
    }, onError: (_) {}));
  }

  /// Sets the guest list of the event [eventKey] with the details in [d]:
  /// invites new guests, drops removed ones, updates everyone's copy.
  /// Returns links for new guests not on Optimizer yet, to send them.
  Future<InviteLinks> setEventGuests(String eventKey, EventDraft d, {required List<String> guests}) async {
    final r = await callServer('setEventGuests', {
      'eventKey': eventKey,
      'event': {
        'title': d.title,
        // All-day: the date at midnight UTC, the same for everyone.
        'start': d.allDay ? DateTime.utc(d.start.year, d.start.month, d.start.day).millisecondsSinceEpoch : d.start.millisecondsSinceEpoch,
        'end': d.allDay ? DateTime.utc(d.end.year, d.end.month, d.end.day).millisecondsSinceEpoch : d.end.millisecondsSinceEpoch,
        'allDay': d.allDay,
        'location': d.location,
        'description': d.description,
      },
      'guests': guests,
      'guestsCanSeeList': d.guestsCanSeeList,
    });
    return inviteLinksFrom(r);
  }

  Future<void> respondInvite(Invite i, {required bool accept}) => callServer('respondInvite', {'inviteId': i.id, 'accept': accept});

  void _listenCanvas() {
    _listenPeople();
    _listenOwn();
    var firstFeeds = true;
    _subs.add(_root.collection('canvasFeeds').snapshots().listen((s) {
      canvasFeeds
        ..clear()
        ..addAll([for (final d in s.docs) CanvasFeed(d.id, d.data())]..sort((a, b) => a.name.compareTo(b.name)));
      // Linked before groups: each gets a group of its own, once. (Only
      // those already there on opening: one linked now is put in a group by
      // whoever linked it.)
      if (firstFeeds && !s.metadata.isFromCache) {
        firstFeeds = false;
        for (final f in canvasFeeds.where((f) => f.todoList == null)) {
          _giveOwnGroup(f.id, f.name, id: 'canvas_${f.id}').catchError((_) {});
        }
      }
      canvasError = null;
      _rebuildCanvas();
    }, onError: _canvasFailed));
    _subs.add(_root.collection('canvasItems').snapshots().listen((s) {
      _canvasItems = s;
      _rebuildCanvas();
    }, onError: _canvasFailed));
    _subs.add(_root.collection('eventEdits').snapshots().listen((s) {
      _localEdits
        ..clear()
        ..addAll({for (final d in s.docs) '${d.data()['calendarKey']}|${d.data()['eventId']}': d.data()});
      notifyListeners();
    }, onError: _canvasFailed));
    _listenHistory();
    _subs.add(_root.collection('removedEvents').snapshots().listen((s) {
      _removed
        ..clear()
        ..addAll([for (final d in s.docs) '${d.data()['key']}']);
      notifyListeners();
    }, onError: _canvasFailed));
    _subs.add(_root.collection('hiddenEvents').snapshots().listen((s) {
      _hiddenEvents
        ..clear()
        ..addAll([for (final d in s.docs) '${d.data()['key']}']);
      if (_hiddenEvents.isEmpty) showHiddenEvents = false;
      notifyListeners();
    }, onError: _canvasFailed));
    _subs.add(_root.collection('todos').snapshots().listen((s) {
      manualTodos = [for (final d in s.docs) Todo.manual(d.id, d.data())];
      notifyListeners();
    }, onError: _canvasFailed));
    _subs.add(_root.collection('todoLists').snapshots().listen((s) {
      todoLists = [for (final d in s.docs) TodoList(d.id, d.data())]..sort((a, b) => a.order.compareTo(b.order));
      notifyListeners();
    }, onError: _canvasFailed));
    _subs.add(_root.collection('taskStatus').snapshots().listen((s) {
      doneTasks.clear();
      _doneAt.clear();
      _quadrants.clear();
      _edits.clear();
      for (final d in s.docs) {
        final data = d.data();
        if (data['done'] == true) {
          doneTasks.add(d.id);
          _doneAt[d.id] = asDate(data['doneAt']);
        }
        if (Quadrant.parse(data['quadrant']) case final q?) _quadrants[d.id] = q;
        if (data['override'] is Map && data['overrideBase'] is Map) {
          _edits[d.id] = {
            'override': Map<String, dynamic>.from(data['override'] as Map),
            'base': Map<String, dynamic>.from(data['overrideBase'] as Map),
          };
        }
      }
      _rebuildCanvas();
    }, onError: _canvasFailed));
  }

  // ---------------------------------------------------------------- your own calendars

  /// Calendars you made in Optimizer, by name.
  List<GoogleCalendar> ownCalendars = [];
  List<CalendarEvent> _ownEvents = [];
  Map<String, Map<String, dynamic>> _ownCalendarDocs = {};
  Map<String, Map<String, dynamic>> _ownEventDocs = {};

  void _listenOwn() {
    _subs.add(_root.collection('ownCalendars').snapshots().listen((s) {
      _ownCalendarDocs = {for (final d in s.docs) d.id: d.data()};
      _rebuildOwn();
    }, onError: _canvasFailed));
    _subs.add(_root.collection('ownEvents').snapshots().listen((s) {
      _ownEventDocs = {for (final d in s.docs) d.id: d.data()};
      _rebuildOwn();
    }, onError: _canvasFailed));
  }

  void _rebuildOwn() {
    ownCalendars = [
      for (final d in _ownCalendarDocs.entries)
        GoogleCalendar(
          id: d.key,
          accountEmail: ownAccount,
          name: '${d.value['name'] ?? 'Calendar'}',
          color: readableColor(parseHexColor(d.value['color'] as String?, canvasPalette.first)),
          primary: false,
          accessRole: 'owner',
        ),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _ownEvents = CalendarStore.eventsFrom(_ownEventDocs, {for (final c in ownCalendars) c.key: c});
    notifyListeners();
  }

  @protected
  Future<void> writeOwnCalendar(String id, Map<String, dynamic>? data) {
    final doc = _root.collection('ownCalendars').doc(id);
    return data == null ? doc.delete() : doc.set(data);
  }

  @protected
  Future<void> writeOwnEvent(String id, Map<String, dynamic>? data) {
    final doc = _root.collection('ownEvents').doc(id);
    return data == null ? doc.delete() : doc.set(data);
  }

  // Shown straight away; Firestore confirms it a moment later.
  Future<void> _putOwnCalendar(String id, Map<String, dynamic>? data) {
    data == null ? _ownCalendarDocs.remove(id) : _ownCalendarDocs[id] = data;
    _rebuildOwn();
    return writeOwnCalendar(id, data);
  }

  Future<void> _putOwnEvent(String id, Map<String, dynamic>? data) {
    data == null ? _ownEventDocs.remove(id) : _ownEventDocs[id] = data;
    _rebuildOwn();
    return writeOwnEvent(id, data);
  }

  static String _newOwnId() => '${DateTime.now().microsecondsSinceEpoch}';

  /// Makes a calendar that lives only in Optimizer, and returns it.
  Future<GoogleCalendar> createOwnCalendar(String name, Color color) async {
    final id = _newOwnId();
    remember('Added calendar “$name”', () => _putOwnCalendar(id, null));
    final write = _putOwnCalendar(id, {'name': name, 'color': colorToHex(color), 'createdAt': Timestamp.now()});
    final made = ownCalendars.firstWhere((c) => c.id == id);
    await write;
    return made;
  }

  Future<void> updateOwnCalendar(GoogleCalendar c, {String? name, Color? color}) {
    final before = _ownCalendarDocs[c.id];
    if (before == null) throw Exception('That calendar isn’t in Optimizer anymore.');
    remember('Changed calendar “${c.name}”', () => _putOwnCalendar(c.id, before));
    return _putOwnCalendar(c.id, {
      ...before,
      if (name != null) 'name': name,
      if (color != null) 'color': colorToHex(color),
    });
  }

  /// Deletes a calendar of yours and everything on it.
  Future<void> deleteOwnCalendar(GoogleCalendar c) => asOneChange('Deleted calendar “${c.name}”', () async {
        for (final e in _ownEvents.where((e) => e.calendar.key == c.key).toList()) {
          await deleteEvent(e);
        }
        final before = _ownCalendarDocs[c.id];
        if (before != null) remember('Deleted calendar “${c.name}”', () => _putOwnCalendar(c.id, before));
        await _putOwnCalendar(c.id, null);
      });

  /// How many events are on a calendar of yours.
  int ownEventCount(GoogleCalendar c) => _ownEvents.where((e) => e.calendar.key == c.key).length;

  Future<String> _saveOwnEvent(EventDraft d, GoogleCalendar cal, CalendarEvent? original) async {
    final id = original?.id ?? _newOwnId();
    final was = original == null ? null : (_ownEvents.where((x) => x.key == original.key).firstOrNull ?? original);
    final saved = CalendarEvent(
        id: id,
        calendar: cal,
        title: d.title,
        description: d.description,
        location: d.location,
        start: d.start,
        end: d.end,
        allDay: d.allDay,
        color: cal.color,
        colorId: d.colorId);
    if (was == null) {
      _log(HistoryAction.added, d.title, after: saved);
      remember('Added “${d.title}”', () => deleteEvent(saved));
    } else {
      _log(HistoryAction.changed, d.title, before: was, after: saved);
      remember('Changed “${was.title}”', () => saveEvent(_draftOf(was), original: saved));
    }
    final ymd = DateFormat('yyyy-MM-dd');
    await _putOwnEvent(id, {
      'calendarKey': cal.key,
      'title': d.title,
      'description': d.description,
      'location': d.location,
      'allDay': d.allDay,
      'start': Timestamp.fromDate(d.start),
      'end': Timestamp.fromDate(d.end),
      // As the server's Google events have it, so they land on the right day anywhere.
      if (d.allDay) 'date': ymd.format(d.start),
      if (d.allDay) 'endDate': ymd.format(d.end),
      'colorId': d.colorId,
    });
    return id;
  }

  Future<void> _deleteOwnEvent(CalendarEvent e) async {
    final was = _ownEvents.where((x) => x.key == e.key).firstOrNull ?? e;
    await _putOwnEvent(e.id, null);
    if (_sent[e.key]?.guests.isNotEmpty ?? false) await setEventGuests(e.key, _draftOf(was), guests: const []);
    _log(HistoryAction.deleted, was.title, before: was);
    remember('Deleted “${was.title}”', () => saveEvent(_draftOf(was)));
  }

  /// Between one of your calendars and a Google one: made there, deleted here,
  /// as one change.
  Future<String?> _moveAcross(EventDraft d, CalendarEvent original) async {
    if (!canEdit(original.calendar)) {
      throw Exception('${original.calendar.name} can’t be changed from Optimizer, so “${original.title}” can’t be moved off it.');
    }
    String? id;
    await asOneChange('Moved “${original.title}”', () async {
      id = await saveEvent(d);
      await deleteEvent(original);
    });
    return id;
  }

  // ---------------------------------------------------------------- undo
  //
  // Every change you make here (events, edits kept in Optimizer, to-dos) is
  // remembered with how to put it back, so the calendar's undo button can
  // reverse the latest one. Kept for this session only.

  final List<UndoStep> _undo = [];
  bool _undoing = false;
  List<UndoStep>? _collecting;

  /// The change undo would reverse, if any.
  UndoStep? get lastChange => _undo.lastOrNull;

  /// Records a change with how to reverse it (for subclasses: fakes in tests).
  @protected
  void remember(String label, Future<void> Function() undo) {
    if (_undoing) return;
    final step = UndoStep(label, undo, _logged);
    _logged = const [];
    if (_collecting != null) {
      _collecting!.add(step);
      return;
    }
    _undo.add(step);
    if (_undo.length > 30) _undo.removeAt(0);
    notifyListeners();
  }

  /// Notes a change made elsewhere (a trip, by the assistant), so undo can
  /// reverse it along with the rest.
  void noteChange(String label, Future<void> Function() undo) => remember(label, undo);

  /// Runs [change] so everything it does is undone together, as [label].
  Future<void> asOneChange(String label, Future<void> Function() change) async {
    if (_collecting != null || _undoing) return change();
    final steps = _collecting = [];
    try {
      await change();
    } finally {
      _collecting = null;
      if (steps.isNotEmpty) {
        _logged = [for (final s in steps) ...s.history];
        remember(label, () async {
          for (final s in steps.reversed) {
            await s.undo();
          }
        });
      }
    }
  }

  /// Reverses the latest change. Returns what was undone.
  Future<String?> undoLast() async {
    final step = _undo.lastOrNull;
    if (step == null) return null;
    _undoing = true;
    try {
      await step.undo();
      _undo.remove(step);
      for (final e in history.where((e) => step.history.contains(e.id))) {
        _markReverted(e);
      }
      return step.label;
    } finally {
      _undoing = false;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- history
  //
  // Everything you change on your calendar, kept for [historyDays] days with
  // what it takes to put it back, so unlike undo it lasts past this session.

  /// Newest first.
  List<HistoryEntry> history = [];

  /// What's just been logged, for the next undo step to know.
  List<String> _logged = const [];

  void _log(HistoryAction action, String title,
      {bool google = false, CalendarEvent? before, CalendarEvent? after, Map<String, dynamic>? editBefore}) {
    if (_undoing) return;
    final entry = HistoryEntry(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      at: DateTime.now(),
      action: action,
      title: title,
      google: google,
      before: before == null ? null : snapshotOf(before),
      after: after == null ? null : snapshotOf(after),
      editBefore: editBefore,
    );
    history = [entry, ...history];
    _logged = [..._logged, entry.id];
    // The change is made either way; a lost line of history shouldn't undo it.
    saveHistory(entry).catchError((Object _) {});
  }

  @protected
  Future<void> saveHistory(HistoryEntry e) async => _root.collection('history').doc(e.id).set(e.toJson());

  void _markReverted(HistoryEntry e) {
    e.reverted = true;
    saveHistory(e).catchError((Object _) {});
    notifyListeners();
  }

  void _listenHistory() {
    final col = _root.collection('history');
    _subs.add(col.orderBy('at', descending: true).limit(300).snapshots().listen((s) {
      final oldest = DateTime.now().subtract(const Duration(days: historyDays));
      history = [
        for (final d in s.docs)
          if (HistoryEntry.fromDoc(d.id, d.data()).at.isAfter(oldest)) HistoryEntry.fromDoc(d.id, d.data()),
      ];
      notifyListeners();
    }, onError: _canvasFailed));
    _clearOldHistory();
  }

  /// Rolling: what's past [historyDays] goes, a batch each time you open the app.
  Future<void> _clearOldHistory() async {
    try {
      final old = await _root
          .collection('history')
          .where('at', isLessThan: Timestamp.fromDate(DateTime.now().subtract(const Duration(days: historyDays))))
          .limit(200)
          .get();
      if (old.docs.isEmpty) return;
      final batch = FirebaseFirestore.instance.batch();
      for (final d in old.docs) {
        batch.delete(d.reference);
      }
      await batch.commit();
    } catch (_) {
      // It'll go next time.
    }
  }

  CalendarEvent _eventOf(Map<String, dynamic> s) {
    final cal = calendarByKey('${s['calendarKey']}');
    if (cal == null) throw Exception('That calendar isn’t in Optimizer anymore, so this can’t be put back.');
    return CalendarEvent(
      id: '${s['eventId']}',
      calendar: cal,
      title: '${s['title'] ?? ''}',
      description: '${s['description'] ?? ''}',
      location: '${s['location'] ?? ''}',
      start: DateTime.fromMillisecondsSinceEpoch((s['start'] as num).toInt()),
      end: DateTime.fromMillisecondsSinceEpoch((s['end'] as num).toInt()),
      allDay: s['allDay'] == true,
      color: cal.color,
      colorId: s['colorId'] as String?,
    );
  }

  /// Puts a change back as it was before, wherever it was made.
  Future<void> revertHistory(HistoryEntry e) async {
    _undoing = true;
    try {
      final before = e.before, after = e.after;
      switch (e.action) {
        case HistoryAction.added:
          await deleteEvent(_eventOf(after!));
        case HistoryAction.changed:
          final now = _eventOf(after!);
          await saveEvent(_draftOf(_eventOf(before!)), original: _events.where((x) => x.key == now.key).firstOrNull ?? now);
        case HistoryAction.deleted:
          await saveEvent(_draftOf(_eventOf(before!)));
        case HistoryAction.removed:
          await _setRemoved(_eventOf(before!), false);
        case HistoryAction.keptHere:
        case HistoryAction.wentBack:
          await _setLocalEdit(_eventOf(before!), e.editBefore);
        case HistoryAction.hid:
          await _setEventHidden(_eventOf(before!), false);
        case HistoryAction.showed:
          await _setEventHidden(_eventOf(before!), true);
      }
      // Undo mustn't put back what's already been put back.
      _undo.removeWhere((s) => s.history.contains(e.id));
      _markReverted(e);
    } finally {
      _undoing = false;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- edits kept in Optimizer
  //
  // A Google event you change without sending the change to Google is kept
  // in axisCalendar/{uid}/eventEdits under the event's own key. It's shown in
  // place of Google's version (same event, never a second copy), marked ✎,
  // and stays that way even if the event later changes in Google, until you
  // send it to Google or go back to Google's version.

  final Map<String, Map<String, dynamic>> _localEdits = {};

  static String _editId(String key) => key.replaceAll('/', '_');

  CalendarEvent _withEdit(CalendarEvent e) {
    final d = _localEdits[e.key];
    if (d == null) return e;
    final colorId = d['colorId'] as String?;
    return e.copyWith(
      title: d['title'] as String?,
      description: d['description'] as String?,
      location: d['location'] as String?,
      start: asDate(d['start']),
      end: asDate(d['end']),
      allDay: d['allDay'] as bool?,
      colorId: colorId,
      color: colorId == null ? null : readableColor(googleEventColors[colorId] ?? e.calendar.color),
      localEdit: true,
    );
  }

  // ---------------------------------------------------------------- hidden events
  //
  // An event you've hidden stays exactly as it is, in Google and here. It's
  // only left off your calendar, unless you ask to see the hidden ones.

  final Set<String> _hiddenEvents = {};

  /// Showing hidden events on the calendar, faintly.
  bool showHiddenEvents = false;

  int get hiddenEventCount => _hiddenEvents.length;

  bool isEventHidden(CalendarEvent e) => _hiddenEvents.contains(e.key);

  CalendarEvent _faintIfHidden(CalendarEvent e) => isEventHidden(e) ? e.copyWith(color: e.color.withValues(alpha: 0.45)) : e;

  void setShowHiddenEvents(bool show) {
    showHiddenEvents = show;
    notifyListeners();
  }

  Future<void> hideEvent(CalendarEvent e) {
    _log(HistoryAction.hid, e.title, before: e);
    remember('Hid “${e.title}”', () => _setEventHidden(e, false));
    return _setEventHidden(e, true);
  }

  Future<void> unhideEvent(CalendarEvent e) {
    _log(HistoryAction.showed, e.title, before: e);
    remember('Showed “${e.title}” again', () => _setEventHidden(e, true));
    return _setEventHidden(e, false);
  }

  Future<void> _setEventHidden(CalendarEvent e, bool hide) {
    hide ? _hiddenEvents.add(e.key) : _hiddenEvents.remove(e.key);
    // Nothing left hidden: nothing to be showing.
    if (_hiddenEvents.isEmpty) showHiddenEvents = false;
    notifyListeners();
    return saveEventHidden(e, hide);
  }

  @protected
  Future<void> saveEventHidden(CalendarEvent e, bool hide) {
    final doc = _root.collection('hiddenEvents').doc(_editId(e.key));
    return hide ? doc.set({'key': e.key, 'title': e.title, 'hiddenAt': Timestamp.now()}) : doc.delete();
  }

  // ---------------------------------------------------------------- deleted in Optimizer only
  //
  // Deleted here but left alone in Google Calendar: the next sync would bring it
  // straight back, so its key is kept to leave it out, until you revert that.

  final Set<String> _removed = {};

  Future<void> removeEventHere(CalendarEvent e) async {
    _log(HistoryAction.removed, e.title, before: e);
    remember('Deleted “${e.title}” from Optimizer', () => _setRemoved(e, false));
    await _setRemoved(e, true);
    // Its guests' invitations came from Optimizer, so they go with it.
    if (_sent[e.key]?.guests.isNotEmpty ?? false) await setEventGuests(e.key, _draftOf(e), guests: const []);
  }

  Future<void> _setRemoved(CalendarEvent e, bool remove) {
    remove ? _removed.add(e.key) : _removed.remove(e.key);
    notifyListeners();
    return saveEventRemoved(e, remove);
  }

  @protected
  Future<void> saveEventRemoved(CalendarEvent e, bool remove) {
    final doc = _root.collection('removedEvents').doc(_editId(e.key));
    return remove ? doc.set({'key': e.key, 'title': e.title, 'removedAt': Timestamp.now()}) : doc.delete();
  }

  /// Keeps [d] as this event's version in Optimizer only.
  Future<void> saveLocalEdit(CalendarEvent original, EventDraft d) {
    final before = _localEdits[original.key];
    _log(HistoryAction.keptHere, d.title,
        before: original,
        after: original.copyWith(
            title: d.title, description: d.description, location: d.location, start: d.start, end: d.end, allDay: d.allDay, colorId: d.colorId),
        editBefore: before);
    remember('Changed “${original.title}” in Optimizer', () => _setLocalEdit(original, before));
    final data = <String, dynamic>{
      'calendarKey': original.calendar.key,
      'eventId': original.id,
      'title': d.title,
      'description': d.description,
      'location': d.location,
      'start': Timestamp.fromDate(d.start),
      'end': Timestamp.fromDate(d.end),
      'allDay': d.allDay,
      'colorId': d.colorId,
      'editedAt': Timestamp.now(),
    };
    _localEdits[original.key] = data; // shown straight away
    notifyListeners();
    return _root.collection('eventEdits').doc(_editId(original.key)).set(data);
  }

  /// Puts an Optimizer-only version back exactly as it was ([data] null: none).
  Future<void> _setLocalEdit(CalendarEvent e, Map<String, dynamic>? data) {
    final doc = _root.collection('eventEdits').doc(_editId(e.key));
    data == null ? _localEdits.remove(e.key) : _localEdits[e.key] = data;
    notifyListeners();
    return data == null ? doc.delete() : doc.set(data);
  }

  /// Back to Google's version of the event.
  Future<void> dropLocalEdit(CalendarEvent e) {
    final before = _localEdits[e.key];
    // Saving to Google stops keeping an edit apart, but that's part of the save.
    if (before != null && _collecting == null) _log(HistoryAction.wentBack, e.title, before: e, editBefore: before);
    if (before != null) remember('Went back to Google’s version of “${e.title}”', () => _setLocalEdit(e, before));
    _localEdits.remove(e.key);
    notifyListeners();
    return _root.collection('eventEdits').doc(_editId(e.key)).delete();
  }

  /// Sends an Optimizer-only version to Google, then stops keeping it apart.
  Future<void> pushLocalEdit(CalendarEvent e) => asOneChange('Saved “${e.title}” to Google', () => _pushLocalEdit(e));

  Future<void> _pushLocalEdit(CalendarEvent e) async {
    final d = EventDraft(
      calendarKey: e.calendar.key,
      title: e.title,
      start: e.start,
      end: e.end,
      allDay: e.allDay,
      description: e.description,
      location: e.location,
      colorId: e.colorId,
    );
    await saveEvent(d, original: e);
    await dropLocalEdit(e);
  }

  void _canvasFailed(Object e) {
    canvasError = '$e';
    notifyListeners();
  }

  /// Each group's classes, by feed id, in name order.
  final Map<String, List<String>> canvasCourses = {};

  /// The calendars of one Canvas group: one per class.
  List<GoogleCalendar> canvasCalendars(CanvasFeed f) => [for (final c in canvasCourses[f.id] ?? const []) f.calendarFor(c)];

  void _rebuildCanvas() {
    final items = _canvasItems;
    final feeds = {for (final f in canvasFeeds) f.id: f};
    canvasCourses.clear();
    for (final d in items?.docs ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[]) {
      final id = d.data()['feedId'];
      if (feeds.containsKey(id)) (canvasCourses[id] ??= []).add(courseOf(d.data()));
    }
    for (final e in canvasCourses.entries) {
      final names = e.value.toSet().toList()..sort((a, b) => a == otherCourse ? 1 : (b == otherCourse ? -1 : a.compareTo(b)));
      canvasCourses[e.key] = names;
      _colorNewCourses(feeds[e.key]!, names);
    }
    final shown = <CanvasItem>[];
    for (final d in items?.docs ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[]) {
      final data = d.data();
      final edit = _edits[d.id];
      if (edit == null) {
        shown.add((id: d.id, data: data, source: data, edited: false));
      } else if (edit['base']['title'] == data['title'] && edit['base']['dueKey'] == canvasDueKey(data)) {
        // Your edit stands while Canvas still has it the way it was.
        shown.add((id: d.id, data: withOverride(data, edit['override'] as Map<String, dynamic>), source: data, edited: true));
      } else {
        // Canvas changed it since: keep your version as your own to-do, and
        // show Canvas's new one alongside.
        _splitOffEdit(d.id, data, edit, feeds[data['feedId']]);
        shown.add((id: d.id, data: data, source: data, edited: false));
      }
    }
    _canvasEvents = canvasEvents(shown, feeds, doneTasks);
    canvasTasks = canvasTasksFrom(shown, feeds);
    notifyListeners();
  }

  void _splitOffEdit(String id, Map<String, dynamic> canvas, Map<String, dynamic> edit, CanvasFeed? feed) {
    final o = edit['override'] as Map<String, dynamic>;
    final course = courseOf(canvas);
    // A fixed id, so two devices noticing at once write the same to-do.
    final key = '${edit['base']['title']}|${edit['base']['dueKey']}'.hashCode.toUnsigned(32).toRadixString(16);
    _root.collection('todos').doc('canvasEdit_${id}_$key').set({
      'title': o['title'],
      'due': o['due'],
      'allDay': o['allDay'] != false,
      'done': doneTasks.contains(id),
      'label': course,
      'color': feed == null ? null : colorToHex(feed.calendarFor(course).color),
      'url': canvas['url'],
      'fromCanvas': id,
      if (_quadrants[id] case final q?) 'quadrant': q.key,
      'createdAt': FieldValue.serverTimestamp(),
    }).catchError((_) {});
    _root.collection('taskStatus').doc(id).set({
      'override': FieldValue.delete(),
      'overrideBase': FieldValue.delete(),
      'done': false,
    }, SetOptions(merge: true)).catchError((_) {});
    _edits.remove(id);
  }

  /// A class seen for the first time gets the next unused color, saved on its
  /// group so it stays the same (and the same on every device).
  void _colorNewCourses(CanvasFeed f, List<String> courses) {
    final missing = courses.where((c) => !f.courseColors.containsKey(c)).toList();
    if (missing.isEmpty) return;
    final used = f.courseColors.values.map((c) => c.toARGB32()).toSet();
    final free = canvasPalette.where((c) => !used.contains(c.toARGB32())).toList();
    final add = <String, String>{
      for (var i = 0; i < missing.length; i++)
        missing[i]: colorToHex(free.isEmpty ? canvasPalette[(used.length + i) % canvasPalette.length] : free[i % free.length]),
    };
    _root.collection('canvasFeeds').doc(f.id).set({'courseColors': add}, SetOptions(merge: true)).catchError((_) {});
  }

  /// Recolors a calendar here: one of your own, a Canvas class, or a Google
  /// calendar (in Optimizer only; Google Calendar keeps its own color).
  Future<void> setCalendarColor(GoogleCalendar c, Color color) => c.isOwn
      ? updateOwnCalendar(c, color: color)
      : c.accountEmail == canvasAccount
          ? setCourseColor(c, color)
          : store.saveCalendarColor(c.key, colorToHex(color));

  Future<void> setCourseColor(GoogleCalendar course, Color color) {
    final at = course.id.indexOf('::');
    final feedId = course.id.substring(0, at);
    final name = course.id.substring(at + 2);
    return _root.collection('canvasFeeds').doc(feedId).set({
      'courseColors': {name: colorToHex(color)},
    }, SetOptions(merge: true));
  }

  String _callError(Object e) {
    if (e is! FirebaseFunctionsException) return '$e';
    // A web call to a function that isn't deployed fails as a bare "internal".
    if (e.code == 'not-found' || (e.code == 'internal' && (e.message ?? 'internal').toLowerCase() == 'internal')) {
      return 'Couldn’t reach Optimizer’s server for this. Its Google sync isn’t deployed yet.';
    }
    return e.message ?? e.code;
  }

  /// Adds a Canvas "Calendar Feed" link; the server checks it, reads it and
  /// keeps it up to date from then on. Returns what was added.
  ///
  /// [group]: the To-dos group its items go in; null gives it a group of its
  /// own, called [name] (or what Canvas calls it).
  Future<String> addCanvasFeed(String url, {String name = '', bool notify = true, String? group}) async {
    try {
      final r = await FirebaseFunctions.instance.httpsCallable('addCanvasFeed').call({
        'url': url,
        'name': name,
        'notifyNew': notify,
        'notifyChanges': notify,
      });
      final d = r.data as Map;
      final id = '${d['id'] ?? ''}';
      if (id.isNotEmpty) {
        group == null ? await _giveOwnGroup(id, name.isEmpty ? '${d['name'] ?? 'School'}' : name) : await _putFeedIn(id, group);
      }
      return 'Added ${d['name']} · ${d['count']} items';
    } catch (e) {
      throw Exception(_callError(e));
    }
  }

  Future<void> removeCanvasFeed(CanvasFeed f) async {
    try {
      await FirebaseFunctions.instance.httpsCallable('removeCanvasFeed').call({'id': f.id});
    } catch (e) {
      throw Exception(_callError(e));
    }
  }

  /// Whether Canvas is being checked right now (from [refreshCanvas]).
  bool canvasChecking = false;

  /// After five refreshes in five minutes, when the server takes another.
  DateTime? canvasRetryAt;

  /// When Canvas was last checked: the latest of the feeds' checks.
  DateTime? get canvasCheckedAt {
    DateTime? last;
    for (final f in canvasFeeds) {
      final c = f.lastChecked;
      if (c != null && (last == null || c.isAfter(last))) last = c;
    }
    return last;
  }

  /// Checks Canvas now. With premium beta the server also checks every
  /// minute; without it, this (on opening and the refresh button) is the only
  /// check, at most five in five minutes. Returns any problems.
  Future<List<String>> refreshCanvas({CanvasFeed? only}) async {
    canvasChecking = true;
    notifyListeners();
    try {
      final r = await FirebaseFunctions.instance.httpsCallable('refreshCanvasFeeds').call({if (only != null) 'id': only.id});
      canvasRetryAt = null;
      return [for (final e in ((r.data as Map)['errors'] as List? ?? const [])) '$e'];
    } catch (e) {
      if (e is FirebaseFunctionsException && e.code == 'resource-exhausted') {
        final at = (e.details is Map) ? (e.details as Map)['retryAt'] : null;
        canvasRetryAt = at is num ? DateTime.fromMillisecondsSinceEpoch(at.toInt()) : DateTime.now().add(const Duration(minutes: 5));
      }
      throw Exception(_callError(e));
    } finally {
      canvasChecking = false;
      notifyListeners();
    }
  }

  /// On opening the app without premium beta: checks Canvas unless it was
  /// checked in the last [fresh] (so reloading doesn't use up refreshes).
  /// Quiet: a problem shows on the feed, not as an error here.
  Future<void> refreshCanvasIfStale({Duration fresh = const Duration(minutes: 5)}) async {
    final last = canvasCheckedAt;
    if (canvasFeeds.isEmpty || canvasChecking) return;
    if (last != null && DateTime.now().difference(last) < fresh) return;
    try {
      await refreshCanvas();
    } catch (_) {}
  }

  /// Changes a to-do's title and date. For a Canvas item this stops Canvas
  /// from updating it — until Canvas itself changes it, when the new version
  /// shows up as well.
  Future<void> editTodo(Todo t, {required String title, DateTime? due, required bool allDay}) {
    final c = t.canvas;
    final before = _edits[t.id];
    remember('Changed “${t.title}”', () {
      if (c == null) {
        return _root.collection('todos').doc(t.id).update({
          'title': t.title,
          'due': t.due == null ? null : Timestamp.fromDate(t.due!),
          'allDay': t.allDay,
        });
      }
      return _root.collection('taskStatus').doc(t.id).set({
        'override': before == null ? FieldValue.delete() : before['override'],
        'overrideBase': before == null ? FieldValue.delete() : before['base'],
      }, SetOptions(merge: true));
    });
    if (c == null) {
      return _root.collection('todos').doc(t.id).update({
        'title': title,
        'due': due == null ? null : Timestamp.fromDate(due),
        'allDay': allDay,
      });
    }
    return _root.collection('taskStatus').doc(t.id).set({
      'override': {'title': title, 'due': Timestamp.fromDate(due ?? c.due), 'allDay': allDay},
      'overrideBase': {'title': c.source['title'], 'dueKey': canvasDueKey(c.source)},
      'editedAt': Timestamp.now(),
    }, SetOptions(merge: true));
  }

  /// Drops your edit of a Canvas item, so it follows Canvas again.
  Future<void> restoreFromCanvas(Todo t) {
    final before = _edits[t.id];
    if (before != null) {
      remember(
          'Undid your edit of “${t.title}”',
          () => _root.collection('taskStatus').doc(t.id).set({
                'override': before['override'],
                'overrideBase': before['base'],
              }, SetOptions(merge: true)));
    }
    return _root.collection('taskStatus').doc(t.id).set({
      'override': FieldValue.delete(),
      'overrideBase': FieldValue.delete(),
    }, SetOptions(merge: true));
  }

  Future<void> addTodo(String title, {DateTime? due, bool allDay = true, String? listId, Quadrant? quadrant}) async {
    final ref = await _root.collection('todos').add({
      'title': title,
      'due': due == null ? null : Timestamp.fromDate(due),
      'allDay': allDay,
      'done': false,
      if (listId != null && listId != TodoList.mainListId) 'listId': listId,
      if (quadrant != null) 'quadrant': quadrant.key,
      'createdAt': FieldValue.serverTimestamp(),
    });
    remember('Added “$title”', () => ref.delete());
  }

  Future<void> deleteTodo(Todo t) async {
    final ref = _root.collection('todos').doc(t.id);
    final data = (await ref.get()).data();
    await ref.delete();
    if (data != null) remember('Deleted “${t.title}”', () => ref.set(data));
  }

  Future<void> setTodoDone(Todo t, bool done) {
    remember(done ? 'Checked off “${t.title}”' : 'Unchecked “${t.title}”', () => setTodoDone(t, !done));
    if (t.canvas != null) return setTaskDone(t.canvas!, done);
    // The device's clock, so the time is there straight away for sorting.
    return _root.collection('todos').doc(t.id).update({'done': done, 'doneAt': done ? Timestamp.now() : null});
  }

  /// Checks off a to-do from the calendar, where it's shown as an event.
  Future<void> setEventDone(CalendarEvent e, bool done) async {
    for (final t in todos) {
      if (t.id == e.id) return setTodoDone(t, done);
    }
  }

  Future<void> setTaskDone(CanvasTask t, bool done) {
    // Shown straight away; Firestore confirms it a moment later.
    final now = DateTime.now();
    done ? doneTasks.add(t.id) : doneTasks.remove(t.id);
    _doneAt[t.id] = done ? now : null;
    _rebuildCanvas();
    // Merged, so an edit you made to it is kept.
    return _root.collection('taskStatus').doc(t.id).set({
      'done': done,
      'doneAt': done ? Timestamp.fromDate(now) : null,
      'title': t.title,
      'course': t.course,
      'due': Timestamp.fromDate(t.due),
      'source': 'canvas',
    }, SetOptions(merge: true));
  }

  // ---------------------------------------------------------------- lists and the matrix

  /// Puts a to-do in a box of the urgent / important matrix, or (null) back
  /// with the ones not sorted yet.
  Future<void> setTodoQuadrant(Todo t, Quadrant? q) {
    if (t.quadrant == q) return Future.value();
    remember(q == null ? 'Unsorted “${t.title}”' : 'Moved “${t.title}” to ${q.title}', () => setTodoQuadrant(_now(t), t.quadrant));
    if (t.canvas != null) {
      // Shown straight away; Firestore confirms it a moment later.
      q == null ? _quadrants.remove(t.id) : _quadrants[t.id] = q;
      notifyListeners();
      return _root.collection('taskStatus').doc(t.id).set({'quadrant': q?.key ?? FieldValue.delete()}, SetOptions(merge: true));
    }
    return _root.collection('todos').doc(t.id).update({'quadrant': q?.key ?? FieldValue.delete()});
  }

  /// Moves one of your own to-dos to another list.
  Future<void> moveTodo(Todo t, String listId) {
    if (t.isCanvas || (t.listId ?? TodoList.mainListId) == listId) return Future.value();
    final before = t.listId ?? TodoList.mainListId;
    remember('Moved “${t.title}”', () => moveTodo(_now(t), before));
    return _root.collection('todos').doc(t.id).update({'listId': listId == TodoList.mainListId ? FieldValue.delete() : listId});
  }

  /// [t] as it is now (an undo may run long after [t] was read).
  Todo _now(Todo t) => todos.where((x) => x.id == t.id).firstOrNull ?? t;

  Future<void> addTodoList(String name) async {
    final order = todoLists.isEmpty ? 0.0 : todoLists.last.order + 1;
    final ref = await _root.collection('todoLists').add({'name': name, 'order': order, 'createdAt': FieldValue.serverTimestamp()});
    remember('Added the group “$name”', () => ref.delete());
  }

  Future<void> renameTodoList(TodoList l, String name) {
    if (l.isMain) {
      final before = _mainListName;
      remember('Renamed “${l.name}”', () => _saveMainListName(before));
      return _saveMainListName(name);
    }
    remember('Renamed “${l.name}”', () => _root.collection('todoLists').doc(l.id).update({'name': l.name}));
    return _root.collection('todoLists').doc(l.id).update({'name': name});
  }

  Future<void> _saveMainListName(String name) {
    _mainListName = name;
    notifyListeners();
    return store.saveTodoSettings({'todoMainList': name});
  }

  /// A new group for a Canvas calendar's items, after your other groups.
  Future<void> _giveOwnGroup(String feedId, String name, {String? id}) async {
    final order = todoLists.isEmpty ? 0.0 : todoLists.last.order + 1;
    final list = id == null ? _root.collection('todoLists').doc() : _root.collection('todoLists').doc(id);
    await list.set({'name': name, 'order': order, 'createdAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    await _putFeedIn(feedId, list.id);
  }

  Future<void> _putFeedIn(String feedId, String group) => _root.collection('canvasFeeds').doc(feedId).update({'todoList': group});

  /// The Canvas calendars whose items are in group [listId].
  List<CanvasFeed> canvasFeedsIn(String listId) {
    final ids = {TodoList.mainListId, for (final l in todoLists) l.id};
    return [
      for (final f in canvasFeeds)
        if ((ids.contains(f.todoList) ? f.todoList : TodoList.mainListId) == listId) f
    ];
  }

  /// Deletes a group you made and your to-dos in it. A Canvas calendar in it
  /// moves to the main group.
  Future<void> deleteTodoList(TodoList l) async {
    if (l.isMain) return;
    final list = _root.collection('todoLists').doc(l.id);
    final listData = (await list.get()).data();
    final inIt = (await _root.collection('todos').where('listId', isEqualTo: l.id).get()).docs;
    final feeds = canvasFeedsIn(l.id);
    final batch = FirebaseFirestore.instance.batch()..delete(list);
    for (final d in inIt) {
      batch.delete(d.reference);
    }
    for (final f in feeds) {
      batch.update(_root.collection('canvasFeeds').doc(f.id), {'todoList': TodoList.mainListId});
    }
    await batch.commit();
    remember('Deleted the group “${l.name}”', () async {
      final back = FirebaseFirestore.instance.batch();
      if (listData != null) back.set(list, listData);
      for (final d in inIt) {
        back.set(d.reference, d.data());
      }
      for (final f in feeds) {
        back.update(_root.collection('canvasFeeds').doc(f.id), {'todoList': l.id});
      }
      await back.commit();
    });
  }

  Future<void> setTodoMatrix(bool on) {
    todoMatrix = on;
    notifyListeners();
    return store.saveTodoSettings({'todoMatrix': on});
  }

  Future<void> setCanvasNotify(CanvasFeed f, bool on) => _root.collection('canvasFeeds').doc(f.id).update({'notifyNew': on, 'notifyChanges': on});

  @override
  void dispose() {
    for (final s in [..._subs, _homeSub, _pageSub]) {
      s?.cancel();
    }
    _lifecycle?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- visibility

  List<GoogleCalendar> get _allCalendars => [...ownCalendars, ...calendars, for (final f in canvasFeeds) ...canvasCalendars(f)];

  bool isVisible(GoogleCalendar c) => !_hidden.contains(c.key);
  List<GoogleCalendar> calendarsFor(String email) => calendars.where((c) => c.accountEmail == email).toList();

  /// Calendars you can add to and change from here: your own, then ones you
  /// may edit in accounts the server can reach.
  List<GoogleCalendar> get writableCalendars => [...ownCalendars, ...calendars.where(canEdit)];
  bool canEdit(GoogleCalendar c) => c.isOwn || (c.canWrite && (_account(c.accountEmail)?.linked ?? false));
  GoogleCalendar? calendarByKey(String key) {
    for (final c in [...ownCalendars, ...calendars]) {
      if (c.key == key) return c;
    }
    return null;
  }

  GoogleCalendar? get defaultCalendar {
    final w = writableCalendars;
    if (w.isEmpty) return null;
    return w.firstWhere((c) => c.primary && isVisible(c), orElse: () => w.first);
  }

  List<CalendarEvent> eventsBetween(DateTime from, DateTime to) => _shown(_events, from, to);

  /// For tests: an event as if read from Google.
  @visibleForTesting
  void debugAddEvent(CalendarEvent e) => _events.add(e);

  List<CalendarEvent> _shown(Iterable<CalendarEvent> google, DateTime from, DateTime to) =>
      [for (final e in google) _withEdit(e), ..._ownEvents, ..._canvasEvents, ..._inviteEvents, ..._tripTiles]
          .where((e) => !_removed.contains(e.key) && (showHiddenEvents || !isEventHidden(e)))
          .map(_faintIfHidden)
          .where((e) => isVisible(e.calendar) && e.overlaps(from, to))
          .toList()
        ..sort((a, b) => a.start.compareTo(b.start));

  // ---------------------------------------------------------------- setup

  AppLifecycleListener? _lifecycle;

  Future<void> init() async {
    _listenCanvas();
    try {
      final p = await SharedPreferences.getInstance();
      _hidden.addAll(p.getStringList(_hiddenKey) ?? const []);
    } catch (_) {
      // Storage can be unavailable (private window); start fresh.
    }
    _subs.add(store.doc.snapshots().listen(_onSettings, onError: (Object e) {
      store.error = '$e';
      notifyListeners();
    }));
    _ensureHome();
    _lifecycle = AppLifecycleListener(onResume: _onResume);
  }

  /// Accounts, calendars and choices, as saved (and kept up to date by the server).
  void _onSettings(DocumentSnapshot<Map<String, dynamic>> s) {
    final d = s.data() ?? const <String, dynamic>{};
    final links = (d['googleLinks'] as Map?) ?? const {};
    accounts
      ..clear()
      ..addAll([
        for (final email in (d['accounts'] as List? ?? const []).whereType<String>()) GoogleAccount.fromLink(email, links[email]),
      ]);
    final order = [for (final a in accounts) a.email];
    calendars
      ..clear()
      ..addAll(CalendarStore.calendarsFrom(d)
        ..sort((x, y) {
          final byAcct = order.indexOf(x.accountEmail).compareTo(order.indexOf(y.accountEmail));
          if (byAcct != 0) return byAcct;
          if (x.primary != y.primary) return x.primary ? -1 : 1;
          return x.name.toLowerCase().compareTo(y.name.toLowerCase());
        }));
    // Your own unsaved change wins over the copy echoing back.
    if (d['hiddenCalendars'] is List && !s.metadata.hasPendingWrites) {
      _hidden
        ..clear()
        ..addAll((d['hiddenCalendars'] as List).whereType<String>());
    }
    autoSync = d['autoSync'] != false;
    if (!s.metadata.hasPendingWrites) {
      todoMatrix = d['todoMatrix'] == true;
      _mainListName = '${d['todoMainList'] ?? ''}';
    }
    keepPast = d['keepPast'] == true;
    pastPending = (d['pastPending'] as List? ?? const []).whereType<String>().toList();
    final times = [
      for (final a in accounts)
        if (a.lastSync != null) a.lastSync!
    ];
    lastSynced = times.isEmpty ? null : times.reduce((a, b) => a.isAfter(b) ? a : b);
    store.error = null;
    // Opening the app: have the server check Google now rather than at its
    // next once-a-minute check.
    if (!_checkedOnOpen && accounts.any((a) => a.linked)) {
      _checkedOnOpen = true;
      unawaited(_syncGoogle());
    }
    _rebuildEvents();
  }

  bool _checkedOnOpen = false;

  Future<void> _saveHidden() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_hiddenKey, _hidden.toList());
    } catch (_) {}
    await store.saveHidden(_hidden.toList());
  }

  /// Sends this tab to Google to allow calendar access. It comes back to
  /// Optimizer, where [finishConnect] links the account.
  Future<void> connectAccount({GoogleAccount? reconnect}) => startGoogleConnect(
        clientId: AppConfig.googleWebClientId,
        scope: AppConfig.googleCalendarScope,
        hint: reconnect?.email,
      );

  /// Opened coming back from Google: the server links that account and
  /// fetches its calendars. Returns the account's email, or null if this
  /// wasn't a return from Google.
  Future<String?> finishConnect() async {
    final code = takeGoogleCode();
    if (code == null) return null;
    final r = await callServer('linkGoogleAccount', {'code': code, 'redirectUri': googleRedirectUri});
    return r is Map ? '${r['email'] ?? 'Google Calendar'}' : 'Google Calendar';
  }

  Future<void> removeAccount(GoogleAccount a) async {
    accounts.remove(a);
    calendars.removeWhere((c) => c.accountEmail == a.email);
    _rebuildEvents();
    await callServer('unlinkGoogleAccount', {'email': a.email});
  }

  void setVisible(GoogleCalendar c, bool visible) {
    visible ? _hidden.remove(c.key) : _hidden.add(c.key);
    _saveHidden();
    notifyListeners();
  }

  /// Shows only this calendar.
  void showOnly(GoogleCalendar only) {
    for (final c in _allCalendars) {
      c.key == only.key ? _hidden.remove(c.key) : _hidden.add(c.key);
    }
    _saveHidden();
    notifyListeners();
  }

  // ---------------------------------------------------------------- events
  //
  // Two spans of axisCalendar/{uid}/events are listened to: the weeks around
  // today (for Home, Ask and the calendar most of the time), and, when the
  // calendar page shows something further off, the weeks around that. With
  // Firestore's offline copy both show at once, then follow every change the
  // server writes.

  /// The span the server keeps in sync (functions/google.js matches).
  static const syncedDays = (back: 42, ahead: 180);

  _Span? _home, _page;
  Map<String, Map<String, dynamic>> _homeDocs = {}, _pageDocs = {};
  StreamSubscription? _homeSub, _pageSub;
  Completer<void> _homeReady = Completer();

  static bool _covers(_Span? w, DateTime from, DateTime to) => w != null && !from.isBefore(w.from) && !to.isAfter(w.to);

  StreamSubscription _watch(_Span w, void Function(Map<String, Map<String, dynamic>>) onDocs, {void Function()? first}) {
    return store.watch(w.from, w.to).listen((docs) {
      onDocs(docs);
      loading = false;
      first?.call();
      _rebuildEvents();
    }, onError: (Object e) {
      store.error = '$e';
      loading = false;
      first?.call();
      notifyListeners();
    });
  }

  /// Listens to the weeks around today, moving along as the days go by.
  void _ensureHome() {
    final today = dayStart(DateTime.now());
    if (_home != null && today.difference(_home!.from).inDays < 49) return;
    _homeSub?.cancel();
    _home = (from: addDays(today, -42), to: addDays(today, 120));
    final ready = _homeReady.isCompleted ? (_homeReady = Completer()) : _homeReady;
    _homeSub = _watch(_home!, (docs) => _homeDocs = docs, first: () {
      if (!ready.isCompleted) ready.complete();
    });
  }

  void _rebuildEvents() {
    final byKey = {for (final c in calendars) c.key: c};
    _events
      ..clear()
      ..addAll(CalendarStore.eventsFrom({..._pageDocs, ..._homeDocs}, byKey));
    notifyListeners();
  }

  /// Shows [from, to) on the calendar page: at once when it's near today or
  /// already listened to; otherwise from Firestore, asking the server to
  /// fetch it from Google if it's outside what it keeps in sync.
  Future<void> loadRange(DateTime from, DateTime to, {bool force = false, bool quiet = false}) async {
    _ensureHome();
    if (_covers(_home, from, to) || _covers(_page, from, to)) {
      notifyListeners();
      return;
    }
    _pageSub?.cancel();
    _pageDocs = {};
    final page = _page = (from: addDays(from, -35), to: addDays(to, 35));
    if (!quiet) loading = true;
    notifyListeners();
    _pageSub = _watch(page, (docs) => _pageDocs = docs);
    final today = dayStart(DateTime.now());
    if (page.from.isBefore(addDays(today, -syncedDays.back)) || page.to.isAfter(addDays(today, syncedDays.ahead))) {
      unawaited(_syncGoogle(from: page.from, to: page.to));
    }
  }

  /// Asks the server to check Google now (on coming back to the app).
  Future<void> reload({bool quiet = false}) => _syncGoogle();

  /// Events in [from, to), without changing what the calendar page shows
  /// (for Home and Ask).
  Future<List<CalendarEvent>> fetchBetween(DateTime from, DateTime to) async {
    _ensureHome();
    if (_covers(_home, from, to)) {
      await _homeReady.future;
      return eventsBetween(from, to);
    }
    if (_covers(_page, from, to)) return eventsBetween(from, to);
    return _shown(await store.loadEvents(from, to, {for (final c in calendars) c.key: c}), from, to);
  }

  // ---------------------------------------------------------------- editing (through the server)

  /// Saves to Google, or to your own calendar; returns the event's id there.
  Future<String?> saveEvent(EventDraft d, {CalendarEvent? original}) async {
    final cal = calendarByKey(d.calendarKey);
    if (cal == null) throw Exception('Pick a calendar for this event.');
    if (original != null && original.calendar.isOwn != cal.isOwn) return _moveAcross(d, original);
    if (cal.isOwn) return _saveOwnEvent(d, cal, original);
    _requireLinked(cal.accountEmail);
    final ymd = DateFormat('yyyy-MM-dd');
    final isPatch = original != null && original.calendar.key == cal.key;
    // PATCH needs explicit nulls to clear the other field (e.g. timed → all-day);
    // POST must not contain them.
    Map<String, dynamic> when(DateTime t) => d.allDay
        ? {'date': ymd.format(t), if (isPatch) 'dateTime': null, if (isPatch) 'timeZone': null}
        : {'dateTime': t.toUtc().toIso8601String(), if (isPatch) 'date': null};
    // Google's version of the event before this change (not one kept only
    // in Optimizer), to put back on undo.
    final was = original == null ? null : (_events.where((x) => x.key == original.key).firstOrNull ?? original);
    final r = await callServer('saveGoogleEvent', {
      'calendarKey': cal.key,
      if (isPatch) 'eventId': original.id,
      // Moved to another calendar: created there, deleted here.
      if (original != null && !isPatch) 'moveFrom': {'calendarKey': original.calendar.key, 'eventId': original.id},
      'body': {
        'summary': d.title,
        'description': d.description,
        'location': d.location,
        if (d.colorId != null || isPatch) 'colorId': d.colorId,
        'start': when(d.start),
        'end': when(d.end),
      },
    });
    final id = '${(r is Map ? r['id'] : null) ?? ''}';
    if (id.isEmpty) return null;
    final saved = CalendarEvent(
        id: id,
        calendar: cal,
        title: d.title,
        description: d.description,
        location: d.location,
        start: d.start,
        end: d.end,
        allDay: d.allDay,
        color: cal.color,
        colorId: d.colorId);
    if (was == null) {
      _log(HistoryAction.added, d.title, google: true, after: saved);
      remember('Added “${d.title}”', () => deleteEvent(saved));
    } else {
      _log(HistoryAction.changed, d.title, google: true, before: was, after: saved);
      remember('Changed “${was.title}”', () => saveEvent(_draftOf(was), original: saved));
    }
    return id;
  }

  static EventDraft _draftOf(CalendarEvent e) => EventDraft(
        calendarKey: e.calendar.key,
        title: e.title,
        start: e.start,
        end: e.end,
        allDay: e.allDay,
        description: e.description,
        location: e.location,
        colorId: e.colorId,
      );

  Future<void> deleteEvent(CalendarEvent e) async {
    if (e.calendar.isOwn) return _deleteOwnEvent(e);
    _requireLinked(e.calendar.accountEmail);
    final was = _events.where((x) => x.key == e.key).firstOrNull ?? e;
    await callServer('deleteGoogleEvent', {'calendarKey': e.calendar.key, 'eventId': e.id});
    // Its guests' invitations go with it.
    if (_sent[e.key]?.guests.isNotEmpty ?? false) await setEventGuests(e.key, _draftOf(was), guests: const []);
    // Undo makes it again (a repeating event's occurrence comes back as a single event).
    _log(HistoryAction.deleted, was.title, google: true, before: was);
    remember('Deleted “${was.title}”', () => saveEvent(_draftOf(was)));
  }

  GoogleAccount? _account(String email) {
    for (final a in accounts) {
      if (a.email == email) return a;
    }
    return null;
  }

  void _requireLinked(String email) {
    if (_account(email)?.linked != true) {
      throw Exception(canLinkGoogle
          ? '$email isn’t linked to Optimizer’s sync yet. Tap Reconnect in the sidebar (a one-time step).'
          : '$email isn’t linked to Optimizer’s sync yet. Connect it once in Optimizer on the web (a one-time step).');
    }
  }
}

typedef _Span = ({DateTime from, DateTime to});

/// A change that can be reversed: what it was, and how to put things back.
class UndoStep {
  UndoStep(this.label, this.undo, [this.history = const []]);
  final String label;
  final Future<void> Function() undo;

  /// The lines in your history for this change.
  final List<String> history;
}

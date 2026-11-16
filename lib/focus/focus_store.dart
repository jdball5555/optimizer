import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../util/dispose_safe.dart';
import '../util/fields.dart';

/// One moment in a focus session: when it started, was paused, resumed or ended.
class FocusMark {
  const FocusMark(this.what, this.at);

  /// 'start', 'pause', 'resume' or 'end'.
  final String what;
  final DateTime at;

  Map<String, dynamic> toJson() => {'what': what, 'at': Timestamp.fromDate(at)};
}

/// A stretch of time set aside to work on one thing.
class FocusSession {
  FocusSession({required this.id, required this.title, required this.plannedMinutes, required this.marks, required this.state});

  factory FocusSession.fromDoc(String id, Map<String, dynamic> d) => FocusSession(
        id: id,
        title: '${d['title'] ?? ''}',
        plannedMinutes: (d['plannedMinutes'] as num?)?.toInt(),
        marks: [
          for (final m in (d['log'] as List? ?? const []))
            if (m is Map && asDate(m['at']) != null) FocusMark('${m['what']}', asDate(m['at'])!),
        ]..sort((a, b) => a.at.compareTo(b.at)),
        state: '${d['state'] ?? 'done'}',
      );

  final String id;
  final String title;

  /// How long you meant to focus; null for open-ended.
  final int? plannedMinutes;
  final List<FocusMark> marks;

  /// 'running', 'paused' or 'done'.
  final String state;

  bool get running => state == 'running';
  bool get paused => state == 'paused';
  bool get done => state == 'done';

  DateTime get started => marks.isEmpty ? DateTime.now() : marks.first.at;
  DateTime? get ended => done && marks.isNotEmpty ? marks.last.at : null;
  Duration? get planned => plannedMinutes == null ? null : Duration(minutes: plannedMinutes!);
  int get pauses => marks.where((m) => m.what == 'pause').length;

  /// Time spent focusing (not paused) up to [now].
  Duration focusedAt(DateTime now) {
    var total = Duration.zero;
    DateTime? from;
    for (final m in marks) {
      if (m.what == 'start' || m.what == 'resume') {
        from ??= m.at;
      } else if (from != null) {
        total += m.at.difference(from);
        from = null;
      }
    }
    if (from != null && running) total += now.difference(from);
    return total.isNegative ? Duration.zero : total;
  }

  /// Time spent paused up to [now].
  Duration pausedAt(DateTime now) {
    final end = ended ?? now;
    final all = end.difference(started) - focusedAt(now);
    return all.isNegative ? Duration.zero : all;
  }

  FocusSession _with(String state, FocusMark mark) =>
      FocusSession(id: id, title: title, plannedMinutes: plannedMinutes, marks: [...marks, mark], state: state);
}

/// Your focus sessions (optimizer/{uid}/focusSessions), every start, pause,
/// resume and end timestamped. One can be going at a time, on any device.
///
/// While one runs with a goal, optimizer/{uid}.focusAlert says when the goal
/// is reached, so the server can notify you then (functions: pollFocusAlerts).
class FocusStore extends ChangeNotifier with DisposeSafe {
  FocusStore(this.uid) {
    _sub = _sessions.orderBy('startedAt', descending: true).limit(60).snapshots().listen((s) {
      sessions = [for (final d in s.docs) FocusSession.fromDoc(d.id, d.data())];
      loaded = true;
      error = null;
      notifyListeners();
    }, onError: (Object e) {
      error = '$e';
      notifyListeners();
    });
  }

  /// Sessions given rather than read, for previews and tests.
  @visibleForTesting
  FocusStore.preview(this.uid, this.sessions) : loaded = true;

  final String uid;
  StreamSubscription? _sub;

  List<FocusSession> sessions = [];
  bool loaded = false;
  String? error;

  DocumentReference<Map<String, dynamic>> get _doc => FirebaseFirestore.instance.collection('optimizer').doc(uid);
  CollectionReference<Map<String, dynamic>> get _sessions => _doc.collection('focusSessions');

  /// The session going now (running or paused), if any.
  FocusSession? get active => sessions.where((s) => !s.done).firstOrNull;

  List<FocusSession> get history => sessions.where((s) => s.done).toList();

  /// Shows a change straight away; Firestore confirms it a moment later.
  void _show(FocusSession s) {
    sessions = [s, ...sessions.where((x) => x.id != s.id)];
    notifyListeners();
  }

  Future<void> start(String title, {int? minutes}) async {
    if (active != null) await end();
    final now = DateTime.now();
    final ref = _sessions.doc();
    final mark = FocusMark('start', now);
    final s = FocusSession(id: ref.id, title: title, plannedMinutes: minutes, marks: [mark], state: 'running');
    _show(s);
    await ref.set({
      'title': title,
      'plannedMinutes': minutes,
      'state': 'running',
      'startedAt': Timestamp.fromDate(now),
      'endedAt': null,
      'log': [mark.toJson()],
      'focusedSeconds': 0,
      'pausedSeconds': 0,
    });
    await _alert(s, now);
  }

  Future<void> pause() => _mark('pause', 'paused');
  Future<void> resume() => _mark('resume', 'running');
  Future<void> end() => _mark('end', 'done');

  Future<void> _mark(String what, String state) async {
    final s = active;
    if (s == null) return;
    final now = DateTime.now();
    final mark = FocusMark(what, now);
    final next = s._with(state, mark);
    _show(next);
    await _sessions.doc(s.id).update({
      'state': state,
      'log': FieldValue.arrayUnion([mark.toJson()]),
      'focusedSeconds': next.focusedAt(now).inSeconds,
      'pausedSeconds': next.pausedAt(now).inSeconds,
      if (state == 'done') 'endedAt': Timestamp.fromDate(now),
      'updatedAt': Timestamp.fromDate(now),
    });
    await _alert(next, now);
  }

  /// Tells the server when this session's goal is reached (or that it
  /// needn't say anything, when it's paused, done or has no goal).
  Future<void> _alert(FocusSession s, DateTime now) async {
    final planned = s.planned;
    final left = planned == null ? null : planned - s.focusedAt(now);
    try {
      await _doc.set({
        'focusAlert': s.running && left != null && left > Duration.zero
            ? {'at': Timestamp.fromDate(now.add(left)), 'title': s.title, 'session': s.id, 'minutes': s.plannedMinutes}
            : null,
      }, SetOptions(merge: true));
    } catch (_) {
      // The session itself is saved; only the reminder is missing.
    }
  }

  Future<void> delete(FocusSession s) => _sessions.doc(s.id).delete();

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

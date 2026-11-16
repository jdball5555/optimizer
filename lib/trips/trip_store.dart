import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import '../people/invites.dart';
import '../people/people_service.dart';
import '../util/dispose_safe.dart';
import 'trip_models.dart';
import 'trip_zones.dart';

/// Your trips (optimizer/{uid}/trips), and the server's help with flights and
/// commutes (functions/trips.js).
class TripStore extends ChangeNotifier with DisposeSafe {
  TripStore(this.uid) {
    _subs.add(_col.snapshots().listen((s) {
      _own = [for (final d in s.docs) Trip.fromDoc(d.id, d.data())];
      _merge();
      loaded = true;
      error = null;
      notifyListeners();
    }, onError: (Object e) {
      error = '$e';
      notifyListeners();
    }));
    final me = FirebaseFirestore.instance.collection('optimizer').doc(uid);
    _subs.add(me.collection('sharedTrips').snapshots().listen((s) {
      _shared = [for (final d in s.docs) Trip.fromDoc(d.id, d.data())];
      _merge();
      notifyListeners();
    }, onError: (Object _) {}));
    _subs.add(me.collection('tripPeople').snapshots().listen((s) {
      _peopleOf = {
        for (final d in s.docs)
          d.id: [
            for (final p in (d.data()['people'] as List? ?? const []))
              if (p is Map) TripPerson.fromJson(p),
          ],
      };
      _merge();
      notifyListeners();
    }, onError: (Object _) {}));
  }

  void _merge() {
    trips = [
      for (final t in _own) t.copyWith(people: _peopleOf[t.id] ?? const []),
      ..._shared,
    ]..sort((a, b) => a.start.compareTo(b.start));
  }

  /// Trips given rather than read, for previews and tests.
  @visibleForTesting
  TripStore.preview(this.uid, this.trips) : loaded = true;

  final String uid;
  final _subs = <StreamSubscription>[];
  List<Trip> _own = [];
  List<Trip> _shared = [];
  Map<String, List<TripPerson>> _peopleOf = {};
  List<Trip> trips = [];

  /// Your groups, to share with.
  PeopleService? people;

  /// Your email, not to share with yourself.
  String? myEmail;
  bool loaded = false;
  String? error;

  /// The trip open on the Trips page, if any.
  String? openId;
  Trip? get opened => trips.where((t) => t.id == openId).firstOrNull;

  /// Just made, so its name is still there to be typed over.
  String? freshId;

  void open(String? id) {
    openId = id;
    notifyListeners();
  }

  CollectionReference<Map<String, dynamic>> get _col => FirebaseFirestore.instance.collection('optimizer').doc(uid).collection('trips');

  /// A new trip's id.
  String newId() => _col.doc().id;

  /// Saves a trip, new or changed. Shown straight away.
  Future<void> save(Trip t) async {
    if (t.isShared) {
      _show(t);
      await callServer('updateSharedTrip', {'shareId': t.shareId, 'fields': _sharedFields(t)});
      return;
    }
    // Where it sets out from, the first time it's known. The first zone it
    // has must not change just because your phone flew somewhere.
    if (t.zone.isEmpty && deviceZone.isNotEmpty) t = t.copyWith(zone: deviceZone);
    _show(t);
    await _col.doc(t.id).set(t.toJson());
    // Everyone it's shared with gets the change, as far as they may see it.
    if (t.people.isNotEmpty) await callServer('syncTripShare', {'tripId': t.id}).catchError((Object _) => null);
  }

  void _show(Trip t) {
    trips = [...trips.where((x) => x.id != t.id), t]..sort((a, b) => a.start.compareTo(b.start));
    notifyListeners();
  }

  Map<String, dynamic> _sharedFields(Trip t) => {
        'title': t.title,
        'destination': t.destination,
        'startDay': '${t.toJson()['startDay']}',
        'endDay': '${t.toJson()['endDay']}',
        'notes': t.notes,
        'links': [for (final l in t.links) l.toJson()],
      };

  Future<void> delete(Trip t) async {
    trips = trips.where((x) => x.id != t.id).toList();
    if (openId == t.id) openId = null;
    notifyListeners();
    if (t.isShared) {
      await callServer('leaveSharedTrip', {'shareId': t.shareId});
      return;
    }
    // Everyone's copy goes first, while the trip's there to say whose they are.
    if (t.people.isNotEmpty) await setTripPeople(t, const []).catchError((Object _) => const <({String email, String link})>[]);
    await _col.doc(t.id).delete();
  }

  /// Sets who [t] is shared with. Returns links for anyone not on Optimizer yet, to send them.
  Future<InviteLinks> setTripPeople(Trip t, List<TripPerson> people) async {
    final r = await callServer('setTripPeople', {
      'tripId': t.id,
      'people': [for (final p in people) p.toJson()]
    });
    if (trips.any((x) => x.id == t.id)) _show(t.copyWith(people: people));
    return inviteLinksFrom(r);
  }

  /// Adds [item] to [t], or replaces the one with its id.
  Future<void> saveItem(Trip t, TripItem item) async {
    final changed = t.copyWith(items: [...t.items.where((i) => i.id != item.id), item]..sort(Trip.byTime));
    if (t.isShared) {
      _show(changed);
      await callServer('saveSharedItem', {'shareId': t.shareId, 'item': item.toCallable()});
      return;
    }
    await save(changed.keepingClocksFrom(t, except: item.id));
  }

  Future<void> deleteItem(Trip t, TripItem item) async {
    final changed = t.copyWith(items: t.items.where((i) => i.id != item.id).toList());
    if (t.isShared) {
      _show(changed);
      await callServer('deleteSharedItem', {'shareId': t.shareId, 'itemId': item.id});
      return;
    }
    await save(changed.keepingClocksFrom(t));
  }

  /// Your last commute, for where it started, to save retyping home.
  TripItem? get _lastCommute {
    final all = [
      for (final t in trips)
        for (final i in t.items)
          if (i.kind == TripItemKind.commute && i.commute?['direction'] != 'from' && '${i.commute?['from'] ?? ''}'.isNotEmpty) i,
    ]..sort(Trip.byTime);
    return all.lastOrNull;
  }

  String get lastCommuteFrom => '${_lastCommute?.commute!['from'] ?? ''}';

  /// That's a real place, not just a name that was typed.
  bool get lastCommuteFromOnMap => _lastCommute?.commute!['fromOnMap'] != false;

  @protected
  Future<Object?> callServer(String name, Map<String, dynamic> data) async {
    try {
      return (await FirebaseFunctions.instance.httpsCallable(name, options: HttpsCallableOptions(timeout: const Duration(minutes: 1))).call(data))
          .data;
    } on FirebaseFunctionsException catch (e) {
      throw Exception(e.message ?? e.code);
    }
  }

  /// Every leg flying as [number] on [date] (the date it leaves).
  Future<List<Map<String, dynamic>>> lookupFlight(String number, DateTime date) async {
    final ymd = '${date.year}-${'${date.month}'.padLeft(2, '0')}-${'${date.day}'.padLeft(2, '0')}';
    final r = await callServer('lookupFlight', {'number': number, 'date': ymd});
    return [
      for (final f in ((r as Map?)?['flights'] as List? ?? const []))
        if (f is Map) _plain(f),
    ];
  }

  // The plugin hands back maps of unknown type; these get stored in Firestore.
  static Map<String, dynamic> _plain(Map m) => {
        for (final e in m.entries) '${e.key}': e.value is Map ? _plain(e.value as Map) : e.value,
      };

  final _placeZones = <String, String>{};

  /// The time zone of a place, or null if Google can't say just now.
  Future<String?> placeZone(String place) async {
    final known = _placeZones[place];
    if (known != null) return known;
    try {
      final zone = ((await callServer('placeZone', {'place': place})) as Map?)?['zone'];
      if (zone is! String || zone.isEmpty) return null;
      return _placeZones[place] = zone;
    } catch (_) {
      return null;
    }
  }

  /// What Google says for a commute at that time of that day: minutes,
  /// meters, legs (each stretch's seconds), leaveAt and arriveAt (ms), and
  /// predicted (false if the time has passed, so it's for that time next week).
  /// Minutes are driving only; [stopMinutes] moves leaveAt or arriveAt. Routes
  /// lists the ways to go ({name, minutes, meters}), Google's pick first.
  Future<Map> commuteTime(
      {required String from,
      required String to,
      required String mode,
      DateTime? leaveAt,
      DateTime? arriveBy,
      List<String> stops = const [],
      int stopMinutes = 0}) async {
    final r = await callServer('commuteTime', {
      'from': from,
      'to': to,
      'mode': mode,
      if (leaveAt != null) 'leaveAt': leaveAt.millisecondsSinceEpoch,
      if (arriveBy != null) 'arriveBy': arriveBy.millisecondsSinceEpoch,
      if (stops.isNotEmpty) 'stops': stops,
      if (stopMinutes > 0) 'stopMinutes': stopMinutes,
    });
    return r as Map;
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}

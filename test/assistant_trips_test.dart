import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:optimizer/ai/ai_service.dart';
import 'package:optimizer/ai/assistant_tools.dart';
import 'package:optimizer/calendar/calendar_history.dart';
import 'package:optimizer/calendar/calendar_service.dart';
import 'package:optimizer/trips/trip_models.dart';
import 'package:optimizer/trips/trip_zones.dart';

import 'trips_test.dart' show FakeTrips;

class _Ai extends ChangeNotifier implements AiService {
  @override
  Set<AiShare> shared = AiShare.values.toSet();
  @override
  Set<AiAct> acts = {AiAct.trips};
  @override
  bool confirmChanges = false;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Calendar extends CalendarService {
  _Calendar() : super('test');
  @override
  Future<void> saveHistory(HistoryEntry e) async {}
}

void main() {
  final first = DateTime(2030, 3, 10), last = DateTime(2030, 3, 14);
  Trip trip({String id = 'a', String title = 'NYC', List<TripItem>? items, String? shareId, String myRole = 'editor'}) => Trip(
      id: id, title: title, destination: 'New York', start: first, end: last, zone: 'America/Chicago', items: items, shareId: shareId, myRole: myRole);

  late FakeTrips store;
  late _Calendar cal;
  late List<String> asked;

  AssistantTools tools({Set<AiAct>? acts, Set<AiShare>? shared, bool ask = false, bool yes = true, List<String>? opened}) => AssistantTools(
        ai: _Ai()
          ..acts = acts ?? {AiAct.trips}
          ..shared = shared ?? AiShare.values.toSet()
          ..confirmChanges = ask,
        calendar: cal,
        trips: store,
        navigate: opened?.add,
        confirm: (w) async {
          asked.add(w);
          return yes;
        },
      );

  setUp(() {
    store = FakeTrips([])..placeZones = {'Hotel Edison': 'America/New_York', 'JFK airport': 'America/New_York', 'AUS airport': 'America/Chicago'};
    cal = _Calendar();
    asked = [];
  });

  Future<String> known(AssistantTools t, [String title = 'NYC']) async {
    final r = await t.run('get_trips', {'include_past': true});
    return ((r.result['trips'] as List).firstWhere((x) => x['title'] == title) as Map)['id'] as String;
  }

  group('viewing', () {
    test('lists trips and what’s on them, on the clock where each thing happens', () async {
      final dinner = DateTime.utc(2030, 3, 11, 22); // 6 PM in New York.
      store.trips = [
        trip(items: [TripItem(id: 'd', kind: TripItemKind.food, title: 'Dinner', start: dinner, end: dinner, zone: 'America/New_York', location: 'Carbone', confirmation: 'XY1')]),
      ];
      final r = await tools().run('get_trips', {'include_past': true});
      final t = (r.result['trips'] as List).single as Map;
      expect(t['title'], 'NYC');
      expect(t['destination'], 'New York');
      final item = (t['items'] as List).single as Map;
      expect(item['start'], '2030-03-11T18:00', reason: 'whatever zone this device is in');
      expect(item['time_zone'], 'America/New_York');
      expect(item['confirmation'], 'XY1');
      expect(r.changed, isFalse);
    });

    test('past trips only when asked', () async {
      store.trips = [
        Trip(id: 'old', title: 'Long ago', start: DateTime(2020), end: DateTime(2020, 1, 3)),
        trip(),
      ];
      final soon = await tools().run('get_trips', {});
      expect((soon.result['trips'] as List).map((t) => t['title']), ['NYC']);
      final all = await tools().run('get_trips', {'include_past': true});
      expect(all.result['trips'], hasLength(2));
    });

    test('works with only reading the calendar on', () async {
      store.trips = [trip()];
      final t = tools(acts: {});
      expect(t.declarations().map((d) => d['name']), contains('get_trips'));
      expect(t.declarations().map((d) => d['name']), isNot(contains('create_trip')));
      expect(((await t.run('get_trips', {})).result['trips'] as List), hasLength(1));
    });

    test('off when nothing allows it', () async {
      store.trips = [trip()];
      final t = tools(acts: {}, shared: {});
      expect(t.declarations().map((d) => d['name']), isNot(contains('get_trips')));
      expect((await t.run('get_trips', {})).result['error'], contains('switched off'));
    });

    test('opens one on the Trips page', () async {
      store.trips = [trip()];
      final opened = <String>[];
      final t = tools(opened: opened);
      final id = await known(t);
      await t.run('open_trip', {'trip_id': id});
      expect(store.openId, 'a');
      expect(opened, ['trips']);
    });
  });

  group('making one', () {
    test('with its days, destination and notes', () async {
      final r = await tools().run('create_trip', {'title': 'Tokyo', 'destination': 'Japan', 'start_date': '2030-04-01', 'end_date': '2030-04-08', 'how': 'fly', 'notes': 'Cherry blossoms'});
      expect(r.changed, isTrue);
      final t = store.trips.single;
      expect([t.title, t.destination, t.notes, t.how], ['Tokyo', 'Japan', 'Cherry blossoms', TripHow.fly]);
      expect([t.start, t.end], [DateTime(2030, 4, 1), DateTime(2030, 4, 8)]);
    });

    test('refuses days the wrong way round', () async {
      final r = await tools().run('create_trip', {'title': 'Tokyo', 'start_date': '2030-04-08', 'end_date': '2030-04-01'});
      expect(r.result['error'], isNotNull);
      expect(store.trips, isEmpty);
    });

    test('needs Change your trips on, whatever else is', () async {
      final t = tools(acts: {AiAct.calendar, AiAct.todos});
      expect(t.declarations().map((d) => d['name']), isNot(contains('create_trip')));
      final r = await t.run('create_trip', {'title': 'Tokyo', 'start_date': '2030-04-01', 'end_date': '2030-04-08'});
      expect(r.result['error'], contains('switched off'));
      expect(store.trips, isEmpty);
    });

    test('asks first when that’s on, and takes no for an answer', () async {
      final r = await tools(ask: true, yes: false).run('create_trip', {'title': 'Tokyo', 'start_date': '2030-04-01', 'end_date': '2030-04-08'});
      expect(asked.single, contains('Add trip “Tokyo”'));
      expect(r.changed, isFalse);
      expect(store.trips, isEmpty);
    });

    test('a date that isn’t real isn’t let through as another', () async {
      final r = await tools().run('create_trip', {'title': 'Tokyo', 'start_date': 'next week', 'end_date': '2030-04-08'});
      expect(r.result['error'], isNotNull);
    });
  });

  group('changing one', () {
    test('only what’s given', () async {
      store.trips = [trip()];
      final t = tools();
      final id = await known(t);
      await t.run('update_trip', {'trip_id': id, 'title': 'Big Apple', 'end_date': '2030-03-16'});
      final now = store.trips.single;
      expect([now.title, now.destination], ['Big Apple', 'New York']);
      expect([now.start, now.end], [first, DateTime(2030, 3, 16)]);
    });

    test('nothing to change is said so', () async {
      store.trips = [trip()];
      final t = tools();
      expect((await t.run('update_trip', {'trip_id': await known(t)})).changed, isFalse);
    });

    test('an unknown id is refused', () async {
      expect((await tools().run('update_trip', {'trip_id': 'v99', 'title': 'x'})).result['error'], contains('Unknown'));
    });
  });

  group('what’s on a trip', () {
    late AssistantTools t;
    late String id;
    setUp(() async {
      store.trips = [trip()];
      t = tools();
      id = await known(t);
    });

    TripItem only() => store.trips.single.items.single;

    test('a stay: on the clock at the hotel, with its details', () async {
      final r = await t.run('add_trip_item', {
        'trip_id': id, 'kind': 'stay', 'title': 'Hotel Edison', 'location': 'Hotel Edison',
        'start': '2030-03-10T15:00', 'end': '2030-03-14T11:00', 'confirmation': 'ABC123', 'notes': 'Late checkout',
      });
      expect(r.changed, isTrue);
      final i = only();
      expect(i.kind, TripItemKind.stay);
      expect(i.zone, 'America/New_York');
      expect(i.start.toUtc(), DateTime.utc(2030, 3, 10, 19), reason: '3 PM in New York, before the clocks change');
      expect(i.end.toUtc(), DateTime.utc(2030, 3, 14, 15), reason: '11 AM there, after they do');
      expect([i.confirmation, i.notes], ['ABC123', 'Late checkout']);
      expect(i.onMap, isTrue);
    });

    test('a stay needs its check-out', () async {
      final r = await t.run('add_trip_item', {'trip_id': id, 'kind': 'stay', 'title': 'Hotel', 'start': '2030-03-10T15:00'});
      expect(r.result['error'], contains('end'));
      expect(store.trips.single.items, isEmpty);
    });

    test('dinner: a time with no end, and a place Google doesn’t know is just a name', () async {
      await t.run('add_trip_item', {'trip_id': id, 'kind': 'food', 'title': 'Dinner', 'location': 'Mom’s place', 'start': '2030-03-11T18:00'});
      final i = only();
      expect(i.oneTime, isTrue);
      expect(i.onMap, isFalse);
    });

    test('something needs a real time, not just a day', () async {
      final r = await t.run('add_trip_item', {'trip_id': id, 'kind': 'activity', 'title': 'Museum', 'start': '2030-03-11'});
      expect(r.result['error'], contains('YYYY-MM-DDTHH:MM'));
    });

    test('a flight: each end on its own airport’s clock, shaped as the editor shapes it', () async {
      await t.run('add_trip_item', {
        'trip_id': id, 'kind': 'flight', 'flight_number': 'aa 123', 'airline': 'American', 'from': 'aus', 'to': 'jfk',
        'start': '2030-03-10T08:00', 'end': '2030-03-10T13:00',
      });
      final i = only();
      expect(i.title, 'AA 123 · AUS – JFK');
      expect(i.start.toUtc(), DateTime.utc(2030, 3, 10, 13), reason: '8 AM in Austin');
      expect(i.end.toUtc(), DateTime.utc(2030, 3, 10, 17), reason: '1 PM in New York');
      expect([i.departure.code, i.arrival.code], ['AUS', 'JFK']);
      expect(i.departure.timeZone, 'America/Chicago');
      expect(i.arrival.time, i.end);
      expect(i.flight!['airline'], 'American');
    });

    test('a flight can’t land before it takes off', () async {
      final r = await t.run('add_trip_item', {'trip_id': id, 'kind': 'flight', 'from': 'AUS', 'to': 'JFK', 'start': '2030-03-10T08:00', 'end': '2030-03-10T08:00'});
      expect(r.result['error'], contains('after'));
    });

    test('a drive with no end takes as long as Google says', () async {
      store.commute = {'minutes': 95, 'meters': 150000};
      await t.run('add_trip_item', {'trip_id': id, 'kind': 'commute', 'from': 'Home', 'to': 'Hotel Edison, NYC', 'start': '2030-03-10T09:00'});
      final i = only();
      expect(i.title, 'Drive to Hotel Edison');
      expect(i.end.difference(i.start).inMinutes, 95);
      expect(i.commute!['fromGoogle'], isTrue);
      expect(i.commute!['meters'], 150000);
    });

    test('a drive Google can’t time asks for an end', () async {
      store.commuteError = Exception('no route');
      final r = await t.run('add_trip_item', {'trip_id': id, 'kind': 'commute', 'from': 'Home', 'to': 'Mars', 'start': '2030-03-10T09:00'});
      expect(r.result['error'], contains('end'));
    });

    test('a train', () async {
      await t.run('add_trip_item', {'trip_id': id, 'kind': 'travel', 'how': 'Train', 'from': 'Penn Station', 'to': 'Boston', 'start': '2030-03-12T09:00', 'end': '2030-03-12T13:00'});
      expect(only().title, 'Train to Boston');
      expect(only().commute!['how'], 'Train');
    });

    test('a rental car', () async {
      await t.run('add_trip_item', {'trip_id': id, 'kind': 'rental', 'location': 'JFK airport', 'car': 'Hertz', 'start': '2030-03-10T14:00', 'end': '2030-03-14T09:00'});
      final i = only();
      expect(i.title, 'Rental car');
      expect(i.commute!['from'], 'JFK airport');
      expect(i.commute!['to'], 'JFK airport', reason: 'dropped off where it was picked up');
      expect(i.commute!['car'], 'Hertz');
    });

    Future<String> itemId() async {
      final r = await t.run('get_trips', {'include_past': true});
      return (((r.result['trips'] as List).single as Map)['items'] as List).first['id'] as String;
    }

    test('moving something keeps its length and its details', () async {
      await t.run('add_trip_item', {'trip_id': id, 'kind': 'activity', 'title': 'Museum', 'location': 'Hotel Edison', 'start': '2030-03-11T10:00', 'end': '2030-03-11T12:00', 'notes': 'Tickets'});
      await t.run('update_trip_item', {'item_id': await itemId(), 'start': '2030-03-12T14:00'});
      final i = only();
      expect(i.start.toUtc(), DateTime.utc(2030, 3, 12, 18));
      expect(i.end.difference(i.start).inHours, 2);
      expect([i.title, i.notes, i.location, i.zone], ['Museum', 'Tickets', 'Hotel Edison', 'America/New_York']);
    });

    test('a moved place finds its new clock', () async {
      store.placeZones['Grand Hotel, Chicago'] = 'America/Chicago';
      await t.run('add_trip_item', {'trip_id': id, 'kind': 'stay', 'title': 'Hotel', 'location': 'Hotel Edison', 'start': '2030-03-10T15:00', 'end': '2030-03-12T11:00'});
      await t.run('update_trip_item', {'item_id': await itemId(), 'location': 'Grand Hotel, Chicago', 'start': '2030-03-10T15:00', 'end': '2030-03-12T11:00'});
      expect(only().zone, 'America/Chicago');
      expect(only().start.toUtc(), DateTime.utc(2030, 3, 10, 20));
    });

    test('renaming leaves the time alone', () async {
      await t.run('add_trip_item', {'trip_id': id, 'kind': 'food', 'title': 'Dinner', 'location': 'Hotel Edison', 'start': '2030-03-11T18:00'});
      final was = only().start;
      await t.run('update_trip_item', {'item_id': await itemId(), 'title': 'Supper'});
      expect(only().title, 'Supper');
      expect(only().start, was);
    });

    test('changing a flight’s time keeps its airports and number', () async {
      await t.run('add_trip_item', {'trip_id': id, 'kind': 'flight', 'flight_number': 'AA 1', 'from': 'AUS', 'to': 'JFK', 'start': '2030-03-10T08:00', 'end': '2030-03-10T13:00'});
      await t.run('update_trip_item', {'item_id': await itemId(), 'start': '2030-03-10T09:00', 'end': '2030-03-10T14:00'});
      final i = only();
      expect(i.title, 'AA 1 · AUS – JFK');
      expect(i.start.toUtc(), DateTime.utc(2030, 3, 10, 14));
      expect(i.departure.time, i.start);
      expect(i.arrival.time, i.end);
    });

    test('taking something off', () async {
      await t.run('add_trip_item', {'trip_id': id, 'kind': 'food', 'title': 'Dinner', 'start': '2030-03-11T18:00'});
      final r = await t.run('remove_trip_item', {'item_id': await itemId()});
      expect(r.changed, isTrue);
      expect(store.trips.single.items, isEmpty);
    });

    test('what’s written can be read back the same', () async {
      await t.run('add_trip_item', {'trip_id': id, 'kind': 'stay', 'title': 'Hotel', 'location': 'Hotel Edison', 'start': '2030-03-10T15:00', 'end': '2030-03-14T11:00'});
      final r = await t.run('get_trips', {'include_past': true});
      final i = (((r.result['trips'] as List).single as Map)['items'] as List).single as Map;
      expect([i['start'], i['end']], ['2030-03-10T15:00', '2030-03-14T11:00']);
    });

    test('says the time back on the clock at that place', () async {
      final r = await t.run('add_trip_item', {'trip_id': id, 'kind': 'food', 'title': 'Dinner', 'location': 'Hotel Edison', 'start': '2030-03-11T18:00'});
      expect(r.note, contains(DateFormat('EEE MMM d, h:mm a').format(DateTime(2030, 3, 11, 18))));
    });
  });

  group('a trip someone shared', () {
    test('to view: can be seen but not changed', () async {
      final dinner = DateTime.utc(2030, 3, 11, 22);
      store.trips = [trip(shareId: 's', myRole: 'viewer', items: [TripItem(id: 'd', kind: TripItemKind.food, title: 'Dinner', start: dinner, end: dinner, myRole: 'viewer')])];
      final t = tools();
      final r = await t.run('get_trips', {'include_past': true});
      final seen = (r.result['trips'] as List).single as Map;
      expect(seen['read_only'], isTrue);
      expect((await t.run('update_trip', {'trip_id': seen['id'], 'title': 'x'})).result['error'], contains('view only'));
      expect((await t.run('add_trip_item', {'trip_id': seen['id'], 'kind': 'food', 'title': 'y', 'start': '2030-03-11T18:00'})).result['error'], contains('view only'));
      final item = (seen['items'] as List).single['id'];
      expect((await t.run('update_trip_item', {'item_id': item, 'title': 'x'})).result['error'], contains('view only'));
      expect((await t.run('remove_trip_item', {'item_id': item})).result['error'], contains('view only'));
      expect(store.called, isEmpty);
    });

    test('to edit: goes through the server, and undoes the same way', () async {
      store.trips = [trip(shareId: 's')];
      final t = tools();
      final id = await known(t);
      await t.run('add_trip_item', {'trip_id': id, 'kind': 'food', 'title': 'Dinner', 'start': '2030-03-11T18:00'});
      expect(store.called['saveSharedItem']?['shareId'], 's');
      expect(store.trips.single.items.single.title, 'Dinner');
      await cal.undoLast();
      expect(store.called['deleteSharedItem']?['shareId'], 's');
      expect(store.trips.single.items, isEmpty);
    });
  });

  group('deleting a whole trip', () {
    final dinner = DateTime.utc(2030, 3, 11, 22);
    TripItem food() => TripItem(id: 'd', kind: TripItemKind.food, title: 'Dinner', start: dinner, end: dinner);

    test('goes, with what’s on it, once you say yes', () async {
      store.trips = [trip(items: [food()])];
      final t = tools();
      final r = await t.run('delete_trip', {'trip_id': await known(t)});
      expect(r.changed, isTrue);
      expect(asked.single, 'Delete trip “NYC” and the thing on it');
      expect(store.trips, isEmpty);
    });

    test('always asks, even with checking before changes off', () async {
      store.trips = [trip()];
      final t = tools(ask: false, yes: false);
      final r = await t.run('delete_trip', {'trip_id': await known(t)});
      expect(asked, hasLength(1));
      expect(r.changed, isFalse);
      expect(store.trips, hasLength(1), reason: 'you said no');
    });

    test('says when it goes for other people too', () async {
      store.trips = [trip().copyWith(people: const [TripPerson(email: 'sam@example.com', role: 'viewer')])];
      final t = tools();
      await t.run('delete_trip', {'trip_id': await known(t)});
      expect(asked.single, contains('everyone it’s shared with'));
    });

    test('undo puts it back, shared as it was', () async {
      const sam = TripPerson(email: 'sam@example.com', role: 'viewer');
      store.trips = [trip(items: [food()]).copyWith(people: const [sam])];
      final t = tools();
      await t.run('delete_trip', {'trip_id': await known(t)});
      await cal.undoLast();
      expect(store.trips.single.items.single.title, 'Dinner');
      expect(store.called['setTripPeople']?['people'], [sam.toJson()]);
    });

    test('one someone shared with you is left, and says it can’t be undone', () async {
      store.trips = [trip(shareId: 's', myRole: 'viewer')];
      final t = tools();
      final r = await t.run('delete_trip', {'trip_id': await known(t)});
      expect(asked.single, allOf(startsWith('Leave “NYC”'), contains('can’t be undone')));
      expect(r.note, 'Left “NYC”');
      expect(store.trips, isEmpty);
      expect(cal.lastChange, isNull, reason: 'nothing to undo it with');
    });

    test('needs Change your trips on', () async {
      store.trips = [trip()];
      final t = tools(acts: {});
      expect(t.declarations().map((d) => d['name']), isNot(contains('delete_trip')));
      expect((await t.run('delete_trip', {'trip_id': 'NYC'})).result['error'], contains('switched off'));
      expect(store.trips, hasLength(1));
    });

    test('an unknown id deletes nothing', () async {
      store.trips = [trip()];
      expect((await tools().run('delete_trip', {'trip_id': 'v99'})).result['error'], contains('Unknown'));
      expect(store.trips, hasLength(1));
    });
  });

  group('undo', () {
    test('takes back a new trip', () async {
      await tools().run('create_trip', {'title': 'Tokyo', 'start_date': '2030-04-01', 'end_date': '2030-04-08'});
      expect(cal.lastChange?.label, contains('Tokyo'));
      await cal.undoLast();
      expect(store.trips, isEmpty);
    });

    test('puts a changed trip back', () async {
      store.trips = [trip()];
      final t = tools();
      await t.run('update_trip', {'trip_id': await known(t), 'title': 'Big Apple'});
      await cal.undoLast();
      expect(store.trips.single.title, 'NYC');
    });

    test('puts something taken off back', () async {
      final dinner = DateTime.utc(2030, 3, 11, 22);
      store.trips = [trip(items: [TripItem(id: 'd', kind: TripItemKind.food, title: 'Dinner', start: dinner, end: dinner)])];
      final t = tools();
      final r = await t.run('get_trips', {'include_past': true});
      await t.run('remove_trip_item', {'item_id': (((r.result['trips'] as List).single as Map)['items'] as List).single['id']});
      expect(store.trips.single.items, isEmpty);
      await cal.undoLast();
      expect(store.trips.single.items.single.title, 'Dinner');
    });

    test('everything in one message goes together', () async {
      final t = tools();
      await cal.asOneChange('Assistant', () async {
        final made = await t.run('create_trip', {'title': 'Tokyo', 'start_date': '2030-04-01', 'end_date': '2030-04-08'});
        await t.run('add_trip_item', {'trip_id': made.result['trip_id'], 'kind': 'stay', 'title': 'Ryokan', 'start': '2030-04-01T15:00', 'end': '2030-04-08T10:00'});
      });
      expect(store.trips.single.items, hasLength(1));
      await cal.undoLast();
      expect(store.trips, isEmpty);
    });
  });

  test('zones are the real ones', () {
    expect(fromWall(DateTime.utc(2030, 3, 11, 18), 'America/New_York').toUtc(), DateTime.utc(2030, 3, 11, 22));
  });
}

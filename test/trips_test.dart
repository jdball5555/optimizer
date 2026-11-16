import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/calendar/calendar_models.dart';
import 'package:optimizer/calendar/flipped_timeline.dart';
import 'package:optimizer/calendar/month_view.dart';
import 'package:optimizer/calendar/vertical_week.dart';
import 'package:optimizer/theme.dart';
import 'package:optimizer/trips/trip_board.dart';
import 'package:optimizer/trips/trip_itinerary.dart';
import 'package:optimizer/trips/trip_models.dart';
import 'package:optimizer/trips/trip_pdf.dart';
import 'package:optimizer/trips/trip_store.dart';
import 'package:optimizer/trips/trip_zones.dart';
import 'package:optimizer/trips/trips_page.dart';
import 'package:optimizer/widgets/address_field.dart';
import 'package:optimizer/widgets/link_text.dart';

import 'preview/calendar_preview_test.dart' show loadFonts, skipPreview;
import 'preview/pages_preview_test.dart' show shot;

/// A store with no Firestore or server behind it.
class FakeTrips extends TripStore {
  FakeTrips(List<Trip> trips) : super.preview('u', trips);

  List<Map<String, dynamic>> flights = [];
  Object? flightError;
  Map? commute;
  Object? commuteError;

  /// Holds back the next answer, until it's completed.
  Completer<Map>? commuteWait;
  List<Map<String, Object?>> asked = [];

  @override
  Future<void> save(Trip t) async {
    trips = [...trips.where((x) => x.id != t.id), t];
    notifyListeners();
  }

  @override
  Future<void> delete(Trip t) async {
    trips = trips.where((x) => x.id != t.id).toList();
    openId = null;
    notifyListeners();
  }

  @override
  String newId() => 'new';

  /// What's been asked of the server.
  final called = <String, Map<String, dynamic>>{};
  Object? called0;

  @override
  Future<Object?> callServer(String name, Map<String, dynamic> data) async {
    called[name] = data;
    return {'links': inviteAnswer};
  }

  List<Map<String, String>> inviteAnswer = [];

  /// What Google would say each place's time zone is.
  Map<String, String> placeZones = {};

  @override
  Future<String?> placeZone(String place) async => placeZones[place];

  @override
  Future<List<Map<String, dynamic>>> lookupFlight(String number, DateTime date) async {
    if (flightError != null) throw flightError!;
    return flights;
  }

  @override
  Future<Map> commuteTime(
      {required String from,
      required String to,
      required String mode,
      DateTime? leaveAt,
      DateTime? arriveBy,
      List<String> stops = const [],
      int stopMinutes = 0}) async {
    asked.add({'from': from, 'to': to, 'mode': mode, 'leaveAt': leaveAt, 'arriveBy': arriveBy, 'stops': stops, 'stopMinutes': stopMinutes});
    if (commuteError != null) throw commuteError!;
    final held = commuteWait;
    if (held != null) return held.future;
    return commute!;
  }
}

class FakePlaces extends Places {
  FakePlaces([this.found = const [
    (id: 'a', text: 'Central Library, Springfield, TX, USA', main: 'Central Library', secondary: 'Springfield, TX, USA'),
    (id: 'b', text: 'Riverside Diner, Shelbyville, TX, USA', main: 'Riverside Diner', secondary: 'Shelbyville, TX, USA'),
  ]]);

  final List<PlaceSuggestion> found;

  @override
  Future<List<PlaceSuggestion>> suggest(String input, String session) async => found;

  @override
  Future<void> picked(String id, String session) async {}
}

/// Suggests just what's typed, so a test can click it.
class EchoPlaces extends Places {
  @override
  Future<List<PlaceSuggestion>> suggest(String input, String session) async => [(id: 'e', text: input, main: input, secondary: '')];

  @override
  Future<void> picked(String id, String session) async {}
}

/// Types into an address box and picks what Google suggests.
Future<void> pick(WidgetTester t, String label, String main) async {
  final field = find.widgetWithText(TextField, label);
  await t.ensureVisible(field);
  await t.tap(field);
  await t.pump();
  await t.enterText(field, main);
  await t.pump(const Duration(milliseconds: 300));
  await t.pump();
  await t.tap(find.text(main).last);
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
}

/// Picks from the type dropdown.
Future<void> setType(WidgetTester t, String label) async {
  await t.tap(find.byType(DropdownButtonFormField<TripItemKind>));
  await t.pumpAndSettle();
  await t.tap(find.text(label).last);
  await t.pumpAndSettle();
}

TripItem item(String id, TripItemKind kind, DateTime start, DateTime end, {String? title, Map<String, dynamic>? flight, Map<String, dynamic>? commute}) =>
    TripItem(id: id, kind: kind, title: title ?? id, start: start, end: end, flight: flight, commute: commute);

Map<String, dynamic> dfwToLax(DateTime dep, DateTime arr) => {
      'number': 'AA 1234',
      'airline': 'American Airlines',
      'aircraft': 'Boeing 737-800',
      'status': 'Expected',
      'departure': {
        'iata': 'DFW',
        'name': 'Dallas Fort Worth',
        'terminal': 'D',
        'gate': 'D12',
        'scheduled': dep.millisecondsSinceEpoch,
        'scheduledLocal': '2026-12-20T08:05',
      },
      'arrival': {'iata': 'LAX', 'name': 'Los Angeles', 'baggageBelt': '4', 'scheduled': arr.millisecondsSinceEpoch, 'scheduledLocal': '2026-12-20T09:30'},
    };

void main() {
  group('the trip’s span', () {
    final t = Trip(id: 't', title: 'Tokyo', start: DateTime(2026, 12, 20), end: DateTime(2026, 12, 27));

    test('with nothing planned, it covers its days', () {
      expect(t.span.start, DateTime(2026, 12, 20));
      expect(t.span.end, DateTime(2026, 12, 28));
      expect(t.days.length, 8);
    });

    test('its tile runs from the start of the first thing to the end of the last', () {
      final s = t.copyWith(items: [
        item('dinner', TripItemKind.activity, DateTime(2026, 12, 23, 19), DateTime(2026, 12, 23, 21)),
        item('commute', TripItemKind.commute, DateTime(2026, 12, 21, 5), DateTime(2026, 12, 21, 6)),
        item('stay', TripItemKind.stay, DateTime(2026, 12, 21, 15), DateTime(2026, 12, 24, 11)),
      ]);
      expect(s.span.start, DateTime(2026, 12, 21, 5));
      expect(s.span.end, DateTime(2026, 12, 24, 11));
      expect(s.tile.start, DateTime(2026, 12, 21, 5));
      expect(s.tile.end, DateTime(2026, 12, 24, 11));
      expect(s.lastDay, DateTime(2026, 12, 24));
    });

    test('one drive is the whole tile, even inside the days set aside', () {
      final s = t.copyWith(items: [item('drive', TripItemKind.commute, DateTime(2026, 12, 21, 6), DateTime(2026, 12, 21, 11, 32))]);
      expect([s.tile.start, s.tile.end], [DateTime(2026, 12, 21, 6), DateTime(2026, 12, 21, 11, 32)]);
      expect(s.tile.spansDays, isFalse);
    });

    test('something with no length still shows', () {
      final s = t.copyWith(items: [item('photo', TripItemKind.activity, DateTime(2026, 12, 21, 6), DateTime(2026, 12, 21, 6))]);
      expect(s.span.end, DateTime(2026, 12, 21, 6, 30));
    });

    test('the trip’s own calendar keeps the days set aside, to plan the rest in', () {
      final s = t.copyWith(items: [item('dinner', TripItemKind.activity, DateTime(2026, 12, 23, 19), DateTime(2026, 12, 23, 21))]);
      expect(s.days.first, DateTime(2026, 12, 20));
      expect(s.days.last, DateTime(2026, 12, 27));
    });

    test('something outside its days stretches both', () {
      final stretched = t.copyWith(items: [
        item('early', TripItemKind.commute, DateTime(2026, 12, 19, 22), DateTime(2026, 12, 19, 23)),
        item('late', TripItemKind.flight, DateTime(2026, 12, 28, 1), DateTime(2026, 12, 28, 9)),
      ]);
      expect(stretched.span.start, DateTime(2026, 12, 19, 22));
      expect(stretched.span.end, DateTime(2026, 12, 28, 9));
      expect(stretched.days.first, DateTime(2026, 12, 19));
      expect(stretched.days.last, DateTime(2026, 12, 28));
    });

    test('a trip ending exactly at midnight doesn’t claim the next day', () {
      expect(t.days.last, DateTime(2026, 12, 27));
    });

    test('its tile is one event, in front of nothing, never sent to Google', () {
      final tile = t.tile;
      expect(tile.isTrip, isTrue);
      expect(tile.backdrop, isTrue);
      expect(tile.spansDays, isTrue);
      expect(tripsCalendar.canWrite, isFalse);
    });

    test('saved and read back, it’s the same trip', () {
      final dep = DateTime(2026, 12, 20, 8, 5), arr = DateTime(2026, 12, 20, 11, 30);
      final full = t.copyWith(destination: 'Japan', items: [item('f', TripItemKind.flight, dep, arr, flight: dfwToLax(dep, arr))]);
      final back = Trip.fromDoc('t', full.toJson());
      expect(back.destination, 'Japan');
      expect(back.items.single.start, dep);
      expect(back.items.single.departure.gate, 'D12');
      expect(back.items.single.departure.localTime, DateTime(2026, 12, 20, 8, 5));
      expect(back.items.single.arrival.baggageBelt, '4');
    });
  });

  group('on the main calendar', () {
    final monday = DateTime(2026, 12, 21);
    final days = [for (var i = 0; i < 7; i++) DateTime(2026, 12, 20 + i)];
    final trip = Trip(id: 't', title: 'Tokyo', start: DateTime(2026, 12, 20), end: DateTime(2026, 12, 24));
    final meeting = CalendarEvent(
      id: 'm', calendar: tripsCalendar, title: 'Meeting', description: '', location: '',
      start: monday.add(const Duration(hours: 9)), end: monday.add(const Duration(hours: 10)), allDay: false, color: Colors.green,
    );

    Future<void> pump(WidgetTester t, Widget w, {Size size = const Size(1400, 900)}) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: w)));
      await t.pump();
    }

    testWidgets('week: the tile runs behind other events without squeezing them', (t) async {
      await pump(t, FlippedTimeline(days: days, events: [trip.tile, meeting], hourWidth: 100, onEventTap: (_) {}));
      expect(t.takeException(), isNull);
      final tile = t.getRect(find.text('Tokyo').first);
      expect(tile, isNotNull);
      final block = t.getRect(find.ancestor(of: find.text('Meeting'), matching: find.byType(EventBlock)));
      final alone = t.getRect(find.byType(EventBlock).first);
      // The meeting has the whole row's height, as if the trip weren't there.
      expect(block.height, greaterThan(alone.height - 2));
      // The tile fills whole days, from midnight on.
      expect(alone.width, greaterThan(100.0 * 23.9));
    });

    testWidgets('week: the title stays in sight while the hours scroll', (t) async {
      await pump(t, FlippedTimeline(days: days, events: [trip.tile], hourWidth: 100, onEventTap: (_) {}));
      // It opens scrolled to 7 am, 700 px past where the tile begins, which
      // would put an ordinary title off the left of the hours (they start at 184).
      expect(t.getRect(find.text('Tokyo').first).left, greaterThanOrEqualTo(184));
    });

    testWidgets('month: one bar across the days, not a line in each', (t) async {
      CalendarEvent? tapped;
      await pump(t, MonthView(month: DateTime(2026, 12), events: [trip.tile], onDayTap: (_) {}, onEventTap: (e) => tapped = e));
      expect(t.takeException(), isNull);
      // Dec 20–24 runs Sunday to Thursday, all in one week.
      expect(find.text('Tokyo'), findsOneWidget);
      final bar = t.getRect(find.ancestor(of: find.text('Tokyo'), matching: find.byType(Material)).first);
      expect(bar.width, greaterThan(1400 / 7 * 4));
      await t.tap(find.text('Tokyo'));
      expect(tapped?.isTrip, isTrue);
    });

    testWidgets('month: a trip across two weeks is a bar in each', (t) async {
      final long = Trip(id: 'l', title: 'Long', start: DateTime(2026, 12, 18), end: DateTime(2026, 12, 22));
      await pump(t, MonthView(month: DateTime(2026, 12), events: [long.tile], onDayTap: (_) {}, onEventTap: (_) {}));
      expect(find.text('Long'), findsNWidgets(2));
    });

    testWidgets('phone week fits, with the tile', (t) async {
      await pump(t, VerticalWeek(days: days, events: [trip.tile, meeting], onEventTap: (_) {}), size: const Size(412, 800));
      expect(t.takeException(), isNull);
      expect(find.text('Tokyo'), findsWidgets);
    });
  });

  group('the trip page', () {
    setUp(() => Places.instance = EchoPlaces());
    tearDown(() => Places.instance = Places());

    final dep = DateTime(2026, 12, 20, 14, 5), arr = DateTime(2026, 12, 20, 17, 30);
    Trip tokyo({List<TripItem>? items}) => Trip(id: 't', title: 'Tokyo', destination: 'Japan', start: DateTime(2026, 12, 20), end: DateTime(2026, 12, 27), items: items);

    Future<FakeTrips> open(WidgetTester t, {List<TripItem>? items, Size size = const Size(1400, 900), TripHow? how = TripHow.fly}) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final trip = tokyo(items: items);
      final store = FakeTrips([how == null ? trip : trip.copyWith(how: how)])..openId = 't';
      await t.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: TripsPage(store: store, active: true))));
      await t.pump();
      return store;
    }

    /// Picks from the list under the +.
    Future<void> add(WidgetTester t, String label) async {
      await t.tap(find.byTooltip('Add to trip'));
      await t.pumpAndSettle();
      await t.tap(find.text(label));
      await t.pumpAndSettle();
    }

    final flight = item('f', TripItemKind.flight, dep, arr, title: 'AA 1234 · DFW – LAX', flight: dfwToLax(dep, arr));

    testWidgets('a large screen shows the itinerary beside the calendar', (t) async {
      await open(t, items: [flight]);
      expect(find.byType(TripItinerary), findsOneWidget);
      expect(find.byType(TripBoard), findsOneWidget);
      expect(find.text('Itinerary'), findsNothing);
      expect(find.text('Trip name'), findsNothing, reason: 'no left column');
    });

    testWidgets('a phone switches between them', (t) async {
      await open(t, items: [flight], size: const Size(412, 915));
      expect(find.byType(TripBoard), findsNothing);
      await t.tap(find.text('Calendar'));
      await t.pump();
      expect(find.byType(TripBoard), findsOneWidget);
      expect(find.byType(TripItinerary), findsNothing);
      expect(t.takeException(), isNull);
    });

    group('the itinerary', () {
      testWidgets('a flight says briefly what and where', (t) async {
        await open(t, items: [flight]);
        expect(find.text('AA 1234'), findsOneWidget);
        expect(find.text('DFW\uFFFCLAX', findRichText: true), findsOneWidget);
        expect(find.textContaining('Gate D12'), findsNothing, reason: 'that’s in the flight itself');
        expect(find.textContaining('American Airlines'), findsNothing);
      });

      testWidgets('each thing’s start time sits left of its title, with the line between', (t) async {
        await open(t, items: [
          flight,
          item('c', TripItemKind.commute, DateTime(2026, 12, 20, 9), DateTime(2026, 12, 20, 10), title: 'Drive to DFW', commute: {'from': '12 Home St, Frisco, TX', 'to': 'DFW Airport, Dallas, TX'}),
          TripItem(id: 'a', kind: TripItemKind.activity, title: 'Griffith Observatory', start: DateTime(2026, 12, 21, 10), end: DateTime(2026, 12, 21, 12), location: 'Griffith Observatory, 2800 E Observatory Rd, Los Angeles'),
        ]);
        expect(find.text('12 Home St\uFFFCDFW Airport', findRichText: true), findsOneWidget);
        expect(find.text('2800 E Observatory Rd, Los Angeles', findRichText: true), findsOneWidget, reason: 'named after the place, so the rest of the address');
        final start = find.descendant(of: find.byType(TripItinerary), matching: find.textContaining(RegExp(r'^9:00\sAM$')));
        expect(start, findsOneWidget);
        final title = find.descendant(of: find.byType(TripItinerary), matching: find.text('Drive to DFW'));
        expect(t.getRect(start).right, lessThan(t.getTopLeft(title).dx));
        expect(t.widget<Text>(start).style!.color, AppColors.primaryText, reason: 'in white');
        expect(t.getTopLeft(title).dy, lessThan(t.getTopLeft(find.text('AA 1234')).dy), reason: 'in order');
        expect(find.text('Monday, December 21'), findsOneWidget);
      });

      testWidgets('a day comes up once, even when an airport’s date isn’t this device’s', (t) async {
        final flyOut = DateTime(2026, 12, 20, 19), land = DateTime(2026, 12, 21, 7);
        final f = dfwToLax(flyOut, land);
        (f['departure'] as Map)['scheduledLocal'] = '2026-12-21T10:00';
        await open(t, items: [
          item('a', TripItemKind.activity, DateTime(2026, 12, 20, 12), DateTime(2026, 12, 20, 13), title: 'Lunch'),
          item('f', TripItemKind.flight, flyOut, land, title: 'AA 1234', flight: f),
          item('b', TripItemKind.activity, DateTime(2026, 12, 20, 21), DateTime(2026, 12, 20, 22), title: 'Late show'),
          item('c', TripItemKind.activity, DateTime(2026, 12, 21, 21), DateTime(2026, 12, 21, 22), title: 'Next night'),
        ]);
        expect(find.text('Sunday, December 20'), findsOneWidget);
        expect(find.text('Monday, December 21'), findsOneWidget);
      });

      testWidgets('getting somewhere says how long it takes in all; other things don’t need to', (t) async {
        await open(t, items: [
          item('d', TripItemKind.commute, DateTime(2026, 12, 20, 9), DateTime(2026, 12, 20, 12, 30), title: 'Drive', commute: {'from': 'A', 'to': 'B'}),
          item('t', TripItemKind.travel, DateTime(2026, 12, 20, 13), DateTime(2026, 12, 20, 13, 45), title: 'Train', commute: {'from': 'B', 'to': 'C'}),
          item('a', TripItemKind.activity, DateTime(2026, 12, 20, 14), DateTime(2026, 12, 20, 16), title: 'Museum'),
          item('s', TripItemKind.stay, DateTime(2026, 12, 20, 17), DateTime(2026, 12, 22, 11), title: 'Hotel'),
        ]);
        final line = find.byType(TripItinerary);
        expect(find.descendant(of: line, matching: find.text('Total 3 h 30 min')), findsOneWidget);
        expect(find.descendant(of: line, matching: find.text('Total 45 min')), findsOneWidget);
        expect(find.descendant(of: line, matching: find.textContaining('Total')), findsNWidgets(2), reason: 'not on the museum or hotel');
      });

      testWidgets('a place to stay has its check in and its check out, each on its own day', (t) async {
        await open(t, items: [item('s', TripItemKind.stay, DateTime(2026, 12, 20, 15), DateTime(2026, 12, 23, 11), title: 'Hotel')]);
        final line = find.byType(TripItinerary);
        expect(find.descendant(of: line, matching: find.text('Hotel')), findsNWidgets(2));
        final checkIn = find.descendant(of: line, matching: find.textContaining(RegExp(r'^Check in at 3:00\sPM \S+$')));
        final checkOut = find.descendant(of: line, matching: find.textContaining(RegExp(r'^Check out at 11:00\sAM \S+$')));
        expect([checkIn, checkOut], everyElement(findsOneWidget));
        final y = t.getTopLeft(find.text('Wednesday, December 23')).dy;
        expect([t.getTopLeft(checkIn).dy < y, t.getTopLeft(checkOut).dy > y], [true, true]);
        await t.tap(checkOut);
        await t.pumpAndSettle();
        expect(find.text('Edit a stay'), findsOneWidget);
      });

      testWidgets('a drive’s stops sit under it, small and with no time of their own', (t) async {
        await open(t, items: [
          item('d', TripItemKind.commute, DateTime(2026, 12, 20, 9), DateTime(2026, 12, 20, 15), title: 'Drive to Austin', commute: {
            'from': 'Home',
            'to': 'Austin',
            'stops': [
              {'place': 'Buc-ee’s, Temple, TX', 'minutes': 30, 'at': DateTime(2026, 12, 20, 11).millisecondsSinceEpoch},
              {'place': '', 'minutes': 20},
            ],
          }),
          item('a', TripItemKind.activity, DateTime(2026, 12, 20, 10), DateTime(2026, 12, 20, 10, 30), title: 'Between'),
        ]);
        final line = find.byType(TripItinerary);
        Finder inLine(String text) => find.descendant(of: line, matching: find.text(text));
        final stop = inLine('Buc-ee’s');
        expect(stop, findsOneWidget);
        expect(inLine('ON THE DRIVE'), findsNothing);
        expect(inLine('30 min stop'), findsOneWidget);
        expect(inLine('20 min stop'), findsOneWidget);
        expect(inLine('Total 6 h, including 50 min of stops'), findsOneWidget, reason: 'the drive’s time has them in it');
        expect(find.descendant(of: line, matching: find.textContaining('11:00')), findsNothing, reason: 'no set time');
        double y(Finder f) => t.getTopLeft(f).dy;
        expect([y(inLine('Drive to Austin')) < y(stop), y(stop) < y(inLine('Between'))], [true, true]);
        await t.tap(stop);
        await t.pumpAndSettle();
        expect(find.widgetWithText(TextField, 'Austin'), findsOneWidget);
      });

      testWidgets('with nothing planned, it points to the first thing to add', (t) async {
        final store = await open(t);
        expect(find.text('Nothing planned yet'), findsOneWidget);
        store.flights = [dfwToLax(dep, arr)];
        await t.tap(find.text('Add your flight'));
        await t.pumpAndSettle();
        expect(find.widgetWithText(TextField, 'Flight number'), findsOneWidget);
      });
    });

    group('time zones', () {
      const chicago = 'America/Chicago', la = 'America/Los_Angeles', tokyo = 'Asia/Tokyo', phoenix = 'America/Phoenix';
      DateTime at(String zone, int d, int h, [int m = 0]) => fromWall(DateTime.utc(2026, 12, d, h, m), zone);
      Finder inLine(Finder f) => find.descendant(of: find.byType(TripItinerary), matching: f);
      Finder inBoard(Finder f) => find.descendant(of: find.byType(TripBoard), matching: f);
      Finder clock(String text) => find.textContaining(RegExp('^${text.replaceAll(' ', r'\s')}\$'));

      TripItem fly(String id, int d, int h, String from, String fromZone, int d2, int h2, int m2, String to, String toZone) => TripItem(
            id: id,
            kind: TripItemKind.flight,
            title: '$id · $from – $to',
            start: at(fromZone, d, h),
            end: at(toZone, d2, h2, m2),
            zone: fromZone,
            endZone: toZone,
            flight: {
              'number': id,
              'departure': {'iata': from, 'timeZone': fromZone},
              'arrival': {'iata': to, 'timeZone': toZone},
            },
          );

      Future<FakeTrips> openZoned(WidgetTester t, List<TripItem> items, {Size size = const Size(1400, 900)}) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final store = FakeTrips([
          Trip(id: 't', title: 'Trip', zone: chicago, how: TripHow.fly, start: DateTime(2026, 12, 20), end: DateTime(2026, 12, 24), items: [...items]..sort(Trip.byTime))
        ])
          ..openId = 't';
        await t.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: TripsPage(store: store, active: true))));
        await t.pump();
        return store;
      }

      testWidgets('once you fly somewhere, everything after is in that zone, and says so', (t) async {
        await openZoned(t, [
          fly('AA 1', 20, 8, 'DFW', chicago, 20, 9, 30, 'LAX', la),
          item('d', TripItemKind.activity, at(chicago, 20, 7), at(chicago, 20, 7, 30), title: 'Coffee'),
          item('e', TripItemKind.activity, at(la, 20, 18), at(la, 20, 20), title: 'Dinner'),
        ]);
        Finder left(String time, String zone) {
          final at = inLine(clock(time));
          expect(at, findsOneWidget, reason: time);
          // The zone's right under its time, flush to the same edge by the line.
          final under = find.descendant(of: find.ancestor(of: at, matching: find.byType(Column)).first, matching: find.text(zone));
          expect(under, findsOneWidget, reason: '$zone under $time');
          expect(t.getTopLeft(under).dy, greaterThanOrEqualTo(t.getBottomLeft(at).dy - 1));
          expect((t.getTopRight(under).dx - t.getTopRight(at).dx).abs(), lessThan(1));
          return at;
        }

        left('7:00 AM', 'CST');
        left('8:00 AM', 'CST');
        expect(inLine(clock('8:00 AM CST – 9:30 AM PST')), findsOneWidget, reason: 'each end in its own');
        expect(inLine(find.text('Now on PST · 2 h earlier')), findsOneWidget);
        left('6:00 PM', 'PST');
        expect(inLine(find.text('Total 3 h 30 min')), findsOneWidget, reason: 'really how long the flight is, across the zones');
        expect(inLine(clock('6:00 PM PST – 8:00 PM PST')), findsOneWidget);
        expect(find.textContaining('CST', findRichText: true), findsWidgets);
        double y(Finder f) => t.getTopLeft(f).dy;
        expect(y(inLine(find.text('Now on PST · 2 h earlier'))), lessThan(y(inLine(find.text('Dinner')))));
        expect(y(inLine(find.text('Now on PST · 2 h earlier'))), greaterThan(y(inLine(find.text('AA 1')))));
      });

      testWidgets('the same with a drive across zones, and back again', (t) async {
        await openZoned(t, [
          TripItem(id: 'd', kind: TripItemKind.commute, title: 'Drive to Phoenix', start: at(chicago, 20, 6), end: at(phoenix, 21, 2), zone: chicago, endZone: phoenix, commute: {'from': 'Dallas', 'to': 'Phoenix'}),
          item('b', TripItemKind.activity, at(phoenix, 21, 10), at(phoenix, 21, 11), title: 'Brunch'),
          fly('AA 2', 22, 9, 'PHX', phoenix, 22, 13, 30, 'DFW', chicago),
          item('h', TripItemKind.activity, at(chicago, 22, 18), at(chicago, 22, 19), title: 'Home'),
        ]);
        expect(inLine(find.text('Now on MST · 1 h earlier')), findsOneWidget);
        expect(inLine(clock('10:00 AM')), findsOneWidget);
        expect(inLine(find.text('Now on CST · 1 h later')), findsOneWidget);
        expect(inLine(clock('6:00 PM')), findsOneWidget);
      });

      testWidgets('a day’s date is the date where you are', (t) async {
        await openZoned(t, [
          fly('JL 7', 20, 11, 'DFW', chicago, 21, 15, 0, 'HND', tokyo),
          item('s', TripItemKind.activity, at(tokyo, 22, 1), at(tokyo, 22, 2), title: 'Karaoke'),
        ]);
        // 1 AM on the 22nd in Tokyo is still the 21st in Dallas.
        expect(inLine(find.text('Tuesday, December 22')), findsOneWidget);
        expect(inLine(clock('1:00 AM')), findsOneWidget);
        expect(inLine(clock('Dec 20, 11:00 AM CST – Dec 21, 3:00 PM JST')), findsOneWidget);
        expect(inLine(find.text('Now on JST · 15 h later')), findsOneWidget);
        expect(inBoard(find.text('CST to JST')), findsOneWidget, reason: 'the calendar says so over the day it happens');
        expect(inBoard(find.text('JST')), findsWidgets);
      });

      testWidgets('on the calendar, things sit at the time on the clock where they are', (t) async {
        await openZoned(t, [
          fly('AA 1', 20, 8, 'DFW', chicago, 20, 9, 30, 'LAX', la),
          item('e', TripItemKind.activity, at(la, 21, 18), at(la, 21, 19), title: 'Dinner'),
        ]);
        expect(inBoard(find.textContaining(RegExp(r'6:00\sPM PST'))), findsOneWidget);
        final hour = t.getTopLeft(find.text('6 PM')).dy + 7;
        expect((t.getTopLeft(inBoard(find.text('Dinner'))).dy - hour).abs(), lessThan(12));
      });

      testWidgets('a time you set is on the clock at that place, whatever this device’s is', (t) async {
        final store = await openZoned(t, [fly('AA 1', 20, 8, 'DFW', chicago, 20, 9, 30, 'LAX', la)]);
        store.placeZones = {'Griffith Observatory, Los Angeles, CA, USA': la};
        final places = FakePlaces(const [(id: 'g', text: 'Griffith Observatory, Los Angeles, CA, USA', main: 'Griffith Observatory', secondary: 'Los Angeles, CA, USA')]);
        Places.instance = places;
        addTearDown(() => Places.instance = Places());
        await t.tap(find.byTooltip('Add to trip'));
        await t.pumpAndSettle();
        await t.tap(find.text('Something to do'));
        await t.pumpAndSettle();
        await t.enterText(find.widgetWithText(TextField, 'Name'), 'Observatory');
        await pick(t, 'Where', 'Griffith Observatory');
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        final a = store.trips.single.items.firstWhere((i) => i.title == 'Observatory');
        expect(a.zone, la);
        expect(a.start, at(la, 20, 10), reason: '10 AM there');
        expect(inLine(clock('10:00 AM')), findsOneWidget);
      });

      testWidgets('a name that’s just typed could be anywhere, so it doesn’t move your zone', (t) async {
        final store = await openZoned(t, [fly('AA 1', 20, 8, 'DFW', chicago, 20, 9, 30, 'LAX', la)]);
        store.placeZones = {'Chick-fil-A': tokyo};
        await t.tap(find.byTooltip('Add to trip'));
        await t.pumpAndSettle();
        await t.tap(find.text('Food'));
        await t.pumpAndSettle();
        await t.enterText(find.widgetWithText(TextField, 'Name'), 'Chick-fil-A');
        await t.enterText(find.widgetWithText(TextField, 'Where'), 'Chick-fil-A');
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        final a = store.trips.single.items.firstWhere((i) => i.kind == TripItemKind.food);
        expect(a.zone, isEmpty);
        expect(store.trips.single.zones[a.id]!.$1, la);
      });

      testWidgets('with no place, a new thing is in the zone you’re in by then', (t) async {
        final store = await openZoned(t, [fly('AA 1', 20, 8, 'DFW', chicago, 20, 9, 30, 'LAX', la)]);
        final slot = t.getRect(inBoard(find.text('Dec 21')));
        await t.tapAt(Offset(slot.left + 30, slot.bottom + 300));
        await t.pumpAndSettle();
        expect(find.text('PST'), findsWidgets, reason: 'the day after landing');
        await t.enterText(find.widgetWithText(TextField, 'Name'), 'Hike');
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        final a = store.trips.single.items.firstWhere((i) => i.title == 'Hike');
        expect(a.zone, isEmpty, reason: 'it goes by where you are');
        expect(inLine(find.textContaining(clockIn(a.start, la))), findsOneWidget);
        expect(clockIn(a.start, la), endsWith('PST'));
      });

      test('in the middle of a drive, you’re still on the clock you left on', () {
        final trip = Trip(id: 't', title: 'T', zone: chicago, start: DateTime(2026, 12, 20), end: DateTime(2026, 12, 24), items: [
          TripItem(id: 'd', kind: TripItemKind.commute, title: 'D', start: at(chicago, 20, 6), end: at(phoenix, 20, 20), zone: chicago, endZone: phoenix),
          item('m', TripItemKind.activity, at(chicago, 20, 10), at(chicago, 20, 11), title: 'Mid-drive'),
          item('a', TripItemKind.activity, at(phoenix, 20, 21), at(phoenix, 20, 22), title: 'After'),
        ]);
        expect(trip.zoneAt(at(chicago, 20, 10)), chicago);
        expect(trip.zones['m']!.$1, chicago);
        expect(trip.zoneAt(at(phoenix, 20, 21)), phoenix);
        expect(trip.zones['a']!.$1, phoenix);
        expect(trip.zonesOn(DateTime(2026, 12, 20)), (chicago, phoenix));
        expect(trip.zonesOn(DateTime(2026, 12, 21)), (phoenix, phoenix));
      });

      test('checking out of a hotel doesn’t move you', () {
        final trip = Trip(id: 't', title: 'T', zone: chicago, start: DateTime(2026, 12, 20), end: DateTime(2026, 12, 24), items: [
          TripItem(id: 's', kind: TripItemKind.stay, title: 'S', start: at(la, 20, 15), end: at(la, 23, 11), zone: la),
          TripItem(id: 'f', kind: TripItemKind.flight, title: 'F', start: at(la, 23, 8), end: at(chicago, 23, 14), zone: la, endZone: chicago),
          item('h', TripItemKind.activity, at(chicago, 23, 18), at(chicago, 23, 19), title: 'Home'),
        ]);
        expect(trip.zones['h']!.$1, chicago);
      });

      testWidgets('typing a flight in: each time is at its airport, and the length comes out right', (t) async {
        final store = await openZoned(t, []);
        store.placeZones = {'DFW airport': chicago, 'LAX airport': la};
        store.flightError = Exception('Flight lookup isn’t set up yet.');
        await t.tap(find.byTooltip('Add to trip'));
        await t.pumpAndSettle();
        await t.tap(find.text('Flight'));
        await t.pumpAndSettle();
        await t.tap(find.text('Type it in yourself'));
        await t.pump();
        await t.enterText(find.widgetWithText(TextField, 'From'), 'dfw');
        await t.enterText(find.widgetWithText(TextField, 'To'), 'lax');
        await t.pump(const Duration(milliseconds: 600));
        await t.pump();
        expect(find.text('CST'), findsOneWidget, reason: 'right after the takeoff time');
        expect(find.text('PST'), findsOneWidget, reason: 'right after the landing time');
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        final f = store.trips.single.items.single;
        expect([f.zone, f.endZone], [chicago, la]);
        expect(f.start, at(chicago, 20, 9));
        expect(f.end, at(la, 20, 11), reason: '11 AM in LA');
        expect(f.end.difference(f.start), const Duration(hours: 4));
      });

      testWidgets('a looked-up flight uses its airports’ zones', (t) async {
        final dep = at(chicago, 20, 8, 5), arr = at(la, 20, 9, 30);
        final store = await openZoned(t, []);
        store.flights = [
          {
            'number': 'AA 1234',
            'departure': {'iata': 'DFW', 'timeZone': chicago, 'scheduled': dep.millisecondsSinceEpoch},
            'arrival': {'iata': 'LAX', 'timeZone': la, 'scheduled': arr.millisecondsSinceEpoch},
          }
        ];
        await t.tap(find.byTooltip('Add to trip'));
        await t.pumpAndSettle();
        await t.tap(find.text('Flight'));
        await t.pumpAndSettle();
        await t.enterText(find.widgetWithText(TextField, 'Flight number'), 'aa1234');
        await t.tap(find.text('Look up flight'));
        await t.pumpAndSettle();
        expect(find.text('CST'), findsOneWidget);
        expect(find.text('PST'), findsOneWidget);
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        final f = store.trips.single.items.single;
        expect([f.start, f.end, f.zone, f.endZone], [dep, arr, chicago, la]);
      });

      testWidgets('a drive leaves on one clock and arrives on another', (t) async {
        final store = await openZoned(t, []);
        store.placeZones = {'Dallas': chicago, 'Phoenix': phoenix};
        store.commute = {'minutes': 960, 'meters': 1000, 'predicted': true};
        await t.tap(find.byTooltip('Add to trip'));
        await t.pumpAndSettle();
        await t.tap(find.text('Car ride'));
        await t.pumpAndSettle();
        await t.tap(find.text('Arrive by'));
        await t.pump(const Duration(milliseconds: 400));
        await pick(t, 'Starting from', 'Dallas');
        await pick(t, 'Final destination', 'Phoenix');
        await t.tap(find.text('Estimate the drive'));
        await t.pumpAndSettle();
        expect(store.asked.last['arriveBy'], fromWall(DateTime.utc(2026, 12, 20, 9), phoenix), reason: '9 AM in Phoenix, for Google’s traffic');
        expect(find.text('CST'), findsWidgets);
        expect(find.text('MST'), findsWidgets);
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        final d = store.trips.single.items.single;
        expect([d.zone, d.endZone], [chicago, phoenix]);
        expect(d.end.difference(d.start), const Duration(minutes: 960));
        expect(wallOf(d.start, chicago).hour, 18, reason: '16 h before 9 AM MST, which is 10 AM CST');
      });

      testWidgets('a time zone can be changed by hand, keeping what the clock says', (t) async {
        final store = await openZoned(t, []);
        await t.tap(find.byTooltip('Add to trip'));
        await t.pumpAndSettle();
        await t.tap(find.text('Something to do'));
        await t.pumpAndSettle();
        await t.enterText(find.widgetWithText(TextField, 'Name'), 'Sushi');
        await t.tap(find.text('CST').first);
        await t.pumpAndSettle();
        await t.enterText(find.widgetWithText(TextField, 'Time zone'), 'tokyo');
        await t.pump();
        await t.tap(find.text('Tokyo'));
        await t.pumpAndSettle();
        expect(find.text('JST'), findsOneWidget, reason: 'one zone for the whole row');
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        final a = store.trips.single.items.single;
        expect(a.zone, tokyo);
        expect(a.start, fromWall(DateTime.utc(2026, 12, 20, 10), tokyo));
      });

      testWidgets('adding a flight later leaves what’s after it at the same time on the clock', (t) async {
        final store = await openZoned(t, [item('e', TripItemKind.activity, at(chicago, 21, 18), at(chicago, 21, 19), title: 'Dinner')]);
        expect(inLine(clock('6:00 PM')), findsOneWidget);
        await store.saveItem(store.trips.single, fly('AA 1', 20, 8, 'DFW', chicago, 20, 9, 30, 'LAX', la));
        await t.pump();
        final dinner = store.trips.single.items.firstWhere((i) => i.id == 'e');
        expect(dinner.start, at(la, 21, 18), reason: 'still 6 PM, now in LA');
        expect(inLine(clock('6:00 PM')), findsOneWidget);
        expect(inLine(find.text('PST')), findsWidgets);
        // Taking the flight off puts it back.
        await store.deleteItem(store.trips.single, store.trips.single.items.firstWhere((i) => i.id == 'AA 1'));
        expect(store.trips.single.items.single.start, at(chicago, 21, 18));
      });

      testWidgets('what has its own place stays put when a flight changes', (t) async {
        final store = await openZoned(t, [
          TripItem(id: 'e', kind: TripItemKind.activity, title: 'Show', start: at(la, 21, 18), end: at(la, 21, 19), zone: la),
        ]);
        await store.saveItem(store.trips.single, fly('AA 1', 20, 8, 'DFW', chicago, 20, 9, 30, 'SFO', la));
        expect(store.trips.single.items.firstWhere((i) => i.id == 'e').start, at(la, 21, 18));
      });

      testWidgets('saved and read back, on any device', (t) async {
        final trip = Trip(id: 't', title: 'T', zone: chicago, start: DateTime(2026, 12, 20), end: DateTime(2026, 12, 24), items: [
          fly('AA 1', 20, 8, 'DFW', chicago, 20, 9, 30, 'LAX', la),
        ]);
        final back = Trip.fromDoc('t', trip.toJson());
        expect([back.zone, back.start, back.end], [chicago, DateTime(2026, 12, 20), DateTime(2026, 12, 24)]);
        expect(back.zones['AA 1'], (chicago, la));
        // Written on another device, the plain date still says the same day.
        final elsewhere = {...trip.toJson(), 'start': DateTime.utc(2026, 12, 20, 5).toIso8601String()};
        expect(Trip.fromDoc('t', elsewhere).start, DateTime(2026, 12, 20));
      });

      test('daylight saving, years out', () {
        expect(zoneLabel(DateTime.utc(2030, 7, 1), chicago), 'CDT');
        expect(zoneLabel(DateTime.utc(2030, 1, 1), chicago), 'CST');
        expect(zoneLabel(DateTime.utc(2034, 7, 1), 'Europe/London'), 'BST');
        expect(fromWall(DateTime.utc(2030, 7, 1, 12), chicago).toUtc(), DateTime.utc(2030, 7, 1, 17));
      });

      test('zones with no short name say their offset', () {
        expect(zoneLabel(DateTime.utc(2026, 12, 1), 'Asia/Dubai'), 'GMT+4');
        expect(zoneLabel(DateTime.utc(2026, 12, 1), 'Asia/Kolkata'), 'IST');
        expect(zoneLabel(DateTime.utc(2026, 12, 1), 'Asia/Kathmandu'), 'GMT+5:45');
        expect(zoneLabel(DateTime.utc(2026, 12, 1), 'America/Sao_Paulo'), 'GMT-3');
      });

      for (final size in const [Size(1400, 900), Size(412, 915), Size(360, 640)]) {
        testWidgets('long zone names fit ${size.width.toInt()} wide', (t) async {
          await openZoned(t, [
            fly('NP 1', 20, 8, 'DXB', 'Asia/Dubai', 20, 16, 30, 'KTM', 'Asia/Kathmandu'),
            item('e', TripItemKind.stay, at('Asia/Kathmandu', 20, 18), at('Asia/Kathmandu', 23, 11), title: 'A guest house with a long name in the mountains'),
          ], size: size);
          expect(t.takeException(), isNull);
          await t.tap(find.text('Calendar').evaluate().isEmpty ? find.byType(TripBoard) : find.text('Calendar'), warnIfMissed: false);
          await t.pump();
          expect(t.takeException(), isNull);
        });
      }
    });

    group('drives', () {
      Future<FakeTrips> driveEditor(WidgetTester t, {Size size = const Size(1400, 900), List<TripItem>? items}) async {
        final store = await open(t, size: size, items: items);
        store.commute = {'minutes': 60, 'meters': 1000, 'predicted': true};
        final places = FakePlaces();
        Places.instance = places;
        addTearDown(() => Places.instance = Places());
        await add(t, 'Car ride');
        return store;
      }

      testWidgets('every drive is the same: a ride to the airport can have stops too', (t) async {
        final store = await open(t, items: [flight]);
        store.commute = {'minutes': 45, 'meters': 40000, 'predicted': true};
        await t.tap(find.descendant(of: find.byType(TripItinerary), matching: find.text('AA 1234')));
        await t.pumpAndSettle();
        await t.ensureVisible(find.text('Ride to the airport'));
        await t.tap(find.text('Ride to the airport'));
        await t.pumpAndSettle();
        expect(find.text('Add a stop'), findsOneWidget);
        expect(find.widgetWithText(TextField, 'Starting from'), findsOneWidget);
        expect(find.widgetWithText(TextField, 'Final destination'), findsOneWidget);
      });

      testWidgets('its places go under the map, beside the form', (t) async {
        await driveEditor(t);
        final map = t.getRect(find.text('Add a location to see it here'));
        for (final label in ['Starting from', 'Final destination']) {
          final field = t.getRect(find.widgetWithText(TextField, label));
          expect(field.top, greaterThan(map.bottom), reason: label);
          expect(field.left, greaterThan(t.getRect(find.text('Leave at')).right), reason: label);
        }
        await t.tap(find.text('Add a stop'));
        await t.pump();
        final stop = t.getRect(find.widgetWithText(TextField, 'Stop 1'));
        expect(stop.top, greaterThan(t.getRect(find.widgetWithText(TextField, 'Starting from')).bottom));
        expect(stop.bottom, lessThan(t.getRect(find.widgetWithText(TextField, 'Final destination')).top));
      });

      for (final size in const [Size(1100, 700), Size(412, 915), Size(360, 640)]) {
        testWidgets('it all fits ${size.width.toInt()} wide', (t) async {
          await driveEditor(t, size: size);
          await t.ensureVisible(find.text('Add a stop'));
          await t.tap(find.text('Add a stop'));
          await t.pump();
          expect(t.takeException(), isNull);
        });
      }

      testWidgets('on a phone: no blank map, the places then the times, and the people last', (t) async {
        final store = await open(t, size: const Size(412, 915));
        store.trips = [store.trips.single.copyWith(people: const [TripPerson(email: 'ann@x.com', role: 'viewer')])];
        store.notifyListeners();
        await t.pump();
        await add(t, 'Car ride');
        expect(find.text('Add a location to see it here'), findsNothing);
        final field = t.getRect(find.widgetWithText(TextField, 'Final destination'));
        final time = t.getRect(find.text('Leave at'));
        expect(field.bottom, lessThan(time.top));
        expect(time.bottom, lessThan(915 - 80), reason: 'there without scrolling');
        await t.dragUntilVisible(find.text('People'), find.byType(ListView).first, const Offset(0, -200));
        await t.pumpAndSettle();
        expect(t.getRect(find.text('People')).top, greaterThan(t.getRect(find.widgetWithText(TextField, 'Notes')).bottom));
      });

      testWidgets('picked places are real: the map shows them and Google times it without asking', (t) async {
        final store = await driveEditor(t);
        await pick(t, 'Starting from', 'Riverside Diner');
        await pick(t, 'Final destination', 'Central Library');
        await t.pump(const Duration(milliseconds: 500));
        await t.pumpAndSettle();
        expect(store.asked.single['from'], 'Riverside Diner, Shelbyville, TX, USA');
        expect(find.text('1 h'), findsOneWidget);
        final map = t.widget<PlaceMap>(find.byType(PlaceMap));
        expect([map.from, map.to], ['Riverside Diner, Shelbyville, TX, USA', 'Central Library, Springfield, TX, USA']);
      });

      testWidgets('a place you only typed is never looked up, or changed', (t) async {
        final store = await driveEditor(t);
        await pick(t, 'Starting from', 'Riverside Diner');
        final to = find.widgetWithText(TextField, 'Final destination');
        await t.tap(to);
        await t.pump();
        await t.enterText(to, 'Chick-fil-A');
        await t.pump(const Duration(milliseconds: 300));
        // Google would have found some Chick-fil-A: it mustn't be asked.
        store.commute = {'minutes': 5, 'meters': 1000, 'predicted': true, 'from': 'Somewhere', 'to': 'Chick-fil-A, 1 Random Rd, Nowhere'};
        expect(find.text('Estimate the drive'), findsNothing, reason: 'there’s nothing to estimate');
        expect(find.textContaining('“Chick-fil-A” isn’t on the map'), findsOneWidget);
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        expect(store.asked, isEmpty);
        expect(store.trips.single.items, isEmpty, reason: 'no time for it yet');
        expect(t.widget<TextField>(to).controller!.text, 'Chick-fil-A');
        await t.enterText(find.widgetWithText(TextField, 'Minutes'), '20');
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        final d = store.trips.single.items.single;
        expect(d.commute!['to'], 'Chick-fil-A');
        expect(d.commute!['toOnMap'], false);
        expect(d.commute!.containsKey('fromOnMap'), isFalse);
        expect(d.commute!['minutes'], 20);
        expect(d.title, 'Drive to Chick-fil-A');
      });

      testWidgets('clicking the suggestion after all makes it real, and Google takes over', (t) async {
        final store = await driveEditor(t);
        await pick(t, 'Starting from', 'Riverside Diner');
        final to = find.widgetWithText(TextField, 'Final destination');
        await t.enterText(to, 'Chick-fil-A');
        FocusManager.instance.primaryFocus?.unfocus();
        await t.pump(const Duration(milliseconds: 500));
        expect(store.asked, isEmpty);
        expect(find.widgetWithText(TextField, 'Minutes'), findsOneWidget);
        await pick(t, 'Final destination', 'Central Library');
        await t.pump(const Duration(milliseconds: 500));
        await t.pumpAndSettle();
        expect(store.asked.single['to'], 'Central Library, Springfield, TX, USA');
        expect(find.widgetWithText(TextField, 'Minutes'), findsNothing);
      });

      group('stops', () {
        Future<void> addStop(WidgetTester t, {String? typed, String? picked, int n = 1}) async {
          await t.tap(find.text('Add a stop'));
          await t.pump();
          if (typed != null) {
            await t.enterText(find.widgetWithText(TextField, 'Stop $n'), typed);
            await t.pump();
          }
          if (picked != null) await pick(t, 'Stop $n', picked);
        }

        Future<FakeTrips> ends(WidgetTester t, Map<String, dynamic> answer) async {
          final store = await open(t);
          store.commute = answer;
          await add(t, 'Car ride');
          await pick(t, 'Starting from', 'Dallas, TX');
          await pick(t, 'Final destination', 'Austin, TX');
          await t.pump(const Duration(milliseconds: 500));
          await t.pumpAndSettle();
          return store;
        }

        testWidgets('a typed stop is left out of the route, but its time still counts', (t) async {
          final store = await ends(t, {'minutes': 180, 'meters': 300000, 'predicted': true, 'legs': [10800]});
          await addStop(t, typed: 'Chick-fil-A');
          FocusManager.instance.primaryFocus?.unfocus();
          await t.pump(const Duration(milliseconds: 500));
          await t.pumpAndSettle();
          expect(store.asked.last['stops'], isEmpty, reason: 'not sent to Google');
          expect(store.asked.last['stopMinutes'], 30);
          expect(find.text('3 h 30 min'), findsOneWidget, reason: 'the drive and the stop');
          expect(find.text('3 h driving + 30 min at your stop'), findsOneWidget);
          expect(find.textContaining('left out of the route: Chick-fil-A'), findsOneWidget);
          expect(find.text('Just a name, not on the map'), findsOneWidget);
          await t.tap(find.text('Save'));
          await t.pumpAndSettle();
          final d = store.trips.single.items.single;
          expect(d.end.difference(d.start), const Duration(minutes: 210));
          final stop = d.stops.single;
          expect([stop.place, stop.onMap, stop.at], ['Chick-fil-A', false, null]);
        });

        testWidgets('picked stops are the route, in order, each stretch and each stop added up', (t) async {
          final store = await ends(t, {'minutes': 180, 'meters': 300000, 'predicted': true, 'legs': [3600, 3600, 3600]});
          await addStop(t, picked: 'Waco, TX');
          await t.tap(find.byTooltip('How long you’ll stop'));
          await t.pumpAndSettle();
          await t.tap(find.text('15 min').last);
          await t.pumpAndSettle();
          await addStop(t, picked: 'Temple, TX', n: 2);
          await t.pump(const Duration(milliseconds: 500));
          await t.pumpAndSettle();
          expect(store.asked.last['stops'], ['Waco, TX', 'Temple, TX']);
          // 3 h of driving, with 15 and 30 minutes of stops.
          expect(find.text('3 h 45 min'), findsOneWidget);
          await t.tap(find.text('Save'));
          await t.pumpAndSettle();
          final d = store.trips.single.items.single;
          expect(d.end.difference(d.start), const Duration(minutes: 225));
          expect(d.stops[0].at, d.start.add(const Duration(hours: 1)), reason: 'first stretch');
          expect(d.stops[1].at, d.start.add(const Duration(hours: 2, minutes: 15)), reason: 'second stretch, after the first stop');
        });

        testWidgets('typed and picked together: only the picked ones are on the route', (t) async {
          final store = await ends(t, {'minutes': 120, 'meters': 300000, 'predicted': true, 'legs': [3600, 3600]});
          await addStop(t, typed: 'Lunch somewhere');
          await addStop(t, picked: 'Temple, TX', n: 2);
          await t.pump(const Duration(milliseconds: 500));
          await t.pumpAndSettle();
          expect(store.asked.last['stops'], ['Temple, TX']);
          expect(find.text('3 h'), findsOneWidget, reason: '2 h of driving and two half-hour stops');
          await t.tap(find.text('Save'));
          await t.pumpAndSettle();
          final d = store.trips.single.items.single;
          expect(d.stops[0].at, isNull);
          // An hour of road, after half an hour at the typed stop.
          expect(d.stops[1].at, d.start.add(const Duration(minutes: 90)));
        });
      });

      testWidgets('even if the server read something differently, what you picked stays', (t) async {
        final store = await driveEditor(t);
        store.commute = {'minutes': 60, 'meters': 1000, 'predicted': true, 'from': 'Other place', 'to': 'Other place 2'};
        await pick(t, 'Starting from', 'Riverside Diner');
        await pick(t, 'Final destination', 'Central Library');
        await t.pump(const Duration(milliseconds: 500));
        await t.pumpAndSettle();
        expect(t.widget<TextField>(find.widgetWithText(TextField, 'Starting from')).controller!.text, 'Riverside Diner, Shelbyville, TX, USA');
      });

      testWidgets('clicking a box offers every place on this trip', (t) async {
        final store = await driveEditor(t, items: [
          TripItem(id: 's', kind: TripItemKind.stay, title: 'Hotel', start: dep, end: arr, location: 'The Line Hotel, Los Angeles'),
          TripItem(id: 'f', kind: TripItemKind.food, title: 'Lunch', start: dep, end: arr, location: 'Chick-fil-A', onMap: false),
          item('d', TripItemKind.commute, dep, arr, title: 'Old drive', commute: {'from': 'Home', 'to': 'Dallas', 'fromOnMap': false, 'stops': [{'place': 'Temple', 'minutes': 5}]}),
        ]);
        final to = find.widgetWithText(TextField, 'Final destination');
        await t.tap(to);
        await t.pump();
        await t.pump();
        for (final name in ['The Line Hotel', 'Chick-fil-A', 'Dallas', 'Temple']) {
          expect(find.text(name), findsWidgets, reason: name);
        }
        expect(find.text('Powered by Google'), findsNothing, reason: 'these are your own');
        // A real place stays real, and a name stays a name.
        await t.tap(find.text('The Line Hotel'));
        await t.pump();
        expect(t.widget<TextField>(to).controller!.text, 'The Line Hotel, Los Angeles');
        await t.pump(const Duration(milliseconds: 100));
        expect(t.widget<PlaceMap>(find.byType(PlaceMap)).to, 'The Line Hotel, Los Angeles');
        final from = find.widgetWithText(TextField, 'Starting from');
        await t.tap(from);
        await t.enterText(from, 'chick');
        await t.pump(const Duration(milliseconds: 300));
        await t.pump();
        await t.tap(find.text('Chick-fil-A').last);
        await t.pump(const Duration(milliseconds: 100));
        expect(t.widget<TextField>(from).controller!.text, 'Chick-fil-A');
        expect(store.asked, isEmpty, reason: 'it’s just a name');
      });

      testWidgets('other travel’s places go under the map too', (t) async {
        await open(t);
        await add(t, 'Other travel');
        final map = t.getRect(find.text('Add a location to see it here'));
        expect(t.getRect(find.widgetWithText(TextField, 'From')).top, greaterThan(map.bottom));
      });
    });

    group('what something is', () {
      Future<FakeTrips> editing(WidgetTester t, TripItem i) async {
        final store = await open(t, items: [i]);
        await t.tap(find.descendant(of: find.byType(TripItinerary), matching: find.text(i.title)).first);
        await t.pumpAndSettle();
        return store;
      }

      testWidgets('something to do turns into food', (t) async {
        final store = await editing(t, item('a', TripItemKind.activity, dep, arr, title: 'Tacos'));
        expect(find.text('Edit an activity'), findsOneWidget);
        await setType(t, 'Food');
        expect(find.text('Edit food'), findsOneWidget);
        expect(find.widgetWithText(TextField, 'Name'), findsOneWidget);
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        final f = store.trips.single.items.single;
        expect([f.id, f.kind, f.title, f.start], ['a', TripItemKind.food, 'Tacos', dep]);
      });

      testWidgets('those are the only two to choose from', (t) async {
        await editing(t, item('a', TripItemKind.food, dep, arr, title: 'Tacos'));
        await t.tap(find.byType(DropdownButtonFormField<TripItemKind>));
        await t.pumpAndSettle();
        expect(find.text('Something to do'), findsWidgets);
        for (final other in ['Drive', 'Flight', 'Stay', 'Rental car', 'Other travel']) {
          expect(find.text(other), findsNothing, reason: other);
        }
      });

      for (final (label, kind, words) in const [
        ('Flight', TripItemKind.flight, 'flight'),
        ('Drive', TripItemKind.commute, 'drive'),
        ('Stay', TripItemKind.stay, 'stay'),
        ('Rental car', TripItemKind.rental, 'rental car'),
        ('Other travel', TripItemKind.travel, 'other travel'),
      ]) {
        testWidgets('a $words just says what it is, and hovering says why it’s stuck that way', (t) async {
          final store = await open(t);
          store.trips = [store.trips.single.copyWith(items: [item('x', kind, dep, arr, title: 'The thing', commute: {'from': 'A', 'to': 'B'})])];
          store.notifyListeners();
          await t.pump();
          await t.tap(find.descendant(of: find.byType(TripItinerary), matching: find.textContaining(RegExp('The thing|Check in|Pick up'))).first);
          await t.pumpAndSettle();
          expect(find.byType(DropdownButtonFormField<TripItemKind>), findsNothing);
          final shown = find.text(label);
          expect(shown, findsOneWidget);
          expect(find.ancestor(of: shown, matching: find.byWidgetPredicate((w) => w is ButtonStyleButton || w is InkWell)), findsNothing, reason: 'not a button');
          final tip = t.widget<Tooltip>(find.ancestor(of: shown, matching: find.byType(Tooltip)).first);
          expect(tip.message, contains('can’t change the type of a $words'));
          expect(tip.message, contains('go back'));
        });
      }
    });

    group('the drive’s times', () {
      testWidgets('leave at, the date and time, and the type share a row on a big screen', (t) async {
        await t.runAsync(loadFonts);
        await open(t, size: const Size(1500, 900));
        await add(t, 'Car ride');
        final y = t.getCenter(find.text('Leave at')).dy;
        expect((t.getCenter(find.textContaining(RegExp(r'^9:00\sAM$')).first).dy - y).abs(), lessThan(4));
        expect((t.getCenter(find.text('Drive')).dy - y).abs(), lessThan(4));
        expect(t.getTopLeft(find.text('Drive')).dx, greaterThan(t.getTopLeft(find.text('Leave at')).dx));
      });

      for (final size in const [Size(412, 915), Size(360, 640), Size(1100, 700)]) {
        testWidgets('they wrap without trouble at ${size.width.toInt()} wide', (t) async {
          await open(t, size: size);
          await add(t, 'Car ride');
          expect(t.takeException(), isNull);
        });
      }
    });

    test('a stop with no address is never its own tile', () {
      final at = dep.add(const Duration(hours: 1));
      final trip = Trip(id: 't', title: 'T', start: DateTime(2026, 12, 20), end: DateTime(2026, 12, 22), items: [
        item('d', TripItemKind.commute, dep, arr, title: 'Drive', commute: {
          'stops': [
            {'place': 'Chick-fil-A', 'minutes': 20, 'onMap': false, 'at': at.millisecondsSinceEpoch},
            {'place': '', 'minutes': 10, 'at': at.millisecondsSinceEpoch},
            {'place': 'Waco, TX', 'minutes': 30, 'at': at.millisecondsSinceEpoch},
          ],
        }),
      ]);
      expect(trip.itemEvents.map((e) => e.title), ['Drive', 'Waco']);
    });

    group('just a time, with no end', () {
      testWidgets('a toggle takes the end away, and brings it back as it was', (t) async {
        final store = await open(t);
        await add(t, 'Something to do');
        await t.enterText(find.widgetWithText(TextField, 'Name'), 'Sunset');
        final end = find.textContaining(RegExp(r'^11:00\sAM$'));
        expect(end, findsOneWidget);
        await t.tap(find.byType(Checkbox));
        await t.pump();
        expect(end, findsNothing);
        await t.tap(find.byType(Checkbox));
        await t.pump();
        expect(end, findsOneWidget);
        await t.tap(find.byType(Checkbox));
        await t.pump();
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        final a = store.trips.single.items.single;
        expect(a.end, a.start);
        expect(a.oneTime, isTrue);
        // One time, everywhere it shows.
        final time = find.textContaining(RegExp(r'^10:00\sAM( \S+)?$'));
        expect(find.descendant(of: find.byType(TripItinerary), matching: time), findsNWidgets(2), reason: 'beside the line, and under the title');
        expect(find.descendant(of: find.byType(TripBoard), matching: find.text('Sunset')), findsOneWidget);
        expect(find.textContaining('–'), findsNothing);
        // Opening it again, it's still just a time.
        await t.tap(find.descendant(of: find.byType(TripItinerary), matching: find.text('Sunset')));
        await t.pumpAndSettle();
        expect(t.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
      });

      testWidgets('food can be just a time too', (t) async {
        final store = await open(t);
        await add(t, 'Food');
        await t.enterText(find.widgetWithText(TextField, 'Name'), 'Chick-fil-A');
        await t.tap(find.byType(Checkbox));
        await t.pump();
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        expect(store.trips.single.items.single.oneTime, isTrue);
      });
    });

    group('flights: the number and date are all it takes', () {
      const chicago = 'America/Chicago', la = 'America/Los_Angeles';
      final out = fromWall(DateTime.utc(2026, 12, 20, 8, 5), chicago), lands = fromWall(DateTime.utc(2026, 12, 20, 10, 30), la);
      Map<String, dynamic> found({String depZone = chicago, String arrZone = la}) => {
            'number': 'AA 1234',
            'airline': 'American Airlines',
            'aircraft': 'Boeing 737-800',
            'status': 'Expected',
            'miles': 1235,
            'departure': {'iata': 'DFW', 'name': 'Dallas Fort Worth', 'timeZone': depZone, 'terminal': 'D', 'gate': 'D12', 'scheduled': out.millisecondsSinceEpoch},
            'arrival': {'iata': 'LAX', 'name': 'Los Angeles', 'timeZone': arrZone, 'baggageBelt': '4', 'scheduled': lands.millisecondsSinceEpoch},
          };

      testWidgets('type the number and press Save: it looks it up and saves all of it', (t) async {
        final store = await open(t);
        store.flights = [found()];
        await add(t, 'Flight');
        expect(find.widgetWithText(TextField, 'From'), findsNothing, reason: 'nothing else to fill in yet');
        await t.enterText(find.widgetWithText(TextField, 'Flight number'), 'aa1234');
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        final f = store.trips.single.items.single;
        expect([f.start, f.end, f.zone, f.endZone], [out, lands, chicago, la]);
        expect(f.title, 'AA 1234 · DFW – LAX');
        expect([f.departure.gate, f.departure.terminal, f.arrival.baggageBelt, f.flight!['aircraft']], ['D12', 'D', '4', 'Boeing 737-800']);
      });

      testWidgets('moving on from the number looks it up, with no button, and shows everything', (t) async {
        final store = await open(t);
        store.flights = [found()];
        await add(t, 'Flight');
        await t.enterText(find.widgetWithText(TextField, 'Flight number'), 'aa1234');
        await t.pump();
        FocusManager.instance.primaryFocus?.unfocus();
        await t.pumpAndSettle();
        expect(find.text('American Airlines · AA 1234'), findsOneWidget);
        expect(find.text('CST'), findsOneWidget);
        expect(find.text('PST'), findsOneWidget);
        expect(find.textContaining(RegExp(r'^8:05\sAM$')), findsOneWidget);
        expect(find.textContaining(RegExp(r'^10:30\sAM$')), findsOneWidget);
        expect(find.text('4 h 25 min'), findsOneWidget, reason: 'real time in the air, across the zones');
        expect(find.text('1235 mi'), findsOneWidget);
        expect(find.text('Leaves from Terminal D, Gate D12'), findsOneWidget);
        expect(find.text('Lands at Bags at belt 4'), findsOneWidget);
        expect(find.text('Boeing 737-800'), findsOneWidget);
      });

      testWidgets('with no zone from the flight service, it finds the airports’ zones and the times stay right', (t) async {
        final store = await open(t);
        store.flights = [found(depZone: '', arrZone: '')];
        store.placeZones = {'DFW airport': chicago, 'LAX airport': la};
        await add(t, 'Flight');
        await t.enterText(find.widgetWithText(TextField, 'Flight number'), 'aa1234');
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        final f = store.trips.single.items.single;
        expect([f.start, f.end, f.zone, f.endZone], [out, lands, chicago, la]);
      });

      testWidgets('if even that fails, the moments are still right', (t) async {
        final store = await open(t);
        store.flights = [found(depZone: '', arrZone: '')];
        await add(t, 'Flight');
        await t.enterText(find.widgetWithText(TextField, 'Flight number'), 'aa1234');
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        final f = store.trips.single.items.single;
        expect([f.start, f.end], [out, lands]);
      });

      testWidgets('if it can’t be looked up, Save stops so you can fill it in', (t) async {
        final store = await open(t);
        store.flightError = Exception('Flight lookup isn’t set up yet, so fill in the details below.');
        await add(t, 'Flight');
        await t.enterText(find.widgetWithText(TextField, 'Flight number'), 'AA 1');
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        expect(store.trips.single.items, isEmpty);
        expect(find.textContaining('isn’t set up yet'), findsOneWidget);
        expect(find.widgetWithText(TextField, 'From'), findsOneWidget);
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        expect(store.trips.single.items.length, 1, reason: 'now it’s your call');
      });

      testWidgets('a number that flies more than one leg asks which', (t) async {
        final store = await open(t);
        store.flights = [
          found(),
          {...found(), 'departure': {'iata': 'LAX', 'timeZone': la, 'scheduled': lands.millisecondsSinceEpoch}, 'arrival': {'iata': 'SFO', 'timeZone': la, 'scheduled': lands.add(const Duration(hours: 1)).millisecondsSinceEpoch}},
        ];
        await add(t, 'Flight');
        await t.enterText(find.widgetWithText(TextField, 'Flight number'), 'aa1234');
        await t.tap(find.text('Look up flight'));
        await t.pumpAndSettle();
        await t.tap(find.text('LAX – SFO'));
        await t.pumpAndSettle();
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        expect(store.trips.single.items.single.arrival.iata, 'SFO');
      });

      testWidgets('saved, it opens to what was found, and its details can still be changed', (t) async {
        final store = await open(t);
        store.flights = [found()];
        await add(t, 'Flight');
        await t.enterText(find.widgetWithText(TextField, 'Flight number'), 'aa1234');
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        await t.tap(find.descendant(of: find.byType(TripItinerary), matching: find.text('AA 1234')));
        await t.pumpAndSettle();
        expect(find.text('American Airlines · AA 1234'), findsOneWidget);
        await t.tap(find.text('Change details'));
        await t.pump();
        expect(find.widgetWithText(TextField, 'Airline'), findsOneWidget);
        expect(t.widget<TextField>(find.widgetWithText(TextField, 'To')).controller!.text, 'LAX');
      });
    });

    group('the editing page', () {
      testWidgets('it uses the width of a laptop', (t) async {
        await open(t, size: const Size(1500, 900));
        await add(t, 'Something to do');
        final name = t.getRect(find.widgetWithText(TextField, 'Name'));
        expect(name.left, lessThan(60), reason: 'no empty margin to the left');
        final where = t.getRect(find.widgetWithText(TextField, 'Where'));
        expect(where.right, greaterThan(1400), reason: 'nor to the right');
      });

      testWidgets('start and end are on one row, with one time zone, and End time takes the end away', (t) async {
        await open(t, size: const Size(1500, 900));
        await add(t, 'Something to do');
        final start = t.getRect(find.textContaining(RegExp(r'^10:00\sAM$')));
        final end = t.getRect(find.textContaining(RegExp(r'^11:00\sAM$')));
        expect((start.top - end.top).abs(), lessThan(1), reason: 'the same row');
        expect(find.descendant(of: find.byWidgetPredicate((w) => w is TextButton), matching: find.byIcon(Icons.arrow_drop_down)), findsOneWidget, reason: 'one zone button');
        expect(t.getTopLeft(find.text('End time')).dy, greaterThan(end.bottom), reason: 'the choice is on the row below');
      });

      testWidgets('the type is a dropdown in the row with the name', (t) async {
        await open(t, size: const Size(1500, 900));
        await add(t, 'Food');
        final type = t.getRect(find.byType(DropdownButtonFormField<TripItemKind>));
        final name = t.getRect(find.widgetWithText(TextField, 'Name'));
        expect((type.center.dy - name.center.dy).abs(), lessThan(4));
        expect(type.left, greaterThan(name.right));
      });

      testWidgets('Save comes right after the notes, and not at the top', (t) async {
        await open(t, size: const Size(1500, 900));
        await add(t, 'Something to do');
        final save = t.getRect(find.widgetWithText(FilledButton, 'Save'));
        expect(save.top, greaterThan(t.getRect(find.widgetWithText(TextField, 'Notes')).bottom));
        expect(save.left, lessThan(200));
      });

      testWidgets('on a phone Save stays in reach', (t) async {
        await open(t, size: const Size(412, 700));
        await add(t, 'Something to do');
        expect(t.getRect(find.widgetWithText(FilledButton, 'Save')).bottom, greaterThan(640));
        expect(t.takeException(), isNull);
      });

      for (final size in const [Size(1500, 900), Size(1100, 700), Size(800, 700), Size(412, 915), Size(360, 640)]) {
        for (final type in const ['Flight', 'Car ride', 'Rental car', 'Other travel', 'Place to stay', 'Food', 'Something to do']) {
          testWidgets('$type fits ${size.width.toInt()} wide', (t) async {
            await open(t, size: size, items: [flight]);
            await add(t, type);
            expect(t.takeException(), isNull);
          });
        }
      }
    });

    group('links', () {
      const url = 'https://www.booking.com/hotel/line.html';

      testWidgets('a link pasted into notes shows as one, ready to open', (t) async {
        await open(t);
        await add(t, 'Something to do');
        await t.enterText(find.widgetWithText(TextField, 'Notes'), 'Booked at $url.');
        await t.pump();
        expect(find.text('booking.com/hotel/line.html'), findsOneWidget, reason: 'without the period after it');
      });

      test('finding links', () {
        expect(findLinks('see https://a.com/x, or www.b.org.'), ['https://a.com/x', 'www.b.org']);
        expect(findLinks('nothing here, not even a.b'), isEmpty);
        expect(linkUri('www.b.org').toString(), 'https://www.b.org');
      });

      Future<FakeTrips> linked(WidgetTester t, {Size size = const Size(1400, 900)}) async {
        final store = await open(t, size: size, items: [
          TripItem(id: 'a', kind: TripItemKind.stay, title: 'The Line', start: dep, end: arr.add(const Duration(days: 2)), notes: 'Room at $url'),
          TripItem(id: 'b', kind: TripItemKind.activity, title: 'Museum', start: dep, end: arr),
        ]);
        await t.tap(find.byTooltip('Links and notes'));
        await t.pumpAndSettle();
        return store;
      }

      testWidgets('the trip’s links are grouped under their entries', (t) async {
        await linked(t);
        final dialog = find.byType(Dialog);
        expect(find.descendant(of: dialog, matching: find.text('The Line')), findsOneWidget);
        expect(find.descendant(of: dialog, matching: find.text('booking.com/hotel/line.html')), findsOneWidget);
        expect(find.descendant(of: dialog, matching: find.text('Museum')), findsNothing, reason: 'it has no links');
      });

      testWidgets('general links and notes are for the whole trip', (t) async {
        final store = await linked(t);
        await t.enterText(find.widgetWithText(TextField, 'Notes for the whole trip'), 'Bring a coat');
        await t.pump(const Duration(milliseconds: 600));
        expect(store.trips.single.notes, 'Bring a coat');
        await t.enterText(find.widgetWithText(TextField, 'Paste a link'), 'not a link');
        await t.tap(find.text('Add'));
        await t.pump();
        expect(find.textContaining('doesn’t look like a link'), findsOneWidget);
        await t.enterText(find.widgetWithText(TextField, 'Paste a link'), 'airbnb.com/rooms/1');
        await t.tap(find.text('Add'));
        await t.pump();
        expect(store.trips.single.links.single.url, 'https://airbnb.com/rooms/1');
        await t.tap(find.byTooltip('Remove this link'));
        await t.pump();
        expect(store.trips.single.links, isEmpty);
        final back = Trip.fromDoc('t', store.trips.single.copyWith(links: const [TripLink(url: 'https://a.com')], notes: 'n').toJson());
        expect([back.notes, back.links.single.url], ['n', 'https://a.com']);
      });

      testWidgets('on a phone it’s in the ⋯ menu', (t) async {
        await open(t, size: const Size(412, 915));
        expect(find.byTooltip('Links and notes'), findsNothing);
        await t.tap(find.byTooltip('Trip options'));
        await t.pumpAndSettle();
        expect(find.text('Links and notes'), findsOneWidget);
        expect(find.text('Download PDF'), findsOneWidget);
        expect(find.text('Share'), findsOneWidget);
      });
    });

    group('sharing', () {
      const ann = TripPerson(email: 'ann@x.com', name: 'Ann', role: 'editor'), bo = TripPerson(email: 'bo@x.com', role: 'viewer');

      Future<FakeTrips> mine(WidgetTester t, {List<TripItem>? items, Size size = const Size(1400, 900)}) async {
        final store = await open(t, items: items, size: size);
        store.trips = [store.trips.single.copyWith(people: const [ann, bo])];
        store.notifyListeners();
        await t.pump();
        return store;
      }

      Trip shared(String role, {List<TripItem>? items}) => Trip.fromDoc('share1', {
            'title': 'Their trip',
            'startDay': '2026-12-20',
            'endDay': '2026-12-22',
            'shareId': 'share1',
            'ownerName': 'Sam',
            'ownerEmail': 'sam@x.com',
            'myRole': role,
            'people': [
              {'email': 'me@x.com', 'name': 'Me', 'role': role}
            ],
            'items': [for (final i in items ?? const <TripItem>[]) i.toJson()],
          });

      Future<FakeTrips> theirs(WidgetTester t, String role, {List<Map<String, dynamic>>? raw}) async {
        t.view.physicalSize = const Size(1400, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final doc = shared(role).toJson()
          ..addAll({
            'shareId': 'share1',
            'ownerName': 'Sam',
            'ownerEmail': 'sam@x.com',
            'myRole': role,
            'items': raw ?? const [],
          });
        final store = FakeTrips([Trip.fromDoc('share1', doc)])..openId = 'share1';
        await t.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: TripsPage(store: store, active: true))));
        await t.pump();
        return store;
      }

      Map<String, dynamic> rawItem(String id, String title, String myRole) => {
            ...item(id, TripItemKind.activity, dep, arr, title: title).toJson(),
            'myRole': myRole,
            'canSee': [
              {'email': 'me@x.com', 'name': 'Me', 'role': myRole}
            ],
          };

      testWidgets('share with people, each who can view or edit', (t) async {
        final store = await open(t);
        store.inviteAnswer = [
          {'email': 'new@x.com', 'link': 'https://optimizer.axisoptic.com/?invite=abc'}
        ];
        await t.tap(find.byTooltip('Share'));
        await t.pumpAndSettle();
        await t.enterText(find.widgetWithText(TextField, 'Email address'), 'New@x.com, bad');
        await t.testTextInput.receiveAction(TextInputAction.done);
        await t.pump();
        expect(find.text('new@x.com'), findsOneWidget);
        expect(find.textContaining('doesn’t look like an email'), findsOneWidget);
        await t.enterText(find.widgetWithText(TextField, 'Email address'), '');
        await t.tap(find.text('Can view').last);
        await t.pumpAndSettle();
        await t.tap(find.text('Can edit').last);
        await t.pumpAndSettle();
        await t.tap(find.widgetWithText(FilledButton, 'Save'));
        await t.pumpAndSettle();
        expect(store.called['setTripPeople'], {'tripId': 't', 'people': [{'email': 'new@x.com', 'role': 'editor'}]});
        // Someone not on Optimizer yet: their link, to send.
        expect(find.textContaining('Send new@x.com their invitation'), findsOneWidget);
      });

      testWidgets('each entry shows who can see it, in the same place, and can differ', (t) async {
        final store = await mine(t, items: [item('a', TripItemKind.activity, dep, arr, title: 'Surprise')]);
        await t.tap(find.descendant(of: find.byType(TripItinerary), matching: find.text('Surprise')));
        await t.pumpAndSettle();
        expect(find.text('People'), findsOneWidget);
        expect(t.getRect(find.text('People')).top, greaterThan(t.getRect(find.widgetWithText(TextField, 'Where')).bottom), reason: 'under the address');
        expect(find.text('Ann'), findsOneWidget);
        expect(find.text('bo@x.com'), findsOneWidget);
        await t.tap(find.text('Can view').last);
        await t.pumpAndSettle();
        await t.tap(find.text('Can’t see').last);
        await t.pumpAndSettle();
        expect(find.text('Just for this entry'), findsOneWidget);
        await t.tap(find.widgetWithText(FilledButton, 'Save'));
        await t.pumpAndSettle();
        final saved = store.trips.single.items.single;
        expect(saved.access, {'bo@x.com': 'none'});
        expect(store.trips.single.peopleOn(saved).map((p) => p.email), ['ann@x.com'], reason: 'Bo can’t see it');
        final back = TripItem.fromJson(saved.toJson());
        expect(back.access, {'bo@x.com': 'none'});
      });

      testWidgets('setting it back to what they have on the trip clears the difference', (t) async {
        final store = await mine(t, items: [
          TripItem(id: 'a', kind: TripItemKind.activity, title: 'X', start: dep, end: arr, access: const {'bo@x.com': 'none'}),
        ]);
        await t.tap(find.descendant(of: find.byType(TripItinerary), matching: find.text('X')));
        await t.pumpAndSettle();
        await t.tap(find.text('Can’t see'));
        await t.pumpAndSettle();
        await t.tap(find.text('Can view').last);
        await t.pumpAndSettle();
        await t.tap(find.widgetWithText(FilledButton, 'Save'));
        await t.pumpAndSettle();
        expect(store.trips.single.items.single.access, isEmpty);
      });

      testWidgets('with nobody on it, an entry says only you', (t) async {
        await open(t);
        await add(t, 'Something to do');
        expect(find.textContaining('Only you can see this'), findsOneWidget);
      });

      testWidgets('viewers can’t change anything: no +, and an entry just opens to read', (t) async {
        final store = await theirs(t, 'viewer', raw: [rawItem('a', 'Dinner at https://x.com', 'viewer')]);
        expect(find.byTooltip('Add to trip'), findsNothing);
        expect(find.byTooltip('Share'), findsNothing);
        expect(find.textContaining('Shared by Sam, you can view'), findsOneWidget);
        await t.tap(find.descendant(of: find.byType(TripItinerary), matching: find.textContaining('Dinner')));
        await t.pumpAndSettle();
        expect(find.textContaining('You can view this'), findsOneWidget);
        expect(find.text('Owner'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Save'), findsNothing);
        await t.tap(find.text('Close'));
        await t.pumpAndSettle();
        // Nor by clicking the calendar.
        final heading = t.getRect(find.descendant(of: find.byType(TripBoard), matching: find.text('Dec 21')));
        await t.tapAt(Offset(heading.left + 30, heading.bottom + 300));
        await t.pumpAndSettle();
        expect(find.text('Add an activity'), findsNothing);
        expect(store.called, isEmpty);
      });

      testWidgets('an editor’s changes go through the server, not into someone else’s data', (t) async {
        final store = await theirs(t, 'editor', raw: [rawItem('a', 'Dinner', 'editor')]);
        await t.tap(find.descendant(of: find.byType(TripItinerary), matching: find.text('Dinner')));
        await t.pumpAndSettle();
        await t.enterText(find.widgetWithText(TextField, 'Name'), 'Late dinner');
        await t.tap(find.widgetWithText(FilledButton, 'Save'));
        await t.pumpAndSettle();
        final sent = store.called['saveSharedItem']!;
        expect(sent['shareId'], 'share1');
        expect((sent['item'] as Map)['title'], 'Late dinner');
        expect((sent['item'] as Map)['start'], dep.millisecondsSinceEpoch, reason: 'in a form the server takes');
        expect(find.descendant(of: find.byType(TripItinerary), matching: find.text('Late dinner')), findsOneWidget, reason: 'shown straight away');
      });

      testWidgets('an editor can be view-only on one entry', (t) async {
        await theirs(t, 'editor', raw: [rawItem('a', 'Locked', 'viewer')]);
        await t.tap(find.descendant(of: find.byType(TripItinerary), matching: find.text('Locked')));
        await t.pumpAndSettle();
        expect(find.textContaining('You can view this'), findsOneWidget);
      });

      testWidgets('you can leave a trip shared with you, but not delete it', (t) async {
        final store = await theirs(t, 'editor');
        await t.tap(find.byTooltip('Trip options'));
        await t.pumpAndSettle();
        expect(find.text('Delete trip'), findsNothing);
        await t.tap(find.text('Leave trip'));
        await t.pumpAndSettle();
        await t.tap(find.widgetWithText(FilledButton, 'Leave'));
        await t.pumpAndSettle();
        expect(store.trips, isEmpty);
      });
    });

    group('the PDF', () {
      testWidgets('has everything on it, and a stay’s both ends', (t) async {
        const home = 'America/Chicago', la = 'America/Los_Angeles';
        DateTime w(String z, int day, int h, [int m = 0]) => fromWall(DateTime.utc(2026, 12, day, h, m), z);
        final trip = Trip(id: 'p', title: 'West Coast — “Winter”', destination: 'California', zone: home, how: TripHow.fly, start: DateTime(2026, 12, 20), end: DateTime(2026, 12, 22), notes: 'Bring a coat. https://weather.com/la', links: const [TripLink(url: 'https://maps.google.com/x')], items: [
          TripItem(id: 'c', kind: TripItemKind.commute, title: 'Drive to Dallas Fort Worth', start: w(home, 20, 5), end: w(home, 20, 6, 15), zone: home, endZone: home, location: 'DFW', commute: {'from': '9830 Great Hall Ln, Frisco, TX 75035, USA', 'to': 'DFW Airport, 2400 Aviation Dr, Dallas, TX', 'minutes': 60, 'meters': 60000, 'route': 'TX-121 S', 'stops': [{'place': 'Buc-ee’s, 1550 Lone Star Pkwy, Texas', 'minutes': 15}]}),
          TripItem(id: 'f', kind: TripItemKind.flight, title: 'AA 1234 · DFW – LAX', start: w(home, 20, 8, 5), end: w(la, 20, 9, 30), zone: home, endZone: la, confirmation: 'ABC123', flight: {'number': 'AA 1234', 'airline': 'American Airlines', 'aircraft': 'Boeing 737-800', 'departure': {'iata': 'DFW', 'name': 'Dallas Fort Worth', 'terminal': 'D', 'gate': 'D12'}, 'arrival': {'iata': 'LAX', 'name': 'Los Angeles', 'baggageBelt': '4'}}),
          TripItem(id: 'r', kind: TripItemKind.rental, title: 'Hertz', start: w(la, 20, 10, 30), end: w(la, 22, 9), zone: la, endZone: la, location: 'LAX', confirmation: 'H99', commute: {'from': '9000 Airport Blvd, Los Angeles, CA', 'to': '9000 Airport Blvd, Los Angeles, CA', 'car': 'Midsize SUV'}),
          TripItem(id: 's', kind: TripItemKind.stay, title: 'The Line Hotel', start: w(la, 20, 15), end: w(la, 22, 8), zone: la, endZone: la, location: 'The Line Hotel, 3515 Wilshire Blvd, Los Angeles, CA 90010', notes: 'Room booked at https://booking.com/line', confirmation: 'L55'),
          TripItem(id: 'e', kind: TripItemKind.food, title: 'Chick-fil-A', start: w(la, 21, 12), end: w(la, 21, 12), zone: la),
          TripItem(id: 'a', kind: TripItemKind.activity, title: 'Griffith Observatory', start: w(la, 21, 18), end: w(la, 21, 20), zone: la, location: 'Griffith Observatory, 2800 E Observatory Rd, Los Angeles, CA 90027'),
        ]);
        final bytes = await t.runAsync(() => tripPdf(trip));
        expect(bytes, isNotNull);
        expect(String.fromCharCodes(bytes!.take(5)), '%PDF-');
        expect(bytes.length, greaterThan(5000));
        final out = const String.fromEnvironment('PREVIEW_OUT').isNotEmpty ? const String.fromEnvironment('PREVIEW_OUT') : Platform.environment['PREVIEW_OUT'];
        if (out != null) await t.runAsync(() => File('$out/trip.pdf').writeAsBytes(bytes));
      });

      testWidgets('an empty trip still makes one', (t) async {
        Object? failed;
        final bytes = await t.runAsync(() => tripPdf(Trip(id: 'p', title: 'Empty', start: DateTime(2026, 12, 20), end: DateTime(2026, 12, 22))).catchError((Object e, StackTrace s) {
              failed = '$e\n$s';
              throw e;
            }));
        expect(failed, isNull);
        expect(String.fromCharCodes(bytes!.take(5)), '%PDF-');
      });
    });

    group('rental cars', () {
      testWidgets('pick up and drop off, each its own entry on the line', (t) async {
        final store = await open(t);
        final places = FakePlaces(const [(id: 'h', text: 'Hertz, Love Field, Dallas, TX, USA', main: 'Hertz', secondary: 'Love Field, Dallas, TX, USA')]);
        Places.instance = places;
        addTearDown(() => Places.instance = Places());
        await add(t, 'Rental car');
        expect(find.text('Add a rental car'), findsOneWidget);
        await t.enterText(find.widgetWithText(TextField, 'Rental company'), 'Hertz');
        await t.enterText(find.widgetWithText(TextField, 'Confirmation number'), 'abc123');
        await t.enterText(find.widgetWithText(TextField, 'Car type'), 'Midsize SUV');
        await pick(t, 'Pick-up location', 'Hertz');
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        final r = store.trips.single.items.single;
        expect([r.kind, r.title, r.confirmation, r.commute!['car'], r.commute!['from'], r.commute!['to']],
            [TripItemKind.rental, 'Hertz', 'abc123', 'Midsize SUV', 'Hertz, Love Field, Dallas, TX, USA', 'Hertz, Love Field, Dallas, TX, USA']);
        final line = find.byType(TripItinerary);
        expect(find.descendant(of: line, matching: find.textContaining('Pick up at')), findsOneWidget);
        expect(find.descendant(of: line, matching: find.textContaining('Drop off at')), findsOneWidget);
        final board = find.byType(TripBoard);
        final ribbon = t.getRect(find.descendant(of: board, matching: find.text('Hertz')));
        expect(ribbon.bottom, lessThan(t.getRect(find.descendant(of: board, matching: find.text('10 AM'))).top + 500));
        // Read back whole.
        final back = TripItem.fromJson(r.toJson());
        expect([back.kind, back.confirmation], [TripItemKind.rental, 'abc123']);
      });

      testWidgets('a different drop-off shows where you’re leaving it, and is offered later', (t) async {
        final store = await open(t);
        await add(t, 'Rental car');
        await t.enterText(find.widgetWithText(TextField, 'Pick-up location'), 'Dallas');
        await t.enterText(find.widgetWithText(TextField, 'Drop-off location, if different'), 'Austin');
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        final line = find.byType(TripItinerary);
        expect(find.descendant(of: line, matching: find.text('Dallas', findRichText: true)), findsOneWidget);
        expect(find.descendant(of: line, matching: find.text('Austin', findRichText: true)), findsOneWidget);
        expect(store.trips.single.savedPlaces.map((p) => p.text), containsAll(['Dallas', 'Austin']));
        expect(store.trips.single.items.single.title, 'Rental car');
        // Opening it again, the drop-off is still there.
        await t.tap(find.descendant(of: line, matching: find.textContaining('Drop off at')));
        await t.pumpAndSettle();
        expect(t.widget<TextField>(find.widgetWithText(TextField, 'Drop-off location, if different')).controller!.text, 'Austin');
      });
    });

    group('food, colors and days', () {
      testWidgets('food is on the list, and just needs a name', (t) async {
        final store = await open(t);
        await add(t, 'Food');
        expect(find.text('Add food'), findsOneWidget);
        await t.enterText(find.widgetWithText(TextField, 'Name'), 'Chick-fil-A');
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        final f = store.trips.single.items.single;
        expect([f.kind, f.title, f.location], [TripItemKind.food, 'Chick-fil-A', '']);
        expect(wallOf(f.start, '').hour, 12, reason: 'around lunchtime');
        final back = TripItem.fromJson(f.toJson());
        expect(back.kind, TripItemKind.food);
      });

      test('every type has its own color', () {
        final colors = TripItemKind.values.map((k) => k.color.toARGB32()).toSet();
        expect(colors.length, TripItemKind.values.length);
      });

      testWidgets('a calendar tile takes its type’s color', (t) async {
        await open(t, items: [item('f', TripItemKind.food, dep, arr, title: 'Tacos'), item('h', TripItemKind.flight, dep.add(const Duration(days: 1)), arr.add(const Duration(days: 1)), title: 'Home')]);
        Color fill(String title) {
          final m = find.ancestor(of: find.descendant(of: find.byType(TripBoard), matching: find.text(title)), matching: find.byType(Material)).first;
          return t.widget<Material>(m).color!;
        }

        expect(fill('Tacos'), isNot(fill('Home')));
        expect(fill('Tacos').r, greaterThan(fill('Tacos').b), reason: 'rose, not blue');
      });

      testWidgets('each day has a band, and a number', (t) async {
        await open(t, items: [
          item('a', TripItemKind.activity, DateTime(2026, 12, 20, 10), DateTime(2026, 12, 20, 11), title: 'One'),
          item('b', TripItemKind.activity, DateTime(2026, 12, 22, 10), DateTime(2026, 12, 22, 11), title: 'Two'),
        ]);
        expect(find.text('Day 1'), findsOneWidget);
        expect(find.text('Day 3'), findsOneWidget);
        expect(t.getTopLeft(find.text('Day 3')).dy, greaterThan(t.getBottomLeft(find.descendant(of: find.byType(TripItinerary), matching: find.text('One'))).dy));
      });
    });

    group('the + button', () {
      for (final (name, size) in const [('a laptop', Size(1500, 900)), ('a small window', Size(820, 700))]) {
        testWidgets('on $name the buttons sit right after the title, + first', (t) async {
          await open(t, size: size);
          double left(String tip) => t.getTopLeft(find.byTooltip(tip)).dx;
          final title = t.getTopRight(find.text('Tokyo')).dx, subtitle = t.getTopRight(find.textContaining('Japan')).dx;
          final plus = left('Add to trip');
          expect(plus, greaterThan(subtitle));
          expect(plus - (title > subtitle ? title : subtitle), lessThan(60), reason: 'right beside it, not across the page');
          expect(left('Links and notes'), greaterThan(plus));
          expect(left('Download PDF'), greaterThan(left('Links and notes')));
          expect(left('Share'), greaterThan(left('Download PDF')));
          expect(left('Trip options'), greaterThan(left('Share')));
        });
      }

      testWidgets('a very long name shrinks rather than pushing the buttons off', (t) async {
        final store = await open(t, size: const Size(360, 640));
        store.trips = [store.trips.single.copyWith(title: 'A very very very long name for a trip to somewhere far away')];
        store.notifyListeners();
        await t.pump();
        expect(t.getTopRight(find.byTooltip('Trip options')).dx, lessThanOrEqualTo(360));
        expect(t.takeException(), isNull);
      });

      testWidgets('lists everything you can add', (t) async {
        await open(t);
        await t.tap(find.byTooltip('Add to trip'));
        await t.pumpAndSettle();
        for (final label in ['Flight', 'Car ride', 'Rental car', 'Other travel', 'Place to stay', 'Food', 'Something to do']) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
        expect(t.takeException(), isNull);
      });

      testWidgets('on a road trip, the first car ride is the main drive, then just rides', (t) async {
        final store = await open(t, how: TripHow.drive);
        store.commute = {'minutes': 60, 'meters': 1000, 'predicted': true};
        await add(t, 'Car ride');
        expect(find.text('Add a drive'), findsOneWidget);
        await t.tap(find.byTooltip('Back'));
        await t.pumpAndSettle();
        expect(find.text('Add the drive'), findsOneWidget);
      });

      testWidgets('fits a small phone', (t) async {
        await open(t, size: const Size(360, 640));
        await t.tap(find.byTooltip('Add to trip'));
        await t.pumpAndSettle();
        expect(find.text('Something to do'), findsOneWidget);
        expect(t.takeException(), isNull);
      });
    });

    group('the calendar', () {
      final hotel = item('s', TripItemKind.stay, DateTime(2026, 12, 20, 15), DateTime(2026, 12, 23, 11), title: 'Hotel');

      testWidgets('a panel for each day, starting at the trip’s first', (t) async {
        await open(t, items: [flight]);
        expect(find.descendant(of: find.byType(TripBoard), matching: find.text('Dec 20')), findsOneWidget);
        expect(find.descendant(of: find.byType(TripBoard), matching: find.text('Dec 27')), findsOneWidget);
      });

      testWidgets('a stay runs across the top, over the days', (t) async {
        await open(t, items: [hotel, item('a', TripItemKind.activity, DateTime(2026, 12, 21, 10), DateTime(2026, 12, 21, 12), title: 'Museum')]);
        final board = find.byType(TripBoard);
        final ribbon = t.getRect(find.descendant(of: board, matching: find.text('Hotel')));
        final tile = t.getRect(find.descendant(of: board, matching: find.text('Museum')));
        expect(ribbon.bottom, lessThan(tile.top));
        await t.tap(find.descendant(of: board, matching: find.text('Hotel')));
        await t.pumpAndSettle();
        expect(find.text('Delete stay'), findsOneWidget);
      });

      testWidgets('things at the same time sit side by side', (t) async {
        await open(t, items: [
          item('a', TripItemKind.activity, DateTime(2026, 12, 21, 10), DateTime(2026, 12, 21, 12), title: 'Museum'),
          item('b', TripItemKind.activity, DateTime(2026, 12, 21, 11), DateTime(2026, 12, 21, 13), title: 'Lunch'),
        ]);
        final board = find.byType(TripBoard);
        final a = t.getRect(find.descendant(of: board, matching: find.text('Museum')));
        final b = t.getRect(find.descendant(of: board, matching: find.text('Lunch')));
        expect(a.right, lessThanOrEqualTo(b.left));
      });

      testWidgets('a drive past midnight shows on both days', (t) async {
        await open(t, items: [item('d', TripItemKind.commute, DateTime(2026, 12, 20, 22), DateTime(2026, 12, 21, 3), title: 'Night drive', commute: {})]);
        expect(find.descendant(of: find.byType(TripBoard), matching: find.text('Night drive')), findsNWidgets(2));
        expect(t.takeException(), isNull);
      });

      testWidgets('hovering doesn’t change a tile’s size', (t) async {
        await open(t, items: [item('a', TripItemKind.activity, DateTime(2026, 12, 21, 10), DateTime(2026, 12, 21, 12), title: 'Museum')]);
        final tile = find.descendant(of: find.byType(TripBoard), matching: find.text('Museum'));
        final before = t.getRect(tile);
        final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: t.getCenter(tile));
        await t.pump(const Duration(milliseconds: 300));
        expect(t.getRect(tile), before);
        await mouse.removePointer();
      });

      testWidgets('clicking an empty spot adds something at that time', (t) async {
        await open(t, items: [flight]);
        final heading = t.getRect(find.descendant(of: find.byType(TripBoard), matching: find.text('Dec 21')));
        await t.tapAt(Offset(heading.left + 30, heading.bottom + 300));
        await t.pumpAndSettle();
        expect(find.text('Add an activity'), findsOneWidget);
      });
    });

    testWidgets('looking up a flight fills it in', (t) async {
      final store = await open(t);
      store.flights = [dfwToLax(dep, arr)];
      await add(t, 'Flight');
      await t.enterText(find.widgetWithText(TextField, 'Flight number'), 'aa1234');
      await t.tap(find.text('Look up flight'));
      await t.pumpAndSettle();
      expect(find.text('American Airlines · AA 1234'), findsOneWidget);
      expect(find.textContaining('Gate D12'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'From'), findsNothing, reason: 'nothing left to fill in');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      final saved = store.trips.single.items.single;
      expect(saved.start, dep);
      expect(saved.end, arr);
      expect(saved.title, 'AA 1234 · DFW – LAX');
      expect(saved.departure.localTime, DateTime(2026, 12, 20, 8, 5));
      expect(saved.departure.gate, 'D12');
    });

    testWidgets('with no flight service, you can still type a flight in', (t) async {
      final store = await open(t);
      store.flightError = Exception('Flight lookup isn’t set up yet, so fill in the details below.');
      await add(t, 'Flight');
      await t.enterText(find.widgetWithText(TextField, 'Flight number'), 'UA 9');
      await t.tap(find.text('Look up flight'));
      await t.pumpAndSettle();
      expect(find.textContaining('isn’t set up yet'), findsOneWidget);
      await t.enterText(find.widgetWithText(TextField, 'From'), 'sfo');
      await t.enterText(find.widgetWithText(TextField, 'To'), 'jfk');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      final saved = store.trips.single.items.single;
      expect(saved.title, 'UA 9 · SFO – JFK');
      expect(saved.departure.time, saved.start);
    });

    testWidgets('saving a looked-up flight unchanged keeps its airport clocks', (t) async {
      final store = await open(t, items: [flight]);
      await t.tap(find.text('AA 1234'));
      await t.pumpAndSettle();
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(store.trips.single.items.single.departure.localTime, DateTime(2026, 12, 20, 8, 5), reason: 'unchanged keeps it');
    });

    testWidgets('a commute to the airport asks Google, arriving two hours ahead', (t) async {
      final store = await open(t, items: [
        flight,
        item('old', TripItemKind.commute, dep.subtract(const Duration(days: 30)), dep.subtract(const Duration(days: 30)), commute: {'from': '12 Home St', 'to': 'Somewhere'}),
      ]);
      store.commute = {'minutes': 45, 'meters': 40000, 'predicted': true};
      await t.tap(find.text('AA 1234'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('Ride to the airport'));
      await t.tap(find.text('Ride to the airport'));
      await t.pumpAndSettle();
      // It starts from where you last left from, and asks straight away.
      expect(store.asked.single['from'], '12 Home St');
      expect(store.asked.single['to'], contains('Dallas Fort Worth'));
      expect(store.asked.single['arriveBy'], dep.subtract(const Duration(hours: 2)));
      expect(find.textContaining('From Google, for that time of that day'), findsOneWidget);
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      final c = store.trips.single.items.firstWhere((i) => i.commute?['flightId'] == 'f');
      expect(c.end, dep.subtract(const Duration(hours: 2)));
      expect(c.start, dep.subtract(const Duration(hours: 2, minutes: 45)));
      expect(c.commute!['direction'], 'to');
      expect(find.text('Ride to the airport'), findsNothing, reason: 'it has one now');
      expect(find.text('Ride from the airport'), findsOneWidget);
    });

    testWidgets('changing a place it knows asks Google again on saving', (t) async {
      final store = await open(t);
      final places = FakePlaces();
      Places.instance = places;
      addTearDown(() => Places.instance = Places());
      store.commute = {'minutes': 20, 'meters': 1000, 'predicted': true};
      await add(t, 'Car ride');
      await pick(t, 'Starting from', 'Riverside Diner');
      await pick(t, 'Final destination', 'Central Library');
      await t.pump(const Duration(milliseconds: 500));
      await t.pumpAndSettle();
      expect(store.asked.length, 1, reason: 'both are real places, so it just asks');
      await pick(t, 'Final destination', 'Riverside Diner');
      store.commute = {'minutes': 50, 'meters': 1000, 'predicted': true};
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(store.asked.length, 2);
      expect(store.trips.single.items.single.commute!['minutes'], 50);
    });

    testWidgets('if Google can’t answer, it says so and takes typed minutes', (t) async {
      final store = await open(t);
      store.commuteError = Exception('Google travel times aren’t turned on yet, so type the minutes in for now.');
      await add(t, 'Car ride');
      await pick(t, 'Starting from', 'Home');
      await pick(t, 'Final destination', 'Hotel');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(store.trips.single.items, isEmpty, reason: 'no time known yet');
      expect(find.textContaining('type how long it takes'), findsOneWidget);
      await t.enterText(find.widgetWithText(TextField, 'Minutes'), '30');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      final c = store.trips.single.items.single;
      expect(c.end.difference(c.start), const Duration(minutes: 30));
      expect(c.commute!['fromGoogle'], false);
    });

    testWidgets('deleting asks first', (t) async {
      final store = await open(t, items: [item('a', TripItemKind.activity, dep, arr, title: 'Museum')]);
      await t.tap(find.descendant(of: find.byType(TripItinerary), matching: find.text('Museum')));
      await t.pumpAndSettle();
      await t.tap(find.text('Delete activity'));
      await t.pumpAndSettle();
      expect(store.trips.single.items, isNotEmpty);
      await t.tap(find.widgetWithText(FilledButton, 'Delete'));
      await t.pumpAndSettle();
      expect(store.trips.single.items, isEmpty);
    });

    for (final size in const [Size(1400, 900), Size(1100, 620), Size(900, 700), Size(412, 915), Size(360, 640)]) {
      testWidgets('fits ${size.width.toInt()}x${size.height.toInt()}', (t) async {
        await open(t, size: size, items: [
          flight,
          item('c', TripItemKind.commute, dep.subtract(const Duration(hours: 3)), dep.subtract(const Duration(hours: 2)), title: 'Drive to a very long airport name indeed', commute: {'from': '12 Home St', 'minutes': 60, 'predicted': true}),
          item('s', TripItemKind.stay, DateTime(2026, 12, 20, 15), DateTime(2026, 12, 27, 11), title: 'Hotel'),
          item('a', TripItemKind.activity, DateTime(2026, 12, 21, 10), DateTime(2026, 12, 21, 12), title: 'Museum'),
        ]);
        expect(t.takeException(), isNull);
      });
    }

    group('a new trip starts with Fly, Drive or Other', () {
      Future<FakeTrips> choose(WidgetTester t, String? how, {Size size = const Size(1400, 1000), bool stayInDetails = false}) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final store = FakeTrips([]);
        await t.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: TripsPage(store: store, active: true))));
        await t.tap(find.text('New trip'));
        await t.pumpAndSettle();
        if (how != null) {
          await t.tap(find.text(how));
          await t.pumpAndSettle();
          if (!stayInDetails) {
            await t.tap(find.text('Done'));
            await t.pumpAndSettle();
          }
        }
        return store;
      }

      testWidgets('three big buttons take the whole screen', (t) async {
        final store = await choose(t, null);
        final fly = t.getRect(find.ancestor(of: find.text('Fly'), matching: find.byType(Material)).first);
        final drive = t.getRect(find.ancestor(of: find.text('Drive'), matching: find.byType(Material)).first);
        final other = t.getRect(find.ancestor(of: find.text('Other'), matching: find.byType(Material)).first);
        expect(fly.height, greaterThan(800));
        expect(fly.width, greaterThan(400));
        expect([fly.right < drive.left, drive.right < other.left], [true, true], reason: 'side by side');
        expect(find.textContaining('Spaceship'), findsOneWidget);
        expect(store.trips, isEmpty, reason: 'nothing’s made until you answer');
        await t.tap(find.byTooltip('Back'));
        await t.pumpAndSettle();
        expect(store.trips, isEmpty);
        expect(find.text('New trip'), findsOneWidget);
      });

      for (final size in const [Size(360, 560), Size(412, 915), Size(800, 400)]) {
        testWidgets('they fit ${size.width.toInt()}x${size.height.toInt()}', (t) async {
          await choose(t, null, size: size);
          expect(t.takeException(), isNull);
        });
      }

      testWidgets('on a phone they stack', (t) async {
        await choose(t, null, size: const Size(412, 915));
        final fly = t.getRect(find.ancestor(of: find.text('Fly'), matching: find.byType(Material)).first);
        final drive = t.getRect(find.ancestor(of: find.text('Drive'), matching: find.byType(Material)).first);
        expect(fly.bottom, lessThan(drive.top));
        expect(fly.width, greaterThan(370));
      });

      testWidgets('answering opens the trip’s page, with its name ready to type over', (t) async {
        final store = await choose(t, 'Fly', stayInDetails: true);
        expect(store.opened?.how, TripHow.fly);
        await t.pump();
        final name = t.widget<TextField>(find.widgetWithText(TextField, 'Trip name'));
        expect(name.controller!.selection.textInside(name.controller!.text), 'New flight');
        await t.tap(find.text('Done'));
        await t.pumpAndSettle();
        expect(find.byType(TripItinerary), findsOneWidget);
        expect(find.byType(TripBoard), findsOneWidget);
        expect(find.text('Add your flight'), findsOneWidget);
      });

      testWidgets('flying: one flight, then another', (t) async {
        final store = await choose(t, 'Fly');
        store.flights = [dfwToLax(dep, arr)];
        await add(t, 'Flight');
        await t.enterText(find.widgetWithText(TextField, 'Flight number'), 'aa1234');
        await t.tap(find.text('Look up flight'));
        await t.pumpAndSettle();
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        expect(store.opened!.items.single.departure.gate, 'D12');
        expect(find.text('Add your flight'), findsNothing);
      });

      testWidgets('driving: no "Where to", just the main drive’s start and destination', (t) async {
        final store = await choose(t, 'Drive');
        store.commute = {'minutes': 326, 'meters': 484000, 'predicted': true};
        await add(t, 'Car ride');
        expect(find.text('Add a drive'), findsOneWidget);
        await pick(t, 'Starting from', '9830 Great Hall Ln');
        await pick(t, 'Final destination', 'Alamodome, 100 Montana St, San Antonio, TX');
        await t.tap(find.text('Estimate the drive'));
        await t.pumpAndSettle();
        final leave = store.asked.single['leaveAt'] as DateTime;
        expect(leave.hour, 9);
        expect(leave, DateTime(store.opened!.start.year, store.opened!.start.month, store.opened!.start.day, 9));
        expect(find.textContaining('From Google, for that time of that day'), findsOneWidget);
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        expect(store.asked.length, 1, reason: 'already asked for exactly this');
        final drive = store.opened!.mainDrive!;
        expect(drive.title, 'Drive to Alamodome');
        expect(drive.end.difference(drive.start), const Duration(minutes: 326));
        expect(store.opened!.destination, 'Alamodome', reason: 'the trip’s destination comes from the drive');
        // The itinerary now has the drive, and where it goes.
        expect(find.text('Add the drive'), findsNothing);
        expect(find.descendant(of: find.byType(TripItinerary), matching: find.text('Drive to Alamodome')), findsOneWidget);
        expect(find.text('9830 Great Hall Ln\uFFFCAlamodome', findRichText: true), findsOneWidget);
      });

      group('the travel time', () {
        Future<FakeTrips> drive(WidgetTester t, {Size size = const Size(1400, 1000)}) async {
          final store = await choose(t, 'Drive', size: size);
          store.commute = {'minutes': 332, 'meters': 484000, 'predicted': true};
          await add(t, 'Car ride');
          await pick(t, 'Starting from', '9830 Great Hall Ln, Frisco');
          await pick(t, 'Final destination', 'Alamodome, San Antonio');
          return store;
        }

        Future<void> estimate(WidgetTester t) async {
          await t.tap(find.text('Estimate the drive'));
          await t.pumpAndSettle();
        }

        testWidgets('leave at a time: it says when you arrive, and how long in hours and minutes', (t) async {
          final store = await drive(t);
          await estimate(t);
          final leave = store.asked.last['leaveAt'] as DateTime;
          expect(store.asked.last['arriveBy'], isNull);
          expect(find.text('5 h 32 min'), findsOneWidget);
          expect(find.text('301 mi'), findsOneWidget);
          expect(find.text('LEAVE'), findsOneWidget);
          expect(find.text('ARRIVE'), findsOneWidget);
          expect(find.textContaining(RegExp(r'^9:00\sAM$')), findsNWidgets(2), reason: 'the leaving time you set, on its button and the card');
          expect(find.textContaining(RegExp(r'^2:32\sPM$')), findsOneWidget, reason: 'the arrival worked out from it');
          expect(find.textContaining('How long'), findsNothing, reason: 'no raw minutes box');
          await t.tap(find.text('Save'));
          await t.pumpAndSettle();
          expect(store.opened!.mainDrive!.start, leave);
          expect(store.opened!.mainDrive!.end, leave.add(const Duration(minutes: 332)));
        });

        testWidgets('arrive by a time: it says when to leave, and asks about that arrival', (t) async {
          final store = await drive(t);
          await estimate(t);
          await t.tap(find.text('Arrive by'));
          await t.pump();
          // Switching keeps the journey where it was: now you've set 2:32 PM, arriving.
          await t.pump(const Duration(milliseconds: 400));
          await t.pumpAndSettle();
          final arrive = store.asked.last['arriveBy'] as DateTime;
          expect(store.asked.last['leaveAt'], isNull);
          expect([arrive.hour, arrive.minute], [14, 32]);
          expect(find.textContaining(RegExp(r'^9:00\sAM$')), findsOneWidget, reason: 'when to leave, worked out from it');
          await t.tap(find.text('Save'));
          await t.pumpAndSettle();
          expect(store.opened!.mainDrive!.end, arrive);
          expect(store.opened!.mainDrive!.start, arrive.subtract(const Duration(minutes: 332)));
          expect(store.opened!.mainDrive!.commute?['timing'], 'arrive');
        });

        testWidgets('choosing a new time asks again by itself', (t) async {
          final store = await drive(t);
          await estimate(t);
          expect(store.asked.length, 1);
          await t.tap(find.textContaining(RegExp(r'^9:00\sAM$')).first);
          await t.pumpAndSettle();
          await t.tap(find.text('OK'));
          await t.pump();
          expect(store.asked.length, 1, reason: 'the same time isn’t a change');
          await t.pump(const Duration(seconds: 1));
          await t.pumpAndSettle();
          expect(store.asked.length, 1);
        });

        testWidgets('an answer for what you’ve since changed isn’t used', (t) async {
          final store = await drive(t);
          final answer = Completer<Map>();
          store.commuteWait = answer;
          await t.tap(find.text('Estimate the drive'));
          await t.pump();
          await t.tap(find.text('Arrive by'));
          await t.pump();
          store.commuteWait = null;
          answer.complete({'minutes': 999, 'meters': 1, 'predicted': true});
          await t.pump();
          await t.pump(const Duration(milliseconds: 400));
          await t.pumpAndSettle();
          expect(find.textContaining('16 h'), findsNothing);
          expect(store.asked.last['arriveBy'], isNotNull);
          expect(find.text('5 h 32 min'), findsOneWidget);
        });

        testWidgets('a time that’s passed says what it’s an estimate of', (t) async {
          final store = await drive(t);
          store.commute = {'minutes': 332, 'meters': 484000, 'predicted': false};
          await estimate(t);
          expect(find.textContaining('same time next week'), findsOneWidget);
        });

        testWidgets('you can type your own, in hours and minutes, and go back to Google’s', (t) async {
          final store = await drive(t);
          await estimate(t);
          await t.tap(find.text('Type it yourself'));
          await t.pump();
          await t.enterText(find.widgetWithText(TextField, 'Hours'), '6');
          await t.enterText(find.widgetWithText(TextField, 'Minutes'), '5');
          await t.pump();
          expect(find.text('6 h 5 min'), findsOneWidget);
          expect(find.text('Your own estimate.'), findsOneWidget);
          await t.tap(find.text('Estimate the drive'));
          await t.pumpAndSettle();
          expect(find.text('5 h 32 min'), findsOneWidget);
          expect(store.asked.length, 2);
        });

        group('choosing a route', () {
          const routes = [
            {'name': 'I-35 E', 'minutes': 332, 'meters': 484000},
            {'name': 'US-281 S', 'minutes': 340, 'meters': 508000},
          ];

          testWidgets('picking another way changes the times, for the day you set', (t) async {
            final store = await drive(t);
            store.commute = {'minutes': 332, 'meters': 484000, 'predicted': true, 'routes': routes};
            await estimate(t);
            expect(find.text('via I-35 E'), findsOneWidget);
            expect(find.text('5 h 40 min · 316 mi'), findsOneWidget);
            expect(find.textContaining(RegExp(r'^2:32\sPM$')), findsOneWidget);
            await t.tap(find.text('via US-281 S'));
            await t.pump();
            expect(find.textContaining(RegExp(r'^2:40\sPM$')), findsOneWidget);
            expect(find.text('316 mi'), findsOneWidget);
            expect(store.asked.length, 1, reason: 'Google already said');
            await t.tap(find.text('Save'));
            await t.pumpAndSettle();
            final d = store.opened!.mainDrive!;
            expect(d.end.difference(d.start), const Duration(minutes: 340));
            expect(d.commute!['route'], 'US-281 S');
            // Opening it again keeps the choice, and the others to change to.
            await t.tap(find.text('Drive to Alamodome').first);
            await t.pumpAndSettle();
            expect(find.text('via I-35 E'), findsOneWidget);
            await t.tap(find.text('via I-35 E'));
            await t.pump();
            expect(find.textContaining(RegExp(r'^2:32\sPM$')), findsOneWidget);
          });

          testWidgets('arriving by a time: another way changes when to leave', (t) async {
            final store = await drive(t);
            store.commute = {'minutes': 332, 'meters': 484000, 'predicted': true, 'routes': routes};
            await estimate(t);
            await t.tap(find.text('Arrive by'));
            await t.pump(const Duration(milliseconds: 400));
            await t.pumpAndSettle();
            await t.tap(find.text('via US-281 S'));
            await t.pump();
            expect(find.textContaining(RegExp(r'^8:52\sAM$')), findsOneWidget);
          });

          testWidgets('your pick stays when Google asks again, if it’s still a way to go', (t) async {
            final store = await drive(t);
            store.commute = {'minutes': 332, 'meters': 484000, 'predicted': true, 'routes': routes};
            await estimate(t);
            await t.tap(find.text('via US-281 S'));
            await t.pump();
            await t.enterText(find.widgetWithText(TextField, 'Notes'), 'x');
            store.commute = {
              'minutes': 300, 'meters': 484000, 'predicted': true,
              'routes': [
                {'name': 'I-35 E', 'minutes': 300, 'meters': 484000},
                {'name': 'US-281 S', 'minutes': 310, 'meters': 508000},
              ],
            };
            await t.tap(find.text('Arrive by'));
            await t.pump(const Duration(milliseconds: 400));
            await t.pumpAndSettle();
            expect(find.text('5 h 10 min'), findsOneWidget);
          });

          testWidgets('with only one way, there’s nothing to pick', (t) async {
            final store = await drive(t);
            store.commute = {'minutes': 332, 'meters': 484000, 'predicted': true, 'routes': [routes.first]};
            await estimate(t);
            expect(find.text('via I-35 E'), findsNothing);
          });
        });

        group('stops on the way', () {
          Future<void> addStop(WidgetTester t, String place, {String? length}) async {
            await t.ensureVisible(find.text('Add a stop'));
            await t.pumpAndSettle();
            await t.tap(find.text('Add a stop'));
            await t.pump();
            final n = t.widgetList(find.byIcon(Icons.local_cafe_outlined)).length;
            if (place.isNotEmpty) await pick(t, 'Stop $n', place);
            if (length != null) {
              await t.tap(find.byTooltip('How long you’ll stop').last);
              await t.pumpAndSettle();
              await t.tap(find.text(length).last);
              await t.pumpAndSettle();
            }
          }

          testWidgets('a stop’s time counts: it shows driving, stops and when you’re at each', (t) async {
            final store = await drive(t);
            store.commute = {'minutes': 332, 'meters': 484000, 'predicted': true, 'legs': [6000, 13920]};
            await addStop(t, 'Buc-ee’s, Temple, TX');
            await estimate(t);
            expect(store.asked.last['stops'], ['Buc-ee’s, Temple, TX']);
            expect(store.asked.last['stopMinutes'], 30);
            expect(find.text('6 h 2 min'), findsOneWidget, reason: 'driving and stopping together');
            expect(find.text('5 h 32 min driving + 30 min at your stop'), findsOneWidget);
            // Leave at 9:00; the first stretch is 1 h 40 min.
            expect(find.textContaining(RegExp(r'^Buc-ee’s: 10:40\sAM \S+ – 11:10\sAM \S+$')), findsOneWidget);
            expect(find.textContaining(RegExp(r'^3:02\sPM$')), findsOneWidget, reason: 'arrival includes the stop');
            final map = t.widget<PlaceMap>(find.byType(PlaceMap));
            expect(map.via, ['Buc-ee’s, Temple, TX'], reason: 'Google knows it, so it’s on the map');
            await t.tap(find.text('Save'));
            await t.pumpAndSettle();
            final d = store.opened!.mainDrive!;
            expect(d.end.difference(d.start), const Duration(minutes: 362));
            expect(d.commute!['minutes'], 332, reason: 'driving only');
            final stop = d.stops.single;
            expect([stop.place, stop.minutes], ['Buc-ee’s, Temple, TX', 30]);
            expect(stop.at, d.start.add(const Duration(minutes: 100)));
            expect(store.opened!.tile.end, d.end);
            // On the itinerary and the calendar.
            final line = find.byType(TripItinerary);
            expect(find.descendant(of: line, matching: find.text('Buc-ee’s')), findsOneWidget);
            expect(find.descendant(of: line, matching: find.text('30 min stop')), findsOneWidget);
            expect(find.descendant(of: find.byType(TripBoard), matching: find.text('Buc-ee’s')), findsOneWidget);
            final events = store.opened!.itemEvents;
            expect(events.length, 2);
            expect(events.first.backdrop, isTrue, reason: 'the drive runs behind its stop');
            expect([events.last.title, events.last.start], ['Buc-ee’s', stop.at]);
          });

          testWidgets('arrive by: stops come out of when you leave', (t) async {
            final store = await drive(t);
            await estimate(t);
            await t.tap(find.text('Arrive by'));
            await t.pump(const Duration(milliseconds: 400));
            await t.pumpAndSettle();
            final arrive = store.asked.last['arriveBy'] as DateTime;
            await addStop(t, '', length: '1 h');
            await t.pump(const Duration(milliseconds: 400));
            await t.pumpAndSettle();
            expect(store.asked.last['stopMinutes'], 60);
            expect(store.asked.last['arriveBy'], arrive, reason: 'your arrival stays put');
            await t.tap(find.text('Save'));
            await t.pumpAndSettle();
            final d = store.opened!.mainDrive!;
            expect(d.end, arrive);
            expect(d.start, arrive.subtract(const Duration(minutes: 392)));
          });

          testWidgets('just time, with no place: no change to the route', (t) async {
            final store = await drive(t);
            await estimate(t);
            await addStop(t, '', length: '15 min');
            await t.pump(const Duration(milliseconds: 400));
            await t.pumpAndSettle();
            expect(store.asked.last['stops'], isEmpty);
            expect(find.text('5 h 47 min'), findsOneWidget);
          });

          testWidgets('leaving at a set time, changing how long doesn’t ask Google again', (t) async {
            final store = await drive(t);
            await addStop(t, '');
            await estimate(t);
            final asked = store.asked.length;
            await t.tap(find.byTooltip('How long you’ll stop'));
            await t.pumpAndSettle();
            await t.tap(find.text('1 h').last);
            await t.pump(const Duration(milliseconds: 500));
            await t.pumpAndSettle();
            expect(store.asked.length, asked);
            expect(find.text('6 h 32 min'), findsOneWidget);
          });

          testWidgets('a stop can be removed, and saved stops come back to edit', (t) async {
            final store = await drive(t);
            store.commute = {'minutes': 332, 'meters': 484000, 'predicted': true, 'legs': [6000, 7000, 6920]};
            await addStop(t, 'Waco');
            await addStop(t, 'Temple');
            await estimate(t);
            await t.tap(find.text('Save'));
            await t.pumpAndSettle();
            expect(store.opened!.mainDrive!.stops.map((s) => s.place), ['Waco', 'Temple']);
            await t.tap(find.text('Drive to Alamodome').first);
            await t.pumpAndSettle();
            expect(find.widgetWithText(TextField, 'Waco'), findsOneWidget);
            await t.tap(find.byTooltip('Remove this stop').first);
            await t.pump();
            await t.pump();
            expect(find.widgetWithText(TextField, 'Waco'), findsNothing);
            expect(find.widgetWithText(TextField, 'Temple'), findsOneWidget);
            store.commute = {'minutes': 320, 'meters': 484000, 'predicted': true, 'legs': [8000, 11200]};
            await t.tap(find.text('Save'));
            await t.pumpAndSettle();
            expect(store.asked.last['stops'], ['Temple']);
            expect(store.opened!.mainDrive!.stops.single.place, 'Temple');
            expect(t.takeException(), isNull);
          });

          testWidgets('tapping a stop on the calendar opens the drive', (t) async {
            final store = await drive(t);
            store.commute = {'minutes': 332, 'meters': 484000, 'predicted': true, 'legs': [6000, 13920]};
            await addStop(t, 'Temple, TX');
            await estimate(t);
            await t.tap(find.text('Save'));
            await t.pumpAndSettle();
            await t.tap(find.text('Temple').last);
            await t.pumpAndSettle();
            expect(find.text('Edit drive'), findsOneWidget);
          });

          for (final size in const [Size(360, 700), Size(412, 915)]) {
            testWidgets('they fit ${size.width.toInt()} wide', (t) async {
              await drive(t, size: size);
              await addStop(t, 'Temple, TX');
              await t.pumpAndSettle();
              expect(t.takeException(), isNull);
            });
          }
        });

        testWidgets('saved, it’s a tile on the trip’s calendar and sets the big tile', (t) async {
          final store = await drive(t);
          await estimate(t);
          await t.tap(find.text('Save'));
          await t.pumpAndSettle();
          final trip = store.opened!;
          final drive2 = trip.mainDrive!;
          expect(trip.itemEvents.single.start, drive2.start);
          expect(trip.itemEvents.single.end, drive2.end);
          expect(find.descendant(of: find.byType(TripBoard), matching: find.text('Drive to Alamodome')), findsOneWidget, reason: 'on the calendar');
          expect(trip.tile.start, drive2.start);
          expect(trip.tile.end, drive2.end);
        });

        for (final size in const [Size(360, 640), Size(412, 915)]) {
          testWidgets('the card fits ${size.width.toInt()} wide', (t) async {
            await drive(t, size: size);
            // Both places were picked, so it's already asked.
            await t.pump(const Duration(milliseconds: 500));
            await t.pumpAndSettle();
            await t.scrollUntilVisible(find.text('5 h 32 min'), 200, scrollable: find.byType(Scrollable).first);
            await t.pumpAndSettle();
            expect(find.text('5 h 32 min'), findsOneWidget);
            expect(t.takeException(), isNull);
          });
        }
      });

      testWidgets('driving: if Google can’t answer, it takes typed minutes', (t) async {
        final store = await choose(t, 'Drive');
        store.commuteError = Exception('Google’s Routes API is off for this project, so type the minutes in for now.');
        await add(t, 'Car ride');
        await pick(t, 'Starting from', 'Home');
        await pick(t, 'Final destination', 'Austin');
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        expect(find.textContaining('type how long it takes'), findsOneWidget);
        await t.enterText(find.widgetWithText(TextField, 'Hours'), '1');
        await t.enterText(find.widgetWithText(TextField, 'Minutes'), '45');
        await t.pump();
        expect(find.text('1 h 45 min'), findsOneWidget);
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        expect(store.opened!.mainDrive!.commute?['minutes'], 105);
      });

      testWidgets('other: however you like', (t) async {
        final store = await choose(t, 'Other');
        await add(t, 'Other travel');
        await t.enterText(find.widgetWithText(TextField, 'How are you getting there?'), 'Spaceship');
        await t.enterText(find.widgetWithText(TextField, 'To'), 'Mars, Solar System');
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        expect(store.opened!.items.single.title, 'Spaceship to Mars');
      });

      testWidgets('its details open from its title, and save as you change them', (t) async {
        final store = await choose(t, 'Fly');
        await t.tap(find.text('New flight'));
        await t.pumpAndSettle();
        await t.enterText(find.widgetWithText(TextField, 'Trip name'), '2026 State Marching Contest');
        await t.pump(const Duration(milliseconds: 600));
        expect(store.opened!.title, '2026 State Marching Contest');
        expect(find.text('2026 State Marching Contest'), findsWidgets, reason: 'the header follows');
        await t.enterText(find.widgetWithText(TextField, 'Where to'), 'San Antonio');
        await t.pump(const Duration(milliseconds: 600));
        expect(store.opened!.destination, 'San Antonio');
        await t.tap(find.byWidgetPredicate((w) => w is InkWell && w.customBorder is CircleBorder).last);
        await t.pump();
        expect(store.opened!.color, tripColors.last);
      });

      testWidgets('a road trip’s details don’t ask where to: its main drive says', (t) async {
        await choose(t, 'Drive', stayInDetails: true);
        expect(find.widgetWithText(TextField, 'Trip name'), findsOneWidget);
        expect(find.widgetWithText(TextField, 'Where to'), findsNothing);
      });

      testWidgets('a name that’s still being typed isn’t lost closing them', (t) async {
        final store = await choose(t, 'Fly', stayInDetails: true);
        await t.enterText(find.widgetWithText(TextField, 'Trip name'), 'Quick');
        await t.pump(const Duration(milliseconds: 100));
        await t.tap(find.text('Done'));
        await t.pumpAndSettle();
        expect(store.trips.single.title, 'Quick');
      });

      testWidgets('the ⋯ menu opens the details and deletes, after asking', (t) async {
        final store = await choose(t, 'Fly');
        await t.tap(find.byTooltip('Trip options'));
        await t.pumpAndSettle();
        await t.tap(find.text('Trip details'));
        await t.pumpAndSettle();
        expect(find.widgetWithText(TextField, 'Trip name'), findsOneWidget);
        await t.tap(find.text('Done'));
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('Trip options'));
        await t.pumpAndSettle();
        await t.tap(find.text('Delete trip'));
        await t.pumpAndSettle();
        expect(store.trips, isNotEmpty);
        await t.tap(find.widgetWithText(FilledButton, 'Delete'));
        await t.pumpAndSettle();
        expect(store.trips, isEmpty);
      });

      testWidgets('an older trip that never said just has the +', (t) async {
        await open(t, how: null);
        expect(find.text('Nothing planned yet'), findsOneWidget);
        expect(find.byTooltip('Add to trip'), findsOneWidget);
        expect(find.byType(FilledButton), findsNothing);
      });

      testWidgets('a phone starts on the itinerary, with the first thing to add', (t) async {
        await choose(t, 'Drive', size: const Size(412, 915));
        expect(find.text('Add the drive'), findsOneWidget);
        await t.tap(find.text('Calendar'));
        await t.pump();
        expect(find.text('Add the drive'), findsNothing);
        expect(t.takeException(), isNull);
      });
    });

    testWidgets('a stay’s address goes under its map, which is there from the start', (t) async {
      await open(t, size: const Size(1400, 900));
      await add(t, 'Place to stay');
      expect(find.text('Add a location to see it here'), findsOneWidget);
      final field = t.getRect(find.widgetWithText(TextField, 'Address'));
      final empty = t.getRect(find.ancestor(of: find.text('Add a location to see it here'), matching: find.byType(Container)).first);
      expect(field.top, greaterThan(empty.bottom));
      expect(field.left, greaterThan(t.getRect(find.widgetWithText(TextField, 'Name')).right), reason: 'on the right');
    });

    testWidgets('the list of trips, and back from one', (t) async {
      final store = await open(t, size: const Size(412, 915));
      await t.tap(find.byTooltip('All trips'));
      await t.pump();
      expect(store.openId, isNull);
      expect(find.text('New trip'), findsOneWidget);
      await t.tap(find.text('Tokyo'));
      await t.pump();
      expect(store.openId, 't');
    });
  });

  // ------ previews

  final now = DateTime.now();
  final d = DateTime(now.year, now.month, now.day);
  DateTime at(int day, int h, [int m = 0]) => d.add(Duration(days: day, hours: h, minutes: m));
  Map<String, dynamic> local(Map<String, dynamic> f, DateTime dep, DateTime arr) {
    (f['departure'] as Map)['scheduledLocal'] = dep.toIso8601String();
    (f['arrival'] as Map)['scheduledLocal'] = arr.toIso8601String();
    return f;
  }

  Trip sample() {
    final dep = at(2, 8, 5), arr = at(2, 11, 30);
    return Trip(id: 'p', title: 'Los Angeles', destination: 'California', start: at(2, 0), end: at(6, 0), items: [
      item('c', TripItemKind.commute, at(2, 5, 20), at(2, 6, 5), title: 'Drive to Dallas Fort Worth (DFW)', commute: {'from': '12 Home St', 'to': 'DFW', 'minutes': 45, 'predicted': true, 'flightId': 'f', 'direction': 'to'}),
      item('f', TripItemKind.flight, dep, arr, title: 'AA 1234 · DFW – LAX', flight: local(dfwToLax(dep, arr), dep, arr)),
      item('s', TripItemKind.stay, at(2, 15), at(6, 11), title: 'The Line Hotel'),
      item('a', TripItemKind.activity, at(3, 10), at(3, 13), title: 'Griffith Observatory'),
      item('b', TripItemKind.activity, at(3, 18), at(3, 20), title: 'Dinner with Sam'),
      item('h', TripItemKind.flight, at(6, 15), at(6, 20), title: 'AA 2 · LAX – DFW', flight: local(dfwToLax(at(6, 15), at(6, 20)), at(6, 15), at(6, 20))),
    ]);
  }

  for (final (name, size) in [('new_trip_desktop', const Size(1440, 880)), ('new_trip_phone', const Size(412, 860)), ('new_trip_small', const Size(360, 600)), ('new_trip_short', const Size(820, 420))]) {
    testWidgets(skip: skipPreview, name, (t) async {
      await t.runAsync(loadFonts);
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      final store = FakeTrips([]);
      await t.pumpWidget(MaterialApp(theme: buildTheme(), debugShowCheckedModeBanner: false,
          builder: (_, child) => RepaintBoundary(key: const ValueKey('shot'), child: child!),
          home: Scaffold(body: TripsPage(store: store, active: true))));
      await t.tap(find.text('New trip'));
      await t.pumpAndSettle();
      await shot(t, name);
      if (name == 'new_trip_desktop') {
        final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: t.getCenter(find.text('Drive')));
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        await shot(t, 'new_trip_hover');
        await mouse.removePointer();
        await t.pump(const Duration(milliseconds: 400));
      }
      t.view.reset();
    });
  }

  for (final (name, size) in [('drive_desktop', const Size(1300, 900)), ('drive_phone', const Size(412, 980))]) {
    testWidgets(skip: skipPreview, name, (t) async {
      await t.runAsync(loadFonts);
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      final store = FakeTrips([Trip(id: 'p', title: 'State Marching Contest', how: TripHow.drive, start: at(7, 0), end: at(10, 0))])
        ..openId = 'p'
        ..commute = {'minutes': 332, 'meters': 484000, 'predicted': true};
      await t.pumpWidget(MaterialApp(theme: buildTheme(), debugShowCheckedModeBanner: false,
          builder: (_, child) => RepaintBoundary(key: const ValueKey('shot'), child: child!),
          home: Scaffold(body: TripsPage(store: store, active: true))));
      await t.pump();
      await t.tap(find.text('Add the drive'));
      await t.pumpAndSettle();
      await pick(t, 'Starting from', '9830 Great Hall Ln, Frisco, TX 75035, USA');
      await pick(t, 'Final destination', 'Alamodome, 100 Montana St, San Antonio, TX 78203, USA');
      store.commute = {'minutes': 332, 'meters': 484000, 'predicted': true, 'legs': [6000, 13920]};
      if (name == 'drive_phone') {
        store.commute = {
          'minutes': 332, 'meters': 484000, 'predicted': true,
          'routes': [
            {'name': 'I-35 E', 'minutes': 332, 'meters': 484000},
            {'name': 'US-281 S and I-10 E', 'minutes': 340, 'meters': 508000},
          ],
        };
      } else {
        await t.tap(find.text('Add a stop'));
        await t.pump();
        await pick(t, 'Stop 1', 'Buc-ee’s, Temple, TX');
      }
      await t.tap(find.text('Estimate the drive'));
      await t.pumpAndSettle();
      await shot(t, name);
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 300));
      await shot(t, '${name}_saved');
      t.view.reset();
    });
  }

  for (final (name, how, size) in [('trip_new_drive', TripHow.drive, const Size(1300, 850)), ('trip_new_drive_phone', TripHow.drive, const Size(412, 915))]) {
    testWidgets(skip: skipPreview, name, (t) async {
      await t.runAsync(loadFonts);
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      final store = FakeTrips([Trip(id: 'p', title: 'State Marching Contest', how: how, start: at(7, 0), end: at(10, 0))])..openId = 'p';
      await t.pumpWidget(MaterialApp(theme: buildTheme(), debugShowCheckedModeBanner: false,
          home: RepaintBoundary(key: const ValueKey('shot'), child: Scaffold(body: TripsPage(store: store, active: true)))));
      await t.pump(const Duration(milliseconds: 300));
      await shot(t, name);
      t.view.reset();
    });
  }

  for (final (name, size) in [('trip_desktop', const Size(1500, 950)), ('trip_phone', const Size(412, 915))]) {
    testWidgets(skip: skipPreview, name, (t) async {
      await t.runAsync(loadFonts);
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      final store = FakeTrips([sample().copyWith(how: TripHow.fly)])..openId = 'p';
      await t.pumpWidget(MaterialApp(theme: buildTheme(), debugShowCheckedModeBanner: false,
          builder: (_, child) => RepaintBoundary(key: const ValueKey('shot'), child: child!),
          home: Scaffold(body: TripsPage(store: store, active: true))));
      await t.pump(const Duration(milliseconds: 300));
      await shot(t, name);
      await t.tap(find.byTooltip('Add to trip'));
      await t.pumpAndSettle();
      await shot(t, '${name}_add');
      await t.tapAt(const Offset(5, 500));
      await t.pumpAndSettle();
      if (name == 'trip_phone') {
        await t.tap(find.text('Calendar'));
        await t.pumpAndSettle();
        await shot(t, '${name}_calendar');
      }
      t.view.reset();
    });
  }

  for (final (name, size) in [('trip_zones_desktop', const Size(1500, 950)), ('trip_zones_phone', const Size(412, 915))]) {
    testWidgets(skip: skipPreview, name, (t) async {
      await t.runAsync(loadFonts);
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      const home = 'America/Chicago', phx = 'America/Phoenix', la = 'America/Los_Angeles';
      DateTime w(String z, int day, int h, [int m = 0]) => fromWall(DateTime.utc(2026, 11, day, h, m), z);
      final store = FakeTrips([
        Trip(id: 'p', title: 'West Coast', destination: 'California', zone: home, how: TripHow.drive, start: DateTime(2026, 11, 6), end: DateTime(2026, 11, 9), items: [
          TripItem(id: 'd', kind: TripItemKind.commute, title: 'Drive to Phoenix', start: w(home, 6, 6), end: w(phx, 6, 21, 30), zone: home, endZone: phx, commute: {
            'from': '9830 Great Hall Ln, Frisco, TX',
            'to': 'Phoenix, AZ',
            'stops': [
              {'place': 'Buc-ee’s, Amarillo, TX', 'minutes': 30, 'at': w(home, 6, 12).millisecondsSinceEpoch, 'zone': home},
              {'place': 'Albuquerque, NM', 'minutes': 45, 'at': w('America/Denver', 6, 15).millisecondsSinceEpoch, 'zone': 'America/Denver'},
            ],
          }),
          TripItem(id: 'h', kind: TripItemKind.stay, title: 'Arizona Biltmore', location: 'Arizona Biltmore, Phoenix, AZ', start: w(phx, 6, 22), end: w(phx, 7, 9), zone: phx),
          TripItem(id: 'f', kind: TripItemKind.flight, title: 'WN 88 · PHX – LAX', start: w(phx, 7, 11), end: w(la, 7, 12, 25), zone: phx, endZone: la, flight: {
            'number': 'WN 88',
            'departure': {'iata': 'PHX', 'timeZone': phx},
            'arrival': {'iata': 'LAX', 'timeZone': la},
          }),
          item('l', TripItemKind.food, w(la, 7, 13, 30), w(la, 7, 14, 30), title: 'Chick-fil-A'),
          item('g', TripItemKind.activity, w(la, 7, 18), w(la, 7, 20), title: 'Griffith Observatory'),
          item('z', TripItemKind.activity, w(la, 7, 21), w(la, 7, 21), title: 'Sunset at the pier'),
          TripItem(id: 'r', kind: TripItemKind.rental, title: 'Hertz', location: 'LAX Airport', start: w(la, 7, 13), end: w(la, 8, 16), zone: la, endZone: la, commute: {'from': 'LAX Airport', 'to': 'LAX Airport', 'car': 'SUV'}),
          item('e', TripItemKind.activity, w(la, 8, 10), w(la, 8, 13), title: 'Santa Monica Pier'),
        ]..sort(Trip.byTime))
      ])
        ..openId = 'p';
      await t.pumpWidget(MaterialApp(theme: buildTheme(), debugShowCheckedModeBanner: false,
          builder: (_, child) => RepaintBoundary(key: const ValueKey('shot'), child: child!),
          home: Scaffold(body: TripsPage(store: store, active: true))));
      await t.pump(const Duration(milliseconds: 300));
      await shot(t, name);
      if (name == 'trip_zones_phone') {
        await t.tap(find.text('Calendar'));
        await t.pumpAndSettle();
        await shot(t, '${name}_calendar');
      } else {
        await t.tap(find.byTooltip('Add to trip'));
        await t.pumpAndSettle();
        await t.tap(find.text('Something to do'));
        await t.pumpAndSettle();
        await t.enterText(find.widgetWithText(TextField, 'Notes'), 'Tickets: https://www.griffithobservatory.org/visit');
        await t.pumpAndSettle();
        await shot(t, 'trip_zones_editor');
        await t.tap(find.byTooltip('Back'));
        await t.pumpAndSettle();
        store.flights = [
          {
            'number': 'AA 1234', 'airline': 'American Airlines', 'aircraft': 'Boeing 737-800', 'status': 'Expected', 'miles': 1235,
            'departure': {'iata': 'DFW', 'name': 'Dallas Fort Worth', 'timeZone': home, 'terminal': 'D', 'gate': 'D12', 'scheduled': w(home, 6, 8, 5).millisecondsSinceEpoch},
            'arrival': {'iata': 'LAX', 'name': 'Los Angeles', 'timeZone': la, 'terminal': '4', 'baggageBelt': '4', 'scheduled': w(la, 6, 10, 30).millisecondsSinceEpoch},
          }
        ];
        await t.tap(find.byTooltip('Add to trip'));
        await t.pumpAndSettle();
        await t.tap(find.text('Flight'));
        await t.pumpAndSettle();
        await t.enterText(find.widgetWithText(TextField, 'Flight number'), 'aa1234');
        await t.tap(find.text('Look up flight'));
        await t.pumpAndSettle();
        await shot(t, 'trip_zones_flight');
      }
      t.view.reset();
    });
  }

  for (final (name, size) in [('small_phone', const Size(390, 844)), ('small_window', const Size(820, 760))]) {
    testWidgets(skip: skipPreview, 'trip_screens_$name', (t) async {
      await t.runAsync(loadFonts);
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      final trip = sample().copyWith(how: TripHow.fly, people: const [TripPerson(email: 'ann@example.com', name: 'Ann Lee', role: 'editor'), TripPerson(email: 'bo@example.com', role: 'viewer')]);
      final store = FakeTrips([trip])..openId = 'p';
      store.commute = {'minutes': 332, 'meters': 484000, 'predicted': true};
      await t.pumpWidget(MaterialApp(theme: buildTheme(), debugShowCheckedModeBanner: false,
          builder: (_, child) => RepaintBoundary(key: const ValueKey('shot'), child: child!),
          home: Scaffold(body: TripsPage(store: store, active: true))));
      await t.pump(const Duration(milliseconds: 300));
      Future<void> snap(String s) async {
        await t.pumpAndSettle();
        await shot(t, 'small_${name}_$s');
      }

      await snap('trip');
      await t.tap(find.text('Calendar'));
      await snap('calendar');
      await t.tap(find.text('Itinerary'));
      await t.pumpAndSettle();
      for (final (s, label) in const [('drive', 'Car ride'), ('flight', 'Flight'), ('rental', 'Rental car'), ('stay', 'Place to stay'), ('food', 'Food')]) {
        await t.tap(find.byTooltip('Add to trip'));
        await t.pumpAndSettle();
        await t.tap(find.text(label));
        await snap(s);
        await t.tap(find.byTooltip('Back'));
        await t.pumpAndSettle();
      }
      Future<void> fromMenu(String s, String label) async {
        final direct = find.byTooltip(label);
        if (direct.evaluate().isNotEmpty) {
          await t.tap(direct);
        } else {
          await t.tap(find.byTooltip('Trip options'));
          await t.pumpAndSettle();
          await t.tap(find.text(label));
        }
        await snap(s);
        await t.tapAt(const Offset(4, 4));
        await t.pumpAndSettle();
      }

      await fromMenu('share', 'Share');
      await fromMenu('links', 'Links and notes');
      t.view.reset();
    });
  }

  testWidgets(skip: skipPreview, 'trip tile on the calendar', (t) async {
    await t.runAsync(loadFonts);
    t.view.physicalSize = const Size(1300, 900);
    t.view.devicePixelRatio = 1;
    final other = GoogleCalendar(id: 'x', accountEmail: 'a', name: 'Me', color: const Color(0xFF4285F4), primary: true, accessRole: 'owner');
    final sunday = d.subtract(Duration(days: d.weekday % 7));
    final days = [for (var i = 0; i < 7; i++) DateTime(sunday.year, sunday.month, sunday.day + i)];
    final trip = sample();
    final meeting = CalendarEvent(id: 'm', calendar: other, title: 'Standup', description: '', location: '', start: days[1].add(const Duration(hours: 9)), end: days[1].add(const Duration(hours: 10)), allDay: false, color: other.color);
    for (final (name, page) in [
      ('trip_week', FlippedTimeline(days: days, events: [trip.tile, meeting], hourWidth: 96, onEventTap: (_) {})),
      ('trip_month', MonthView(month: d, events: [trip.tile, meeting], onDayTap: (_) {}, onEventTap: (_) {})),
    ]) {
      await t.pumpWidget(MaterialApp(theme: buildTheme(), debugShowCheckedModeBanner: false, home: RepaintBoundary(key: const ValueKey('shot'), child: Scaffold(body: Padding(padding: const EdgeInsets.all(12), child: page)))));
      await t.pump(const Duration(milliseconds: 300));
      await shot(t, name);
    }
    t.view.reset();
  });
}

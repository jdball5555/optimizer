import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/theme.dart';
import 'package:optimizer/widgets/address_field.dart';

import 'preview/calendar_preview_test.dart' show loadFonts, skipPreview;
import 'preview/pages_preview_test.dart' show shot;

class FakePlaces extends Places {
  final asked = <String>[];
  final pickedIds = <String>[];
  Object? error;

  @override
  Future<List<PlaceSuggestion>> suggest(String input, String session) async {
    asked.add(input);
    if (error != null) throw error!;
    return [
      (id: 'a', text: 'Central Library, Springfield, TX, USA', main: 'Central Library', secondary: 'Springfield, TX, USA'),
      (id: 'b', text: 'Riverside Diner, Shelbyville, TX, USA', main: 'Riverside Diner', secondary: 'Shelbyville, TX, USA'),
    ];
  }

  @override
  Future<void> picked(String id, String session) async => pickedIds.add(id);
}

void main() {
  late FakePlaces places;
  late TextEditingController from;
  late TextEditingController to;
  setUp(() {
    places = FakePlaces();
    Places.instance = places;
    from = TextEditingController();
    to = TextEditingController();
  });
  tearDown(() => Places.instance = Places());

  Future<void> form(WidgetTester t, {Size size = const Size(1400, 900)}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: FormWithMap(
          builder: (context, below) => ListView(children: [
            AddressField(controller: from, label: 'From', origin: true),
            const SizedBox(height: 12),
            AddressField(controller: to, label: 'To'),
            if (below != null) below,
          ]),
        ),
      ),
    ));
  }

  Future<void> type(WidgetTester t, String label, String text) async {
    await t.tap(find.widgetWithText(TextField, label));
    await t.pump();
    await t.enterText(find.widgetWithText(TextField, label), text);
    await t.pump(const Duration(milliseconds: 300));
    await t.pump();
  }

  testWidgets('it suggests as you type, waiting for a pause', (t) async {
    await form(t);
    await t.tap(find.widgetWithText(TextField, 'To'));
    await t.pump();
    await t.enterText(find.widgetWithText(TextField, 'To'), 'Te');
    await t.pump(const Duration(milliseconds: 300));
    expect(places.asked, isEmpty, reason: 'too short to ask');
    await t.enterText(find.widgetWithText(TextField, 'To'), 'Tex');
    await t.pump(const Duration(milliseconds: 100));
    await t.enterText(find.widgetWithText(TextField, 'To'), 'Texa');
    await t.pump(const Duration(milliseconds: 100));
    await t.enterText(find.widgetWithText(TextField, 'To'), 'Texas');
    await t.pump(const Duration(milliseconds: 300));
    await t.pump();
    expect(places.asked, ['Texas']);
    expect(find.text('Central Library'), findsOneWidget);
    expect(find.text('Springfield, TX, USA'), findsOneWidget);
    expect(find.text('Powered by Google'), findsOneWidget);
  });

  testWidgets('picking one fills it in, closes the list and shows it on a map beside the form', (t) async {
    await form(t);
    String? changed;
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: FormWithMap(builder: (_, below) => ListView(children: [AddressField(controller: to, label: 'To', onChanged: (v) => changed = v), if (below != null) below])),
      ),
    ));
    expect(find.byType(PlaceMap), findsNothing);
    await type(t, 'To', 'Texas');
    await t.tap(find.text('Central Library'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(to.text, 'Central Library, Springfield, TX, USA');
    expect(changed, to.text);
    expect(places.pickedIds, ['a']);
    expect(places.asked, ['Texas'], reason: 'picking doesn’t ask again');
    expect(find.text('Powered by Google'), findsNothing);
    final map = t.widget<PlaceMap>(find.byType(PlaceMap));
    expect([map.to, map.from], [to.text, null]);
    expect(t.getTopLeft(find.byType(PlaceMap)).dx, greaterThan(t.getTopRight(find.byType(TextField)).dx), reason: 'on the right');
  });

  testWidgets('with a start and a destination, the map shows the route', (t) async {
    await form(t);
    await type(t, 'From', 'Texas');
    await t.tap(find.text('Riverside Diner'));
    await t.pump();
    await type(t, 'To', 'Texas');
    await t.tap(find.text('Central Library'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    final map = t.widget<PlaceMap>(find.byType(PlaceMap));
    expect(map.from, 'Riverside Diner, Shelbyville, TX, USA');
    expect(map.to, 'Central Library, Springfield, TX, USA');
  });

  testWidgets('just typing works too: it goes on the map when you move on', (t) async {
    await form(t);
    places.error = null;
    await type(t, 'To', '12 Home St');
    expect(find.byType(PlaceMap), findsNothing, reason: 'not while typing');
    await t.tap(find.widgetWithText(TextField, 'From'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(t.widget<PlaceMap>(find.byType(PlaceMap)).to, '12 Home St');
    expect(to.text, '12 Home St');
  });

  testWidgets('a saved address shows when the form opens', (t) async {
    to.text = 'Austin, TX';
    await form(t);
    await t.pump();
    expect(t.widget<PlaceMap>(find.byType(PlaceMap)).to, 'Austin, TX');
    expect(places.asked, isEmpty, reason: 'only asks while you’re typing');
  });

  testWidgets('filled in from elsewhere: it follows, without asking Google', (t) async {
    await form(t);
    to.text = 'Austin';
    await t.pump(const Duration(seconds: 1));
    await t.pump();
    expect(t.widget<PlaceMap>(find.byType(PlaceMap)).to, 'Austin');
    expect(places.asked, isEmpty);
  });

  testWidgets('on a phone the map goes under the form', (t) async {
    to.text = 'Austin, TX';
    await form(t, size: const Size(412, 900));
    await t.pump();
    expect(t.getTopLeft(find.byType(PlaceMap)).dy, greaterThan(t.getBottomLeft(find.widgetWithText(TextField, 'To')).dy));
    expect(t.takeException(), isNull);
  });

  testWidgets('when Google is off, it says so and you can still type', (t) async {
    await form(t);
    places.error = PlacesOff('Google’s Places API is off for this project, so addresses can’t autocomplete yet.');
    await type(t, 'To', 'Austin');
    expect(find.textContaining('Places API is off'), findsOneWidget);
    expect(to.text, 'Austin');
  });

  testWidgets(skip: skipPreview, 'address_suggestions', (t) async {
    await t.runAsync(loadFonts);
    t.view.physicalSize = const Size(1200, 620);
    t.view.devicePixelRatio = 1;
    from.text = 'Dallas, TX';
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(),
      debugShowCheckedModeBanner: false,
      builder: (_, child) => RepaintBoundary(key: const ValueKey('shot'), child: child!),
      home: Scaffold(
        body: FormWithMap(
          builder: (context, below) => ListView(padding: const EdgeInsets.all(16), children: [
            AddressField(controller: from, label: 'Starting from', origin: true, icon: Icons.trip_origin),
            const SizedBox(height: 12),
            AddressField(controller: to, label: 'Final destination'),
            if (below != null) below,
          ]),
        ),
      ),
    ));
    await type(t, 'Final destination', 'Texas');
    await t.pump(const Duration(milliseconds: 300));
    await shot(t, 'address_suggestions');
    t.view.reset();
  });

  group('an entry’s location goes under its map', () {
    Future<void> entry(WidgetTester t, Size size) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: FormWithMap(
            location: AddressField(controller: to, label: 'Location'),
            builder: (context, below) => ListView(children: [
              const TextField(decoration: InputDecoration(labelText: 'Title')),
              if (below != null) below,
              const TextField(decoration: InputDecoration(labelText: 'Description')),
            ]),
          ),
        ),
      ));
      await t.pump();
    }

    testWidgets('beside the form: the map’s place is kept while it’s empty', (t) async {
      await entry(t, const Size(1400, 900));
      expect(find.text('Add a location to see it here'), findsOneWidget);
      expect(find.byType(PlaceMap), findsNothing);
      final field = t.getRect(find.widgetWithText(TextField, 'Location'));
      expect(field.left, greaterThan(t.getRect(find.widgetWithText(TextField, 'Title')).right));
      expect(field.top, greaterThan(t.getRect(find.text('Add a location to see it here')).bottom));
    });

    testWidgets('filled in, the map shows above it', (t) async {
      to.text = 'Alamodome';
      await entry(t, const Size(1400, 900));
      expect(find.text('Add a location to see it here'), findsNothing);
      expect(t.getRect(find.widgetWithText(TextField, 'Location')).top, greaterThan(t.getRect(find.byType(PlaceMap)).top));
    });

    testWidgets('on a phone they sit where the form puts them', (t) async {
      await entry(t, const Size(412, 900));
      final field = t.getRect(find.widgetWithText(TextField, 'Location'));
      expect(field.top, greaterThan(t.getRect(find.widgetWithText(TextField, 'Title')).bottom));
      expect(field.bottom, lessThan(t.getRect(find.widgetWithText(TextField, 'Description')).top));
      expect(t.takeException(), isNull);
    });
  });

  group('with a place that has to be picked to be on the map', () {
    Future<ValueNotifier<bool>> linked(WidgetTester t, {List<SavedPlace> saved = const []}) async {
      final onMap = ValueNotifier(false);
      addTearDown(onMap.dispose);
      t.view.physicalSize = const Size(1400, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: FormWithMap(
            location: AddressField(controller: to, label: 'To', onMap: onMap, saved: saved),
            builder: (_, below) => ListView(children: [const TextField(decoration: InputDecoration(labelText: 'Other')), if (below != null) below]),
          ),
        ),
      ));
      return onMap;
    }

    testWidgets('a typed name stays off the map, and says so', (t) async {
      await linked(t);
      await type(t, 'To', 'Chick-fil-A');
      await t.tap(find.widgetWithText(TextField, 'Other'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byType(PlaceMap), findsNothing);
      expect(find.text('Just a name, not on the map'), findsOneWidget);
    });

    testWidgets('picking a suggestion puts it on, and changing it takes it off', (t) async {
      final onMap = await linked(t);
      await type(t, 'To', 'Texas');
      await t.tap(find.text('Riverside Diner'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(onMap.value, isTrue);
      expect(t.widget<PlaceMap>(find.byType(PlaceMap)).to, 'Riverside Diner, Shelbyville, TX, USA');
      await t.enterText(find.widgetWithText(TextField, 'To'), 'Riverside Diner, somewhere else');
      await t.pump();
      expect(onMap.value, isFalse);
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byType(PlaceMap), findsNothing);
    });

    testWidgets('saved places show on clicking in, narrow as you type, and don’t ask Google until there’s enough to', (t) async {
      await linked(t, saved: const [(text: 'Austin, TX', onMap: true), (text: 'Chick-fil-A', onMap: false)]);
      await t.tap(find.widgetWithText(TextField, 'To'));
      await t.pump();
      await t.pump();
      expect(find.text('Austin'), findsOneWidget);
      expect(find.text('TX'), findsOneWidget);
      expect(find.text('Chick-fil-A'), findsOneWidget);
      expect(places.asked, isEmpty);
      await t.enterText(find.widgetWithText(TextField, 'To'), 'ch');
      await t.pump(const Duration(milliseconds: 300));
      await t.pump();
      expect(find.text('Austin'), findsNothing);
      expect(find.text('Chick-fil-A'), findsOneWidget);
      expect(places.asked, isEmpty);
      await t.enterText(find.widgetWithText(TextField, 'To'), 'chick');
      await t.pump(const Duration(milliseconds: 300));
      await t.pump();
      expect(places.asked, ['chick']);
      expect(find.text('Chick-fil-A'), findsOneWidget);
      expect(find.text('Riverside Diner'), findsOneWidget);
      expect(t.getTopLeft(find.text('Chick-fil-A')).dy, lessThan(t.getTopLeft(find.text('Riverside Diner')).dy), reason: 'yours first');
      await t.tap(find.text('Chick-fil-A'));
      await t.pump();
      expect(to.text, 'Chick-fil-A');
      expect(places.pickedIds, isEmpty, reason: 'that’s not a Google pick');
    });
  });

  test('map links carry the address safely', () {
    expect(mapEmbedUrl('Ben & Jerry, VT'), 'https://www.google.com/maps?q=Ben+%26+Jerry%2C+VT&output=embed');
    expect(mapEmbedUrl('B', from: 'A'), 'https://www.google.com/maps?saddr=A&daddr=B&output=embed');
    expect(mapOpenUrl('B', from: 'A'), contains('/maps/dir/?api=1&origin=A&destination=B'));
    expect(mapOpenUrl('A B'), contains('/maps/search/?api=1&query=A+B'));
    expect(mapEmbedUrl('C', from: 'A', via: ['B']), 'https://www.google.com/maps?saddr=A&daddr=B+to%3AC&output=embed');
    expect(mapOpenUrl('C', from: 'A', via: ['B', 'D']), contains('waypoints=B%7CD'));
  });
}

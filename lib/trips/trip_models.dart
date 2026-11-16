import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../calendar/calendar_models.dart';
import '../util/fields.dart';
import '../widgets/link_text.dart';
import 'trip_zones.dart';

enum TripItemKind {
  flight('Flight', Icons.flight, Color(0xFF60A5FA)),
  commute('Drive', Icons.directions_car_outlined, Color(0xFFFBBF24)),
  travel('Other travel', Icons.train_outlined, Color(0xFFA3E635)),
  stay('Stay', Icons.hotel_outlined, Color(0xFFC084FC)),
  rental('Rental car', Icons.car_rental, Color(0xFFF97316)),
  food('Food', Icons.restaurant, Color(0xFFFB7185)),
  activity('Activity', Icons.place_outlined, Color(0xFF2DD4BF));

  const TripItemKind(this.label, this.icon, this.color);
  final String label;
  final IconData icon;
  final Color color;

  /// Checking in and out, or picking up and dropping off: two separate moments.
  bool get hasTwoEnds => this == stay || this == rental;
}

/// Someone a trip is shared with. Their [role] is 'editor', 'viewer', or on an
/// entry, 'none': they can't see it.
class TripPerson {
  const TripPerson({required this.email, this.name = '', required this.role});

  factory TripPerson.fromJson(Map d) => TripPerson(email: '${d['email'] ?? ''}', name: '${d['name'] ?? ''}', role: '${d['role'] ?? 'viewer'}');

  final String email;
  final String name;
  final String role;

  String get shown => name.isEmpty ? email : name;

  Map<String, dynamic> toJson() => {'email': email, 'role': role};
}

/// "Can edit", "Can view", "Can't see".
String roleLabel(String role) => switch (role) { 'editor' => 'Can edit', 'none' => 'Can’t see', _ => 'Can view' };

/// A link that's for the whole trip rather than one thing on it.
class TripLink {
  const TripLink({required this.url, this.label = ''});

  factory TripLink.fromJson(Map d) => TripLink(url: '${d['url'] ?? ''}', label: '${d['label'] ?? ''}');

  final String url;
  final String label;

  Map<String, dynamic> toJson() => {'url': url, if (label.isNotEmpty) 'label': label};
}

/// How you're getting there: what the trip's page offers first.
enum TripHow { fly, drive, other }

/// The name of a place, from a full address: "Alamodome, 100 Montana St…" → "Alamodome".
String placeName(String address) => address.split(',').first.trim();

/// "25 min", "1 h 10 min", "4 h".
String tripMinutes(num m) => m < 60 ? '${m.round()} min' : (m % 60 == 0 ? '${m ~/ 60} h' : '${m ~/ 60} h ${(m % 60).round()} min');

/// One airport end of a flight, in the shape the server hands back (or typed in).
class FlightEnd {
  FlightEnd(Map? d)
      : iata = '${d?['iata'] ?? ''}',
        name = '${d?['name'] ?? ''}',
        city = '${d?['city'] ?? ''}',
        timeZone = '${d?['timeZone'] ?? ''}',
        terminal = '${d?['terminal'] ?? ''}',
        gate = '${d?['gate'] ?? ''}',
        checkInDesk = '${d?['checkInDesk'] ?? ''}',
        baggageBelt = '${d?['baggageBelt'] ?? ''}',
        scheduled = _ms(d?['scheduled']),
        revised = _ms(d?['revised']),
        scheduledLocal = _clock(d?['scheduledLocal']),
        revisedLocal = _clock(d?['revisedLocal']);

  final String iata;
  final String name;
  final String city;
  final String timeZone;
  final String terminal;
  final String gate;
  final String checkInDesk;
  final String baggageBelt;

  /// The moment, on any device's clock.
  final DateTime? scheduled;
  final DateTime? revised;

  /// The clock at the airport, whatever time zone you're in now.
  final DateTime? scheduledLocal;
  final DateTime? revisedLocal;

  DateTime? get time => revised ?? scheduled;
  DateTime? get localTime => revisedLocal ?? scheduledLocal;
  String get code => iata.isNotEmpty ? iata : name;

  static DateTime? _ms(Object? v) => v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
  static DateTime? _clock(Object? v) => v is String ? DateTime.tryParse(v) : null;
}

/// A stop on a drive: somewhere on the route (or, with no [place], just time
/// set aside), and how long you'll be there.
class DriveStop {
  const DriveStop({this.place = '', required this.minutes, this.at, this.zone = '', this.onMap = true});

  factory DriveStop.fromJson(Map d) => DriveStop(
        place: '${d['place'] ?? ''}',
        minutes: (d['minutes'] as num?)?.toInt() ?? 0,
        at: d['at'] is num ? DateTime.fromMillisecondsSinceEpoch((d['at'] as num).toInt()) : null,
        zone: '${d['zone'] ?? ''}',
        onMap: d['onMap'] != false,
      );

  final String place;
  final int minutes;

  /// When you'd get there, if Google has timed the drive.
  final DateTime? at;

  /// The place's own time zone, if known.
  final String zone;

  /// A real place, not just a name that was typed.
  final bool onMap;

  String get name => place.isEmpty ? 'Stop' : placeName(place);

  /// A real place on the drive's route, with a time you'd get there. Anything
  /// else is just time set aside, part of the drive.
  bool get onRoute => at != null && onMap && place.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'place': place,
        'minutes': minutes,
        if (at != null) 'at': at!.millisecondsSinceEpoch,
        if (zone.isNotEmpty) 'zone': zone,
        if (!onMap) 'onMap': false
      };
}

/// One thing on a trip: a flight, a commute, a place to stay, or something to do.
class TripItem {
  TripItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.start,
    required this.end,
    this.location = '',
    this.notes = '',
    this.flight,
    this.commute,
    this.zone = '',
    this.endZone = '',
    this.onMap = true,
    this.confirmation = '',
    this.access = const {},
    this.myRole,
    this.canSee = const [],
  });

  factory TripItem.fromJson(Map d) {
    final start = asDate(d['start']) ?? DateTime.now();
    return TripItem(
      id: '${d['id']}',
      kind: TripItemKind.values.where((k) => k.name == d['kind']).firstOrNull ?? TripItemKind.activity,
      title: '${d['title'] ?? ''}',
      start: start,
      end: asDate(d['end']) ?? start,
      location: '${d['location'] ?? ''}',
      notes: '${d['notes'] ?? ''}',
      flight: d['flight'] is Map ? Map<String, dynamic>.from(d['flight'] as Map) : null,
      commute: d['commute'] is Map ? Map<String, dynamic>.from(d['commute'] as Map) : null,
      zone: '${d['zone'] ?? ''}'.isNotEmpty ? '${d['zone']}' : FlightEnd((d['flight'] as Map?)?['departure'] as Map?).timeZone,
      endZone: '${d['endZone'] ?? ''}'.isNotEmpty ? '${d['endZone']}' : FlightEnd((d['flight'] as Map?)?['arrival'] as Map?).timeZone,
      onMap: d['onMap'] != false,
      confirmation: '${d['confirmation'] ?? ''}',
      access: d['access'] is Map ? {for (final e in (d['access'] as Map).entries) '${e.key}': '${e.value}'} : const {},
      myRole: d['myRole'] as String?,
      canSee: [
        for (final p in (d['canSee'] as List? ?? const []))
          if (p is Map) TripPerson.fromJson(p),
      ],
    );
  }

  final String id;
  final TripItemKind kind;
  final String title;
  final DateTime start;
  final DateTime end;
  final String location;
  final String notes;

  /// A flight's details: number, airline, aircraft, status, departure, arrival.
  final Map<String, dynamic>? flight;

  /// A commute's details: from, to, mode, minutes, meters, predicted, timing
  /// ('arrive' or 'leave'), flightId and direction (for one tied to a flight).
  /// A drive also has stops and legs (each stretch's seconds, from Google).
  /// Other travel has just from, to and how. A rental car has from (where you
  /// pick it up), to (where you drop it off) and car.
  final Map<String, dynamic>? commute;

  /// Its own time zones, where it starts and where it ends, if known: looked
  /// up from its place, or picked. Without them it goes by where you are then
  /// ([Trip.zones]).
  final String zone;
  final String endZone;

  /// Its [location] is a real place, not just a name that was typed. Travel
  /// says the same for its from and to in [commute]: fromOnMap and toOnMap.
  final bool onMap;
  final String confirmation;

  /// Who this differs for from the trip they're on: email to role. Only the
  /// trip's owner has this.
  final Map<String, String> access;

  /// On a trip shared with you: what you can do with this.
  final String? myRole;

  /// On a trip shared with you: who can see this.
  final List<TripPerson> canSee;

  /// Just a time that it happens, with no end.
  bool get oneTime => !end.isAfter(start);

  List<DriveStop> get stops => [
        for (final s in (commute?['stops'] as List? ?? const []))
          if (s is Map) DriveStop.fromJson(s),
      ];

  /// How you get there, as opposed to what you do there.
  bool get isTravel => kind == TripItemKind.flight || kind == TripItemKind.commute || kind == TripItemKind.travel;

  FlightEnd get departure => FlightEnd(flight?['departure'] as Map?);
  FlightEnd get arrival => FlightEnd(flight?['arrival'] as Map?);

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'title': title,
        'start': Timestamp.fromDate(start),
        'end': Timestamp.fromDate(end),
        'location': location,
        'notes': notes,
        if (flight != null) 'flight': flight,
        if (commute != null) 'commute': commute,
        if (zone.isNotEmpty) 'zone': zone,
        if (endZone.isNotEmpty) 'endZone': endZone,
        if (!onMap) 'onMap': false,
        if (confirmation.isNotEmpty) 'confirmation': confirmation,
        if (access.isNotEmpty) 'access': access,
      };

  /// The same, to send to the server.
  Map<String, dynamic> toCallable() => {...toJson(), 'start': start.millisecondsSinceEpoch, 'end': end.millisecondsSinceEpoch};

  TripItem withAccess(Map<String, String> access) => _copy(start, end, commute, access);

  /// The same thing at another time. Its stops move with it.
  TripItem movedTo(DateTime newStart, DateTime newEnd) {
    final by = newStart.difference(start);
    return _copy(
        newStart,
        newEnd,
        commute == null || stops.isEmpty
            ? commute
            : {
                ...commute!,
                'stops': [
                  for (final s in stops) DriveStop(place: s.place, minutes: s.minutes, zone: s.zone, onMap: s.onMap, at: s.at?.add(by)).toJson(),
                ],
              },
        access);
  }

  TripItem _copy(DateTime start, DateTime end, Map<String, dynamic>? commute, Map<String, String> access) => TripItem(
        id: id,
        kind: kind,
        title: title,
        start: start,
        end: end,
        location: location,
        notes: notes,
        flight: flight,
        zone: zone,
        endZone: endZone,
        onMap: onMap,
        confirmation: confirmation,
        commute: commute,
        access: access,
        myRole: myRole,
        canSee: canSee,
      );
}

/// A moment that says which zone you're in by then.
class _ZoneMark {
  const _ZoneMark(this.item, this.at, this.zone);

  final String item;
  final DateTime at;
  final String zone;
}

/// A trip: optimizer/{uid}/trips/{id}, its itinerary in [items].
class Trip {
  Trip(
      {required this.id,
      required this.title,
      required this.start,
      required this.end,
      this.destination = '',
      this.how,
      this.zone = '',
      this.notes = '',
      this.links = const [],
      this.people = const [],
      this.shareId,
      this.ownerName = '',
      this.ownerEmail = '',
      this.myRole = 'editor',
      Color? color,
      List<TripItem>? items})
      : color = color ?? tripColors.first,
        items = items ?? [];

  factory Trip.fromDoc(String id, Map<String, dynamic> d) {
    final start = asDate(d['start']) ?? DateTime.now();
    return Trip(
      id: id,
      title: '${d['title'] ?? 'Trip'}',
      destination: '${d['destination'] ?? ''}',
      how: TripHow.values.where((h) => h.name == d['how']).firstOrNull,
      zone: '${d['zone'] ?? ''}',
      notes: '${d['notes'] ?? ''}',
      links: [
        for (final l in (d['links'] as List? ?? const []))
          if (l is Map) TripLink.fromJson(l),
      ],
      people: [
        for (final p in (d['people'] as List? ?? const []))
          if (p is Map) TripPerson.fromJson(p),
      ],
      shareId: d['shareId'] as String?,
      ownerName: '${d['ownerName'] ?? ''}',
      ownerEmail: '${d['ownerEmail'] ?? ''}',
      myRole: '${d['myRole'] ?? 'editor'}',
      // As written, so they're the same days on a device in any time zone.
      start: _dayOf(d['startDay']) ?? dayStart(start),
      end: _dayOf(d['endDay']) ?? dayStart(asDate(d['end']) ?? start),
      color: d['color'] is int ? Color(d['color'] as int) : tripColors.first,
      items: [
        for (final i in (d['items'] as List? ?? const []))
          if (i is Map) TripItem.fromJson(i)
      ]..sort(byTime),
    );
  }

  final String id;
  final String title;
  final String destination;

  /// What you said when you made it. Trips from before that have [getting].
  final TripHow? how;

  /// The time zone you're setting out from.
  final String zone;

  /// General notes, and links, for the whole trip.
  final String notes;
  final List<TripLink> links;

  /// Who it's shared with (functions/people.js keeps this up to date).
  final List<TripPerson> people;

  /// It's someone else's, shared with you: this is the copy of it you can see.
  final String? shareId;
  final String ownerName;
  final String ownerEmail;

  /// On a trip shared with you: 'editor' or 'viewer'.
  final String myRole;

  bool get isShared => shareId != null;
  bool get canEdit => !isShared || myRole == 'editor';
  bool canEditItem(TripItem i) => !isShared || i.myRole == 'editor';

  /// Who can see [i], and what they can do with it, with [access] in place of its own.
  List<TripPerson> peopleOn(TripItem i, {Map<String, String>? access}) => isShared
      ? i.canSee
      : [
          for (final p in people)
            if ((access ?? i.access)[p.email] != 'none') TripPerson(email: p.email, name: p.name, role: (access ?? i.access)[p.email] ?? p.role),
        ];

  /// The links in each entry's notes, for those that have any, in order.
  List<({TripItem item, List<String> links})> get linksByItem => [
        for (final i in [...items]..sort(byTime))
          if (findLinks(i.notes).isNotEmpty) (item: i, links: findLinks(i.notes).toSet().toList()),
      ];

  /// The first and last days.
  final DateTime start;
  final DateTime end;
  final Color color;
  final List<TripItem> items;

  static int byTime(TripItem a, TripItem b) => a.start.compareTo(b.start);

  static DateTime? _dayOf(Object? v) => v is String ? DateTime.tryParse(v) : null;
  static String _ymd(DateTime d) => '${d.year}-${'${d.month}'.padLeft(2, '0')}-${'${d.day}'.padLeft(2, '0')}';

  String get _home => zone.isNotEmpty ? zone : deviceZone;

  /// The time zones of everything on the trip, where each starts and where it
  /// ends, by the id of its event on the calendar. Following the trip in order:
  /// something with no zone of its own is in the zone you're in by then, so
  /// once a flight or drive has taken you somewhere, it's there.
  Map<String, (String, String)> get zones => _walked.$1;

  /// Besides [zones], each moment that says where you are, in order: something
  /// starting, or travel arriving. Checking out of a hotel doesn't move you.
  late final _walked = () {
    final zones = <String, (String, String)>{};
    final marks = <_ZoneMark>[];
    for (final i in [...items]..sort(byTime)) {
      final start = i.zone.isNotEmpty ? i.zone : _latest(marks, i.start);
      final end = i.endZone.isNotEmpty ? i.endZone : start;
      zones[i.id] = (start, end);
      var along = start;
      for (final (n, s) in i.stops.indexed) {
        along = s.zone.isNotEmpty ? s.zone : along;
        zones['${i.id}#$n'] = (along, along);
      }
      marks.add(_ZoneMark(i.id, i.start, start));
      if (i.isTravel) marks.add(_ZoneMark(i.id, i.end, end));
    }
    marks.sort((a, b) => a.at.compareTo(b.at));
    return (zones, marks);
  }();

  String _latest(List<_ZoneMark> marks, DateTime moment, {String? except}) {
    _ZoneMark? last;
    for (final m in marks) {
      if (m.item != except && !m.at.isAfter(moment) && (last == null || !m.at.isBefore(last.at))) last = m;
    }
    return last?.zone ?? _home;
  }

  /// The zone you're in at [moment], going by what's on the trip apart from [except].
  String zoneAt(DateTime moment, {String? except}) => _latest(_walked.$2, moment, except: except);

  /// The zones you wake up and go to bed in on [day], by the date where each thing happens.
  (String, String) zonesOn(DateTime day) {
    var morning = _home, night = _home;
    for (final m in _walked.$2) {
      final date = inZone(m.at, m.zone);
      if (sameDay(date, day)) {
        night = m.zone;
      } else if (dayStart(date).isBefore(day)) {
        morning = night = m.zone;
      }
    }
    return (morning, night);
  }

  /// Every place on the trip so far, to use again.
  List<({String text, bool onMap})> get savedPlaces {
    final out = <String, ({String text, bool onMap})>{};
    void add(Object? place, bool onMap) {
      final text = '${place ?? ''}'.trim();
      final was = out[text.toLowerCase()];
      if (text.isNotEmpty && (was == null || (onMap && !was.onMap))) out[text.toLowerCase()] = (text: text, onMap: onMap);
    }

    for (final i in [...items]..sort(byTime)) {
      if (i.commute != null) {
        add(i.commute!['from'], i.commute!['fromOnMap'] != false);
        for (final s in i.stops) {
          add(s.place, s.onMap);
        }
        add(i.commute!['to'], i.commute!['toOnMap'] != false);
      } else if (i.kind != TripItemKind.flight) {
        add(i.location, i.onMap);
      }
    }
    return out.values.toList();
  }

  /// The moment a clock says [wall], wherever you are by then.
  DateTime momentOf(DateTime wall, {String? except}) {
    final roughly = zoneAt(fromWall(wall, _home), except: except);
    return fromWall(wall, zoneAt(fromWall(wall, roughly), except: except));
  }

  /// After a change that moves you: what has no zone of its own stays at the
  /// same time on the clock, now in the zone it's in. Dinner at 6 is still at 6.
  Trip keepingClocksFrom(Trip before, {String? except}) => copyWith(items: [
        for (final i in items)
          () {
            final was = before.zones[i.id], now = zones[i.id]!;
            if (i.id == except || i.zone.isNotEmpty || was == null || was == now) return i;
            final start = fromWall(wallOf(i.start, was.$1), now.$1);
            final end = i.endZone.isNotEmpty ? i.end : fromWall(wallOf(i.end, was.$2), now.$2);
            return i.movedTo(start, end);
          }(),
      ]);

  /// How you're getting there: what you said, or what's planned so far.
  TripHow? get getting {
    if (how != null) return how;
    if (items.any((i) => i.kind == TripItemKind.flight)) return TripHow.fly;
    if (mainDrive != null) return TripHow.drive;
    if (items.any((i) => i.kind == TripItemKind.travel)) return TripHow.other;
    return null;
  }

  /// The drive itself, as opposed to a ride to or from an airport.
  TripItem? get mainDrive => items.where((i) => i.kind == TripItemKind.commute && i.commute?['flightId'] == null).firstOrNull;

  Map<String, dynamic> toJson() => {
        'title': title,
        'destination': destination,
        if (how != null) 'how': how!.name,
        if (zone.isNotEmpty) 'zone': zone,
        if (notes.isNotEmpty) 'notes': notes,
        if (links.isNotEmpty) 'links': [for (final l in links) l.toJson()],
        'start': Timestamp.fromDate(start),
        'end': Timestamp.fromDate(end),
        'startDay': _ymd(start),
        'endDay': _ymd(end),
        'color': color.toARGB32(),
        'items': [for (final i in items) i.toJson()],
      };

  Trip copyWith(
          {String? title,
          String? destination,
          TripHow? how,
          String? zone,
          String? notes,
          List<TripLink>? links,
          List<TripPerson>? people,
          DateTime? start,
          DateTime? end,
          Color? color,
          List<TripItem>? items}) =>
      Trip(
        id: id,
        title: title ?? this.title,
        destination: destination ?? this.destination,
        how: how ?? this.how,
        zone: zone ?? this.zone,
        notes: notes ?? this.notes,
        links: links ?? this.links,
        people: people ?? this.people,
        shareId: shareId,
        ownerName: ownerName,
        ownerEmail: ownerEmail,
        myRole: myRole,
        start: start ?? this.start,
        end: end ?? this.end,
        color: color ?? this.color,
        items: items ?? this.items,
      );

  /// When the trip really runs, for its tile on the calendar: from the start
  /// of the first thing on it to the end of the last. With nothing planned
  /// yet, its days.
  ({DateTime start, DateTime end}) get span {
    if (items.isEmpty) return (start: start, end: addDays(end, 1));
    final from = items.map((i) => i.start).reduce((a, b) => a.isBefore(b) ? a : b);
    final to = items.map((i) => i.end.isAfter(i.start) ? i.end : i.start.add(const Duration(minutes: 30))).reduce((a, b) => a.isAfter(b) ? a : b);
    return (start: from, end: to);
  }

  /// The day the first thing happens, by the clock where it happens.
  DateTime get firstDay =>
      items.isEmpty ? start : items.map((i) => dayStart(inZone(i.start, zones[i.id]!.$1))).reduce((a, b) => a.isBefore(b) ? a : b);

  /// The day the last thing ends, by the clock where it ends.
  DateTime get lastDay {
    if (items.isEmpty) return end;
    return items.map((i) {
      final finish = i.end.isAfter(i.start) ? i.end.subtract(const Duration(microseconds: 1)) : i.start;
      return dayStart(inZone(finish, zones[i.id]!.$2));
    }).reduce((a, b) => a.isAfter(b) ? a : b);
  }

  /// Every day on the trip's own calendar: the days you set aside for it, and
  /// any that what's planned runs into.
  List<DateTime> get days {
    final s = firstDay, e = lastDay;
    final first = s.isBefore(start) ? s : start, last = e.isAfter(end) ? e : end;
    return [for (var d = first; !d.isAfter(last); d = addDays(d, 1)) d];
  }

  /// Its one big tile on the main calendar.
  CalendarEvent get tile {
    final s = span;
    return CalendarEvent(
      id: id,
      calendar: tripsCalendar,
      title: title,
      description: '',
      location: destination,
      start: s.start,
      end: s.end,
      allDay: false,
      color: readableColor(color),
      backdrop: true,
    );
  }

  /// Everything on the trip, for its own calendar. A drive's stops show on
  /// top of it. Their ids start with the drive's, to open it.
  List<CalendarEvent> get itemEvents => [
        for (final i in items) ...[
          CalendarEvent(
            id: i.id,
            calendar: _itemCalendars[i.kind]!,
            title: i.title,
            description: i.notes,
            location: i.location,
            start: i.start,
            end: i.end.isAfter(i.start) ? i.end : i.start.add(const Duration(minutes: 30)),
            allDay: false,
            color: i.kind.color,
            // A stay runs behind everything else that happens during it, and a
            // drive behind its stops.
            backdrop: i.kind.hasTwoEnds || i.stops.any((s) => s.onRoute),
          ),
          for (final (n, s) in i.stops.indexed)
            if (s.onRoute)
              CalendarEvent(
                id: '${i.id}#$n',
                calendar: _itemCalendars[TripItemKind.commute]!,
                title: s.name,
                description: '',
                location: s.place,
                start: s.at!,
                end: s.at!.add(Duration(minutes: s.minutes)),
                allDay: false,
                color: TripItemKind.commute.color,
              ),
        ],
      ];

  static final _itemCalendars = {
    for (final k in TripItemKind.values)
      k: GoogleCalendar(id: k.name, accountEmail: 'trip', name: k.label, color: k.color, primary: false, accessRole: 'reader'),
  };
}

const tripColors = [
  Color(0xFF22D3EE),
  Color(0xFFFBBF24),
  Color(0xFFF472B6),
  Color(0xFF34D399),
  Color(0xFFA78BFA),
  Color(0xFFFB923C),
];

/// The calendar trips' tiles belong to: read-only, never sent to Google.
final tripsCalendar =
    GoogleCalendar(id: 'trips', accountEmail: tripsAccount, name: 'Trips', color: tripColors.first, primary: false, accessRole: 'reader');

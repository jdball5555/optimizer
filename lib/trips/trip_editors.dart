import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme.dart';
import '../util/fields.dart';
import '../widgets/address_field.dart';
import '../widgets/entry_form.dart';
import '../widgets/link_text.dart';
import '../widgets/tiles.dart';
import 'trip_chooser.dart';
import 'trip_models.dart';
import 'trip_people.dart';
import 'trip_store.dart';
import 'trip_zones.dart';

String _clean(Object e) => '$e'.replaceFirst('Exception: ', '');

/// A date and a time on the clock in [zone], each a button, and right after
/// the time, which zone that is, to change it.
class _When extends StatelessWidget {
  const _When({this.label, required this.value, required this.zone, required this.onChanged, required this.onZone});

  final String? label;

  /// The wall clock (see trip_zones.dart).
  final DateTime value;
  final String zone;
  final ValueChanged<DateTime> onChanged;
  final ValueChanged<String> onZone;

  /// The date, and the time with its zone: to go in a row with other things.
  List<Widget> parts(BuildContext context) => [
        OutlinedButton(
          onPressed: () async {
            final d = await showDatePicker(
                context: context, initialDate: DateTime(value.year, value.month, value.day), firstDate: DateTime(2000), lastDate: DateTime(2100));
            if (d != null) onChanged(DateTime.utc(d.year, d.month, d.day, value.hour, value.minute));
          },
          child: Text(DateFormat.yMMMEd().format(value)),
        ),
        // Never apart: the zone stays right after the time.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            OutlinedButton(
              onPressed: () async {
                final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: value.hour, minute: value.minute));
                if (t != null) onChanged(DateTime.utc(value.year, value.month, value.day, t.hour, t.minute));
              },
              child: Text(DateFormat.jm().format(value)),
            ),
            const SizedBox(width: 4),
            _ZoneButton(wall: value, zone: zone, onZone: onZone),
          ]),
        ),
      ];

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          if (label != null)
            SizedBox(
                width: MediaQuery.sizeOf(context).width < 420 ? 66 : 92,
                child: Text(label!, style: const TextStyle(color: AppColors.secondaryText, fontSize: 13))),
          Expanded(child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: parts(context))),
        ]),
      );
}

/// Which time zone a time is in, right after it, to change it.
class _ZoneButton extends StatelessWidget {
  const _ZoneButton({required this.wall, required this.zone, required this.onZone});

  final DateTime wall;
  final String zone;
  final ValueChanged<String> onZone;

  @override
  Widget build(BuildContext context) => TextButton.icon(
        onPressed: () async {
          final z = await _pickZone(context, fromWall(wall, zone), zone);
          if (z != null) onZone(z);
        },
        iconAlignment: IconAlignment.end,
        icon: const Icon(Icons.arrow_drop_down, size: 18),
        label: Text(zoneLabel(fromWall(wall, zone), zone)),
      );
}

/// What kind of thing an entry is, when that can't change: a flight, a drive, a
/// stay and a rental car each have their own details. Just words, not a button.
class _KindLabel extends StatelessWidget {
  const _KindLabel({required this.kind});

  final TripItemKind kind;

  static String label(TripItemKind k) => switch (k) {
        TripItemKind.flight => 'Flight',
        TripItemKind.commute => 'Drive',
        TripItemKind.rental => 'Rental car',
        TripItemKind.travel => 'Other travel',
        TripItemKind.stay => 'Stay',
        TripItemKind.food => 'Food',
        TripItemKind.activity => 'Something to do',
      };

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'You can’t change the type of a ${label(kind).toLowerCase()}. If you need something else, go back, delete this and add a new one.',
        waitDuration: const Duration(milliseconds: 700),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(kind.icon, size: 18, color: kind.color),
          const SizedBox(width: 6),
          Text(label(kind), style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
        ]),
      );
}

/// Food and something to do are the same kind of entry, so one can become the other.
class _KindDropdown extends StatelessWidget {
  const _KindDropdown({required this.kind, required this.onChanged});

  final TripItemKind kind;
  final ValueChanged<TripItemKind> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<TripItemKind>(
        initialValue: kind,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Type'),
        items: [
          for (final k in const [TripItemKind.activity, TripItemKind.food])
            DropdownMenuItem(
              value: k,
              child: Row(children: [
                Icon(k.icon, size: 18, color: k.color),
                const SizedBox(width: 8),
                Expanded(child: Text(_KindLabel.label(k), overflow: TextOverflow.ellipsis)),
              ]),
            ),
        ],
        onChanged: (k) {
          if (k != null && k != kind) onChanged(k);
        },
      );
}

const _commonZones = [
  'America/New_York',
  'America/Chicago',
  'America/Denver',
  'America/Phoenix',
  'America/Los_Angeles',
  'America/Anchorage',
  'Pacific/Honolulu',
  'America/Toronto',
  'America/Mexico_City',
  'America/Sao_Paulo',
  'Europe/London',
  'Europe/Paris',
  'Europe/Berlin',
  'Europe/Athens',
  'Africa/Johannesburg',
  'Asia/Dubai',
  'Asia/Kolkata',
  'Asia/Bangkok',
  'Asia/Shanghai',
  'Asia/Tokyo',
  'Asia/Seoul',
  'Australia/Sydney',
  'Pacific/Auckland',
];

String _zoneCity(String zone) => zone.split('/').last.replaceAll('_', ' ');

Future<String?> _pickZone(BuildContext context, DateTime moment, String current) =>
    showDialog<String>(context: context, builder: (_) => _ZonePicker(moment: moment, current: current));

/// The usual time zones, or any at all by searching.
class _ZonePicker extends StatefulWidget {
  const _ZonePicker({required this.moment, required this.current});

  final DateTime moment;
  final String current;

  @override
  State<_ZonePicker> createState() => _ZonePickerState();
}

class _ZonePickerState extends State<_ZonePicker> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final q = _search.trim().toLowerCase().replaceAll(' ', '_');
    final shown = q.isEmpty
        ? _commonZones
        : allZones().where((z) => z.toLowerCase().contains(q) || zoneLabel(widget.moment, z).toLowerCase() == q).take(60).toList();
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 560),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
            child: TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _search = v),
              decoration: const InputDecoration(labelText: 'Time zone', hintText: 'A city, or PST', prefixIcon: Icon(Icons.search)),
            ),
          ),
          Flexible(
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 10), children: [
              for (final z in shown)
                ListTile(
                  dense: true,
                  selected: z == widget.current,
                  title: Text(_zoneCity(z), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  trailing: Text(zoneLabel(widget.moment, z), style: const TextStyle(fontSize: 13)),
                  onTap: () => Navigator.pop(context, z),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// The time zone of a place being edited: looked up from what's typed, unless
/// you picked one. Empty if neither: it goes by where you are then.
class _PlaceZone {
  _PlaceZone(this.zone, [this.askedFor = '']);

  String zone;
  String askedFor;
  bool picked = false;
  Future<void>? finding;

  void pick(String z) {
    zone = z;
    picked = true;
  }
}

Widget _field(TextEditingController c, String label,
        {IconData? icon,
        int? maxLines = 1,
        ValueChanged<String>? onChanged,
        TextInputType? keyboard,
        TextCapitalization caps = TextCapitalization.sentences}) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        maxLines: maxLines,
        minLines: maxLines == null ? 3 : 1,
        keyboardType: keyboard,
        textCapitalization: caps,
        // Multi-line boxes match the browser's copy of them (web/index.html).
        style: maxLines == 1 ? null : const TextStyle(height: 1.65),
        onChanged: onChanged,
        decoration: InputDecoration(labelText: label, alignLabelWithHint: maxLines != 1, prefixIcon: icon == null ? null : Icon(icon)),
      ),
    );

Widget _address(TextEditingController c, String label,
        {bool origin = false,
        ValueChanged<String>? onChanged,
        ValueChanged<String>? onSettled,
        ValueNotifier<bool>? onMap,
        List<SavedPlace> saved = const []}) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AddressField(
          controller: c,
          label: label,
          origin: origin,
          icon: origin ? Icons.trip_origin : Icons.place_outlined,
          onChanged: onChanged,
          onSettled: onSettled,
          onMap: onMap,
          saved: saved),
    );

Future<T?> _page<T>(BuildContext context, Widget page) =>
    Navigator.of(context).push<T>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => page));

// ---------------------------------------------------------------- the trip

/// A new trip starts with one question, the whole screen for it. It's made as
/// soon as you answer, and opens to plan.
Future<void> showNewTrip(BuildContext context, TripStore store) async {
  final how = await _page<TripHow>(context, const TripChooser());
  if (how == null) return;
  final start = addDays(dayStart(DateTime.now()), 7);
  final trip = Trip(
    id: store.newId(),
    title: switch (how) { TripHow.fly => 'New flight', TripHow.drive => 'Road trip', TripHow.other => 'New adventure' },
    how: how,
    zone: deviceZone,
    start: start,
    end: addDays(start, 3),
    color: tripColors[store.trips.length % tripColors.length],
  );
  // Not waiting for the save: offline, it finishes once you're back online.
  store.save(trip).catchError((Object _) {});
  store.freshId = trip.id;
  store.open(trip.id);
}

// ---------------------------------------------------------------- what's on it

/// Adds to the trip, or edits [existing].
Future<void> showItemEditor(BuildContext context, TripStore store, Trip trip, TripItemKind kind, {TripItem? existing, DateTime? start}) =>
    _page<void>(context, _editorFor(store, trip, kind, existing: existing, start: start));

Widget _editorFor(TripStore store, Trip trip, TripItemKind kind, {TripItem? existing, DateTime? start}) {
  return switch (kind) {
    TripItemKind.flight => _FlightEditor(store: store, trip: trip, existing: existing),
    TripItemKind.commute => _CommuteEditor(store: store, trip: trip, existing: existing),
    TripItemKind.travel => _TravelEditor(store: store, trip: trip, existing: existing),
    TripItemKind.stay ||
    TripItemKind.rental ||
    TripItemKind.food ||
    TripItemKind.activity =>
      _PlaceEditor(store: store, trip: trip, kind: kind, existing: existing, start: start),
  };
}

/// The main drive of a road trip: where from, where to, and when you leave.
Future<void> showMainDrive(BuildContext context, TripStore store, Trip trip) => _page<void>(
      context,
      _CommuteEditor(
        store: store,
        trip: trip,
        main: true,
        from: store.lastCommuteFrom,
        to: trip.destination,
        leaveAt: trip.momentOf(DateTime.utc(trip.start.year, trip.start.month, trip.start.day, 9)),
      ),
    );

/// A commute tied to a flight: to the airport (arriving two hours ahead), or from it.
Future<void> showCommuteForFlight(BuildContext context, TripStore store, Trip trip, TripItem flight, {required bool toAirport}) {
  final end = toAirport ? flight.departure : flight.arrival;
  final airport = [end.name, if (end.iata.isNotEmpty && !end.name.contains(end.iata)) '(${end.iata})'].join(' ').trim();
  return _page<void>(
    context,
    _CommuteEditor(
      store: store,
      trip: trip,
      flightId: flight.id,
      direction: toAirport ? 'to' : 'from',
      from: toAirport ? store.lastCommuteFrom : airport,
      to: toAirport ? airport : '',
      fromZone: toAirport ? '' : flight.endZone,
      toZone: toAirport ? flight.zone : '',
      arriveBy: toAirport ? flight.start.subtract(const Duration(hours: 2)) : null,
      leaveAt: toAirport ? null : flight.end.add(const Duration(minutes: 30)),
    ),
  );
}

/// Save and Delete for an item. Neither waits for the network: offline,
/// Firestore finishes once you're back online.
mixin _ItemEditing<W extends StatefulWidget> on State<W> {
  TripStore get store;
  Trip get trip;
  TripItem? get existing;
  String? error;

  /// The trip as it is now, in case it changed while this page was open.
  Trip get _current => store.trips.where((t) => t.id == trip.id).firstOrNull ?? trip;

  /// Everything you can change here, to tell whether you have.
  String get fingerprint;
  String? _first;

  /// Something's different from when this opened.
  bool get unsaved => fingerprint != (_first ??= fingerprint);

  /// Who this differs for from the trip, as you're changing it.
  late final Map<String, String> _access = {...?existing?.access};

  /// Who can see this: under its place, the same on every entry.
  Widget peoplePanel() => TripItemPeople(
        store: store,
        trip: _current,
        item: existing,
        access: _access,
        onChanged: (email, role) => setState(() => role == null ? _access.remove(email) : _access[email] = role),
      );

  void saveItem(TripItem item, {String? destination}) {
    store.saveItem(destination == null ? _current : _current.copyWith(destination: destination), item.withAccess(_access)).catchError((Object e) {
      if (mounted) setState(() => error = _clean(e));
    });
    Navigator.pop(context);
  }

  Future<void> deleteItem() async {
    final item = existing!;
    if (!await confirmAction(context, title: 'Delete “${item.title}”?', message: 'It comes off this trip.') || !mounted) return;
    store.deleteItem(_current, item).catchError((Object e) {
      if (mounted) setState(() => error = _clean(e));
    });
    Navigator.pop(context);
  }

  String get itemId => existing?.id ?? '${DateTime.now().microsecondsSinceEpoch}';

  /// Looks up [z] for [place] if that's something new to ask. What the clock
  /// says stays as you set it; only which zone it's in changes.
  Future<void> findZone(_PlaceZone z, String place) {
    final text = place.trim();
    if (z.picked || text == z.askedFor) return z.finding ?? Future.value();
    z.askedFor = text;
    return z.finding = () async {
      final found = text.isEmpty ? '' : await store.placeZone(text);
      if (!mounted || z.askedFor != text || found == null) return;
      setState(() => z.zone = found);
    }();
  }

  /// The zone you're in by [wall], going by the rest of the trip.
  String zoneThen(DateTime wall) => _current.zoneAt(_current.momentOf(wall, except: existing?.id), except: existing?.id);

  /// The places on this trip so far, to use again.
  List<SavedPlace> get savedPlaces => _current.savedPlaces;

  /// [hour] o'clock on the trip's first day.
  DateTime firstDayAt(int hour) => DateTime.utc(trip.start.year, trip.start.month, trip.start.day, hour);

  (String, String) get savedZones => _current.zones[existing!.id] ?? ('', '');
}

// ---------------------------------------------------------------- flights

class _FlightEditor extends StatefulWidget {
  const _FlightEditor({required this.store, required this.trip, this.existing});

  final TripStore store;
  final Trip trip;
  final TripItem? existing;

  @override
  State<_FlightEditor> createState() => _FlightEditorState();
}

class _FlightEditorState extends State<_FlightEditor> with _ItemEditing {
  @override
  TripStore get store => widget.store;
  @override
  Trip get trip => widget.trip;
  @override
  TripItem? get existing => widget.existing;

  late final _number = TextEditingController(text: '${widget.existing?.flight?['number'] ?? ''}');
  late final _airline = TextEditingController(text: '${widget.existing?.flight?['airline'] ?? ''}');
  late final _from = TextEditingController(text: widget.existing?.departure.iata ?? '');
  late final _to = TextEditingController(text: widget.existing?.arrival.iata ?? '');
  late final _notes = LinkingController(text: widget.existing?.notes ?? '');

  /// The wall clocks: at each airport, what its clock says.
  late DateTime _depart = existing != null ? wallOf(existing!.start, savedZones.$1) : firstDayAt(9);
  late DateTime _arrive = existing != null ? wallOf(existing!.end, savedZones.$2) : _depart.add(const Duration(hours: 2));
  late final _departZone = _PlaceZone(existing?.zone ?? '', (existing?.zone ?? '').isEmpty ? '' : _airport(_from.text));
  late final _arriveZone = _PlaceZone(existing?.endZone ?? '', (existing?.endZone ?? '').isEmpty ? '' : _airport(_to.text));
  Timer? _airportTyping;

  String get _fromZone => _departZone.zone.isNotEmpty ? _departZone.zone : zoneThen(_depart);
  String get _toZone => _arriveZone.zone.isNotEmpty ? _arriveZone.zone : _fromZone;

  static String _airport(String code) => code.trim().isEmpty ? '' : '${code.trim().toUpperCase()} airport';

  Future<void> _findAirports() => Future.wait([findZone(_departZone, _airport(_from.text)), findZone(_arriveZone, _airport(_to.text))]);

  void _airportTyped(String _) {
    _airportTyping?.cancel();
    _airportTyping = Timer(const Duration(milliseconds: 500), () {
      if (mounted) _findAirports();
    });
  }

  void _departAt(DateTime wall) => setState(() {
        final length = fromWall(_arrive, _toZone).difference(fromWall(_depart, _fromZone));
        _depart = wall;
        _arrive = wallOf(fromWall(wall, _fromZone).add(length), _toZone);
      });

  /// What the lookup found, kept whole (terminals, gates, the airports' clocks).
  late Map<String, dynamic>? _found = widget.existing?.flight;
  late final _confirmation = TextEditingController(text: existing?.confirmation ?? '');
  final _numberFocus = FocusNode();
  bool _looking = false;
  String? _lookupNote;

  /// It came from the lookup, so there's a summary to show instead of boxes to fill.
  late bool _lookedUp = _found?['lookedUp'] == true;

  /// Filling in the details by hand: chosen, or because the lookup couldn't.
  late bool _typingIn = existing != null && !_lookedUp;

  /// The number and date last looked up, not to ask twice.
  late String? _lookedFor = existing == null ? null : _asking;
  Future<void>? _lookingUp;

  String get _asking => '${_number.text.trim().toUpperCase()}|${_depart.year}-${_depart.month}-${_depart.day}';

  @override
  void initState() {
    super.initState();
    // Done with the number: look it up, with no button to press.
    _numberFocus.addListener(() {
      if (mounted && !_numberFocus.hasFocus && !_typingIn && _number.text.trim().isNotEmpty && _lookedFor != _asking) _lookup();
    });
  }

  @override
  void dispose() {
    _airportTyping?.cancel();
    for (final c in [_number, _airline, _from, _to, _notes, _confirmation]) {
      c.dispose();
    }
    _numberFocus.dispose();
    super.dispose();
  }

  Future<void> _lookup() => _lookingUp ??= _runLookup().whenComplete(() => _lookingUp = null);

  void _couldntFind(String note) => setState(() {
        _lookupNote = note;
        // Whatever was found for another number or date isn't this flight's.
        if (_lookedUp) _found = null;
        _lookedUp = false;
        _typingIn = true;
      });

  Future<void> _runLookup() async {
    final number = _number.text.trim();
    if (number.isEmpty) {
      setState(() => _lookupNote = 'Type the flight number first, like AA 1234.');
      return;
    }
    _lookedFor = _asking;
    setState(() {
      _looking = true;
      _lookupNote = null;
    });
    try {
      // The date it leaves, at the airport it leaves from.
      final legs = await store.lookupFlight(number, _depart);
      if (!mounted) return;
      if (legs.isEmpty) {
        _couldntFind('No flight $number found on that date. You can fill in the details below.');
      } else if (legs.length == 1) {
        await _apply(legs.first);
      } else {
        setState(() => _looking = false);
        final pick = await showDialog<Map<String, dynamic>>(
          context: context,
          builder: (ctx) => SimpleDialog(title: Text('$number flies more than one leg'), children: [
            for (final l in legs)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, l),
                child: Text('${FlightEnd(l['departure'] as Map?).code} – ${FlightEnd(l['arrival'] as Map?).code}'),
              ),
          ]),
        );
        if (pick != null) {
          await _apply(pick);
        } else {
          // Not settled yet: ask again if you try to save.
          _lookedFor = null;
        }
      }
    } catch (e) {
      if (mounted) _couldntFind(_clean(e));
    } finally {
      if (mounted) setState(() => _looking = false);
    }
  }

  Future<void> _apply(Map<String, dynamic> f) async {
    final dep = FlightEnd(f['departure'] as Map?), arr = FlightEnd(f['arrival'] as Map?);
    setState(() {
      _found = f;
      _lookedUp = true;
      _typingIn = false;
      _number.text = '${f['number'] ?? _number.text}';
      _lookedFor = _asking;
      _airline.text = '${f['airline'] ?? ''}';
      _from.text = dep.iata;
      _to.text = arr.iata;
      // Its airports' own zones if it said. If not, they're looked up next.
      _departZone
        ..zone = dep.timeZone
        ..askedFor = dep.timeZone.isNotEmpty ? _airport(dep.iata) : ''
        ..picked = false;
      _arriveZone
        ..zone = arr.timeZone
        ..askedFor = arr.timeZone.isNotEmpty ? _airport(arr.iata) : ''
        ..picked = false;
    });
    await _findAirports();
    if (!mounted) return;
    // The moments are what's certain: shown on each airport's clock.
    setState(() {
      if (dep.time != null) _depart = wallOf(dep.time!, _fromZone);
      if (arr.time != null) _arrive = wallOf(arr.time!, _toZone);
      _lookedFor = _asking;
    });
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
        context: context, initialDate: DateTime(_depart.year, _depart.month, _depart.day), firstDate: DateTime(2000), lastDate: DateTime(2100));
    if (d == null || !mounted) return;
    _departAt(DateTime.utc(d.year, d.month, d.day, _depart.hour, _depart.minute));
    if (_number.text.trim().isNotEmpty) _lookup();
  }

  /// What the lookup found: when it leaves and lands, how long, and the rest.
  Widget _flightCard() {
    final dep = FlightEnd(_found?['departure'] as Map?), arr = FlightEnd(_found?['arrival'] as Map?);
    final depart = fromWall(_depart, _fromZone), arrive = fromWall(_arrive, _toZone);
    final miles = _found?['miles'] as num?;
    final status = '${_found?['status'] ?? ''}';
    const quiet = TextStyle(color: AppColors.secondaryText, fontSize: 13, height: 1.45);
    final at = [if (dep.terminal.isNotEmpty) 'Terminal ${dep.terminal}', if (dep.gate.isNotEmpty) 'Gate ${dep.gate}'];
    final landing = [
      if (arr.terminal.isNotEmpty) 'Terminal ${arr.terminal}',
      if (arr.gate.isNotEmpty) 'Gate ${arr.gate}',
      if (arr.baggageBelt.isNotEmpty) 'Bags at belt ${arr.baggageBelt}'
    ];
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      decoration: tileDecoration(raised: true),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Text([if (_airline.text.isNotEmpty) _airline.text, _number.text.trim()].join(' · '),
                maxLines: 2, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          if (status.isNotEmpty && status != 'Unknown') Text(status, style: quiet),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(flex: 5, child: _TimeEnd(label: _from.text.trim().toUpperCase(), at: depart, zone: _fromZone, chosen: true)),
          Expanded(
            flex: 4,
            child: _TravelTime(
              icon: Icons.flight,
              text: _looking ? null : tripMinutes(arrive.difference(depart).inMinutes),
              below: miles == null ? '' : '${miles.round()} mi',
            ),
          ),
          Expanded(flex: 5, child: _TimeEnd(label: _to.text.trim().toUpperCase(), at: arrive, zone: _toZone, chosen: true, end: true)),
        ]),
        const SizedBox(height: 10),
        if (dep.name.isNotEmpty || arr.name.isNotEmpty) Text([dep.name, arr.name].where((n) => n.isNotEmpty).join(' to '), style: quiet),
        if (at.isNotEmpty) Text('Leaves from ${at.join(', ')}', style: quiet),
        if (landing.isNotEmpty) Text('Lands at ${landing.join(', ')}', style: quiet),
        if ('${_found?['aircraft'] ?? ''}'.isNotEmpty) Text('${_found!['aircraft']}', style: quiet),
        Wrap(alignment: WrapAlignment.end, children: [
          TextButton(
            onPressed: _looking ? null : _lookup,
            style: TextButton.styleFrom(foregroundColor: AppColors.secondaryText),
            child: const Text('Look up again'),
          ),
          TextButton(
            onPressed: () => setState(() => _typingIn = true),
            style: TextButton.styleFrom(foregroundColor: AppColors.secondaryText),
            child: const Text('Change details'),
          ),
        ]),
      ]),
    );
  }

  @override
  String get fingerprint => [
        for (final c in [_number, _airline, _from, _to, _notes, _confirmation]) c.text,
        _depart,
        _arrive,
        _departZone.picked,
        _arriveZone.picked,
        _access,
      ].join('|');

  bool _hasRide(String direction) => _current.items.any((i) => i.commute?['flightId'] == existing!.id && i.commute?['direction'] == direction);

  Future<void> _addRide({required bool toAirport}) async {
    await showCommuteForFlight(context, store, _current, existing!, toAirport: toAirport);
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    var number = _number.text.trim().toUpperCase();
    if (number.isEmpty && _from.text.trim().isEmpty && _to.text.trim().isEmpty) {
      setState(() => error = 'Fill in the flight number or where it’s going.');
      return;
    }
    // Pressing Save with just a number looks it up first. If it can't, the
    // boxes to fill in have come up, so stop to let you.
    final running = _lookingUp;
    if (running != null || (number.isNotEmpty && !_typingIn && _lookedFor != _asking)) {
      await (running ?? _lookup());
      if (!mounted || !_lookedUp) return;
    }
    setState(() => _looking = true);
    await _findAirports();
    if (!mounted) return;
    setState(() => _looking = false);
    final depart = fromWall(_depart, _fromZone), arrive = fromWall(_arrive, _toZone);
    if (!arrive.isAfter(depart)) {
      setState(() => error = 'It has to land after it takes off.');
      return;
    }
    // As the lookup wrote them, if it just did.
    number = _number.text.trim().toUpperCase();
    final from = _from.text.trim().toUpperCase(), to = _to.text.trim().toUpperCase();
    final found = _found ?? const <String, dynamic>{};
    // A changed time or airport overrides what was looked up for that end.
    Map<String, dynamic> end(Object? before, String code, DateTime at, String zone) {
      final m = before is Map ? Map<String, dynamic>.from(before) : <String, dynamic>{};
      final same = FlightEnd(m).time == at;
      return {
        ...m,
        'iata': code,
        'timeZone': zone,
        if ('${m['iata'] ?? ''}' != code) 'name': '',
        if (!same) ...{'scheduled': at.millisecondsSinceEpoch, 'revised': null, 'scheduledLocal': null, 'revisedLocal': null},
      };
    }

    final route = [if (from.isNotEmpty) from, if (to.isNotEmpty) to].join(' – ');
    saveItem(TripItem(
      id: itemId,
      kind: TripItemKind.flight,
      title: [if (number.isNotEmpty) number, if (route.isNotEmpty) route].join(' · '),
      start: depart,
      end: arrive,
      zone: _departZone.zone,
      endZone: _arriveZone.zone,
      location: FlightEnd(found['departure'] as Map?).name,
      notes: _notes.text.trim(),
      confirmation: _confirmation.text.trim(),
      flight: {
        ...found,
        'lookedUp': _lookedUp,
        'number': number,
        'airline': _airline.text.trim(),
        'departure': end(found['departure'], from, depart, _departZone.zone),
        'arrival': end(found['arrival'], to, arrive, _arriveZone.zone),
      },
    ));
  }

  @override
  Widget build(BuildContext context) {
    return EntryForm(
      unsaved: unsaved,
      title: existing == null ? 'Add a flight' : 'Edit flight',
      saving: _looking,
      onSave: _save,
      error: error,
      onDelete: existing == null ? null : deleteItem,
      deleteLabel: 'Delete flight',
      // No map to go with: on a phone, the people go last.
      mapAt: 99,
      people: peoplePanel(),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: EntryTitleRow(
            title: TextField(
              controller: _number,
              focusNode: _numberFocus,
              autofocus: existing == null,
              textCapitalization: TextCapitalization.characters,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _lookup(),
              decoration: const InputDecoration(labelText: 'Flight number', hintText: 'AA 1234', prefixIcon: Icon(Icons.flight)),
            ),
            side: const _KindLabel(kind: TripItemKind.flight),
            sideIsLabel: true,
          ),
        ),
        // The number and the date are all it takes.
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (!_typingIn)
            OutlinedButton.icon(
              onPressed: _pickDate,
              icon: const Icon(Icons.calendar_today, size: 16),
              label: Text(DateFormat.yMMMEd().format(_depart)),
            ),
          if (!_lookedUp || _lookedFor != _asking)
            FilledButton.icon(
              onPressed: _looking ? null : _lookup,
              icon: _looking
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.search, size: 18),
              label: const Text('Look up flight'),
            ),
          if (!_typingIn && !_lookedUp)
            TextButton(
              onPressed: () => setState(() => _typingIn = true),
              style: TextButton.styleFrom(foregroundColor: AppColors.secondaryText),
              child: const Text('Type it in yourself'),
            ),
        ]),
        if (_lookupNote != null)
          Padding(
              padding: const EdgeInsets.only(top: 8), child: Text(_lookupNote!, style: const TextStyle(color: AppColors.secondaryText, height: 1.4))),
        if (_lookedUp && !_typingIn) _flightCard(),
        if (_typingIn) ...[
          const SizedBox(height: 20),
          _field(_airline, 'Airline', caps: TextCapitalization.words),
          Row(children: [
            Expanded(child: _field(_from, 'From', caps: TextCapitalization.characters, onChanged: _airportTyped)),
            const SizedBox(width: 10),
            Expanded(child: _field(_to, 'To', caps: TextCapitalization.characters, onChanged: _airportTyped)),
          ]),
          _When(label: 'Takes off', value: _depart, zone: _fromZone, onChanged: _departAt, onZone: (z) => setState(() => _departZone.pick(z))),
          _When(
              label: 'Lands',
              value: _arrive,
              zone: _toZone,
              onChanged: (w) => setState(() => _arrive = w),
              onZone: (z) => setState(() => _arriveZone.pick(z))),
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text('Each time is on the clock at its airport.', style: TextStyle(color: AppColors.secondaryText, fontSize: 12.5, height: 1.4)),
          ),
        ],
        const SizedBox(height: 14),
        _field(_confirmation, 'Confirmation number', caps: TextCapitalization.characters),
        NotesField(controller: _notes, label: 'Notes (seat, bags…)'),
        if (existing != null)
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (!_hasRide('to'))
              OutlinedButton.icon(
                onPressed: () => _addRide(toAirport: true),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Ride to the airport'),
              ),
            if (!_hasRide('from'))
              OutlinedButton.icon(
                onPressed: () => _addRide(toAirport: false),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Ride from the airport'),
              ),
          ]),
      ],
    );
  }
}

// ---------------------------------------------------------------- commutes

// Drives from before everything was a drive can be these others too.
const _modes = [('DRIVE', 'Drive'), ('TRANSIT', 'Transit'), ('WALK', 'Walk'), ('BICYCLE', 'Bike')];

class _CommuteEditor extends StatefulWidget {
  const _CommuteEditor(
      {required this.store,
      required this.trip,
      this.existing,
      this.flightId,
      this.direction,
      this.from,
      this.to,
      this.fromZone = '',
      this.toZone = '',
      this.arriveBy,
      this.leaveAt,
      this.main = false});

  final TripStore store;
  final Trip trip;
  final TripItem? existing;
  final String? flightId;

  /// 'to' or 'from' the airport, when tied to a flight.
  final String? direction;
  final String? from;
  final String? to;

  /// What's already known of where it starts and ends, from a flight.
  final String fromZone;
  final String toZone;
  final DateTime? arriveBy;
  final DateTime? leaveAt;

  /// A road trip's main drive, and not a commute along the way.
  final bool main;

  @override
  State<_CommuteEditor> createState() => _CommuteEditorState();
}

/// A stop being edited on the main drive.
class _StopRow {
  _StopRow(DriveStop s)
      : place = TextEditingController(text: s.place),
        minutes = s.minutes,
        zone = _PlaceZone(s.zone, s.zone.isEmpty ? '' : s.place),
        onMap = ValueNotifier(s.place.isNotEmpty && s.onMap);

  final TextEditingController place;
  int minutes;
  final _PlaceZone zone;
  final ValueNotifier<bool> onMap;
}

const _stopLengths = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180];

class _CommuteEditorState extends State<_CommuteEditor> with _ItemEditing {
  @override
  TripStore get store => widget.store;
  @override
  Trip get trip => widget.trip;
  @override
  TripItem? get existing => widget.existing;

  Map<String, dynamic> get _old => widget.existing?.commute ?? const {};

  /// A road trip's main drive sets where the trip's going. Otherwise it's a drive like any other.
  bool get _main => widget.main || (trip.getting == TripHow.drive && existing != null && existing!.id == trip.mainDrive?.id);

  late final _from = TextEditingController(text: '${_old['from'] ?? widget.from ?? store.lastCommuteFrom}');
  late final _to = TextEditingController(text: '${_old['to'] ?? widget.to ?? ''}');
  late final _notes = LinkingController(text: widget.existing?.notes ?? '');
  late final String _mode = '${_old['mode'] ?? 'DRIVE'}';
  late bool _arriving = widget.existing != null ? _old['timing'] != 'leave' : widget.leaveAt == null;

  late final _fromOnMap = ValueNotifier(
      existing != null ? _old['fromOnMap'] != false : _from.text.isNotEmpty && (_from.text != store.lastCommuteFrom || store.lastCommuteFromOnMap));
  late final _toOnMap = ValueNotifier(existing != null ? _old['toOnMap'] != false : _to.text.isNotEmpty);

  /// Where it starts and ends are real places, so Google can say how long it
  /// takes. Only clicking a suggestion makes one real; what's just typed is a name.
  bool get _endsOnMap => _fromOnMap.value && _toOnMap.value;

  /// Has both ends, one or both of them just a name.
  bool get _endsAreNames => _from.text.trim().isNotEmpty && _to.text.trim().isNotEmpty && !_endsOnMap;

  /// Stops that are just names, not part of the route. Their time still counts.
  List<String> get _stopNames => [
        for (final s in _stops)
          if (s.place.text.trim().isNotEmpty && !s.onMap.value) s.place.text.trim()
      ];

  /// You chose a way to go, rather than Google picking.
  bool _routeChosen = false;

  /// Typing the time only because a place is just a name. Pick them all, and Google takes over.
  bool _typingForNames = false;

  late final _fromPlace = existing != null
      ? _PlaceZone(existing!.zone, existing!.zone.isEmpty ? '' : _from.text.trim())
      : _PlaceZone(widget.fromZone, widget.fromZone.isEmpty ? '' : _from.text.trim());
  late final _toPlace = existing != null
      ? _PlaceZone(existing!.endZone, existing!.endZone.isEmpty ? '' : _to.text.trim())
      : _PlaceZone(widget.toZone, widget.toZone.isEmpty ? '' : _to.text.trim());

  /// What the clock says at the time you set: when you arrive, or when you leave.
  late DateTime _wall = existing != null
      ? (_arriving ? wallOf(existing!.end, savedZones.$2) : wallOf(existing!.start, savedZones.$1))
      : widget.arriveBy != null
          ? wallOf(widget.arriveBy!, _toPlace.zone.isNotEmpty ? _toPlace.zone : _current.zoneAt(widget.arriveBy!))
          : widget.leaveAt != null
              ? wallOf(widget.leaveAt!, _fromPlace.zone.isNotEmpty ? _fromPlace.zone : _current.zoneAt(widget.leaveAt!))
              : firstDayAt(9);

  /// Leaving is on the clock where you leave, arriving on the one where you arrive.
  String get _fromZone => _fromPlace.zone.isNotEmpty ? _fromPlace.zone : zoneThen(_wall);
  String get _toZone => _toPlace.zone.isNotEmpty ? _toPlace.zone : _fromZone;
  String get _setZone => _arriving ? _toZone : _fromZone;

  /// The moment of the time you set.
  DateTime get _at => fromWall(_wall, _setZone);

  /// The clock at stop [n], which is its own, or else the one before it.
  String _stopZone(int n) {
    var zone = _fromZone;
    for (var i = 0; i <= n; i++) {
      if (_stops[i].zone.zone.isNotEmpty) zone = _stops[i].zone.zone;
    }
    return zone;
  }

  /// Only for real places, as a name could be anywhere.
  Future<void> _findZones() => Future.wait([
        findZone(_fromPlace, _fromOnMap.value ? _from.text : ''),
        findZone(_toPlace, _toOnMap.value ? _to.text : ''),
        for (final s in _stops) findZone(s.zone, s.onMap.value ? s.place.text : ''),
      ]);
  late int? _meters = (_old['meters'] as num?)?.toInt();
  late bool _predicted = _old['predicted'] == true;
  late bool _fromGoogle = _old['fromGoogle'] == true;
  late final _stops = [for (final s in widget.existing?.stops ?? const <DriveStop>[]) _StopRow(s)];

  /// The ways to go, at that time of that day; the one you're taking.
  late List<Map> _routes = [
    for (final r in (_old['routes'] as List? ?? const []))
      if (r is Map) r
  ];
  late String? _routeName = _old['route'] as String?;

  /// Each stretch of the drive in seconds, between stops, from Google.
  late List<int> _legs = [for (final l in (_old['legs'] as List? ?? const [])) (l as num).toInt()];

  /// How long the driving takes, in minutes.
  late int? _length = (_old['minutes'] as num?)?.toInt();

  /// Typing your own travel time instead of Google's.
  late bool _typing = _length != null && !_fromGoogle;
  late final _typedHours = TextEditingController(text: _typing && (_length ?? 0) >= 60 ? '${_length! ~/ 60}' : '');
  late final _typedMinutes = TextEditingController(text: _typing && (_length ?? 0) % 60 != 0 ? '${_length! % 60}' : '');

  bool _asking = false;
  String? _problem;
  Timer? _soon;

  // What the shown time was worked out for; asked again if any of it changes.
  String _askedFor = '';
  String get _question => [
        _from.text.trim(),
        _to.text.trim(),
        _mode,
        _arriving,
        _at.millisecondsSinceEpoch,
        ..._stopPlaces,
        // Arriving by a set time, stops change when you leave, and so the traffic.
        if (_arriving) _stopMinutes,
      ].join('|');

  /// The stops on the route, in order: first to second, second to third.
  List<String> get _stopPlaces => [
        for (final s in _stops)
          if (s.place.text.trim().isNotEmpty && s.onMap.value) s.place.text.trim()
      ];
  int get _stopMinutes => _stops.fold(0, (n, s) => n + s.minutes);

  /// Driving and stops together.
  Duration? get _journey => _length == null ? null : Duration(minutes: _length! + _stopMinutes);

  /// When you'd reach each stop, if Google has timed each stretch.
  List<DateTime?> _stopTimes(DateTime? leave) {
    if (leave == null || !_fromGoogle || !_upToDate || _legs.length != _stopPlaces.length + 1) return List.filled(_stops.length, null);
    var at = leave;
    var leg = 0;
    return [
      for (final s in _stops)
        () {
          final onRoute = s.place.text.trim().isNotEmpty && s.onMap.value;
          if (onRoute) at = at.add(Duration(seconds: _legs[leg++]));
          // Not on the route, so there's no telling when you'd get there.
          final reached = onRoute ? at : null;
          at = at.add(Duration(minutes: s.minutes));
          return reached;
        }(),
    ];
  }

  bool get _upToDate => _askedFor == _question;

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) _askedFor = _question;
    // Tied to a flight with both ends known: no need to press anything.
    if (widget.existing == null && (widget.from ?? '').isNotEmpty && (widget.to ?? '').isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ask();
      });
    }
  }

  @override
  void dispose() {
    _soon?.cancel();
    for (final c in [_from, _to, _notes, _typedHours, _typedMinutes, for (final s in _stops) s.place]) {
      c.dispose();
    }
    for (final n in [_fromOnMap, _toOnMap, for (final s in _stops) s.onMap]) {
      n.dispose();
    }
    super.dispose();
  }

  /// Something changed that changes the answer: get a new one, unless the time is your own.
  void _changed() {
    final complete = _from.text.trim().isNotEmpty && _to.text.trim().isNotEmpty;
    if (complete && !_endsOnMap && !_typing && !_upToDate) {
      _typeIt();
      _typingForNames = true;
    } else if (_endsOnMap && _typingForNames) {
      _typing = _typingForNames = false;
    }
    setState(() {});
    _findZones();
    _soon?.cancel();
    if (_typing || !complete || !_endsOnMap) return;
    _soon = Timer(const Duration(milliseconds: 350), () {
      if (mounted && !_upToDate) _ask();
    });
  }

  /// Asks Google how long it takes at that time of that day. Returns whether it answered.
  Future<bool> _ask() async {
    _soon?.cancel();
    final from = _from.text.trim(), to = _to.text.trim();
    if (from.isEmpty || to.isEmpty) {
      setState(() => _problem = 'Fill in where you’re leaving from and where you’re going.');
      return false;
    }
    // Google isn't asked about a name: it would just guess at somewhere.
    if (!_endsOnMap) {
      if (!_typing) _typeIt();
      _typingForNames = true;
      setState(() {});
      return false;
    }
    setState(() {
      _asking = true;
      _problem = null;
    });
    await _findZones();
    if (!mounted) return false;
    final question = _question;
    try {
      final r = await store.commuteTime(
        from: from,
        to: to,
        mode: _mode,
        leaveAt: _arriving ? null : _at,
        arriveBy: _arriving ? _at : null,
        stops: _stopPlaces,
        stopMinutes: _stopMinutes,
      );
      if (!mounted) return false;
      // Changed while it was asking: this answer is for something else.
      if (_question != question) return _ask();
      setState(() {
        _legs = [for (final l in (r['legs'] as List? ?? const [])) (l as num).toInt()];
        _length = (r['minutes'] as num).toInt();
        _meters = (r['meters'] as num?)?.toInt();
        _routes = [
          for (final o in (r['routes'] as List? ?? const []))
            if (o is Map) o
        ];
        // Still the way you picked, if it's still one of the ways to go.
        final kept = _routes.where((o) => o['name'] == _routeName).firstOrNull;
        if (kept != null) {
          _length = (kept['minutes'] as num).toInt();
          _meters = (kept['meters'] as num?)?.toInt();
        } else {
          _routeName = _routes.isEmpty ? null : '${_routes.first['name']}';
        }
        _predicted = r['predicted'] == true;
        _fromGoogle = true;
        _typing = _typingForNames = false;
        _askedFor = _question;
      });
      return true;
    } catch (e) {
      if (mounted) setState(() => _problem = _clean(e));
      return false;
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  Future<void> _save() async {
    _soon?.cancel();
    final from = _from.text.trim(), to = _to.text.trim();
    if (to.isEmpty) {
      setState(() => error = 'Fill in where you’re going.');
      return;
    }
    await _findZones();
    if (!mounted) return;
    // Just a name somewhere: Google can't tell how long that takes.
    if (!_typing && !_upToDate && !_endsOnMap) {
      _typeIt();
      _typingForNames = true;
      setState(() {});
      return;
    }
    // Changed since it was asked (or never asked): ask, unless you typed your own.
    if (!_typing && !_upToDate) {
      final answered = await _ask();
      if (!mounted) return;
      if (!answered) {
        if (_length == null) {
          setState(() {
            _typing = true;
            error = 'Google didn’t answer, so type how long it takes.';
          });
          return;
        }
        _fromGoogle = false;
      }
    }
    if (!mounted) return;
    final minutes = _length;
    if (minutes == null || minutes <= 0) {
      setState(() => error = 'Type how long it takes.');
      return;
    }
    final length = Duration(minutes: minutes + _stopMinutes);
    final leaving = _arriving ? _at.subtract(length) : _at;
    final reached = _stopTimes(leaving);
    final mode = _modes.firstWhere((m) => m.$1 == _mode).$2;
    saveItem(
        TripItem(
          id: itemId,
          kind: TripItemKind.commute,
          title: '$mode to ${placeName(to)}',
          start: _arriving ? _at.subtract(length) : _at,
          end: _arriving ? _at : _at.add(length),
          zone: _fromPlace.zone,
          endZone: _toPlace.zone,
          location: to,
          notes: _notes.text.trim(),
          commute: {
            'from': from,
            'to': to,
            if (!_fromOnMap.value) 'fromOnMap': false,
            if (!_toOnMap.value) 'toOnMap': false,
            'mode': _mode,
            'minutes': minutes,
            if (_stops.isNotEmpty) ...{
              'stops': [
                for (final (n, s) in _stops.indexed)
                  DriveStop(place: s.place.text.trim(), minutes: s.minutes, at: reached[n], zone: s.zone.zone, onMap: s.onMap.value).toJson(),
              ],
              'legs': _fromGoogle ? _legs : null,
            },
            if (_fromGoogle && _routeName != null && _routeName!.isNotEmpty) 'route': _routeName,
            if (_fromGoogle && _routes.length > 1) 'routes': [for (final o in _routes) Map<String, dynamic>.from(o)],
            'meters': _fromGoogle ? _meters : null,
            'predicted': _fromGoogle && _predicted,
            'fromGoogle': _fromGoogle,
            'timing': _arriving ? 'arrive' : 'leave',
            'flightId': _old['flightId'] ?? widget.flightId,
            'direction': _old['direction'] ?? widget.direction,
          },
        ),
        destination: _main ? placeName(to) : null);
  }

  @override
  String get fingerprint => [
        for (final c in [_from, _to, _notes, _typedHours, _typedMinutes]) c.text,
        for (final s in _stops) '${s.place.text}:${s.minutes}',
        _wall,
        _arriving,
        _routeChosen ? _routeName : '',
        _fromPlace.picked,
        _toPlace.picked,
        _access,
      ].join('|');

  void _typed(String _) {
    final total = (int.tryParse(_typedHours.text.trim()) ?? 0) * 60 + (int.tryParse(_typedMinutes.text.trim()) ?? 0);
    setState(() {
      _length = total > 0 ? total : null;
      _fromGoogle = false;
      _typingForNames = false;
    });
  }

  void _typeIt() {
    final l = _length;
    setState(() {
      _typing = true;
      _fromGoogle = false;
      _typedHours.text = l != null && l >= 60 ? '${l ~/ 60}' : '';
      _typedMinutes.text = l != null && l % 60 != 0 ? '${l % 60}' : '';
    });
  }

  /// One way to go, to pick.
  Widget _routeRow(Map o) {
    final chosen = o['name'] == _routeName;
    final minutes = (o['minutes'] as num).toInt();
    final meters = (o['meters'] as num?)?.toInt() ?? 0;
    final name = '${o['name']}';
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => setState(() {
        _routeChosen = true;
        _routeName = name;
        _length = minutes;
        _meters = meters;
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(children: [
          Icon(chosen ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 18, color: chosen ? AppColors.primaryText : AppColors.secondaryText),
          const SizedBox(width: 10),
          Expanded(
            child: Text(name.isEmpty ? 'Another way' : 'via $name',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, fontWeight: chosen ? FontWeight.w700 : FontWeight.w500)),
          ),
          const SizedBox(width: 10),
          Text('${tripMinutes(minutes)} · ${(meters / 1609.34).toStringAsFixed(0)} mi',
              style: TextStyle(fontSize: 12.5, color: chosen ? AppColors.primaryText : AppColors.secondaryText)),
        ]),
      ),
    );
  }

  /// A stop on the way: where (or nothing, for just time set aside), and how long.
  Widget _stopRow(int n, _StopRow s) {
    String length(int m) => tripMinutes(m);
    return Padding(
      key: ObjectKey(s),
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(children: [
        Expanded(
          child: AddressField(
            controller: s.place,
            label: 'Stop ${n + 1}',
            icon: Icons.local_cafe_outlined,
            stop: n,
            onMap: s.onMap,
            saved: savedPlaces,
            onChanged: (_) => setState(() {}),
            onSettled: (_) => _changed(),
          ),
        ),
        const SizedBox(width: 8),
        PopupMenuButton<int>(
          tooltip: 'How long you’ll stop',
          initialValue: s.minutes,
          position: PopupMenuPosition.under,
          onSelected: (m) {
            s.minutes = m;
            _changed();
          },
          itemBuilder: (_) => [for (final m in _stopLengths) PopupMenuItem(value: m, child: Text(length(m)))],
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(100), border: Border.all(color: const Color(0x40FFFFFF))),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(length(s.minutes), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const Icon(Icons.arrow_drop_down, size: 18, color: AppColors.secondaryText),
            ]),
          ),
        ),
        IconButton(
          tooltip: 'Remove this stop',
          icon: const Icon(Icons.close, size: 18, color: AppColors.secondaryText),
          onPressed: () {
            _stops.remove(s);
            // Its box is still on screen until the next frame.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              s.place.dispose();
              s.onMap.dispose();
            });
            _changed();
          },
        ),
      ]),
    );
  }

  /// Leave and arrive, the travel time between them, and where it came from.
  Widget _timeCard() {
    final known = _journey;
    final leave = _arriving ? (known == null ? null : _at.subtract(known)) : _at;
    final arrive = _arriving ? _at : (known == null ? null : _at.add(known));
    final miles = _fromGoogle && _upToDate && _meters != null ? _meters! / 1609.34 : null;
    final stale = known != null && !_typing && !_upToDate;
    final names =
        [if (!_fromOnMap.value) _from.text.trim(), if (!_toOnMap.value) _to.text.trim()].where((n) => n.isNotEmpty).map((n) => '“$n”').join(' and ');
    final source = _endsAreNames
        ? '$names ${names.contains(' and ') ? 'aren’t' : 'isn’t'} on the map, so type how long it takes. For Google’s estimate, click the place in the list as you type it.'
        : _typing
            ? 'Your own estimate.'
            : !_fromGoogle || !_upToDate
                ? null
                : _predicted
                    ? 'From Google, for that time of that day.'
                    : 'That time has passed, so this is Google’s estimate for the same time next week.';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      decoration: tileDecoration(raised: true),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(flex: 5, child: _TimeEnd(label: 'LEAVE', at: leave, zone: _fromZone, chosen: !_arriving)),
          Expanded(
            flex: 4,
            child: _TravelTime(
              icon: const {'TRANSIT': Icons.train, 'WALK': Icons.directions_walk, 'BICYCLE': Icons.directions_bike}[_mode] ?? Icons.directions_car,
              text: _asking ? null : (known == null ? '—' : tripMinutes(known.inMinutes)),
              faded: stale,
              below: miles == null ? '' : '${miles.toStringAsFixed(miles < 10 ? 1 : 0)} mi',
            ),
          ),
          Expanded(flex: 5, child: _TimeEnd(label: 'ARRIVE', at: arrive, zone: _toZone, chosen: _arriving, end: true)),
        ]),
        if (_routes.length > 1 && _fromGoogle && _upToDate && !_typing) ...[
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 6),
          for (final o in _routes) _routeRow(o),
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('These times are for the day and time you set. The map shows Google’s own pick for right now, so it can differ.',
                style: TextStyle(color: AppColors.secondaryText, fontSize: 12, height: 1.35)),
          ),
        ],
        if (_stops.isNotEmpty && _length != null) ...[
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 10),
          Text(
            '${tripMinutes(_length!)} driving + ${tripMinutes(_stopMinutes)} at ${_stops.length == 1 ? 'your stop' : '${_stops.length} stops'}',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          for (final (n, at) in _stopTimes(leave).indexed)
            if (at != null)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  '${_stops[n].place.text.trim().isEmpty ? 'Stop' : placeName(_stops[n].place.text)}: '
                  '${clockIn(at, _stopZone(n))} – ${clockIn(at.add(Duration(minutes: _stops[n].minutes)), _stopZone(n))}',
                  style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5),
                ),
              ),
          if (_stopNames.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                'Not on the map, so left out of the route: ${_stopNames.map(placeName).join(', ')}. ${_stopNames.length == 1 ? 'Its' : 'Their'} time still counts.',
                style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5, height: 1.35),
              ),
            ),
        ],
        const SizedBox(height: 12),
        if (_problem != null)
          Text(_problem!, style: const TextStyle(color: AppColors.secondaryText, fontSize: 13, height: 1.4))
        else if (source != null)
          Text(
            source,
            style: const TextStyle(color: AppColors.secondaryText, fontSize: 13, height: 1.4),
          ),
        if (_typing) ...[
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _typedHours,
                keyboardType: TextInputType.number,
                onChanged: _typed,
                decoration: const InputDecoration(labelText: 'Hours'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _typedMinutes,
                keyboardType: TextInputType.number,
                onChanged: _typed,
                decoration: const InputDecoration(labelText: 'Minutes'),
              ),
            ),
          ]),
        ],
        Wrap(alignment: WrapAlignment.end, children: [
          if (!_asking && !_endsAreNames && (_typing || !_upToDate))
            TextButton.icon(
              onPressed: () {
                _askedFor = '';
                _ask();
              },
              icon: const Icon(Icons.schedule, size: 16),
              label: const Text('Estimate the drive'),
            ),
          if (!_typing)
            TextButton(
              onPressed: _typeIt,
              style: TextButton.styleFrom(foregroundColor: AppColors.secondaryText),
              child: const Text('Type it yourself'),
            ),
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) => EntryForm(
        unsaved: unsaved,
        title: existing == null ? 'Add a drive' : 'Edit drive',
        saving: _asking,
        onSave: _save,
        error: error,
        onDelete: existing == null ? null : deleteItem,
        deleteLabel: 'Delete drive',
        people: peoplePanel(),
        location: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          _address(_from, 'Starting from',
              origin: true, onMap: _fromOnMap, saved: savedPlaces, onChanged: (_) => setState(() {}), onSettled: (_) => _changed()),
          for (final (n, s) in _stops.indexed) _stopRow(n, s),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextButton.icon(
                onPressed: _stops.length >= 8
                    ? null
                    : () {
                        _stops.add(_StopRow(const DriveStop(minutes: 30)));
                        _changed();
                      },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add a stop'),
              ),
            ),
          ),
          _address(_to, 'Final destination', onMap: _toOnMap, saved: savedPlaces, onChanged: (_) => setState(() {}), onSettled: (_) => _changed()),
        ]),
        children: [
          // All on one row where there's room.
          Builder(builder: (context) {
            final when = _When(
              value: _wall,
              zone: _setZone,
              onChanged: (w) {
                _wall = w;
                _changed();
              },
              onZone: (z) {
                (_arriving ? _toPlace : _fromPlace).pick(z);
                _changed();
              },
            );
            return Wrap(spacing: 8, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
              PillTabs<bool>(
                items: const [(false, 'Leave at'), (true, 'Arrive by')],
                selected: _arriving,
                onSelected: (v) {
                  if (v == _arriving) return;
                  // The other end becomes the one you set, so nothing jumps.
                  final known = _journey;
                  final other = known == null ? _at : (v ? _at.add(known) : _at.subtract(known));
                  _arriving = v;
                  _wall = wallOf(other, _setZone);
                  _changed();
                },
              ),
              ...when.parts(context),
              const Padding(padding: EdgeInsets.only(left: 6), child: _KindLabel(kind: TripItemKind.commute)),
            ]);
          }),
          const SizedBox(height: 14),
          _timeCard(),
          const SizedBox(height: 16),
          NotesField(controller: _notes),
        ],
      );
}

/// One end of the journey. The one you set is bright; the one worked out from
/// it is a little quieter.
class _TimeEnd extends StatelessWidget {
  const _TimeEnd({required this.label, required this.at, required this.zone, required this.chosen, this.end = false});

  final String label;
  final DateTime? at;
  final String zone;
  final bool chosen;
  final bool end;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: end ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: AppColors.secondaryText, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child:
              Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(
              at == null ? '—' : DateFormat.jm().format(inZone(at!, zone)),
              maxLines: 1,
              style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.5, color: chosen ? AppColors.primaryText : const Color(0xD9FFFFFF)),
            ),
            if (at != null) ...[
              const SizedBox(width: 5),
              Text(zoneLabel(at!, zone), maxLines: 1, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
            ],
          ]),
        ),
        Text(at == null ? ' ' : DateFormat('EEE, MMM d').format(inZone(at!, zone)),
            maxLines: 1, style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
      ]);
}

/// The travel time, on the line between leaving and arriving. Null while asking.
class _TravelTime extends StatelessWidget {
  const _TravelTime({required this.icon, required this.text, required this.below, this.faded = false});

  final IconData icon;
  final String? text;
  final String below;
  final bool faded;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(children: [
          SizedBox(
            height: 20,
            child: text == null
                ? const Center(child: SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2)))
                : FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(text!,
                        maxLines: 1,
                        style:
                            TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: faded ? AppColors.secondaryText : AppColors.primaryText)),
                  ),
          ),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(child: Container(height: 1.5, color: const Color(0x33FFFFFF))),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Icon(icon, size: 16, color: AppColors.secondaryText)),
            Expanded(child: Container(height: 1.5, color: const Color(0x33FFFFFF))),
          ]),
          const SizedBox(height: 4),
          Text(below, maxLines: 1, style: const TextStyle(color: AppColors.secondaryText, fontSize: 12)),
        ]),
      );
}

// ---------------------------------------------------------------- other travel

/// A train, a bus, a ferry: how, from where to where, and when.
class _TravelEditor extends StatefulWidget {
  const _TravelEditor({required this.store, required this.trip, this.existing});

  final TripStore store;
  final Trip trip;
  final TripItem? existing;

  @override
  State<_TravelEditor> createState() => _TravelEditorState();
}

class _TravelEditorState extends State<_TravelEditor> with _ItemEditing {
  @override
  TripStore get store => widget.store;
  @override
  Trip get trip => widget.trip;
  @override
  TripItem? get existing => widget.existing;

  Map<String, dynamic> get _old => widget.existing?.commute ?? const {};

  late final _how = TextEditingController(text: '${_old['how'] ?? ''}');
  late final _from = TextEditingController(text: '${_old['from'] ?? ''}');
  late final _to = TextEditingController(text: '${_old['to'] ?? trip.destination}');
  late final _notes = LinkingController(text: widget.existing?.notes ?? '');

  /// The wall clocks: where you leave, and where you arrive.
  late DateTime _leave = existing != null ? wallOf(existing!.start, savedZones.$1) : firstDayAt(9);
  late DateTime _arrive = existing != null ? wallOf(existing!.end, savedZones.$2) : _leave.add(const Duration(hours: 2));
  late final _fromPlace = _PlaceZone(existing?.zone ?? '', (existing?.zone ?? '').isEmpty ? '' : _from.text.trim());
  late final _toPlace = _PlaceZone(existing?.endZone ?? '', (existing?.endZone ?? '').isEmpty ? '' : _to.text.trim());
  late final _fromOnMap = ValueNotifier(existing != null && _old['fromOnMap'] != false);
  late final _toOnMap = ValueNotifier(existing != null && _old['toOnMap'] != false);
  bool _finding = false;

  @override
  String get fingerprint => [
        for (final c in [_how, _from, _to, _notes]) c.text,
        _leave,
        _arrive,
        _fromPlace.picked,
        _toPlace.picked,
        _access,
      ].join('|');

  String get _fromZone => _fromPlace.zone.isNotEmpty ? _fromPlace.zone : zoneThen(_leave);
  String get _toZone => _toPlace.zone.isNotEmpty ? _toPlace.zone : _fromZone;

  @override
  void dispose() {
    for (final c in [_how, _from, _to, _notes]) {
      c.dispose();
    }
    _fromOnMap.dispose();
    _toOnMap.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final how = _how.text.trim(), to = _to.text.trim();
    if (how.isEmpty) {
      setState(() => error = 'Type how you’re getting there: train, bus, ferry…');
      return;
    }
    setState(() => _finding = true);
    await Future.wait([findZone(_fromPlace, _fromOnMap.value ? _from.text : ''), findZone(_toPlace, _toOnMap.value ? _to.text : '')]);
    if (!mounted) return;
    setState(() => _finding = false);
    final leave = fromWall(_leave, _fromZone), arrive = fromWall(_arrive, _toZone);
    if (!arrive.isAfter(leave)) {
      setState(() => error = 'You have to arrive after you leave.');
      return;
    }
    saveItem(TripItem(
      id: itemId,
      kind: TripItemKind.travel,
      title: to.isEmpty ? how : '$how to ${placeName(to)}',
      start: leave,
      end: arrive,
      zone: _fromPlace.zone,
      endZone: _toPlace.zone,
      location: to,
      notes: _notes.text.trim(),
      commute: {
        'from': _from.text.trim(),
        'to': to,
        'how': how,
        if (!_fromOnMap.value) 'fromOnMap': false,
        if (!_toOnMap.value) 'toOnMap': false,
      },
    ));
  }

  @override
  Widget build(BuildContext context) => EntryForm(
        unsaved: unsaved,
        title: existing == null ? 'Add other travel' : 'Edit travel',
        saving: _finding,
        onSave: _save,
        error: error,
        onDelete: existing == null ? null : deleteItem,
        deleteLabel: 'Delete travel',
        mapAt: 1,
        people: peoplePanel(),
        location: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          _address(_from, 'From',
              origin: true, onMap: _fromOnMap, saved: savedPlaces, onSettled: (t) => findZone(_fromPlace, _fromOnMap.value ? t : '')),
          _address(_to, 'To', onMap: _toOnMap, saved: savedPlaces, onSettled: (t) => findZone(_toPlace, _toOnMap.value ? t : '')),
        ]),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: EntryTitleRow(
              title: TextField(
                controller: _how,
                autofocus: existing == null,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                    labelText: 'How are you getting there?', hintText: 'Train, ferry, spaceship…', prefixIcon: Icon(Icons.rocket_launch)),
              ),
              side: const _KindLabel(kind: TripItemKind.travel),
              sideIsLabel: true,
            ),
          ),
          _When(
              label: 'Leaving',
              value: _leave,
              zone: _fromZone,
              onChanged: (w) => setState(() {
                    final length = fromWall(_arrive, _toZone).difference(fromWall(_leave, _fromZone));
                    _leave = w;
                    _arrive = wallOf(fromWall(w, _fromZone).add(length), _toZone);
                  }),
              onZone: (z) => setState(() => _fromPlace.pick(z))),
          _When(
              label: 'Arriving',
              value: _arrive,
              zone: _toZone,
              onChanged: (w) => setState(() => _arrive = w),
              onZone: (z) => setState(() => _toPlace.pick(z))),
          const SizedBox(height: 6),
          NotesField(controller: _notes),
        ],
      );
}

// ---------------------------------------------------------------- stays and things to do

/// Things to do, food, places to stay and rental cars: one page, so any of
/// them can turn into any other.
class _PlaceEditor extends StatefulWidget {
  const _PlaceEditor({required this.store, required this.trip, required this.kind, this.existing, this.start});

  final TripStore store;
  final Trip trip;
  final TripItemKind kind;
  final TripItem? existing;
  final DateTime? start;

  @override
  State<_PlaceEditor> createState() => _PlaceEditorState();
}

class _PlaceEditorState extends State<_PlaceEditor> with _ItemEditing {
  @override
  TripStore get store => widget.store;
  @override
  Trip get trip => widget.trip;
  @override
  TripItem? get existing => widget.existing;

  late TripItemKind _kind = widget.kind;
  bool get _stay => _kind == TripItemKind.stay;
  bool get _food => _kind == TripItemKind.food;
  bool get _rental => _kind == TripItemKind.rental;

  String get _name => switch (_kind) {
        TripItemKind.stay => 'stay',
        TripItemKind.food => 'food',
        TripItemKind.rental => 'rental car',
        _ => 'activity',
      };

  Map<String, dynamic> get _old => existing?.commute ?? const {};

  late final _title = TextEditingController(text: existing?.title ?? '');
  late final _location = TextEditingController(text: existing?.location ?? '');
  late final _dropOff = TextEditingController(text: '${_old['to'] ?? ''}' == (existing?.location ?? '') ? '' : '${_old['to'] ?? ''}');
  late final _car = TextEditingController(text: '${_old['car'] ?? ''}');
  late final _confirmation = TextEditingController(text: existing?.confirmation ?? '');
  late final _notes = LinkingController(text: existing?.notes ?? '');

  /// The wall clocks, on the clock where it is.
  late DateTime _start = existing != null
      ? wallOf(existing!.start, savedZones.$1)
      : widget.start != null
          ? wallOf(widget.start!, _current.zoneAt(widget.start!))
          : firstDayAt(switch (widget.kind) { TripItemKind.stay => 15, TripItemKind.food => 12, _ => 10 });
  late DateTime _end = existing != null && !existing!.oneTime
      ? wallOf(existing!.end, savedZones.$2)
      : (_twoEnds ? _lastDayCheckout : _start.add(const Duration(hours: 1)));

  /// It has an end time, or is just a time that it happens.
  late bool _hasEnd = existing == null || !existing!.oneTime;

  bool get _twoEnds => _kind.hasTwoEnds;

  DateTime get _lastDayCheckout {
    final last = DateTime.utc(trip.end.year, trip.end.month, trip.end.day, 11);
    return last.isAfter(_start) ? last : DateTime.utc(_start.year, _start.month, _start.day + 1, 11);
  }

  late final _place = _PlaceZone(existing?.zone ?? '', (existing?.zone ?? '').isEmpty ? '' : _location.text.trim());
  late final _dropPlace = _PlaceZone(
      _dropOff.text.isEmpty ? '' : existing?.endZone ?? '', _dropOff.text.isEmpty || (existing?.endZone ?? '').isEmpty ? '' : _dropOff.text.trim());
  late final _onMap = ValueNotifier(existing != null && (_rental ? _old['fromOnMap'] != false : existing!.onMap));
  late final _dropOnMap = ValueNotifier(existing != null && _dropOff.text.isNotEmpty && _old['toOnMap'] != false);
  bool _finding = false;

  String get _zone => _place.zone.isNotEmpty ? _place.zone : zoneThen(_start);

  @override
  String get fingerprint => [
        _kind,
        for (final c in [_title, _location, _dropOff, _car, _confirmation, _notes]) c.text,
        _start,
        _end,
        _hasEnd,
        _place.picked,
        _dropPlace.picked,
        _access,
      ].join('|');
  String get _endZone => _rental && _dropPlace.zone.isNotEmpty ? _dropPlace.zone : _zone;

  @override
  void dispose() {
    for (final c in [_title, _location, _dropOff, _car, _confirmation, _notes]) {
      c.dispose();
    }
    _onMap.dispose();
    _dropOnMap.dispose();
    super.dispose();
  }

  Future<DateTime?> _pickDay(DateTime wall) async {
    final d = await showDatePicker(
        context: context, initialDate: DateTime(wall.year, wall.month, wall.day), firstDate: DateTime(2000), lastDate: DateTime(2100));
    return d == null ? null : DateTime.utc(d.year, d.month, d.day, wall.hour, wall.minute);
  }

  Future<DateTime?> _pickClock(DateTime wall) async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: wall.hour, minute: wall.minute));
    return t == null ? null : DateTime.utc(wall.year, wall.month, wall.day, t.hour, t.minute);
  }

  void _startAt(DateTime? wall) {
    if (wall == null || !mounted) return;
    setState(() {
      final length = _end.difference(_start);
      _start = wall;
      _end = wall.add(length);
    });
  }

  void _endAt(DateTime? wall) {
    if (wall != null && mounted) setState(() => _end = wall);
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty && !_rental) {
      setState(() => error = 'Give it a name.');
      return;
    }
    setState(() => _finding = true);
    await Future.wait([
      findZone(_place, _onMap.value ? _location.text : ''),
      findZone(_dropPlace, _rental && _dropOnMap.value ? _dropOff.text : ''),
    ]);
    if (!mounted) return;
    setState(() => _finding = false);
    final start = fromWall(_start, _zone);
    final end = _hasEnd || _twoEnds ? fromWall(_end, _endZone) : start;
    if (end.isBefore(start) || (_twoEnds && !end.isAfter(start))) {
      setState(() => error = _rental
          ? 'You have to drop it off after you pick it up.'
          : (_stay ? 'Check out has to be after check in.' : 'It has to end after it starts.'));
      return;
    }
    final pickUp = _location.text.trim(), dropOff = _dropOff.text.trim();
    saveItem(TripItem(
      id: itemId,
      kind: _kind,
      title: title.isEmpty ? 'Rental car' : title,
      start: start,
      end: end,
      zone: _place.zone,
      endZone: _rental ? _dropPlace.zone : '',
      onMap: _onMap.value,
      location: pickUp,
      notes: _notes.text.trim(),
      confirmation: _confirmation.text.trim(),
      commute: !_rental
          ? null
          : {
              'from': pickUp,
              'to': dropOff.isEmpty ? pickUp : dropOff,
              if (!_onMap.value) 'fromOnMap': false,
              if (!(dropOff.isEmpty ? _onMap.value : _dropOnMap.value)) 'toOnMap': false,
              if (_car.text.trim().isNotEmpty) 'car': _car.text.trim(),
            },
    ));
  }

  @override
  Widget build(BuildContext context) {
    final showEnd = _twoEnds || _hasEnd;
    return EntryForm(
      unsaved: unsaved,
      title: '${existing == null ? 'Add' : 'Edit'} ${_stay ? 'a stay' : (_food ? 'food' : (_rental ? 'a rental car' : 'an activity'))}',
      saving: _finding,
      onSave: _save,
      error: error,
      onDelete: existing == null ? null : deleteItem,
      deleteLabel: 'Delete $_name',
      mapAt: 1,
      people: peoplePanel(),
      location: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        AddressField(
            controller: _location,
            label: _stay ? 'Address' : (_rental ? 'Pick-up location' : 'Where'),
            origin: _rental,
            onMap: _onMap,
            saved: savedPlaces,
            onSettled: (t) => findZone(_place, _onMap.value ? t : '')),
        if (_rental) ...[
          const SizedBox(height: 12),
          AddressField(
              controller: _dropOff,
              label: 'Drop-off location, if different',
              onMap: _dropOnMap,
              saved: savedPlaces,
              onSettled: (t) => findZone(_dropPlace, _dropOnMap.value ? t : '')),
        ],
      ]),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: EntryTitleRow(
            title: TextField(
              controller: _title,
              autofocus: existing == null,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: _rental ? 'Rental company' : 'Name', prefixIcon: Icon(_kind.icon, color: _kind.color)),
            ),
            side: _twoEnds ? _KindLabel(kind: _kind) : _KindDropdown(kind: _kind, onChanged: (k) => setState(() => _kind = k)),
            sideIsLabel: _twoEnds,
          ),
        ),
        TimeRange(
          start: _start,
          end: _end,
          showEnd: showEnd,
          startLabel: _stay ? 'Check in' : (_rental ? 'Pick up' : null),
          endLabel: _stay ? 'Check out' : (_rental ? 'Drop off' : null),
          onStartDate: () async => _startAt(await _pickDay(_start)),
          onStartTime: () async => _startAt(await _pickClock(_start)),
          onEndDate: () async => _endAt(await _pickDay(_end)),
          onEndTime: () async => _endAt(await _pickClock(_end)),
          zone: Row(mainAxisSize: MainAxisSize.min, children: [
            _ZoneButton(wall: _start, zone: _zone, onZone: (z) => setState(() => _place.pick(z))),
            // A one-way rental can end in another zone.
            if (showEnd && _endZone != _zone) _ZoneButton(wall: _end, zone: _endZone, onZone: (z) => setState(() => _dropPlace.pick(z))),
          ]),
        ),
        const SizedBox(height: 6),
        if (!_twoEnds) TimeOption(label: 'End time', value: _hasEnd, onChanged: (v) => setState(() => _hasEnd = v)),
        const SizedBox(height: 12),
        if (_rental) _field(_car, 'Car type', caps: TextCapitalization.words),
        if (_stay || _rental) _field(_confirmation, 'Confirmation number', caps: TextCapitalization.characters),
        NotesField(controller: _notes),
      ],
    );
  }
}

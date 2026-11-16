import 'dart:async';
import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import 'calm_scrollbar.dart';
import 'map_frame.dart';

/// One address Google suggests.
typedef PlaceSuggestion = ({String id, String text, String main, String secondary});

/// A place already used somewhere nearby, to use again. [onMap] if it's a real
/// place on the map, rather than a name that was just typed.
typedef SavedPlace = ({String text, bool onMap});

/// Google said it can't suggest addresses, and why.
class PlacesOff implements Exception {
  PlacesOff(this.message);
  final String message;
}

/// Asks Optimizer's server for address suggestions (functions/places.js).
class Places {
  /// Swapped for a fake in tests.
  static Places instance = Places();

  static const _nearKey = 'optimizer.placesNear';
  ({double lat, double lng})? _near;
  bool _loadedNear = false;

  Future<List<PlaceSuggestion>> suggest(String input, String session) async {
    await _loadNear();
    try {
      final r = await FirebaseFunctions.instance.httpsCallable('placeSuggest').call({
        'input': input,
        'session': session,
        if (_near != null) 'near': {'lat': _near!.lat, 'lng': _near!.lng},
      });
      return [
        for (final s in ((r.data as Map)['suggestions'] as List? ?? const []))
          (id: '${s['id']}', text: '${s['text']}', main: '${s['main']}', secondary: '${s['secondary'] ?? ''}'),
      ];
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'failed-precondition') throw PlacesOff(e.message ?? 'Address suggestions aren’t available.');
      return const [];
    } catch (_) {
      // Typing the address still works.
      return const [];
    }
  }

  /// Ends the typing session Google bills as one, and leans later suggestions
  /// toward the place you picked.
  Future<void> picked(String id, String session) async {
    try {
      final r = await FirebaseFunctions.instance.httpsCallable('placeDetails').call({'id': id, 'session': session});
      final d = r.data as Map;
      final lat = (d['lat'] as num?)?.toDouble(), lng = (d['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) return;
      _near = (lat: lat, lng: lng);
      final p = await SharedPreferences.getInstance();
      await p.setString(_nearKey, '$lat,$lng');
    } catch (_) {
      // Only a nicety.
    }
  }

  Future<void> _loadNear() async {
    if (_loadedNear) return;
    _loadedNear = true;
    try {
      final v = (await SharedPreferences.getInstance()).getString(_nearKey)?.split(',');
      if (v != null && v.length == 2) _near = (lat: double.parse(v[0]), lng: double.parse(v[1]));
    } catch (_) {
      // Suggestions just won't lean anywhere.
    }
  }
}

/// A Google map of [to], or the route to it from [from]. It needs no key: this
/// is the same page as Google Maps' own "embed a map".
String mapEmbedUrl(String to, {String? from, List<String> via = const []}) => from == null
    ? Uri.https('www.google.com', '/maps', {'q': to, 'output': 'embed'}).toString()
    : Uri.https('www.google.com', '/maps', {
        'saddr': from,
        'daddr': [...via, to].join(' to:'),
        'output': 'embed'
      }).toString();

/// The same thing in Google Maps itself.
String mapOpenUrl(String to, {String? from, List<String> via = const []}) => from == null
    ? Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': to}).toString()
    : Uri.https('www.google.com', '/maps/dir/', {
        'api': '1',
        'origin': from,
        'destination': to,
        if (via.isNotEmpty) 'waypoints': via.join('|'),
        'travelmode': 'driving',
      }).toString();

/// The addresses settled on in a form: what its map should show.
class _FormAddresses extends ChangeNotifier {
  // Oldest first, so the last is the one most recently changed.
  final _all = <Object, ({String text, bool origin, int? stop})>{};
  bool _gone = false;

  void report(Object field, String text, {required bool origin, int? stop}) {
    final was = _all[field];
    if (was?.text == text && was?.stop == stop) return;
    _all.remove(field);
    if (text.isNotEmpty) _all[field] = (text: text, origin: origin, stop: stop);
    _changed();
  }

  void remove(Object field) {
    if (_all.remove(field) != null) _changed();
  }

  void _changed() {
    // A field can come and go while the page is being built: wait until that's over.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      notifyListeners();
    } else {
      scheduleMicrotask(() {
        if (!_gone) notifyListeners();
      });
    }
  }

  /// Where the map points: the latest place you're going, and where from if
  /// that's somewhere else. Just a starting point, if that's all there is.
  ({String to, String? from, List<String> via})? get shown {
    final list = _all.values.toList();
    if (list.isEmpty) return null;
    final going = list.where((a) => !a.origin && a.stop == null);
    final starts = list.where((a) => a.origin);
    if (going.isEmpty) return starts.isEmpty ? null : (to: starts.last.text, from: null, via: const []);
    final to = going.last.text;
    final from = starts.isEmpty ? null : starts.last.text;
    final stops = list.where((a) => a.stop != null).toList()..sort((a, b) => a.stop!.compareTo(b.stop!));
    return (to: to, from: from == null || from.toLowerCase() == to.toLowerCase() ? null : from, via: [for (final a in stops) a.text]);
  }

  @override
  void dispose() {
    _gone = true;
    super.dispose();
  }
}

class _FormScope extends InheritedWidget {
  const _FormScope({required this.addresses, required super.child});

  final _FormAddresses addresses;

  @override
  bool updateShouldNotify(_FormScope old) => addresses != old.addresses;
}

/// An editing page's form, with a map of the addresses in it, as Google
/// Calendar does: beside the form when there's room, and on a phone under it
/// (passed to [builder] to put at the end of the form).
class FormWithMap extends StatefulWidget {
  const FormWithMap({super.key, required this.builder, this.location, this.people});

  final Widget Function(BuildContext context, Widget? below) builder;

  /// An entry's one address: it goes under the map rather than with the rest
  /// of the form, and the map's place is kept for it even while it's empty.
  final Widget? location;

  /// Who can see the entry, under its place. The same spot on every entry.
  final Widget? people;

  /// How wide the page must be to fit the map beside the form.
  static const beside = 1040.0;

  @override
  State<FormWithMap> createState() => _FormWithMapState();
}

class _FormWithMapState extends State<FormWithMap> {
  final _addresses = _FormAddresses();

  @override
  void dispose() {
    _addresses.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _FormScope(
        addresses: _addresses,
        child: LayoutBuilder(
          builder: (context, box) => ListenableBuilder(
            listenable: _addresses,
            builder: (context, _) {
              final shown = _addresses.shown;
              final wide = box.maxWidth >= FormWithMap.beside;
              final height = wide ? 340.0 : 170.0;
              final location = widget.location;
              final map = shown != null
                  ? PlaceMap(to: shown.to, from: shown.from, via: shown.via, height: height)
                  // No address yet: a blank map's only worth the room beside the form.
                  : (location != null && wide ? _NoMap(height: height) : null);
              final people = widget.people;
              final panel = map == null && people == null && location == null
                  ? null
                  : Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                      if (map != null) map,
                      if (location != null) ...[const SizedBox(height: 10), location],
                      if (people != null) ...[
                        if (map != null) const SizedBox(height: 18),
                        people,
                      ],
                    ]);
              return Center(
                child: ConstrainedBox(
                  // Uses the room a laptop has, up to where lines get too long to read.
                  constraints: BoxConstraints(maxWidth: wide && panel != null ? 1560 : 720),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      flex: 3,
                      child: Builder(
                        builder: (context) => widget.builder(
                          context,
                          wide || panel == null ? null : Padding(padding: const EdgeInsets.only(top: 12, bottom: 12), child: panel),
                        ),
                      ),
                    ),
                    if (wide && panel != null)
                      Expanded(
                        flex: 2,
                        child: withoutAutoScrollbar(
                          context,
                          SingleChildScrollView(padding: const EdgeInsets.fromLTRB(4, 8, 24, 16), child: panel),
                        ),
                      ),
                  ]),
                ),
              );
            },
          ),
        ),
      );
}

/// Where the map goes, before there's an address to show.
class _NoMap extends StatelessWidget {
  const _NoMap({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) => Container(
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border)),
        child: const Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.map_outlined, size: 30, color: AppColors.secondaryText),
          SizedBox(height: 8),
          Text('Add a location to see it here', style: TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
        ]),
      );
}

/// A little Google map, and a way to open it in Google Maps.
class PlaceMap extends StatelessWidget {
  const PlaceMap({super.key, required this.to, this.from, this.via = const [], this.height = 200});

  final String to;
  final String? from;

  /// Stops along the route, in order.
  final List<String> via;
  final double height;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(height: height, child: mapFrame(mapEmbedUrl(to, from: from, via: via))),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => launchUrl(Uri.parse(mapOpenUrl(to, from: from, via: via)), mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.open_in_new, size: 15),
            label: const Text('Open in Google Maps', style: TextStyle(fontSize: 12.5)),
            style: TextButton.styleFrom(foregroundColor: AppColors.secondaryText),
          ),
        ),
      ]);
}

/// A text box for an address that suggests as you type, like Google
/// Calendar's. You can always just type: nothing has to be picked. In a
/// [FormWithMap], it goes on the map once you've settled on it.
class AddressField extends StatefulWidget {
  const AddressField({
    super.key,
    required this.controller,
    required this.label,
    this.icon = Icons.place_outlined,
    this.origin = false,
    this.stop,
    this.onChanged,
    this.onSettled,
    this.onSubmitted,
    this.onMap,
    this.saved = const [],
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;

  /// Where a route starts, rather than somewhere you're going.
  final bool origin;

  /// Where this is among a route's stops, if it is one.
  final int? stop;
  final ValueChanged<String>? onChanged;

  /// You've moved on from it with a different address: picked one, or left the field.
  final ValueChanged<String>? onSettled;
  final VoidCallback? onSubmitted;

  /// With this, what's typed is just a name, and stays off the map, until it's
  /// a place: picked from the list. Without it, whatever's typed goes on the map.
  final ValueNotifier<bool>? onMap;

  /// Places to offer before anything's typed, and among the suggestions after.
  final List<SavedPlace> saved;

  @override
  State<AddressField> createState() => _AddressFieldState();
}

// Kept alive: scrolled off a phone's screen, its address stays on the map.
class _AddressFieldState extends State<AddressField> with AutomaticKeepAliveClientMixin {
  static const _pause = Duration(milliseconds: 250);
  static const _settlePause = Duration(milliseconds: 700);

  final _focus = FocusNode();
  _FormAddresses? _form;
  Timer? _wait;
  Timer? _settleSoon;
  Completer<Iterable<PlaceSuggestion>>? _asking;
  String? _session;
  String? _note;
  late String _settledOn = widget.controller.text.trim();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
    widget.controller.addListener(_textChanged);
    widget.onMap?.addListener(_report);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _settle();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _form = context.dependOnInheritedWidgetOfExactType<_FormScope>()?.addresses;
  }

  @override
  void didUpdateWidget(AddressField old) {
    super.didUpdateWidget(old);
    // Another stop was removed, so this one moved up.
    if (old.stop != widget.stop || old.origin != widget.origin) _report();
    if (old.onMap != widget.onMap) {
      old.onMap?.removeListener(_report);
      widget.onMap?.addListener(_report);
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    _settleSoon?.cancel();
    widget.controller.removeListener(_textChanged);
    widget.onMap?.removeListener(_report);
    _focus.dispose();
    _form?.remove(this);
    super.dispose();
  }

  void _focusChanged() {
    if (!_focus.hasFocus) _settle();
    // A field that's never been touched hasn't worked out its list yet.
    final c = widget.controller;
    if (_focus.hasFocus && widget.saved.isNotEmpty && !c.selection.isValid) c.selection = TextSelection.collapsed(offset: c.text.length);
    // Only there to say what's typed isn't on the map, once you've moved on.
    if (widget.onMap != null && mounted) setState(() {});
  }

  // Filled in from elsewhere (a destination following "Where to").
  void _textChanged() {
    if (_focus.hasFocus) return;
    _settleSoon?.cancel();
    _settleSoon = Timer(_settlePause, _settle);
  }

  void _report() => _form?.report(this, widget.onMap?.value == false ? '' : widget.controller.text.trim(), origin: widget.origin, stop: widget.stop);

  void _settle() {
    final text = widget.controller.text.trim();
    _report();
    if (text == _settledOn) return;
    _settledOn = text;
    widget.onSettled?.call(text);
  }

  void _endAsking() {
    final c = _asking;
    _asking = null;
    if (c != null && !c.isCompleted) c.complete(const []);
  }

  // Ids that say a suggestion came from [AddressField.saved].
  static const _savedOnMap = '#saved', _savedName = '#name';

  List<PlaceSuggestion> _savedOptions(String text) {
    final typed = text.toLowerCase();
    return [
      for (final p in widget.saved)
        if (p.text.toLowerCase() != typed && p.text.toLowerCase().contains(typed))
          () {
            final comma = p.text.indexOf(',');
            return (
              id: p.onMap ? _savedOnMap : _savedName,
              text: p.text,
              main: comma < 0 ? p.text : p.text.substring(0, comma),
              secondary: comma < 0 ? '' : p.text.substring(comma + 1).trim(),
            );
          }(),
    ];
  }

  Future<Iterable<PlaceSuggestion>> _options(TextEditingValue value) {
    _wait?.cancel();
    _endAsking();
    final text = value.text.trim();
    final saved = _savedOptions(text);
    if (text.length < 3 || !_focus.hasFocus) return Future.value(saved);
    final asking = Completer<Iterable<PlaceSuggestion>>();
    _asking = asking;
    _wait = Timer(_pause, () async {
      try {
        final found = await Places.instance.suggest(text, _session ??= _newSession());
        // Gone by now: the list it would open is gone too, so leave it unanswered.
        if (!mounted) return;
        if (!asking.isCompleted) asking.complete([...saved, ...found]);
        if (_note != null) setState(() => _note = null);
      } on PlacesOff catch (e) {
        if (!mounted) return;
        if (!asking.isCompleted) asking.complete(saved);
        setState(() => _note = e.message);
      }
    });
    return asking.future;
  }

  static String _newSession() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  void _picked(PlaceSuggestion s) {
    _wait?.cancel();
    _endAsking();
    final fromHere = s.id == _savedOnMap || s.id == _savedName;
    if (!fromHere) {
      final session = _session;
      _session = null;
      if (session != null) Places.instance.picked(s.id, session);
    }
    widget.onMap?.value = s.id != _savedName;
    _settle();
    widget.onChanged?.call(widget.controller.text);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return RawAutocomplete<PlaceSuggestion>(
      textEditingController: widget.controller,
      focusNode: _focus,
      displayStringForOption: (s) => s.text,
      optionsBuilder: _options,
      onSelected: _picked,
      fieldViewBuilder: (context, controller, focus, submit) => TextField(
        controller: controller,
        focusNode: focus,
        textCapitalization: TextCapitalization.words,
        onChanged: (v) {
          widget.onMap?.value = false;
          widget.onChanged?.call(v);
        },
        onSubmitted: (_) {
          submit();
          widget.onSubmitted?.call();
        },
        decoration: InputDecoration(
          labelText: widget.label,
          prefixIcon: Icon(widget.icon),
          helperText: _note ??
              (widget.onMap?.value == false && !_focus.hasFocus && widget.controller.text.trim().isNotEmpty ? 'Just a name, not on the map' : null),
          helperMaxLines: 2,
        ),
      ),
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Material(
            color: AppColors.surfaceHigh,
            elevation: 8,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: AppColors.border)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: [
                for (final (i, s) in options.indexed)
                  Builder(builder: (context) {
                    final lit = AutocompleteHighlightedOption.of(context) == i;
                    return InkWell(
                      onTap: () => onSelected(s),
                      child: Container(
                        color: lit ? AppColors.faint : null,
                        padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
                        child: Row(children: [
                          Icon(s.id == _savedOnMap || s.id == _savedName ? Icons.history : Icons.place_outlined,
                              size: 18, color: AppColors.secondaryText),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(s.main,
                                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                              if (s.secondary.isNotEmpty)
                                Text(s.secondary,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
                            ]),
                          ),
                        ]),
                      ),
                    );
                  }),
                if (options.any((s) => s.id != _savedOnMap && s.id != _savedName))
                  const Padding(
                    padding: EdgeInsets.fromLTRB(14, 4, 14, 8),
                    child: Text('Powered by Google', textAlign: TextAlign.right, style: TextStyle(color: AppColors.secondaryText, fontSize: 11)),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme.dart';
import '../util/fields.dart';
import '../widgets/address_field.dart';
import 'trip_models.dart';
import 'trip_store.dart';

/// The trip's name, where it's going, its days and its color, saved as you
/// change them. A new trip opens here with its name ready to type over.
Future<void> showTripDetails(BuildContext context, TripStore store, String tripId) =>
    showDialog<void>(context: context, builder: (_) => _TripDetails(store: store, tripId: tripId));

class _TripDetails extends StatefulWidget {
  const _TripDetails({required this.store, required this.tripId});

  final TripStore store;
  final String tripId;

  @override
  State<_TripDetails> createState() => _TripDetailsState();
}

class _TripDetailsState extends State<_TripDetails> {
  TripStore get store => widget.store;
  Trip? get _trip => store.trips.where((t) => t.id == widget.tripId).firstOrNull;

  late final _title = TextEditingController(text: _trip?.title ?? '');
  late final _destination = TextEditingController(text: _trip?.destination ?? '');
  Timer? _typing;

  @override
  void initState() {
    super.initState();
    _title.selection = TextSelection(baseOffset: 0, extentOffset: _title.text.length);
  }

  @override
  void dispose() {
    if (_typing?.isActive == true) {
      _typing!.cancel();
      // After this frame: saving tells the page, which is being built right now.
      final title = _title.text.trim(), destination = _destination.text.trim();
      scheduleMicrotask(() => _saveText(title, destination));
    }
    _title.dispose();
    _destination.dispose();
    super.dispose();
  }

  void _saveText(String title, String destination) {
    // Deleted in the meantime: leave it deleted.
    final now = _trip;
    if (now == null) return;
    // A road trip's destination is the main drive's, so isn't typed here.
    final changed = now.copyWith(title: title.isEmpty ? null : title, destination: now.getting == TripHow.drive ? null : destination);
    if (changed.title != now.title || changed.destination != now.destination) store.save(changed).catchError((Object _) {});
  }

  void _typed([String? _]) {
    _typing?.cancel();
    _typing = Timer(const Duration(milliseconds: 500), () => _saveText(_title.text.trim(), _destination.text.trim()));
  }

  void _set(Trip Function(Trip) change) {
    final now = _trip;
    if (now != null) store.save(change(now)).catchError((Object _) {});
  }

  Future<void> _pickDay(DateTime value, void Function(DateTime) picked) async {
    final d = await showDatePicker(context: context, initialDate: value, firstDate: DateTime(2000), lastDate: DateTime(2100));
    if (d != null) picked(d);
  }

  Widget _day(String label, DateTime value, void Function(DateTime) picked) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          SizedBox(width: 72, child: Text(label, style: const TextStyle(color: AppColors.secondaryText, fontSize: 13))),
          Expanded(
            child: OutlinedButton(
              onPressed: () => _pickDay(value, picked),
              child: Text(DateFormat('EEE, MMM d, y').format(value), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: ListenableBuilder(
            listenable: store,
            builder: (context, _) {
              final trip = _trip;
              if (trip == null) return const SizedBox.shrink();
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text('Trip details', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      controller: _title,
                      autofocus: true,
                      textCapitalization: TextCapitalization.words,
                      onChanged: _typed,
                      decoration: const InputDecoration(labelText: 'Trip name'),
                    ),
                  ),
                  if (trip.getting != TripHow.drive)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: AddressField(controller: _destination, label: 'Where to', onChanged: _typed),
                    ),
                  _day(
                      'First day',
                      trip.start,
                      (d) => _set((t) {
                            final length = t.end.difference(t.start).inDays;
                            return t.copyWith(start: d, end: addDays(d, length));
                          })),
                  _day('Last day', trip.end, (d) => _set((t) => t.copyWith(end: d, start: d.isBefore(t.start) ? d : t.start))),
                  if (trip.items.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 8),
                      child: Text(
                        'On your calendar from ${DateFormat('EEE, MMM d, h:mm a').format(trip.span.start)} to ${DateFormat('EEE, MMM d, h:mm a').format(trip.span.end)}: the first thing planned to the last.',
                        style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5, height: 1.35),
                      ),
                    ),
                  const SizedBox(height: 6),
                  Wrap(spacing: 10, runSpacing: 10, children: [
                    for (final c in tripColors)
                      InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => _set((t) => t.copyWith(color: c)),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                          child: c.toARGB32() == trip.color.toARGB32() ? const Icon(Icons.check, size: 18, color: Colors.black87) : null,
                        ),
                      ),
                  ]),
                  const SizedBox(height: 14),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
                  ),
                ]),
              );
            },
          ),
        ),
      );
}

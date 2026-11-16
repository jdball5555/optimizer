import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme.dart';
import '../widgets/link_text.dart';
import 'trip_models.dart';
import 'trip_store.dart';

/// Everything linked on a trip, under whichever entry it's on, with general
/// notes and links for the whole trip first. Saved as you change them.
Future<void> showTripLinks(BuildContext context, TripStore store, String tripId, {void Function(String itemId)? onOpenItem}) =>
    showDialog<void>(context: context, builder: (_) => _TripLinks(store: store, tripId: tripId, onOpenItem: onOpenItem));

class _TripLinks extends StatefulWidget {
  const _TripLinks({required this.store, required this.tripId, this.onOpenItem});

  final TripStore store;
  final String tripId;
  final void Function(String itemId)? onOpenItem;

  @override
  State<_TripLinks> createState() => _TripLinksState();
}

const _label = TextStyle(color: AppColors.secondaryText, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 1);

class _TripLinksState extends State<_TripLinks> {
  TripStore get store => widget.store;
  Trip? get _trip => store.trips.where((t) => t.id == widget.tripId).firstOrNull;

  late final _notes = LinkingController(text: _trip?.notes ?? '');
  final _newLink = TextEditingController();
  Timer? _typing;
  String? _error;

  @override
  void dispose() {
    if (_typing?.isActive == true) {
      _typing!.cancel();
      // After this frame: saving tells the page, which is being built right now.
      final notes = _notes.text;
      scheduleMicrotask(() => _saveNotes(notes));
    }
    _notes.dispose();
    _newLink.dispose();
    super.dispose();
  }

  void _save(Trip Function(Trip) change) {
    final now = _trip;
    if (now != null) store.save(change(now)).catchError((Object _) {});
  }

  void _saveNotes(String notes) {
    if (_trip?.notes != notes) _save((t) => t.copyWith(notes: notes));
  }

  void _typed(String _) {
    _typing?.cancel();
    _typing = Timer(const Duration(milliseconds: 500), () => _saveNotes(_notes.text));
  }

  void _addLink() {
    final found = findLinks(_newLink.text);
    final typed = _newLink.text.trim();
    // "booking.com/x" with nothing in front of it is still a link.
    final links = found.isNotEmpty ? found : [if (RegExp(r'^[^\s@]+\.[a-z]{2,}(/\S*)?$', caseSensitive: false).hasMatch(typed)) 'https://$typed'];
    setState(() => _error = links.isEmpty && typed.isNotEmpty ? 'That doesn’t look like a link.' : null);
    if (links.isEmpty) return;
    _newLink.clear();
    _save((t) => t.copyWith(links: [
          ...t.links,
          for (final l in links)
            if (!t.links.any((x) => x.url == l)) TripLink(url: linkUri(l).toString()),
        ]));
  }

  Widget _linkRow(String link, {VoidCallback? onRemove}) => Row(children: [
        const Icon(Icons.link, size: 16, color: AppColors.secondaryText),
        const SizedBox(width: 8),
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => openLink(link),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(shortLink(link, length: 60),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Energy.ice, fontSize: 13.5, decoration: TextDecoration.underline, decorationColor: Energy.ice)),
            ),
          ),
        ),
        if (onRemove != null)
          IconButton(
            tooltip: 'Remove this link',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 16, color: AppColors.secondaryText),
            onPressed: onRemove,
          ),
      ]);

  @override
  Widget build(BuildContext context) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListenableBuilder(
            listenable: store,
            builder: (context, _) {
              final trip = _trip;
              if (trip == null) return const SizedBox.shrink();
              final byItem = trip.linksByItem;
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('Links and notes', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 16),
                  if (trip.canEdit)
                    TextField(
                      controller: _notes,
                      onChanged: _typed,
                      minLines: 3,
                      maxLines: null,
                      textCapitalization: TextCapitalization.sentences,
                      style: const TextStyle(height: 1.65),
                      decoration: const InputDecoration(labelText: 'Notes for the whole trip', alignLabelWithHint: true),
                    )
                  else if (trip.notes.isNotEmpty) ...[
                    const Text('NOTES FOR THE WHOLE TRIP', style: _label),
                    const SizedBox(height: 6),
                    LinkText(trip.notes, style: const TextStyle(fontSize: 14, height: 1.5)),
                  ],
                  const SizedBox(height: 20),
                  const Text('LINKS FOR THE WHOLE TRIP', style: _label),
                  const SizedBox(height: 4),
                  for (final l in trip.links)
                    _linkRow(l.url,
                        onRemove: !trip.canEdit ? null : () => _save((t) => t.copyWith(links: t.links.where((x) => x.url != l.url).toList()))),
                  for (final l in findLinks(trip.notes).where((l) => !trip.links.any((x) => x.url == l)).toSet()) _linkRow(l),
                  if (trip.canEdit)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(children: [
                        Expanded(
                          child: TextField(
                            controller: _newLink,
                            keyboardType: TextInputType.url,
                            onSubmitted: (_) => _addLink(),
                            decoration: InputDecoration(hintText: 'Paste a link', isDense: true, errorText: _error),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(onPressed: _addLink, child: const Text('Add')),
                      ]),
                    )
                  else if (trip.links.isEmpty && findLinks(trip.notes).isEmpty)
                    const Text('None yet.', style: TextStyle(color: AppColors.secondaryText, fontSize: 13)),
                  for (final e in byItem) ...[
                    const SizedBox(height: 20),
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: widget.onOpenItem == null ? null : () => widget.onOpenItem!(e.item.id),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(children: [
                          Icon(e.item.kind.icon, size: 16, color: e.item.kind.color),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(e.item.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                          ),
                          Text(DateFormat('MMM d').format(e.item.start), style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 2),
                    for (final l in e.links) _linkRow(l),
                  ],
                  if (byItem.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 14),
                      child: Text('Links in any entry’s notes show up here, under that entry.',
                          style: TextStyle(color: AppColors.secondaryText, fontSize: 12.5, height: 1.4)),
                    ),
                  const SizedBox(height: 14),
                  Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))),
                ]),
              );
            },
          ),
        ),
      );
}

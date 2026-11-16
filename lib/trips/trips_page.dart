import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme.dart';
import '../util/fields.dart';
import '../widgets/tiles.dart';
import 'trip_board.dart';
import 'trip_details.dart';
import 'trip_editors.dart';
import 'trip_itinerary.dart';
import 'trip_links.dart';
import 'trip_models.dart';
import 'trip_pdf.dart';
import 'trip_people.dart';
import 'trip_store.dart';

const _label = TextStyle(color: AppColors.secondaryText, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.2);

String tripDates(DateTime start, DateTime end) {
  final thisYear = start.year == DateTime.now().year && end.year == start.year;
  final s = thisYear ? DateFormat('MMM d') : DateFormat('MMM d, y');
  if (sameDay(start, end)) return s.format(start);
  if (start.year == end.year && start.month == end.month) {
    return '${s.format(start)} – ${end.day}${thisYear ? '' : ', ${end.year}'}';
  }
  return '${s.format(start)} – ${s.format(end)}';
}

/// Your trips, or one trip open: its itinerary and its own calendar.
class TripsPage extends StatelessWidget {
  const TripsPage({super.key, required this.store, required this.active, this.onBack});

  final TripStore store;

  /// This page is the one showing (the app keeps every page alive underneath).
  final bool active;

  /// Off the page on a phone, whose bar has no room for Trips.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final trip = store.opened;
        final back = trip != null ? () => store.open(null) : onBack;
        return PopScope(
          canPop: !active || back == null,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) back?.call();
          },
          child: trip != null ? _TripView(key: ValueKey(trip.id), store: store, trip: trip) : _TripList(store: store, onBack: onBack),
        );
      },
    );
  }
}

class _TripList extends StatelessWidget {
  const _TripList({required this.store, this.onBack});

  final TripStore store;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final today = dayStart(DateTime.now());
    final coming = store.trips.where((t) => !t.lastDay.isBefore(today)).toList();
    final past = store.trips.where((t) => t.lastDay.isBefore(today)).toList().reversed.toList();
    return ListView(padding: EdgeInsets.fromLTRB(16, PageSpace.top(context), 16, 32), children: [
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (onBack != null) IconButton(tooltip: 'Back to the calendar', icon: const Icon(Icons.arrow_back), onPressed: onBack),
              Expanded(
                child: PageHeader(title: 'Trips', actions: [
                  FilledButton.icon(
                    onPressed: () => showNewTrip(context, store),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('New trip'),
                  ),
                ]),
              ),
            ]),
            if (store.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Text('Couldn’t read your trips.\n${store.error}', style: const TextStyle(color: AppColors.danger)),
              )
            else if (store.trips.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 24),
                child: Text(
                    'Plan a trip here: how you’re getting there, where you’re staying and what you’re doing. '
                    'It shows on your calendar as one tile from start to end.',
                    style: TextStyle(color: AppColors.secondaryText, height: 1.45)),
              ),
            if (coming.isNotEmpty) ...[
              SizedBox(height: PageSpace.gap(context)),
              for (final t in coming) _TripRow(trip: t, store: store),
            ],
            if (past.isNotEmpty) ...[
              const Padding(padding: EdgeInsets.fromLTRB(4, 22, 4, 10), child: Text('PAST', style: _label)),
              for (final t in past) _TripRow(trip: t, store: store),
            ],
          ]),
        ),
      ),
    ]);
  }
}

class _TripRow extends StatelessWidget {
  const _TripRow({required this.trip, required this.store});

  final Trip trip;
  final TripStore store;

  @override
  Widget build(BuildContext context) {
    final today = dayStart(DateTime.now());
    final first = trip.firstDay;
    final days = DateTime.utc(first.year, first.month, first.day).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
    final soon = trip.lastDay.isBefore(today)
        ? null
        : days <= 0
            ? 'On now'
            : days == 1
                ? 'Tomorrow'
                : 'In $days days';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Tile(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        onTap: () => store.open(trip.id),
        child: Row(children: [
          Container(width: 5, height: 40, decoration: BoxDecoration(color: trip.color, borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(trip.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              Text(
                [
                  tripDates(trip.firstDay, trip.lastDay),
                  if (trip.destination.isNotEmpty) trip.destination,
                  if (trip.isShared)
                    'Shared by ${trip.ownerName.isEmpty ? trip.ownerEmail : trip.ownerName}, you ${trip.canEdit ? 'can edit' : 'can view'}',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5),
              ),
            ]),
          ),
          if (soon != null) Text(soon, style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

enum _Tab { itinerary, calendar }

/// One trip: its itinerary beside its calendar, or taking turns with less room.
/// The + up top adds to it, and its title opens its details.
class _TripView extends StatefulWidget {
  const _TripView({super.key, required this.store, required this.trip});

  final TripStore store;
  final Trip trip;

  @override
  State<_TripView> createState() => _TripViewState();
}

class _TripViewState extends State<_TripView> {
  _Tab _tab = _Tab.itinerary;

  Trip get trip => widget.trip;
  TripStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    if (store.freshId == trip.id) {
      store.freshId = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showTripDetails(context, store, trip.id);
      });
    }
  }

  void _openItem(String id) {
    // A drive's stop opens the drive.
    final base = id.split('#').first;
    final item = trip.items.where((i) => i.id == base).firstOrNull;
    if (item == null) return;
    if (trip.canEditItem(item)) {
      showItemEditor(context, store, trip, item.kind, existing: item);
    } else {
      showTripItemDetails(context, store, trip, item);
    }
  }

  void _add(TripItemKind kind) {
    // The first car ride of a road trip is the drive itself.
    if (kind == TripItemKind.commute && trip.getting == TripHow.drive && trip.mainDrive == null) {
      showMainDrive(context, store, trip);
    } else {
      showItemEditor(context, store, trip, kind);
    }
  }

  Widget _header(bool roomy) => Padding(
        padding: EdgeInsets.fromLTRB(4, PageSpace.top(context), 12, PageSpace.gap(context) - 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconButton(tooltip: 'All trips', icon: const Icon(Icons.arrow_back), onPressed: () => store.open(null)),
          // Only as wide as the name: the buttons come right after it, like the calendar's.
          Flexible(
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: trip.canEdit ? () => showTripDetails(context, store, trip.id) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 5, height: 36, decoration: BoxDecoration(color: trip.color, borderRadius: BorderRadius.circular(3))),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(trip.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageTitleStyle(context)),
                      Text(
                        [
                          tripDates(trip.firstDay, trip.lastDay),
                          if (trip.destination.isNotEmpty) trip.destination,
                          if (trip.isShared)
                            'Shared by ${trip.ownerName.isEmpty ? trip.ownerEmail : trip.ownerName}, you ${trip.canEdit ? 'can edit' : 'can view'}',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.secondaryText, fontSize: 13),
                      ),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 10),
          if (trip.canEdit) ...[
            _AddButton(onPicked: _add),
            const SizedBox(width: 6),
          ],
          if (roomy) ...[
            IconButton(tooltip: 'Links and notes', icon: const Icon(Icons.link), onPressed: _links),
            IconButton(tooltip: 'Download PDF', icon: const Icon(Icons.picture_as_pdf_outlined), onPressed: _downloadPdf),
            if (!trip.isShared)
              IconButton(
                tooltip: 'Share',
                icon: trip.people.isEmpty
                    ? const Icon(Icons.person_add_alt)
                    : Badge.count(
                        count: trip.people.length,
                        backgroundColor: AppColors.surfaceHigh,
                        textColor: AppColors.primaryText,
                        child: const Icon(Icons.group_outlined)),
                onPressed: () => showTripShare(context, store, trip),
              ),
          ],
          PopupMenuButton<String>(
            tooltip: 'Trip options',
            icon: const Icon(Icons.more_horiz),
            onSelected: (v) async {
              switch (v) {
                case 'links':
                  _links();
                case 'pdf':
                  _downloadPdf();
                case 'share':
                  showTripShare(context, store, trip);
                case 'details':
                  showTripDetails(context, store, trip.id);
                case 'leave':
                  if (await confirmAction(context,
                      title: 'Leave “${trip.title}”?',
                      message: 'It comes off your calendar. You’d need to be shared on it again.',
                      action: 'Leave')) {
                    await store.delete(trip);
                  }
                default:
                  if (await confirmAction(context,
                      title: 'Delete “${trip.title}”?', message: 'Its whole itinerary goes with it, and its tile leaves your calendar.')) {
                    await store.delete(trip);
                  }
              }
            },
            itemBuilder: (_) => [
              if (!roomy) ...[
                const PopupMenuItem(value: 'links', child: Text('Links and notes')),
                const PopupMenuItem(value: 'pdf', child: Text('Download PDF')),
                if (!trip.isShared) const PopupMenuItem(value: 'share', child: Text('Share')),
              ],
              if (trip.canEdit) const PopupMenuItem(value: 'details', child: Text('Trip details')),
              if (trip.isShared)
                const PopupMenuItem(value: 'leave', child: Text('Leave trip', style: TextStyle(color: AppColors.danger)))
              else
                const PopupMenuItem(value: 'delete', child: Text('Delete trip', style: TextStyle(color: AppColors.danger))),
            ],
          ),
          if (PageEnd.of(context) case final end?) end,
        ]),
      );

  void _links() => showTripLinks(context, store, trip.id, onOpenItem: _openItem);

  Future<void> _downloadPdf() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await downloadTripPdf(trip);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn’t make the PDF: $e')));
    }
  }

  /// With nothing planned: the one thing to do first, going by how you said you're getting there.
  Widget _empty() {
    final first = !trip.canEdit
        ? null
        : switch (trip.getting) {
            TripHow.fly => (TripItemKind.flight, 'Add your flight'),
            TripHow.drive => (TripItemKind.commute, 'Add the drive'),
            TripHow.other => (TripItemKind.travel, 'Add how you’re getting there'),
            null => null,
          };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 40, 20, 32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Nothing planned yet', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(trip.canEdit ? 'Add things with the + up top, and they line up here in order.' : 'What gets added shows up here.',
            textAlign: TextAlign.center, style: TextStyle(color: AppColors.secondaryText, height: 1.4)),
        if (first != null) ...[
          const SizedBox(height: 18),
          FilledButton.icon(onPressed: () => _add(first.$1), icon: Icon(first.$1.icon, size: 18), label: Text(first.$2)),
        ],
      ]),
    );
  }

  Widget _itinerary() => TripItinerary(trip: trip, onOpen: _openItem, empty: _empty());

  Widget _board() => TripBoard(
        trip: trip,
        onOpen: _openItem,
        onSlot: (wall) {
          if (trip.canEdit) showItemEditor(context, store, trip, TripItemKind.activity, start: trip.momentOf(wall));
        },
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      return SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(c.maxWidth >= 720),
          Expanded(
            child: c.maxWidth >= 960
                ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    SizedBox(width: 430, child: _itinerary()),
                    Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(0, 4, 16, 16), child: _board())),
                  ])
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Center(
                        child: PillTabs<_Tab>(
                          items: const [(_Tab.itinerary, 'Itinerary'), (_Tab.calendar, 'Calendar')],
                          selected: _tab,
                          onSelected: (v) => setState(() => _tab = v),
                        ),
                      ),
                    ),
                    Expanded(
                      child: _tab == _Tab.itinerary
                          ? Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 620), child: _itinerary()))
                          : Padding(padding: const EdgeInsets.fromLTRB(0, 0, 12, 12), child: _board()),
                    ),
                  ]),
          ),
        ]),
      );
    });
  }
}

/// The + that lists what can go on a trip.
class _AddButton extends StatelessWidget {
  const _AddButton({required this.onPicked});

  final ValueChanged<TripItemKind> onPicked;

  static const _options = [
    (TripItemKind.flight, 'Flight', 'Look it up by flight number'),
    (TripItemKind.commute, 'Car ride', 'Timed for that day and time'),
    (TripItemKind.rental, 'Rental car', 'Pick up, drop off, confirmation'),
    (TripItemKind.travel, 'Other travel', 'Train, bus, ferry, anything else'),
    (TripItemKind.stay, 'Place to stay', 'Hotel, Airbnb, a friend’s couch'),
    (TripItemKind.food, 'Food', 'Breakfast, lunch, dinner, a snack'),
    (TripItemKind.activity, 'Something to do', 'A show, a museum, anything else'),
  ];

  @override
  Widget build(BuildContext context) => PopupMenuButton<TripItemKind>(
        tooltip: 'Add to trip',
        position: PopupMenuPosition.under,
        offset: const Offset(0, 8),
        constraints: const BoxConstraints(minWidth: 290, maxWidth: 320),
        onSelected: onPicked,
        itemBuilder: (_) => [
          for (final (kind, label, hint) in _options)
            PopupMenuItem(
              value: kind,
              height: 60,
              child: Row(children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(color: kind.color.withValues(alpha: 0.16), shape: BoxShape.circle),
                  child: Icon(kind.icon, size: 19, color: kind.color),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(label, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                    Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.secondaryText, fontSize: 12)),
                  ]),
                ),
              ]),
            ),
        ],
        child: Container(
          width: 40,
          height: 40,
          decoration: const BoxDecoration(color: AppColors.primaryText, shape: BoxShape.circle),
          child: const Icon(Icons.add, color: AppColors.background, size: 24),
        ),
      );
}

import 'package:flutter/material.dart';

import '../people/invite_flow.dart';
import '../people/person_row.dart';
import '../theme.dart';
import '../widgets/entry_form.dart';
import '../widgets/link_text.dart';
import 'trip_models.dart';
import 'trip_schedule.dart';
import 'trip_store.dart';

/// Which role to give someone, as a small menu.
class _RoleMenu extends StatelessWidget {
  const _RoleMenu({required this.role, required this.roles, required this.onChanged});

  final String role;
  final List<String> roles;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        tooltip: 'What they can do',
        initialValue: role,
        position: PopupMenuPosition.under,
        onSelected: onChanged,
        itemBuilder: (_) => [for (final r in roles) PopupMenuItem(value: r, child: Text(roleLabel(r)))],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(roleLabel(role), style: TextStyle(fontSize: 12.5, color: role == 'none' ? AppColors.secondaryText : AppColors.primaryText)),
            const Icon(Icons.arrow_drop_down, size: 18, color: AppColors.secondaryText),
          ]),
        ),
      );
}

const _quietRole = TextStyle(color: AppColors.secondaryText, fontSize: 12.5);

/// Who can see an entry on a trip, and what they can do with it. The trip's
/// owner can make any of them different on this one entry.
class TripItemPeople extends StatelessWidget {
  const TripItemPeople({super.key, required this.store, required this.trip, required this.item, required this.access, required this.onChanged});

  final TripStore store;
  final Trip trip;

  /// Null for one not saved yet.
  final TripItem? item;
  final Map<String, String> access;

  /// A person's role on this entry; null: the same as on the trip.
  final void Function(String email, String? role) onChanged;

  @override
  Widget build(BuildContext context) {
    final i = item;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      PeopleHeading(
        action: trip.isShared
            ? null
            : TextButton(
                onPressed: () => showTripShare(context, store, trip),
                style: TextButton.styleFrom(foregroundColor: AppColors.secondaryText, visualDensity: VisualDensity.compact),
                child: const Text('Share trip'),
              ),
      ),
      PersonRow(
        name: trip.isShared ? (trip.ownerName.isEmpty ? trip.ownerEmail : trip.ownerName) : 'You',
        trailing: const Text('Owner', style: _quietRole),
      ),
      if (trip.isShared)
        for (final p in i != null ? i.canSee : trip.people) PersonRow(name: p.shown, trailing: Text(roleLabel(p.role), style: _quietRole))
      else if (trip.people.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: Text('Only you can see this. Share the trip to add people.',
              style: TextStyle(color: AppColors.secondaryText, fontSize: 12.5, height: 1.4)),
        )
      else
        for (final p in trip.people)
          PersonRow(
            name: p.shown,
            detail: access[p.email] == null ? null : 'Just for this entry',
            trailing: _RoleMenu(
              role: access[p.email] ?? p.role,
              roles: const ['editor', 'viewer', 'none'],
              onChanged: (r) => onChanged(p.email, r == p.role ? null : r),
            ),
          ),
    ]);
  }
}

/// An entry on a trip you can only look at.
Future<void> showTripItemDetails(BuildContext context, TripStore store, Trip trip, TripItem i) {
  final (start, end) = trip.zones[i.id] ?? ('', '');
  final entry = TripEntry(i, TripPart.whole, i.start, start, end);
  const quiet = TextStyle(color: AppColors.secondaryText, fontSize: 13.5, height: 1.45);
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      title: Row(children: [
        Icon(i.kind.icon, size: 20, color: i.kind.color),
        const SizedBox(width: 10),
        Expanded(child: Text(entry.title)),
      ]),
      content: SingleChildScrollView(
        child: EntryDetailsLayout(
          location: i.kind == TripItemKind.flight ? '' : i.location,
          people: TripItemPeople(store: store, trip: trip, item: i, access: const {}, onChanged: (_, __) {}),
          details: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(entry.when, style: const TextStyle(fontSize: 14, height: 1.4)),
            if (i.kind != TripItemKind.stay && i.kind != TripItemKind.food && i.kind != TripItemKind.activity && entry.fullPlaces.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 6), child: Text(entry.fullPlaces.join(' to '), style: quiet)),
            for (final s in i.stops) Text('Stop: ${s.place.isEmpty ? 'Stop' : s.place}, ${tripMinutes(s.minutes)}', style: quiet),
            if (i.confirmation.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 6), child: Text('Confirmation: ${i.confirmation}', style: quiet)),
            if (i.notes.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 12), child: LinkText(i.notes, style: const TextStyle(fontSize: 14, height: 1.5))),
            const SizedBox(height: 12),
            const Text('You can view this, but not change it.', style: TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
    ),
  );
}

/// Who a trip is shared with: people and groups, each who can view or edit it.
Future<void> showTripShare(BuildContext context, TripStore store, Trip trip) =>
    showDialog<void>(context: context, builder: (_) => _TripShare(store: store, trip: trip));

class _TripShare extends StatefulWidget {
  const _TripShare({required this.store, required this.trip});

  final TripStore store;
  final Trip trip;

  @override
  State<_TripShare> createState() => _TripShareState();
}

class _TripShareState extends State<_TripShare> {
  late final List<TripPerson> _people = [...widget.trip.people];
  final _email = TextEditingController();
  String _newRole = 'viewer';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  void _add(Iterable<String> emails) {
    final me = widget.store.myEmail;
    setState(() {
      for (final e in emails) {
        if (e != me && !_people.any((p) => p.email == e)) _people.add(TripPerson(email: e, role: _newRole));
      }
    });
  }

  /// Returns whether what's typed could be added.
  bool _addTyped() {
    final typed = _email.text.split(RegExp(r'[,;\s]+')).map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).toList();
    final bad = typed.where((e) => !looksLikeEmail(e)).toList();
    _add(typed.where(looksLikeEmail));
    setState(() {
      _email.text = bad.join(', ');
      _error = bad.isEmpty ? null : 'That doesn’t look like an email address: ${bad.join(', ')}';
    });
    return bad.isEmpty;
  }

  Future<void> _save() async {
    if (!_addTyped()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final links = await widget.store.setTripPeople(widget.trip, _people);
      if (!mounted) return;
      final navigator = Navigator.of(context);
      final outer = navigator.context;
      navigator.pop();
      if (outer.mounted) await showInviteLinks(outer, links);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e'.replaceFirst('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.store.people?.groups ?? const [];
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Share “${widget.trip.title}”', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('They’ll see the whole trip, except any entry you hide from them. To change it for one entry, open that entry.',
                style: TextStyle(color: AppColors.secondaryText, fontSize: 13, height: 1.4)),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(hintText: 'Email address', prefixIcon: Icon(Icons.person_add_alt)),
                  onSubmitted: (_) => _addTyped(),
                ),
              ),
              const SizedBox(width: 6),
              _RoleMenu(role: _newRole, roles: const ['viewer', 'editor'], onChanged: (r) => setState(() => _newRole = r)),
              if (groups.isNotEmpty)
                PopupMenuButton<int>(
                  tooltip: 'Add a group',
                  icon: const Icon(Icons.group_add_outlined),
                  onSelected: (n) => _add(groups[n].emails),
                  itemBuilder: (_) => [
                    for (final (n, g) in groups.indexed)
                      PopupMenuItem(value: n, child: Text('${g.name} · ${g.emails.length} ${g.emails.length == 1 ? 'person' : 'people'}')),
                  ],
                ),
            ]),
            const SizedBox(height: 12),
            const PersonRow(name: 'You', trailing: Text('Owner', style: _quietRole)),
            for (final (n, p) in _people.indexed)
              PersonRow(
                name: p.shown,
                detail: p.name.isEmpty ? null : p.email,
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  _RoleMenu(
                    role: p.role,
                    roles: const ['viewer', 'editor'],
                    onChanged: (r) => setState(() => _people[n] = TripPerson(email: p.email, name: p.name, role: r)),
                  ),
                  IconButton(
                    tooltip: 'Remove ${p.shown}',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 16, color: AppColors.secondaryText),
                    onPressed: () => setState(() => _people.removeAt(n)),
                  ),
                ]),
              ),
            if (_error != null)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: AppColors.danger))),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

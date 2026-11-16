import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import '../util/fields.dart';
import '../widgets/address_field.dart';
import '../widgets/entry_form.dart';
import '../widgets/link_text.dart';
import '../widgets/tiles.dart' show confirmAction;
import 'calendar_models.dart';
import 'calendar_service.dart';
import 'canvas.dart';
import '../people/invite_flow.dart';
import '../people/invites.dart';
import '../people/people_service.dart';
import '../people/person_row.dart';

/// Read-only details popup, with Edit, and Delete behind the ⋯ menu (the
/// edit page has Delete too). An
/// event changed in Optimizer only says so, with ways to send the change to
/// Google or go back to Google's version.
Future<void> showEventDetails(BuildContext context, CalendarService service, CalendarEvent e) {
  if (e.isTrip) {
    service.onOpenTrip?.call(e.id);
    return Future.value();
  }
  final invite = service.inviteFor(e);
  final guests = service.guestsOf(e)?.guests ?? const <Guest>[];
  final isGoogle = e.calendar.accountEmail != canvasAccount && invite == null;
  final canPush = service.canEdit(e.calendar);
  final theme = Theme.of(context);
  final t = DateFormat.jm();
  final d = DateFormat.yMMMMEEEEd();
  final String when;
  if (e.allDay) {
    final lastDay = addDays(e.end, -1);
    when = sameDay(e.start, lastDay) ? d.format(e.start) : '${d.format(e.start)} – ${d.format(lastDay)}';
  } else if (sameDay(e.start, e.end)) {
    when = '${d.format(e.start)}\n${t.format(e.start)} – ${t.format(e.end)}';
  } else {
    when = '${d.format(e.start)} ${t.format(e.start)} –\n${d.format(e.end)} ${t.format(e.end)}';
  }

  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 12, 0),
      title: Row(
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(color: e.color, borderRadius: BorderRadius.circular(4)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(e.title)),
          if (isGoogle)
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () {
                Navigator.pop(ctx);
                showEventEditor(context, service, existing: e);
              },
            ),
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_horiz),
            onSelected: (v) async {
              if (v == 'hide' || v == 'show') {
                Navigator.pop(ctx);
                await _guard(context, () => v == 'hide' ? service.hideEvent(e) : service.unhideEvent(e));
                return;
              }
              final where = await _askDelete(ctx, service, e);
              if (where == null || !ctx.mounted) return;
              Navigator.pop(ctx);
              await _guard(context, () => where == _DeleteIn.google ? service.deleteEvent(e) : service.removeEventHere(e));
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: service.isEventHidden(e) ? 'show' : 'hide',
                child: Row(children: [
                  Icon(service.isEventHidden(e) ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
                  const SizedBox(width: 10),
                  Flexible(child: Text(service.isEventHidden(e) ? 'Show on my calendar' : 'Hide from my calendar')),
                ]),
              ),
              if (isGoogle)
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(children: [
                    Icon(Icons.delete_outline, size: 18, color: AppColors.danger),
                    SizedBox(width: 10),
                    Text('Delete event', style: TextStyle(color: AppColors.danger)),
                  ]),
                ),
            ],
          ),
        ],
      ),
      content: EntryDetailsLayout(
        location: e.location,
        people: (invite?.guests ?? guests).isEmpty
            ? null
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                const PeopleHeading(),
                GuestList(guests: invite?.guests ?? guests),
              ]),
        details: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (e.localEdit)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
                decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(12)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('✎ Changed in Optimizer only. Google Calendar still has the original.', style: TextStyle(fontSize: 13, height: 1.35)),
                  Wrap(spacing: 4, children: [
                    if (canPush)
                      TextButton(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await _guard(context, () => service.pushLocalEdit(e));
                        },
                        child: const Text('Save to Google'),
                      ),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        service.dropLocalEdit(e);
                      },
                      child: const Text('Use Google’s version'),
                    ),
                  ]),
                ]),
              ),
            if (invite != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  '${invite.fromName.isEmpty ? invite.fromEmail : invite.fromName} invited you · '
                  '${invite.pending ? 'not answered yet' : invite.status == 'accepted' ? 'you’re going' : 'you declined'}',
                  style: const TextStyle(color: AppColors.secondaryText, fontSize: 13),
                ),
              ),
            Text(when, style: theme.textTheme.bodyMedium),
            if (e.recurring) ...[
              const SizedBox(height: 4),
              Text('Repeating event — changes apply to this occurrence only',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
            if (e.description.isNotEmpty) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(child: LinkText(_stripHtml(e.description))),
              ),
            ],
            const SizedBox(height: 12),
            Row(children: [
              const Icon(Icons.calendar_today_outlined, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    e.calendar.accountEmail == canvasAccount ? '${e.calendar.name} · Canvas' : '${e.calendar.name} · ${e.calendar.source}',
                    style: theme.textTheme.bodySmall),
              ),
            ]),
          ],
        ),
      ),
      actions: [
        if (invite != null) ...[
          if (invite.status != 'declined')
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _guard(context, () => service.respondInvite(invite, accept: false));
              },
              child: const Text('Decline'),
            ),
          if (invite.status != 'accepted')
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _guard(context, () => service.respondInvite(invite, accept: true));
              },
              child: const Text('Accept'),
            ),
        ],
        if (e.htmlLink != null)
          TextButton.icon(
            onPressed: () => launchUrl(Uri.parse(e.htmlLink!), mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: Text(e.calendar.accountEmail == canvasAccount ? 'Open in Canvas' : 'Open in Google Calendar'),
          ),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
      ],
    ),
  );
}

String _stripHtml(String s) => s
    .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&');

enum _DeleteIn { google, optimizer }

/// Where to delete an event from. Null: don't.
Future<_DeleteIn?> _askDelete(BuildContext context, CalendarService service, CalendarEvent e) async {
  // On a calendar of your own there's only the one place to delete it from.
  if (e.calendar.isOwn) {
    return await confirmAction(context, title: 'Delete “${e.title}”?', message: 'You can put it back from your calendar history.') ? _DeleteIn.google : null;
  }
  final canPush = service.canEdit(e.calendar);
  return showDialog<_DeleteIn>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Delete “${e.title}”?'),
      content: Text(
        canPush
            ? 'Delete it from Google Calendar too, or only here? Only here, it stays in Google Calendar and just stops showing in Optimizer. You can put it back from your calendar history.'
            : 'This calendar can’t be changed from Optimizer, so it stays in Google Calendar and just stops showing here. You can put it back from your calendar history.',
        style: const TextStyle(color: AppColors.secondaryText, height: 1.4),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, _DeleteIn.optimizer), child: const Text('Only in Optimizer')),
        if (canPush)
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, _DeleteIn.google),
            child: const Text('Delete in Google too'),
          ),
      ],
    ),
  );
}

Future<void> _guard(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', ''))));
    }
  }
}

Future<void> showEventEditor(
  BuildContext context,
  CalendarService service, {
  CalendarEvent? existing,
  DateTime? start,
  bool allDay = false,
}) async {
  final cal = existing?.calendar ?? service.defaultCalendar;
  if (cal == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(CalendarService.canLinkGoogle
            ? 'Make a calendar in the side panel, or connect a Google account, first.'
            : 'Make a calendar in the side panel first, or link Google Calendar once in Optimizer on the web.'),
      ),
    );
    return;
  }
  final s = existing?.start ?? start ?? DateTime.now();
  final draft = EventDraft(
    calendarKey: cal.key,
    title: existing?.title == '(No title)' ? '' : (existing?.title ?? ''),
    start: s,
    end: existing?.end ?? (allDay ? addDays(s, 1) : s.add(const Duration(hours: 1))),
    allDay: existing?.allDay ?? allDay,
    description: existing?.description ?? '',
    location: existing?.location ?? '',
    colorId: existing?.colorId,
    guests: [for (final g in (existing == null ? null : service.guestsOf(existing))?.guests ?? const <Guest>[]) g.email],
    guestsCanSeeList: (existing == null ? null : service.guestsOf(existing))?.guestsCanSeeList ?? true,
  );
  // A whole page rather than a popup, so the keyboard has room and you can
  // just go back.
  await Navigator.of(context).push(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _EventEditorDialog(service: service, draft: draft, existing: existing),
  ));
}

class _EventEditorDialog extends StatefulWidget {
  const _EventEditorDialog({required this.service, required this.draft, this.existing});

  final CalendarService service;
  final EventDraft draft;
  final CalendarEvent? existing;

  @override
  State<_EventEditorDialog> createState() => _EventEditorDialogState();
}

class _EventEditorDialogState extends State<_EventEditorDialog> {
  late final _title = TextEditingController(text: widget.draft.title);
  late final _location = TextEditingController(text: widget.draft.location);
  late final _description = LinkingController(text: _stripHtml(widget.draft.description));
  final _guestField = TextEditingController();

  /// Who was already invited before this edit.
  late final _invitedBefore = {...widget.draft.guests};
  bool _saving = false;
  String? _error;

  EventDraft get d => widget.draft;

  String get _fingerprint => [
        _title.text,
        _location.text,
        _description.text,
        _guestField.text,
        d.start,
        d.end,
        d.allDay,
        d.calendarKey,
        d.colorId,
        d.guests,
        d.guestsCanSeeList,
      ].join('|');
  String? _first;

  /// Something's different from when this opened.
  bool get _unsaved => _fingerprint != (_first ??= _fingerprint);

  void _typed() => setState(() {});

  @override
  void initState() {
    super.initState();
    // So Back knows as soon as anything's been typed.
    for (final c in [_title, _location, _description, _guestField]) {
      c.addListener(_typed);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _description.dispose();
    _guestField.dispose();
    super.dispose();
  }

  // For all-day events the editor shows the inclusive last day.
  DateTime get _shownEnd => d.allDay ? addDays(d.end, -1) : d.end;

  Future<void> _pickDate({required bool isStart}) async {
    final current = isStart ? d.start : _shownEnd;
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      final length = d.end.difference(d.start);
      if (isStart) {
        d.start = DateTime(picked.year, picked.month, picked.day, d.start.hour, d.start.minute);
        d.end = d.start.add(length); // keep the duration
      } else if (d.allDay) {
        d.end = addDays(picked, 1);
      } else {
        d.end = DateTime(picked.year, picked.month, picked.day, d.end.hour, d.end.minute);
      }
      _fixOrder();
    });
  }

  Future<void> _pickTime({required bool isStart}) async {
    final current = isStart ? d.start : d.end;
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(current));
    if (picked == null) return;
    setState(() {
      if (isStart) {
        final length = d.end.difference(d.start);
        d.start = DateTime(d.start.year, d.start.month, d.start.day, picked.hour, picked.minute);
        d.end = d.start.add(length);
      } else {
        d.end = DateTime(d.end.year, d.end.month, d.end.day, picked.hour, picked.minute);
      }
      _fixOrder();
    });
  }

  void _fixOrder() {
    if (!d.end.isAfter(d.start)) {
      d.end = d.allDay ? addDays(d.start, 1) : d.start.add(const Duration(hours: 1));
    }
  }

  void _toggleAllDay(bool v) {
    setState(() {
      d.allDay = v;
      if (v) {
        d.start = dayStart(d.start);
        d.end = addDays(dayStart(d.end.isAfter(d.start) ? addDays(d.end, -1) : d.start), 1);
        if (!d.end.isAfter(d.start)) d.end = addDays(d.start, 1);
      } else {
        final now = DateTime.now();
        d.start = DateTime(d.start.year, d.start.month, d.start.day, now.hour + 1);
        d.end = d.start.add(const Duration(hours: 1));
      }
    });
  }

  Future<void> _save() async {
    // Nothing to send anywhere, so nothing to ask.
    if (widget.existing != null && !_unsaved) {
      Navigator.pop(context);
      return;
    }
    d
      ..title = _title.text.trim().isEmpty ? '(No title)' : _title.text.trim()
      ..location = _location.text.trim()
      ..description = _description.text;
    final existing = widget.existing;
    // Ask first (for an existing event), then show it saving.
    final cal = widget.service.calendarByKey(d.calendarKey);
    final canPush = cal != null && widget.service.canEdit(cal);
    if (_guestField.text.trim().isNotEmpty) _addGuest(_guestField.text);
    bool? toGoogle = true;
    // An event on your own calendar has nowhere else to be saved, so nothing to ask.
    if (existing != null && !existing.calendar.isOwn) {
      if (cal?.isOwn ?? false) {
        toGoogle = await _askMoveOutOfGoogle(cal!) ? true : null;
      } else {
        toGoogle = canPush ? await _askGoogle() : false;
      }
    }
    if (toGoogle == null) return;
    final hadGuests = _invitedBefore.isNotEmpty;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // The event's key once saved, for its guest list.
      String? key;
      if (existing == null) {
        final id = await widget.service.saveEvent(d);
        if (id != null) key = '${d.calendarKey}|$id';
      } else {
        if (toGoogle) {
          // One change, as far as undo is concerned.
          await widget.service.asOneChange('Changed “${existing.title}”', () async {
            final id = await widget.service.saveEvent(d, original: existing);
            if (id != null) key = '${d.calendarKey}|$id';
            if (existing.localEdit) await widget.service.dropLocalEdit(existing);
          });
          // Moved to another calendar: its old guest list goes, the new one takes over.
          if (hadGuests && key != existing.key) await widget.service.setEventGuests(existing.key, d, guests: const []);
        } else {
          // Kept in Optimizer only: same event, marked as different from Google.
          d.calendarKey = existing.calendar.key;
          await widget.service.saveLocalEdit(existing, d);
          key = existing.key;
        }
      }
      if (key != null && (d.guests.isNotEmpty || hadGuests)) {
        final links = await widget.service.setEventGuests(key!, d, guests: d.guests);
        if (mounted) await showInviteLinks(context, links);
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() {
        _saving = false;
        _error = '$e';
      });
    }
  }

  void _addGuest(String raw) {
    final emails = raw.split(RegExp(r'[,;\s]+')).map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty);
    final bad = emails.where((e) => !looksLikeEmail(e)).toList();
    setState(() {
      for (final e in emails) {
        if (looksLikeEmail(e) && !d.guests.contains(e)) d.guests.add(e);
      }
      _guestField.text = bad.join(', ');
      _error = bad.isEmpty ? null : 'That doesn’t look like an email address: ${bad.join(', ')}';
    });
  }

  /// Who's invited, how each has answered, and ways to add more.
  Widget _guestsSection() {
    final known = {
      for (final g in widget.existing == null ? const <Guest>[] : widget.service.guestsOf(widget.existing!)?.guests ?? const <Guest>[]) g.email: g
    };
    final groups = widget.service.people?.groups ?? const <PeopleGroup>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      const PeopleHeading(),
      if (d.guests.isEmpty)
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text('Only you. Add guests to invite them.', style: TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
        ),
      for (final email in d.guests)
        PersonRow(
          name: known[email]?.name.isNotEmpty == true ? known[email]!.name : email,
          detail: known[email]?.name.isNotEmpty == true ? email : null,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(
              switch (known[email]?.status) { 'accepted' => 'Going', 'declined' => 'Not going', 'pending' => 'Invited', _ => 'Not sent yet' },
              style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5),
            ),
            IconButton(
              tooltip: 'Remove $email',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 16, color: AppColors.secondaryText),
              onPressed: () => setState(() => d.guests.remove(email)),
            ),
          ]),
        ),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _guestField,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(hintText: 'Add guests by email', prefixIcon: Icon(Icons.person_add_alt)),
            onSubmitted: _addGuest,
          ),
        ),
        if (groups.isNotEmpty) ...[
          const SizedBox(width: 8),
          PopupMenuButton<PeopleGroup>(
            tooltip: 'Invite a group',
            icon: const Icon(Icons.group_add_outlined),
            onSelected: (g) => setState(() {
              final me = FirebaseAuth.instance.currentUser?.email?.toLowerCase();
              for (final e in g.emails) {
                if (e != me && !d.guests.contains(e)) d.guests.add(e);
              }
            }),
            itemBuilder: (_) => [
              for (final g in groups)
                PopupMenuItem(value: g, child: Text('${g.name} · ${g.emails.length} ${g.emails.length == 1 ? 'person' : 'people'}')),
            ],
          ),
        ],
      ]),
      if (d.guests.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child:
              TimeOption(label: 'Guests can see the guest list', value: d.guestsCanSeeList, onChanged: (v) => setState(() => d.guestsCanSeeList = v)),
        ),
    ]);
  }

  Future<void> _delete() async {
    final e = widget.existing!;
    final where = await _askDelete(context, widget.service, e);
    if (where == null || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await (where == _DeleteIn.google ? widget.service.deleteEvent(e) : widget.service.removeEventHere(e));
      if (mounted) Navigator.pop(context);
    } catch (err) {
      setState(() {
        _saving = false;
        _error = '$err'.replaceFirst('Exception: ', '');
      });
    }
  }

  Future<bool> _askMoveOutOfGoogle(GoogleCalendar to) => confirmAction(
        context,
        title: 'Move to ${to.name}?',
        message: 'It’s deleted from Google Calendar and from then on is only in Optimizer.',
        action: 'Move',
      );

  /// True: save to Google too. False: keep in Optimizer only. Null: cancel.
  Future<bool?> _askGoogle() => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Save to Google Calendar too?'),
          content: const Text(
            'Saving to Google changes the event in Google Calendar as well. Keep it in Optimizer only and Google '
            'Calendar stays as it is; the event is marked ✎ here, and changes made in Google won’t overwrite yours.',
            style: TextStyle(color: AppColors.secondaryText, height: 1.4),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Only in Optimizer')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save to Google')),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A read-only event (edited in Optimizer only) keeps its own calendar in the list.
    final existingCal = widget.existing?.calendar;
    final cals = [
      ...widget.service.writableCalendars,
      if (existingCal != null && !widget.service.writableCalendars.any((c) => c.key == existingCal.key)) existingCal,
    ];
    final selected = widget.service.calendarByKey(d.calendarKey);

    return EntryForm(
      title: widget.existing == null ? 'New event' : 'Edit event',
      unsaved: _unsaved,
      saving: _saving,
      saveLabel: widget.existing == null ? 'Save' : 'Save changes',
      onSave: _save,
      error: _error,
      onDelete: widget.existing == null ? null : _delete,
      deleteLabel: 'Delete event',
      mapAt: 1,
      location: AddressField(controller: _location, label: 'Location'),
      people: _guestsSection(),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: EntryTitleRow(
            title: TextField(
              controller: _title,
              // Straight to typing for a new event; an existing one opens without the keyboard.
              autofocus: widget.existing == null,
              decoration: const InputDecoration(labelText: 'Title'),
              onSubmitted: (_) => _saving ? null : _save(),
            ),
            side: DropdownButtonFormField<String>(
              initialValue: selected?.key,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Calendar'),
              items: [
                for (final c in cals)
                  DropdownMenuItem(
                    value: c.key,
                    child: Row(children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(color: c.color, borderRadius: BorderRadius.circular(3)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text('${c.name}  ·  ${c.source}', overflow: TextOverflow.ellipsis)),
                    ]),
                  ),
              ],
              onChanged: (v) => setState(() => d.calendarKey = v ?? d.calendarKey),
            ),
          ),
        ),
        TimeRange(
          start: d.start,
          end: _shownEnd,
          allDay: d.allDay,
          onStartDate: () => _pickDate(isStart: true),
          onStartTime: () => _pickTime(isStart: true),
          onEndDate: () => _pickDate(isStart: false),
          onEndTime: () => _pickTime(isStart: false),
          zone: d.allDay
              ? null
              : Text(d.start.timeZoneName, style: const TextStyle(color: AppColors.secondaryText, fontSize: 13, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 6),
        TimeOption(label: 'All day', value: d.allDay, onChanged: _toggleAllDay),
        const SizedBox(height: 12),
        Text('Color', style: theme.textTheme.labelMedium),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _swatch(null, selected?.color ?? Colors.grey, 'Calendar color'),
            for (final entry in googleEventColors.entries) _swatch(entry.key, readableColor(entry.value), null),
          ],
        ),
        const SizedBox(height: 18),
        NotesField(controller: _description, label: 'Description'),
      ],
    );
  }

  Widget _swatch(String? id, Color color, String? tip) {
    final selected = d.colorId == id;
    return Tooltip(
      message: tip ?? '',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => setState(() => d.colorId = id),
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: id == null ? Border.all(color: Theme.of(context).colorScheme.outline, width: 2) : null,
          ),
          child: selected ? Icon(Icons.check, size: 16, color: onColor(color)) : null,
        ),
      ),
    );
  }
}

/// Who's invited, each with how they answered.
class GuestList extends StatelessWidget {
  const GuestList({super.key, required this.guests, this.group = false});

  final List<Guest> guests;

  /// Members of a group rather than guests of an event (worded to match).
  final bool group;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        for (final g in guests)
          PersonRow(
            name: g.shown,
            trailing: Text(
              switch (g.status) {
                'accepted' => group ? 'Member' : 'Going',
                'declined' => group ? 'Declined' : 'Not going',
                'organizer' => 'Organizer',
                'owner' => 'Owner',
                _ => 'Invited',
              },
              style: const TextStyle(color: AppColors.secondaryText, fontSize: 12),
            ),
          ),
      ]);
}

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../calendar/calendar_service.dart';
import '../calendar/event_editor.dart';
import '../theme.dart';
import '../widgets/tiles.dart';
import 'invite_flow.dart';
import 'invites.dart';
import 'people_service.dart';

/// Your people: invitations waiting for an answer, your groups (make one,
/// invite people to it, and invite a whole group to an event at once), and
/// everyone you share a group with.
class PeoplePage extends StatelessWidget {
  const PeoplePage({super.key, required this.people, required this.calendar, required this.myEmail});

  final PeopleService people;
  final CalendarService calendar;

  /// Yours, to leave yourself out of "Everyone".
  final String myEmail;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([people, calendar]),
      builder: (context, _) {
        final pending = calendar.pendingInvites;
        final me = myEmail.toLowerCase();
        final everyone = <String, (Guest, List<String>)>{};
        for (final g in people.groups) {
          for (final m in g.members) {
            if (m.email == me || m.status == 'declined' || m.status == 'pending') continue;
            final had = everyone[m.email];
            everyone[m.email] = (had?.$1.name.isNotEmpty == true ? had!.$1 : m, [...?had?.$2, g.name]);
          }
        }
        final folks = everyone.values.toList()..sort((a, b) => a.$1.shown.toLowerCase().compareTo(b.$1.shown.toLowerCase()));

        return ListView(
          padding: EdgeInsets.fromLTRB(16, PageSpace.top(context), 16, 32),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  PageHeader(title: 'People', actions: [
                    FilledButton.icon(
                      onPressed: () => _newGroup(context),
                      icon: const Icon(Icons.group_add_outlined, size: 18),
                      label: const Text('New group'),
                    ),
                  ]),
                  if (pending.isNotEmpty) ...[
                    const _Label('Invitations'),
                    for (final i in pending) _InviteTile(invite: i, calendar: calendar),
                  ],
                  const _Label('Groups'),
                  if (people.error != null)
                    Text('Couldn’t read your groups.\n${people.error}', style: const TextStyle(color: AppColors.danger))
                  else if (people.groups.isEmpty)
                    const Text('Make a group to invite everyone in it to an event at once.', style: TextStyle(color: AppColors.secondaryText))
                  else
                    for (final g in people.groups) _GroupTile(group: g, people: people, calendar: calendar),
                  if (folks.isNotEmpty) ...[
                    const _Label('Everyone'),
                    Tile(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(children: [
                        for (final (p, groups) in folks)
                          ListTile(
                            dense: true,
                            leading: CircleAvatar(radius: 16, child: Text(p.shown.characters.first.toUpperCase())),
                            title: Text(p.shown, style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text([if (p.name.isNotEmpty) p.email, groups.join(', ')].join(' · '),
                                style: const TextStyle(color: AppColors.secondaryText, fontSize: 12)),
                          ),
                      ]),
                    ),
                  ],
                ]),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _newGroup(BuildContext context) async {
    final name = await _askName(context, title: 'New group', action: 'Create');
    if (name == null || !context.mounted) return;
    await _guard(context, () async {
      final id = await people.saveGroup(name);
      if (context.mounted && id.isNotEmpty) await invitePeopleTo(context, people, calendar, id, name);
    });
  }
}

/// Asks for emails, then invites them to the group (with links to send
/// anyone not on Optimizer yet).
Future<void> invitePeopleTo(BuildContext context, PeopleService people, CalendarService calendar, String groupId, String groupName) async {
  final raw = await showDialog<String>(
    context: context,
    builder: (ctx) => _TextDialog(
      title: 'Invite people to $groupName',
      hint: 'Emails, separated by commas',
      action: 'Invite',
      email: true,
    ),
  );
  final emails = (raw ?? '').split(RegExp(r'[,;\s]+')).map((e) => e.trim().toLowerCase()).where(looksLikeEmail).toSet().toList();
  if (emails.isEmpty || !context.mounted) return;
  await _guard(context, () async {
    final links = await people.inviteToGroup(groupId, emails);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Invited ${emails.length} to $groupName')));
    await showInviteLinks(context, links);
  });
}

Future<String?> _askName(BuildContext context, {required String title, required String action, String initial = ''}) async {
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => _TextDialog(title: title, hint: 'Family, Roommates, Study group…', action: action, initial: initial),
  );
  final n = name?.trim() ?? '';
  return n.isEmpty ? null : n;
}

/// A box to type into, with Cancel and [action]. It owns its text, so the
/// text is let go only once the dialog has finished closing (letting go of it
/// as soon as the button is pressed breaks the closing animation).
class _TextDialog extends StatefulWidget {
  const _TextDialog({required this.title, required this.hint, required this.action, this.initial = '', this.email = false});

  final String title;
  final String hint;
  final String action;
  final String initial;

  /// Emails (several lines, email keyboard) rather than a name.
  final bool email;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: _field,
            autofocus: true,
            keyboardType: widget.email ? TextInputType.emailAddress : TextInputType.text,
            textCapitalization: widget.email ? TextCapitalization.none : TextCapitalization.words,
            minLines: 1,
            maxLines: widget.email ? 4 : 1,
            style: const TextStyle(height: 1.65),
            decoration: InputDecoration(hintText: widget.hint),
            onSubmitted: widget.email ? null : (v) => Navigator.pop(context, v),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, _field.text), child: Text(widget.action)),
        ],
      );
}

Future<void> _guard(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', ''))));
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 26, 4, 10),
        child: Text(text.toUpperCase(),
            style: const TextStyle(color: AppColors.secondaryText, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
      );
}

/// An invitation waiting for your answer.
class _InviteTile extends StatelessWidget {
  const _InviteTile({required this.invite, required this.calendar});

  final Invite invite;
  final CalendarService calendar;

  @override
  Widget build(BuildContext context) {
    final i = invite;
    final from = i.fromName.isEmpty ? i.fromEmail : i.fromName;
    final when = !i.isEvent
        ? null
        : i.allDay
            ? DateFormat('EEEE, MMMM d').format(DateTime.utc(i.start!.toUtc().year, i.start!.toUtc().month, i.start!.toUtc().day))
            : DateFormat('EEEE, MMMM d · h:mm a').format(i.start!);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Tile(
        padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
        child: Row(children: [
          Icon(i.isEvent ? Icons.event_outlined : Icons.groups_outlined, color: AppColors.secondaryText),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(i.isEvent ? i.title : 'Join “${i.title}”', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              Text([from, if (when != null) when].join(' · '), style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
            ]),
          ),
          TextButton(onPressed: () => _guard(context, () => calendar.respondInvite(i, accept: false)), child: const Text('Decline')),
          const SizedBox(width: 4),
          FilledButton(onPressed: () => _guard(context, () => calendar.respondInvite(i, accept: true)), child: const Text('Accept')),
        ]),
      ),
    );
  }
}

/// One group: its members and how each answered; yours to manage if you made it.
class _GroupTile extends StatelessWidget {
  const _GroupTile({required this.group, required this.people, required this.calendar});

  final PeopleGroup group;
  final PeopleService people;
  final CalendarService calendar;

  @override
  Widget build(BuildContext context) {
    final g = group;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: HoverMenu(
        top: 10,
        right: 10,
        actions: g.mine
            ? [
                MenuAction(
                  label: 'Rename',
                  icon: Icons.edit_outlined,
                  onSelected: () async {
                    final name = await _askName(context, title: 'Rename group', action: 'Save', initial: g.name);
                    if (name != null && context.mounted) await _guard(context, () => people.saveGroup(name, group: g));
                  },
                ),
                MenuAction(
                  label: 'Delete group',
                  icon: Icons.delete_outline,
                  confirm: ('Delete “${g.name}”?', 'Everyone in it is taken out, and invitations to it are cancelled.', 'Delete'),
                  onSelected: () => _guard(context, () => people.deleteGroup(g)),
                ),
              ]
            : [
                MenuAction(
                  label: 'Leave group',
                  icon: Icons.logout,
                  confirm: ('Leave “${g.name}”?', 'You’d need ${g.ownerName.isEmpty ? 'its owner' : g.ownerName} to invite you again.', 'Leave'),
                  onSelected: () => _guard(context, () => people.removeFromGroup(g)),
                ),
              ],
        child: Tile(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Icon(Icons.groups_outlined, size: 20, color: AppColors.secondaryText),
              const SizedBox(width: 10),
              Expanded(child: Text(g.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
              if (g.mine)
                Padding(
                  padding: const EdgeInsets.only(right: 36),
                  child: TextButton.icon(
                    onPressed: () => invitePeopleTo(context, people, calendar, g.id, g.name),
                    icon: const Icon(Icons.person_add_alt, size: 18),
                    label: const Text('Invite'),
                  ),
                ),
            ]),
            const SizedBox(height: 4),
            if (!g.mine)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('${g.ownerName}’s group', style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
              ),
            for (final m in g.members)
              Row(children: [
                Expanded(child: GuestList(guests: [m], group: true)),
                // The owner can take people out (asking first).
                if (g.mine && m.status != 'owner')
                  IconButton(
                    tooltip: 'Remove ${m.shown}',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    icon: const Icon(Icons.close, color: AppColors.secondaryText),
                    onPressed: () async {
                      final ok =
                          await confirmAction(context, title: 'Remove ${m.shown}?', message: 'They’re taken out of “${g.name}”.', action: 'Remove');
                      if (ok && context.mounted) await _guard(context, () => people.removeFromGroup(g, email: m.email));
                    },
                  ),
              ]),
          ]),
        ),
      ),
    );
  }
}

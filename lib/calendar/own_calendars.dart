import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/tiles.dart';
import 'calendar_models.dart';
import 'calendar_service.dart';
import 'canvas_section.dart';

/// The sidebar's calendars you made yourself, above anything synced.
class OwnCalendarsSection extends StatelessWidget {
  const OwnCalendarsSection({super.key, required this.service, required this.toggle});

  final CalendarService service;

  /// Draws a calendar's on/off row (the same one the others use), with [more]
  /// added to its ⋯ menu.
  final Widget Function(GoogleCalendar calendar, List<MenuAction> more) toggle;

  @override
  Widget build(BuildContext context) {
    return Tile(
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Expanded(
            child: Text('My calendars', style: TextStyle(color: AppColors.secondaryText, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          IconButton(
            tooltip: 'New calendar',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add, color: AppColors.secondaryText),
            onPressed: () => showOwnCalendarEditor(context, service),
          ),
        ]),
        if (service.ownCalendars.isEmpty)
          const Padding(
            padding: EdgeInsets.only(right: 8, bottom: 4),
            child: Text('Calendars you make here stay in Optimizer. They aren’t synced with anything.',
                style: TextStyle(color: AppColors.secondaryText, fontSize: 11.5, height: 1.35)),
          ),
        for (final c in service.ownCalendars)
          toggle(c, [
            MenuAction(label: 'Edit calendar', icon: Icons.edit_outlined, onSelected: () => showOwnCalendarEditor(context, service, existing: c)),
            MenuAction(
              label: 'Delete calendar',
              icon: Icons.delete_outline,
              confirm: _deleteQuestion(service, c),
              onSelected: () => _delete(context, service, c),
            ),
          ]),
      ]),
    );
  }

  static (String, String, String) _deleteQuestion(CalendarService service, GoogleCalendar c) {
    final n = service.ownEventCount(c);
    return (
      'Delete ${c.name}?',
      n == 0 ? 'There’s nothing on it.' : 'The ${n == 1 ? 'event' : '$n events'} on it will be deleted too.',
      'Delete',
    );
  }

  static Future<void> _delete(BuildContext context, CalendarService service, GoogleCalendar c) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await service.deleteOwnCalendar(c);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', ''))));
    }
  }
}

/// Makes a calendar, or changes the name and color of one of yours.
Future<void> showOwnCalendarEditor(BuildContext context, CalendarService service, {GoogleCalendar? existing}) async {
  final colors = calendarColorChoices;
  final used = {for (final c in service.ownCalendars) c.color.toARGB32()};
  final name = TextEditingController(text: existing?.name ?? '');
  var color = existing?.color ?? colors.firstWhere((c) => !used.contains(c.toARGB32()), orElse: () => colors.first);
  var busy = false;
  String? error;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
      Future<void> save() async {
        final n = name.text.trim();
        if (n.isEmpty) {
          setLocal(() => error = 'Give it a name.');
          return;
        }
        setLocal(() {
          busy = true;
          error = null;
        });
        try {
          existing == null ? await service.createOwnCalendar(n, color) : await service.updateOwnCalendar(existing, name: n, color: color);
          if (ctx.mounted) Navigator.pop(ctx);
        } catch (e) {
          setLocal(() {
            busy = false;
            error = '$e'.replaceFirst('Exception: ', '');
          });
        }
      }

      return AlertDialog(
        title: Text(existing == null ? 'New calendar' : 'Edit calendar'),
        content: SizedBox(
          width: 340,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              controller: name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
              onSubmitted: (_) => busy ? null : save(),
            ),
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in colors)
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => setLocal(() => color = c),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                    child: c.toARGB32() == color.toARGB32() ? Icon(Icons.check, size: 18, color: onColor(c)) : null,
                  ),
                ),
            ]),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(error!, style: const TextStyle(color: AppColors.danger)),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: busy ? null : save, child: Text(existing == null ? 'Create' : 'Save')),
        ],
      );
    }),
  );
}

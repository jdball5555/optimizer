import 'package:flutter/material.dart';

import '../notifications/notification_service.dart';
import '../theme.dart';
import '../widgets/tiles.dart';
import 'calendar_models.dart';
import 'calendar_service.dart';
import 'canvas.dart';

/// The sidebar's Canvas calendars: each group you added, split into its
/// classes (each with its own on/off and color). Notifications are in Settings.
class CanvasSection extends StatelessWidget {
  const CanvasSection({super.key, required this.service, required this.notifications, required this.toggle});

  final CalendarService service;
  final NotificationService? notifications;

  /// Draws a calendar's on/off row (the same one Google calendars use), with
  /// [more] added to its ⋯ menu.
  final Widget Function(GoogleCalendar calendar, List<MenuAction> more) toggle;

  @override
  Widget build(BuildContext context) {
    final feeds = service.canvasFeeds;
    if (feeds.isEmpty && service.canvasError == null) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (service.canvasError != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Tooltip(
            message: service.canvasError!,
            child: const Text('Couldn’t read your Canvas calendars. Your Firestore rules may need updating.',
                style: TextStyle(color: AppColors.danger, fontSize: 12)),
          ),
        ),
      for (final f in feeds)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Tile(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const Icon(Icons.school_outlined, size: 15, color: AppColors.secondaryText),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(f.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.secondaryText, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Group options',
                  iconSize: 18,
                  icon: const Icon(Icons.more_horiz, color: AppColors.secondaryText),
                  onSelected: (v) async {
                    if (v == 'check') {
                      await _run(context, () async {
                        final errors = await service.refreshCanvas(only: f);
                        return errors.isEmpty ? '${f.name} is up to date' : errors.join('\n');
                      });
                    } else if (v == 'remove') {
                      final a = removeCanvasAction(context, service, f);
                      if (await confirmAction(context, title: a.confirm!.$1, message: a.confirm!.$2, action: a.confirm!.$3)) {
                        a.onSelected();
                      }
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'check', child: Text('Check Canvas now')),
                    PopupMenuItem(value: 'remove', child: Text('Remove group', style: TextStyle(color: AppColors.danger))),
                  ],
                ),
              ]),
              for (final c in service.canvasCalendars(f))
                toggle(c, [
                  MenuAction(label: 'Change color', icon: Icons.palette_outlined, onSelected: () => pickCalendarColor(context, service, c)),
                ]),
              if (f.lastError != null)
                Padding(
                  padding: const EdgeInsets.only(left: 2, top: 2, right: 8),
                  child: Text(f.lastError!,
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.danger, fontSize: 11.5)),
                ),
            ]),
          ),
        ),
    ]);
  }
}

/// Runs [action] and shows what it returned, or what went wrong.
Future<void> _run(BuildContext context, Future<String> Function() action) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final msg = await action();
    messenger.showSnackBar(SnackBar(content: Text(msg)));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', ''))));
  }
}

/// Explains, then asks the system for notification permission.
Future<void> offerNotifications(BuildContext context, NotificationService? n, {bool ask = true}) async {
  if (n == null || !NotificationService.supported || n.enabled) return;
  if (ask) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.notifications_active_outlined),
        title: const Text('Turn on notifications?'),
        content: const Text(
          'Optimizer can tell you when a teacher adds an assignment to one of your Canvas calendars, '
          'or moves a due date: the class, the assignment and when it’s due.',
          style: TextStyle(color: AppColors.secondaryText),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Turn on')),
        ],
      ),
    );
    if (ok != true) {
      await n.markAsked();
      return;
    }
  }
  final on = await n.enable();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(on ? 'Notifications are on' : n.error ?? 'Notifications are blocked. Allow them for Optimizer in your device or browser settings.'),
  ));
}

/// The colors a calendar can be given.
List<Color> get calendarColorChoices => [...canvasPalette, ...googleEventColors.values.map(readableColor)];

/// Picks a new color for a calendar: a Canvas class or a Google calendar.
Future<void> pickCalendarColor(BuildContext context, CalendarService service, GoogleCalendar course) async {
  final colors = calendarColorChoices;
  final picked = await showDialog<Color>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(course.name),
      content: SizedBox(
        width: 300,
        child: Wrap(spacing: 10, runSpacing: 10, children: [
          for (final c in colors)
            InkWell(
              customBorder: const CircleBorder(),
              onTap: () => Navigator.pop(ctx, c),
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: c.toARGB32() == course.color.toARGB32() ? Border.all(color: Colors.white, width: 3) : null,
                ),
              ),
            ),
        ]),
      ),
    ),
  );
  if (picked != null) await service.setCalendarColor(course, picked);
}

/// Asks for a Canvas "Calendar Feed" link and adds it.
Future<void> showAddCanvasDialog(BuildContext context, CalendarService service, NotificationService? notifications) async {
  final url = TextEditingController();
  final name = TextEditingController();
  var notify = true;
  var busy = false;
  String? error;

  final added = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        Future<void> add() async {
          final link = url.text.trim();
          if (!looksLikeCanvasFeed(link)) {
            setLocal(() => error = 'That isn’t a Canvas calendar feed link. It ends in .ics and has /feeds/calendars/ in it.');
            return;
          }
          setLocal(() {
            busy = true;
            error = null;
          });
          try {
            final msg = await service.addCanvasFeed(link, name: name.text.trim(), notify: notify);
            if (ctx.mounted) Navigator.pop(ctx, msg);
          } catch (e) {
            setLocal(() {
              busy = false;
              error = '$e'.replaceFirst('Exception: ', '');
            });
          }
        }

        return AlertDialog(
          title: const Text('Add a Canvas calendar'),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text(
                'In Canvas, open Calendar and click “Calendar Feed” (bottom right of the page). '
                'Copy that link and paste it here. All your courses’ assignments and events come with it.',
                style: TextStyle(color: AppColors.secondaryText, height: 1.4),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: url,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Calendar feed link',
                  hintText: 'https://school.instructure.com/feeds/calendars/user_….ics',
                  prefixIcon: Icon(Icons.link),
                ),
                onSubmitted: (_) => busy ? null : add(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: name,
                decoration: const InputDecoration(
                  labelText: 'Group name',
                  hintText: 'e.g. Fall 2026',
                  helperText: 'It’s split into your classes automatically; each can be turned on or off and given a color.',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: notify,
                onChanged: (v) => setLocal(() => notify = v),
                title: const Text('Notify me about new assignments'),
                subtitle:
                    const Text('And when a due date moves. Checked every minute.', style: TextStyle(color: AppColors.secondaryText, fontSize: 12)),
              ),
              if (error != null) Text(error!, style: const TextStyle(color: AppColors.danger)),
            ]),
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: busy ? null : add,
              child: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Add'),
            ),
          ],
        );
      },
    ),
  );
  if (added == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(added)));
  if (notify) await offerNotifications(context, notifications);
}

/// Quick check before asking the server (which checks properly): Canvas feed
/// links look like `https://school/feeds/calendars/user_TOKEN.ics`.
bool looksLikeCanvasFeed(String link) {
  final u = Uri.tryParse(link.replaceFirst(RegExp(r'^webcals?://', caseSensitive: false), 'https://'));
  return u != null && u.hasAuthority && RegExp(r'^/feeds/calendars/[\w-]+\.ics$', caseSensitive: false).hasMatch(u.path);
}

/// Removing a Canvas calendar, with a confirmation, for the ⋯ menu.
MenuAction removeCanvasAction(BuildContext context, CalendarService service, CanvasFeed f) => MenuAction(
      label: 'Remove calendar',
      icon: Icons.delete_outline,
      confirm: (
        'Remove ${f.name}?',
        'Its classes and assignments stop showing here and you won’t be notified about them. Nothing changes in Canvas.',
        'Remove'
      ),
      onSelected: () => _run(context, () async {
        await service.removeCanvasFeed(f);
        return 'Removed ${f.name}';
      }),
    );

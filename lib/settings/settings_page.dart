import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/ai_service.dart';
import '../auth/profile.dart';
import '../calendar/calendar_page.dart';
import '../calendar/calendar_service.dart';
import '../networth/net_worth_page.dart';
import '../notifications/notification_service.dart';
import '../premium/premium_beta.dart';
import '../theme.dart';
import '../widgets/tiles.dart';
import 'feedback_page.dart';

/// Opened from your profile picture: notifications, calendar sync, Canvas
/// alerts, AI, privacy and signing out.
class SettingsPage extends StatelessWidget {
  const SettingsPage(
      {super.key,
      required this.user,
      required this.notifications,
      required this.calendar,
      required this.ai,
      required this.premium,
      this.embedded = false});

  /// A page of the app (the website's side bar has it), rather than opened over it.
  final bool embedded;

  final User user;
  final NotificationService notifications;
  final CalendarService calendar;
  final AiService ai;

  /// Premium beta: the assistant's and money settings are only there with it.
  final PremiumBeta premium;

  static Future<void> open(BuildContext context,
      {required User user,
      required NotificationService notifications,
      required CalendarService calendar,
      required AiService ai,
      required PremiumBeta premium}) {
    return Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsPage(user: user, notifications: notifications, calendar: calendar, ai: ai, premium: premium),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: embedded ? null : AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: Listenable.merge([notifications, calendar, hideAmounts, ai, premium]),
        builder: (context, _) => ListView(
          padding: EdgeInsets.fromLTRB(16, embedded ? PageSpace.top(context) : 4, 16, 32),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (embedded) Padding(padding: EdgeInsets.only(bottom: PageSpace.gap(context) - 20), child: const PageHeader(title: 'Settings')),
                  // Notifications are for Canvas alerts, which come from the
                  // every-minute check: premium beta's.
                  if (premium.on) ...[
                    _section('Notifications'),
                    Tile(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(children: [
                        SwitchListTile(
                          value: notifications.enabled,
                          onChanged: NotificationService.supported ? (on) => _setDevice(context, on) : null,
                          title: const Text('Notifications on this device'),
                          subtitle: Text(_deviceStatus(), style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
                        ),
                        if (notifications.enabled)
                          ListTile(
                            leading: const Icon(Icons.notifications_outlined),
                            title: const Text('Send a test notification'),
                            subtitle: const Text('Arrives in 10 seconds: lock your phone or leave the app to see it like a real one',
                                style: TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
                            onTap: () async {
                              final messenger = ScaffoldMessenger.of(context);
                              messenger.showSnackBar(const SnackBar(content: Text('Sending in 10 seconds…')));
                              try {
                                final sent = await notifications.sendTest(delaySeconds: 10);
                                messenger.showSnackBar(SnackBar(
                                    content: Text(sent == 0
                                        ? 'No devices have notifications turned on'
                                        : 'Sent to $sent ${sent == 1 ? 'device' : 'devices'}')));
                              } catch (e) {
                                messenger.showSnackBar(SnackBar(content: Text('Couldn’t send: $e')));
                              }
                            },
                          ),
                      ]),
                    ),
                  ],
                  // Google Calendar is the Calendar page's, a premium beta feature.
                  if (premium.on) ...[
                    _section('Calendar'),
                    Tile(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(children: [
                        SwitchListTile(
                          value: calendar.autoSync,
                          onChanged: calendar.setAutoSync,
                          title: const Text('Auto-sync with Google'),
                          subtitle: const Text('Checks Google Calendar every minute, even with Optimizer closed',
                              style: TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
                        ),
                        SwitchListTile(
                          value: calendar.keepPast,
                          onChanged: calendar.setKeepPast,
                          title: const Text('Keep past events'),
                          subtitle: const Text(
                              'Once an event is over, Optimizer keeps it as it was, even if it’s changed or deleted in Google Calendar. '
                              'For a calendar you add later, you’ll be asked whether to save its past events.',
                              style: TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
                        ),
                        ListTile(
                          title: const Text('Calendar layout on this device'),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 2, bottom: 8),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              const Text('Desktop shows the week with hours across, for a tablet or a big phone',
                                  style: TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
                              const SizedBox(height: 10),
                              ValueListenableBuilder(
                                valueListenable: calendarLayout,
                                builder: (context, layout, _) => PillTabs<CalendarLayout>(
                                  dense: true,
                                  items: const [
                                    (CalendarLayout.auto, 'Automatic'),
                                    (CalendarLayout.phone, 'Phone'),
                                    (CalendarLayout.desktop, 'Desktop')
                                  ],
                                  selected: layout,
                                  onSelected: setCalendarLayout,
                                ),
                              ),
                            ]),
                          ),
                        ),
                        ListTile(
                          leading: calendar.syncing
                              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.sync),
                          title: const Text('Sync now'),
                          subtitle: Text(
                              calendar.lastSynced == null
                                  ? 'Google and Canvas'
                                  : 'Last synced with Google ${DateFormat.jm().format(calendar.lastSynced!)}',
                              style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
                          onTap: calendar.syncing
                              ? null
                              : () async {
                                  final messenger = ScaffoldMessenger.of(context);
                                  final result = await calendar.syncNow();
                                  messenger.showSnackBar(SnackBar(content: Text(result)));
                                },
                        ),
                      ]),
                    ),
                  ],
                  if (premium.on && calendar.canvasFeeds.isNotEmpty) ...[
                    _section('Canvas alerts'),
                    Tile(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(children: [
                        for (final f in calendar.canvasFeeds)
                          SwitchListTile(
                            value: f.notifies,
                            onChanged: (on) => calendar.setCanvasNotify(f, on),
                            secondary: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(color: f.color, borderRadius: BorderRadius.circular(4)),
                            ),
                            title: Text(f.name),
                            subtitle:
                                const Text('New assignments and changed due dates', style: TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
                          ),
                      ]),
                    ),
                  ],
                  if (premium.on) ...[
                    _section('Assistant'),
                    _AiSettings(ai: ai),
                    _section('Privacy'),
                    Tile(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: SwitchListTile(
                        value: hideAmounts.value,
                        onChanged: (on) {
                          hideAmounts.value = on;
                          SharedPreferences.getInstance().then((p) => p.setBool('optimizer.hideAmounts', on), onError: (_) {});
                        },
                        title: const Text('Hide money amounts'),
                        subtitle: const Text('Shows •••• instead of balances and net worth',
                            style: TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
                      ),
                    ),
                  ],
                  _section('Feedback'),
                  Tile(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: const Icon(Icons.chat_bubble_outline),
                      title: const Text('Send feedback'),
                      subtitle:
                          const Text('Report a bug or suggest an improvement', style: TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => FeedbackPage.open(context, premium: premium),
                    ),
                  ),
                  _section('Account'),
                  Tile(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(children: [
                      ListTile(
                        leading: const Icon(Icons.person_outline),
                        title: Text(
                          user.displayName?.isNotEmpty == true ? user.displayName! : 'Add your name',
                          style: user.displayName?.isNotEmpty == true ? null : const TextStyle(color: AppColors.secondaryText),
                        ),
                        trailing:
                            IconButton(tooltip: 'Edit name', icon: const Icon(Icons.edit_outlined, size: 20), onPressed: () => _editName(context)),
                        onTap: () => _editName(context),
                        subtitle: user.email == null && !premium.on
                            ? null
                            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                if (user.email != null) Text(user.email!, style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5)),
                                if (premium.on) const Padding(padding: EdgeInsets.only(top: 4), child: PremiumBetaBadge()),
                              ]),
                      ),
                      ListTile(
                        leading: const Icon(Icons.logout, color: AppColors.danger),
                        title: const Text('Sign out', style: TextStyle(color: AppColors.danger)),
                        onTap: () async {
                          final ok = await confirmAction(context,
                              title: 'Sign out?', message: 'You can sign back in with your Axis account.', action: 'Sign out');
                          if (!ok || !context.mounted) return;
                          Navigator.of(context).pop();
                          await FirebaseAuth.instance.signOut();
                        },
                      ),
                    ]),
                  ),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Your name, as Optimizer (and your other Axis apps) show it.
  Future<void> _editName(BuildContext context) async {
    final field = TextEditingController(text: user.displayName ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        void save() => Navigator.pop(ctx, field.text.trim());
        return AlertDialog(
          title: const Text('Your name'),
          content: SizedBox(
            width: 400,
            child: TextField(
              controller: field,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              autofillHints: const [AutofillHints.name],
              decoration: const InputDecoration(labelText: 'Name'),
              onSubmitted: (_) => save(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: save, child: const Text('Save')),
          ],
        );
      },
    );
    field.dispose();
    if (name == null || name == (user.displayName ?? '') || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (name.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Type a name to save it.')));
      return;
    }
    try {
      await saveDisplayName(user, name);
      messenger.showSnackBar(const SnackBar(content: Text('Name saved')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn’t save your name: $e')));
    }
  }

  String _deviceStatus() {
    if (!NotificationService.supported) return 'Not available on this device yet';
    if (notifications.enabled) return 'You’ll be told about new Canvas assignments here';
    if (notifications.error != null) return notifications.error!;
    return 'Off';
  }

  Future<void> _setDevice(BuildContext context, bool on) async {
    if (!on) return notifications.disable();
    final ok = await notifications.enable();
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Notifications are blocked for Optimizer. Allow them in your phone’s (or browser’s) settings, then try again.'),
      ));
    }
  }

  static Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 22, 4, 8),
        child: Text(title.toUpperCase(),
            style: const TextStyle(color: AppColors.secondaryText, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1)),
      );
}

/// The built-in assistant: what it may read, what it may change, and
/// whether it checks with you first. There's no key to set up: it runs on
/// Optimizer's server (Gemini).
class _AiSettings extends StatelessWidget {
  const _AiSettings({required this.ai});

  final AiService ai;

  static const _note = TextStyle(color: AppColors.secondaryText, fontSize: 12.5, height: 1.35);

  @override
  Widget build(BuildContext context) {
    return Tile(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Row(children: [
          Icon(Icons.auto_awesome, size: 18, color: AppColors.positive),
          SizedBox(width: 8),
          Expanded(child: Text('Built in · Gemini', style: TextStyle(fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 4),
        const Text('Open it from the arrow at the top right of any page, or the Ask page. Nothing to set up.', style: _note),
        const SizedBox(height: 16),
        const Text('What it can see', style: TextStyle(fontWeight: FontWeight.w700)),
        for (final s in AiShare.values)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: ai.shared.contains(s),
            onChanged: (on) => ai.setShare(s, on),
            title: Text(s.label),
            subtitle: Text(s.detail, style: _note),
          ),
        const SizedBox(height: 10),
        const Text('What it can do', style: TextStyle(fontWeight: FontWeight.w700)),
        for (final a in AiAct.values)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: ai.acts.contains(a),
            onChanged: (on) => ai.setAct(a, on),
            title: Text(a.label),
            subtitle: Text(a.detail, style: _note),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: ai.confirmChanges,
          onChanged: ai.acts.isEmpty ? null : ai.setConfirmChanges,
          title: const Text('Check with me before each change'),
          subtitle: const Text('Off: it makes the changes, and you can undo them from the chat.', style: _note),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 4, bottom: 8),
          child: Text(
            'When you ask something, your question and the parts switched on above go to Google’s Gemini, '
            'through Optimizer’s server, to answer it. Changes it makes go through the same steps as yours, '
            'so they show in your calendar’s undo and history.',
            style: _note,
          ),
        ),
      ]),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'invites.dart';

bool looksLikeEmail(String s) => RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(s.trim());

/// After inviting: anyone not on Optimizer yet needs their link, sent by you
/// (a text, an email, anything). It lets them make an account and answer.
Future<void> showInviteLinks(BuildContext context, InviteLinks links) async {
  if (links.isEmpty || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(links.length == 1 ? 'Send ${links.first.email} their invitation' : 'Send them their invitations'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            '${links.length == 1 ? 'They aren’t' : 'These people aren’t'} on Optimizer yet. Copy ${links.length == 1 ? 'their link' : 'each link'} '
            'and send it to them; it lets them make an account and answer.',
            style: TextStyle(color: AppColors.secondaryText, height: 1.4),
          ),
          const SizedBox(height: 12),
          for (final x in links)
            Row(children: [
              Expanded(child: Text(x.email, overflow: TextOverflow.ellipsis)),
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: x.link));
                  // At once, not queued behind whatever message is showing.
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(SnackBar(content: Text('Link for ${x.email} copied')));
                },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy link'),
              ),
            ]),
        ]),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
    ),
  );
}

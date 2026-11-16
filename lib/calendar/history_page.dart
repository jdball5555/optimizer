import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme.dart';
import '../util/fields.dart';
import '../widgets/tiles.dart';
import 'calendar_history.dart';
import 'calendar_service.dart';

Future<void> showCalendarHistory(BuildContext context, CalendarService service) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => CalendarHistoryPage(service: service)));

/// What you've changed on your calendar lately, newest first, with a way to
/// put any of it back.
class CalendarHistoryPage extends StatelessWidget {
  const CalendarHistoryPage({super.key, required this.service});

  final CalendarService service;

  static String _day(DateTime d) {
    final today = dayStart(DateTime.now());
    if (sameDay(d, today)) return 'Today';
    if (sameDay(d, addDays(today, -1))) return 'Yesterday';
    return DateFormat('EEEE, MMMM d').format(d);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          leading: IconButton(tooltip: 'Back', icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context)),
          title: const Text('Calendar history'),
        ),
        body: ListenableBuilder(
          listenable: service,
          builder: (context, _) {
            final all = service.history;
            final rows = <Widget>[];
            DateTime? day;
            for (final e in all) {
              if (day == null || !sameDay(day, e.at)) {
                day = e.at;
                rows.add(Padding(
                  padding: EdgeInsets.fromLTRB(4, rows.isEmpty ? 4 : 22, 4, 8),
                  child: Text(_day(e.at), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                ));
              }
              rows.add(_HistoryRow(service: service, entry: e));
            }
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(4, 0, 4, 14),
                    child: Text('Changes stay here for $historyDays days, then clear away on their own.',
                        style: TextStyle(color: AppColors.secondaryText, fontSize: 13, height: 1.4)),
                  ),
                  if (all.isEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(4, 20, 4, 0),
                      child: Text('Nothing yet. When you change something on your calendar, it shows up here.',
                          style: TextStyle(color: AppColors.secondaryText, height: 1.4)),
                    ),
                  ...rows,
                ]),
              ),
            );
          },
        ),
      );
}

class _HistoryRow extends StatefulWidget {
  const _HistoryRow({required this.service, required this.entry});

  final CalendarService service;
  final HistoryEntry entry;

  @override
  State<_HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends State<_HistoryRow> {
  bool _reverting = false;

  static IconData _icon(HistoryAction a) => switch (a) {
        HistoryAction.added => Icons.add,
        HistoryAction.changed || HistoryAction.keptHere => Icons.edit_outlined,
        HistoryAction.deleted || HistoryAction.removed => Icons.delete_outline,
        HistoryAction.wentBack => Icons.restore,
        HistoryAction.hid => Icons.visibility_off_outlined,
        HistoryAction.showed => Icons.visibility_outlined,
      };

  Future<void> _revert() async {
    final e = widget.entry;
    final messenger = ScaffoldMessenger.of(context);
    if (!await confirmAction(context, title: 'Revert this change to “${e.title}”?', message: e.revertWarning, action: 'Revert') || !mounted) return;
    setState(() => _reverting = true);
    try {
      await widget.service.revertHistory(e);
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text('$err'.replaceFirst('Exception: ', ''))));
    } finally {
      if (mounted) setState(() => _reverting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    const quiet = TextStyle(color: AppColors.secondaryText, fontSize: 12.5, height: 1.4);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: e.reverted ? 0.55 : 1,
        child: Tile(
          padding: const EdgeInsets.fromLTRB(14, 11, 8, 11),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: Icon(_icon(e.action), size: 18, color: AppColors.secondaryText)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                Text('${e.label} at ${DateFormat.jm().format(e.at)} · ${e.google ? 'Google Calendar and Optimizer' : 'Optimizer only'}',
                    style: quiet),
                for (final d in e.details) Text(d, style: quiet),
              ]),
            ),
            const SizedBox(width: 8),
            if (e.reverted)
              const Padding(padding: EdgeInsets.all(8), child: Text('Reverted', style: quiet))
            else if (_reverting)
              const Padding(padding: EdgeInsets.all(10), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
            else
              TextButton(onPressed: _revert, child: const Text('Revert')),
          ]),
        ),
      ),
    );
  }
}

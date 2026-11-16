import 'package:intl/intl.dart';

import '../calendar/calendar_service.dart';
import '../calendar/todos.dart';
import '../journal/habit_store.dart';
import '../journal/journal_store.dart';
import '../networth/finance_store.dart';
import '../util/fields.dart';
import 'ai_service.dart';

/// What the AI is told: who it's helping and how, then the parts of your
/// data you've switched on (Settings → AI), as plain text. Built fresh for
/// every question so it's always current.
Future<String> buildAiContext({
  required Set<AiShare> shared,
  required String? name,
  required CalendarService calendar,
  required JournalStore journal,
  required HabitStore habits,
  required FinanceStore finance,
}) async {
  final now = DateTime.now();
  final today = dayStart(now);
  final day = DateFormat('EEE, MMM d');
  final time = DateFormat.jm();
  final money = NumberFormat.simpleCurrency();
  final out = StringBuffer()
    ..writeln('You are the assistant inside Optimizer, ${name ?? 'the user'}’s personal app for their calendar, '
        'to-dos, journal, habits and money. Answer their questions using the data below, which comes from their '
        'own accounts. Be direct and specific (names, dates, numbers), and keep answers short unless they ask for detail. '
        'If something they ask about isn’t in the data, say so rather than guessing. Their journal is private and '
        'personal; be kind and thoughtful when it comes up.')
    ..writeln()
    ..writeln('Right now it is ${DateFormat('EEEE, MMMM d, y · h:mm a').format(now)} (${now.timeZoneName}).')
    ..writeln('Data included: ${shared.isEmpty ? 'none' : shared.map((s) => s.label).join(', ')}. '
        '${AiShare.values.where((s) => !shared.contains(s)).map((s) => s.label).join(', ')} '
        '${shared.length == AiShare.values.length ? '' : 'is switched off; you can’t see it.'}');

  if (shared.contains(AiShare.calendar)) {
    final events = await calendar.fetchBetween(addDays(today, -3), addDays(today, 15));
    out
      ..writeln()
      ..writeln('## Calendar (3 days ago to 2 weeks ahead)');
    if (events.isEmpty) out.writeln('No events.');
    for (final e in events) {
      final when = e.allDay ? '${day.format(e.start)} · all day' : '${day.format(e.start)} · ${time.format(e.start)}–${time.format(e.end)}';
      out.writeln('- $when · ${e.title} (${e.calendar.name})${e.location.isNotEmpty ? ' @ ${e.location}' : ''}');
    }
  }

  if (shared.contains(AiShare.calendar) && calendar.trips.isNotEmpty) {
    out
      ..writeln()
      ..writeln('## Trips');
    for (final t in calendar.trips) {
      out.writeln('- ${t.title}${t.destination.isEmpty ? '' : ' (${t.destination})'}: ${day.format(t.start)} to ${day.format(t.end)}');
      for (final i in t.items) {
        out.writeln('  - ${day.format(i.start)} ${time.format(i.start)}–${time.format(i.end)} · ${i.kind.label} · ${i.title}${i.location.isEmpty ? '' : ' @ ${i.location}'}');
      }
    }
  }

  if (shared.contains(AiShare.todos)) {
    final todos = calendar.todos;
    final open = todos.where((t) => !t.done).toList()
      ..sort((a, b) => (a.due ?? DateTime(2100)).compareTo(b.due ?? DateTime(2100)));
    final done = todos.where((t) => t.done && t.doneAt != null && t.doneAt!.isAfter(addDays(today, -14))).toList()
      ..sort((a, b) => b.doneAt!.compareTo(a.doneAt!));
    String due(Todo t) => t.due == null ? 'no date' : (t.allDay ? day.format(t.due!) : '${day.format(t.due!)} ${time.format(t.due!)}');
    out
      ..writeln()
      ..writeln('## To-dos (Canvas assignments and their own)')
      ..writeln('Still to do:');
    if (open.isEmpty) out.writeln('- nothing');
    for (final t in open.take(120)) {
      final late = t.due != null && (t.allDay ? t.due!.isBefore(today) : t.due!.isBefore(now));
      out.writeln('- ${t.title}${t.label.isNotEmpty ? ' [${t.label}]' : ''} · due ${due(t)}${late ? ' · OVERDUE' : ''}');
    }
    out.writeln('Checked off in the last two weeks:');
    if (done.isEmpty) out.writeln('- nothing');
    for (final t in done.take(60)) {
      out.writeln('- ${t.title}${t.label.isNotEmpty ? ' [${t.label}]' : ''} · done ${day.format(t.doneAt!)} ${time.format(t.doneAt!)}');
    }
  }

  if (shared.contains(AiShare.journal)) {
    final since = addDays(today, -60);
    final recent = journal.entries.where((e) => e.date != null && !e.date!.isBefore(since)).toList().reversed;
    out
      ..writeln()
      ..writeln('## Journal (last 60 days, oldest first; ${journal.entries.length} entries in total, older ones not included)');
    if (recent.isEmpty) out.writeln('No entries in that time.');
    for (final e in recent) {
      out.writeln('### ${DateFormat('EEEE, MMMM d, y').format(e.date!)}${e.header.isNotEmpty ? ' — ${e.header}' : ''}');
      if (e.people.isNotEmpty) out.writeln('People: ${e.people.join(', ')}');
      out.writeln(e.body.trim());
      void notes(List<JournalNote> list, String indent) {
        for (final n in list) {
          out.writeln('$indent↳ ${n.date == null ? '' : DateFormat('MMM d').format(n.date!)}${n.header.isNotEmpty ? ' — ${n.header}' : ''}: ${n.body.trim()}');
          notes(n.children, '$indent  ');
        }
      }

      notes(e.context, '');
    }
  }

  if (shared.contains(AiShare.habits)) {
    out
      ..writeln()
      ..writeln('## Habits (✓ done, ✗ slipped, – skipped, · nothing logged; last 14 days, oldest first)');
    if (habits.habits.isEmpty) out.writeln('No habits.');
    for (final h in habits.habits) {
      final s = habits.stats(h);
      final days = [
        for (var i = 13; i >= 0; i--)
          switch (s.on(addDays(today, -i))) {
            DayStatus.done => '✓',
            DayStatus.slipped => '✗',
            DayStatus.skipped => '–',
            DayStatus.none => '·',
          },
      ].join();
      out.writeln('- ${h.title} (${h.isGoodHabit ? 'build' : 'break'}; goal ${h.targetStreak} days): '
          'streak ${s.current}, best ${s.best}; $days');
    }
  }

  if (shared.contains(AiShare.money)) {
    out
      ..writeln()
      ..writeln('## Money');
    final points = finance.points;
    if (points.isNotEmpty) {
      final latest = points.last;
      String change(Duration d) {
        final then = finance.before(d);
        return then == null ? 'n/a' : money.format(latest.total - then.total);
      }

      out.writeln('Net worth ${money.format(latest.total)} (as of ${day.format(latest.date)} ${time.format(latest.date)}); '
          'change: 1 day ${change(const Duration(hours: 23))}, 30 days ${change(const Duration(days: 30))}, '
          '1 year ${change(const Duration(days: 365))}.');
    }
    final accounts = finance.accounts;
    if (accounts != null) {
      for (final g in accountGroups) {
        final list = accounts.where((a) => accountGroupOf(a) == g).toList();
        if (list.isEmpty) continue;
        out.writeln('$g: ${list.map((a) => '${a['name']} ${money.format(accountBalance(a))}').join(', ')}');
      }
    }
    final month = DateTime(now.year, now.month);
    final flow = finance.cashFlow(month);
    final cats = finance.spendingByCategory(month).entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    out.writeln('This month: spent ${money.format(flow.expense)}, income ${money.format(flow.income)}. '
        'By category: ${cats.map((e) => '${e.key} ${money.format(e.value)}').join(', ')}.');
    final recent = finance.transactions.take(25);
    if (recent.isNotEmpty) {
      out.writeln('Latest transactions: ${recent.map((t) => '${t.date == null ? '' : DateFormat('MMM d').format(t.date!)} ${t.name} '
          '${t.isIncome ? '+' : '-'}${money.format(t.size)}${t.category == null ? '' : ' (${t.category})'}').join('; ')}.');
    }
    final holdings = finance.holdings;
    if (holdings.isNotEmpty) {
      out.writeln('Stocks: ${holdings.map((h) => '${h.ticker} ${money.format(h.value)}'
          '${h.dayPct == null ? '' : ' (${h.dayPct!.toStringAsFixed(2)}% today)'}').join(', ')}.');
    }
    final fills = finance.gasFills.where((f) => f.mpg != null).take(5).toList();
    if (fills.isNotEmpty) out.writeln('Recent gas mileage: ${fills.map((f) => '${f.mpg!.toStringAsFixed(1)} mpg').join(', ')}.');
  }
  return out.toString();
}

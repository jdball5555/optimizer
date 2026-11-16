import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme.dart';
import '../util/fields.dart';
import '../widgets/tiles.dart';
import 'habit_store.dart';

const _done = AppColors.positive;
const _slip = AppColors.danger;
const _breakAccent = Color(0xFFF5B454);

/// Axis Journal's habits: each with its streak, and the last seven days to
/// tap through (done, slipped, skipped).
class HabitsView extends StatelessWidget {
  const HabitsView({super.key, required this.store});

  final HabitStore store;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        if (store.error != null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SelectableText('Couldn’t read your habits.\n${store.error}',
                  textAlign: TextAlign.center, style: const TextStyle(color: AppColors.secondaryText)),
            ),
          );
        }
        if (!store.loaded) return const Center(child: CircularProgressIndicator());
        final habits = store.habits;
        final today = DateTime.now();
        final doneToday = habits.where((h) => store.stats(h).on(today) == DayStatus.done).length;

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            Row(children: [
              Expanded(
                child: Text(
                  habits.isEmpty ? 'No habits yet' : 'Today · $doneToday of ${habits.length} done',
                  style: const TextStyle(color: AppColors.secondaryText, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              TextButton.icon(
                onPressed: () => _newHabit(context),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New habit'),
              ),
            ]),
            const SizedBox(height: 8),
            if (habits.isEmpty)
              const Tile(
                padding: EdgeInsets.all(24),
                child: Text('Add a habit to build (something to do more) or break (something to stop).',
                    style: TextStyle(color: AppColors.secondaryText)),
              )
            else ...[
              // Today: one ring per habit; tap to check it off.
              SizedBox(
                height: 128,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: habits.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 14),
                  itemBuilder: (context, i) => _TodayRing(store: store, habit: habits[i]),
                ),
              ),
              const SizedBox(height: 18),
              const Text('LAST 12 WEEKS',
                  style: TextStyle(color: AppColors.secondaryText, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1)),
              const SizedBox(height: 10),
              TileGrid(minTileWidth: 320, maxColumns: 3, tiles: [for (final h in habits) _HistoryCard(store: store, habit: h)]),
            ],
          ],
        );
      },
    );
  }

  Future<void> _newHabit(BuildContext context) async {
    final title = TextEditingController();
    final description = TextEditingController();
    var build = true;
    var goal = 21;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('New habit'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(controller: title, autofocus: true, decoration: const InputDecoration(labelText: 'Habit')),
              const SizedBox(height: 12),
              TextField(controller: description, decoration: const InputDecoration(labelText: 'Why (optional)')),
              const SizedBox(height: 16),
              Row(children: [
                for (final (value, icon, label, hint) in const [
                  (true, Icons.north_east, 'Build', 'Something to do more'),
                  (false, Icons.block, 'Break', 'Something to stop'),
                ]) ...[
                  if (!value) const SizedBox(width: 10),
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => setLocal(() => build = value),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: build == value ? AppColors.surfaceHigh : AppColors.surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: build == value ? AppColors.primaryText : AppColors.border),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Icon(icon, size: 20),
                          const SizedBox(height: 6),
                          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                          Text(hint, style: const TextStyle(color: AppColors.secondaryText, fontSize: 12)),
                        ]),
                      ),
                    ),
                  ),
                ],
              ]),
              const SizedBox(height: 16),
              const Text('Goal', style: TextStyle(color: AppColors.secondaryText, fontSize: 12)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, children: [
                for (final g in const [7, 21, 30, 66, 90])
                  ChoiceChip(label: Text('$g days'), selected: goal == g, onSelected: (_) => setLocal(() => goal = g)),
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                if (title.text.trim().isEmpty) return;
                await store.add(title: title.text.trim(), description: description.text.trim(), build: build, target: goal);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }
}

Color _accent(Habit h) => h.isGoodHabit ? AppColors.primaryText : _breakAccent;

Color _statusColor(DayStatus s) => switch (s) {
      DayStatus.done => _done,
      DayStatus.slipped => _slip,
      DayStatus.skipped => const Color(0x59FFFFFF),
      DayStatus.none => const Color(0x14FFFFFF),
    };

/// A habit today: its icon in a ring that fills toward its goal streak. Tap
/// to cycle today (done → slipped → skipped).
class _TodayRing extends StatelessWidget {
  const _TodayRing({required this.store, required this.habit});

  final HabitStore store;
  final Habit habit;

  @override
  Widget build(BuildContext context) {
    final stats = store.stats(habit);
    final today = DateTime.now();
    final status = stats.on(today);
    final progress = (stats.current / habit.targetStreak).clamp(0.0, 1.0);
    final fill = status == DayStatus.none ? AppColors.surface : _statusColor(status).withValues(alpha: 0.9);
    return SizedBox(
      width: 78,
      child: Column(children: [
        GestureDetector(
          onTap: () => store.setDay(habit, today, nextHabitValue(status)),
          child: SizedBox.square(
            dimension: 72,
            child: CustomPaint(
              painter: _RingPainter(progress: progress, color: _accent(habit)),
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
                  child: Icon(
                    switch (status) {
                      DayStatus.done => Icons.check_rounded,
                      DayStatus.slipped => Icons.close_rounded,
                      DayStatus.skipped => Icons.remove_rounded,
                      DayStatus.none => habit.icon,
                    },
                    color: status == DayStatus.none ? _accent(habit) : AppColors.background,
                    size: 26,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(habit.title,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.local_fire_department, size: 12, color: AppColors.secondaryText),
          Flexible(
            child: Text(' ${stats.current} / ${habit.targetStreak}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.secondaryText, fontSize: 11)),
          ),
        ]),
      ]),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final track = Paint()
      ..color = const Color(0x1FFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5;
    canvas.drawArc(rect.deflate(3), 0, 6.2832, false, track);
    if (progress > 0) {
      canvas.drawArc(
        rect.deflate(3),
        -1.5708,
        6.2832 * progress,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.progress != progress || old.color != color;
}

/// A habit's last 12 weeks as a grid of days (a column per week), colored
/// by how each went, with its streaks. Tap a day to change it.
class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.store, required this.habit});

  final HabitStore store;
  final Habit habit;

  static const _weeks = 12;

  @override
  Widget build(BuildContext context) {
    final stats = store.stats(habit);
    final today = dayStart(DateTime.now());
    // Columns are Sunday-first weeks, ending with this one.
    final firstDay = addDays(today, -(today.weekday % 7) - 7 * (_weeks - 1));
    var done = 0, tracked = 0;
    for (var i = 0; i < _weeks * 7; i++) {
      final s = stats.on(addDays(firstDay, i));
      if (s == DayStatus.done) done++;
      if (s == DayStatus.done || s == DayStatus.slipped) tracked++;
    }
    return HoverMenu(
      top: 8,
      right: 8,
      actions: [
        MenuAction(
          label: 'Delete habit',
          icon: Icons.delete_outline,
          onSelected: () => store.delete(habit),
          confirm: ('Delete “${habit.title}”?', 'It’s removed from Axis Journal too. Its past check-ins stay in your history.', 'Delete'),
        ),
      ],
      child: Tile(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.only(right: 28),
            child: Row(children: [
              Icon(habit.icon, size: 20, color: _accent(habit)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(habit.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              ),
              Text(habit.isGoodHabit ? 'Build' : 'Break',
                  style: TextStyle(color: _accent(habit).withValues(alpha: 0.8), fontSize: 11.5, fontWeight: FontWeight.w600)),
            ]),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (context, c) {
            const gap = 3.0;
            final cell = ((c.maxWidth - gap * (_weeks - 1)) / _weeks).floorToDouble().clamp(8.0, 30.0);
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (var w = 0; w < _weeks; w++) ...[
                if (w > 0) const SizedBox(width: gap),
                Column(children: [
                  for (var d = 0; d < 7; d++) ...[
                    if (d > 0) const SizedBox(height: gap),
                    Builder(builder: (context) {
                      final day = addDays(firstDay, w * 7 + d);
                      if (day.isAfter(today)) return SizedBox.square(dimension: cell);
                      final s = stats.on(day);
                      return Tooltip(
                        message: DateFormat('EEE, MMM d').format(day),
                        waitDuration: const Duration(milliseconds: 600),
                        child: GestureDetector(
                          onTap: () => store.setDay(habit, day, nextHabitValue(s)),
                          child: Container(
                            width: cell,
                            height: cell,
                            decoration: BoxDecoration(
                              color: _statusColor(s),
                              borderRadius: BorderRadius.circular(3),
                              border: sameDay(day, today) ? Border.all(color: AppColors.primaryText, width: 1.5) : null,
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                ]),
              ],
            ]);
          }),
          const SizedBox(height: 12),
          // Wraps rather than overflowing with large text sizes.
          Wrap(spacing: 18, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            _stat('${stats.current}', 'streak'),
            _stat('${stats.best}', 'best'),
            _stat(tracked == 0 ? '—' : '${(done / tracked * 100).round()}%', 'kept'),
            Text('Goal ${habit.targetStreak} days', style: const TextStyle(color: AppColors.secondaryText, fontSize: 11.5)),
          ]),
        ]),
      ),
    );
  }

  Widget _stat(String value, String label) =>
      Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Text(value, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(color: AppColors.secondaryText, fontSize: 11.5)),
      ]);
}

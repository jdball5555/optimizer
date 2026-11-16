import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../util/fields.dart';
import '../util/dispose_safe.dart';

/// A habit from Axis Journal (axis_journal_habits): something to build (do
/// more) or break (stop), with a streak to reach.
class Habit {
  Habit(this.id, Map<String, dynamic> d)
      : title = '${d['title'] ?? ''}',
        description = '${d['description'] ?? ''}',
        targetStreak = (d['targetStreak'] as num?)?.toInt() ?? 21,
        isGoodHabit = d['isGoodHabit'] != false,
        createdAt = asDate(d['createdAt']) ?? DateTime(2000),
        iconKey = d['iconKey'] as String?;

  final String id;
  final String title;
  final String description;
  final int targetStreak;
  final bool isGoodHabit;
  final DateTime createdAt;
  final String? iconKey;

  IconData get icon => habitIcons[iconKey] ?? habitIcons['star']!;
}

/// One day's record for a habit (axis_journal_habit_logs): done, slipped
/// (false) or skipped (null).
class HabitLog {
  HabitLog(this.id, Map<String, dynamic> d)
      : habitId = '${d['habitId'] ?? ''}',
        date = asDate(d['date']) ?? DateTime(2000),
        completed = d['completed'] as bool?,
        weight = (d['weight'] as num?)?.toInt() ?? 1;

  final String id;
  final String habitId;
  final DateTime date;
  final bool? completed;
  final int weight;
}

enum DayStatus { none, done, slipped, skipped }

/// Streaks and per-day results, worked out exactly as Axis Journal does.
class HabitStats {
  HabitStats(List<HabitLog> logs) {
    final oldestFirst = [...logs]..sort((a, b) => a.date.compareTo(b.date));
    // The last log of a day wins.
    for (final log in oldestFirst) {
      byDay[dayStart(log.date)] = switch (log.completed) {
        true => DayStatus.done,
        false => DayStatus.slipped,
        null => DayStatus.skipped,
      };
    }
    var run = 0;
    for (final log in oldestFirst) {
      if (log.completed == true) {
        run += log.weight;
        if (run > best) best = run;
      } else if (log.completed == false) {
        run = 0;
      }
    }
    // Current streak: back from the newest log, skips don't break it.
    for (final log in oldestFirst.reversed) {
      if (log.completed == true) {
        current += log.weight;
      } else if (log.completed == false) {
        break;
      }
    }
  }

  final byDay = <DateTime, DayStatus>{};
  int current = 0;
  int best = 0;

  DayStatus on(DateTime d) => byDay[dayStart(d)] ?? DayStatus.none;
}

/// Tapping a day cycles it: nothing → done → slipped → skipped → done …
bool? nextHabitValue(DayStatus s) => switch (s) {
      DayStatus.none || DayStatus.skipped => true,
      DayStatus.done => false,
      DayStatus.slipped => null,
    };

/// Your Axis Journal habits and their logs, live. Writes go to the same
/// documents, so Axis Journal sees every check-off.
class HabitStore extends ChangeNotifier with DisposeSafe {
  HabitStore(this.uid) {
    _subs = [
      _habits.where('userId', isEqualTo: uid).snapshots().listen((s) {
        habits = [for (final d in s.docs) Habit(d.id, d.data())]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        loaded = true;
        _changed();
      }, onError: _failed),
      _logs.where('userId', isEqualTo: uid).snapshots().listen((s) {
        _byHabit = {};
        for (final d in s.docs) {
          final log = HabitLog(d.id, d.data());
          (_byHabit[log.habitId] ??= []).add(log);
        }
        _stats.clear();
        _changed();
      }, onError: _failed),
    ];
  }

  /// For previews and tests: fixed habits and logs, no Firestore.
  @visibleForTesting
  HabitStore.withData(this.uid, this.habits, List<HabitLog> logs) : loaded = true {
    _subs = const [];
    for (final l in logs) {
      (_byHabit[l.habitId] ??= []).add(l);
    }
  }

  final String uid;
  late final List<StreamSubscription> _subs;
  List<Habit> habits = [];
  bool loaded = false;
  Object? error;
  Map<String, List<HabitLog>> _byHabit = {};
  final _stats = <String, HabitStats>{};

  CollectionReference<Map<String, dynamic>> get _habits => FirebaseFirestore.instance.collection('axis_journal_habits');
  CollectionReference<Map<String, dynamic>> get _logs => FirebaseFirestore.instance.collection('axis_journal_habit_logs');

  void _changed() {
    error = null;
    notifyListeners();
  }

  void _failed(Object e) {
    error = e;
    notifyListeners();
  }

  HabitStats stats(Habit h) => _stats.putIfAbsent(h.id, () => HabitStats(_byHabit[h.id] ?? const []));

  /// Records [completed] for [day], replacing what was there (as Axis Journal does).
  Future<void> setDay(Habit h, DateTime day, bool? completed) async {
    final logs = (_byHabit[h.id] ?? const <HabitLog>[]).where((l) => sameDay(l.date, day)).toList();
    if (logs.isNotEmpty) {
      for (final l in logs) {
        await _logs.doc(l.id).update({'completed': completed});
      }
      return;
    }
    final now = DateTime.now();
    final at = sameDay(day, now) ? now : DateTime(day.year, day.month, day.day, 12);
    await _logs.add({
      'userId': uid,
      'habitId': h.id,
      'date': Timestamp.fromDate(at),
      'completed': completed,
      'dueDate': Timestamp.fromDate(at),
      'weight': 1,
    });
  }

  Future<void> add({required String title, String description = '', required bool build, int target = 21}) => _habits.add({
        'userId': uid,
        'title': title,
        'description': description,
        'targetStreak': target,
        'isGoodHabit': build,
        'createdAt': Timestamp.now(),
        'rank': 5,
        'iconKey': matchHabitIcon(title, description),
      });

  Future<void> delete(Habit h) => _habits.doc(h.id).delete();

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}

/// A rough pick of icon for a new habit: the first icon key named in its
/// title or description (Axis Journal lets you change it).
String matchHabitIcon(String title, String description) {
  final words = '$title $description'.toLowerCase().split(RegExp(r'[^a-z0-9]+')).toSet();
  for (final key in habitIcons.keys) {
    if (words.contains(key)) return key;
  }
  return 'star';
}

/// Axis Journal's habit icons, by the key it stores in iconKey.
const habitIcons = <String, IconData>{
  'run': Icons.directions_run_rounded,
  'walk': Icons.directions_walk_rounded,
  'hike': Icons.hiking_rounded,
  'gym': Icons.fitness_center_rounded,
  'bike': Icons.directions_bike_rounded,
  'swim': Icons.pool_rounded,
  'yoga': Icons.self_improvement_rounded,
  'sports': Icons.sports_basketball_rounded,
  'soccer': Icons.sports_soccer_rounded,
  'tennis': Icons.sports_tennis_rounded,
  'golf': Icons.sports_golf_rounded,
  'martial': Icons.sports_martial_arts_rounded,
  'posture': Icons.accessibility_new_rounded,
  'weight': Icons.monitor_weight_rounded,
  'heart': Icons.favorite_rounded,
  'health': Icons.monitor_heart_rounded,
  'meditate': Icons.spa_rounded,
  'journal': Icons.edit_note_rounded,
  'read': Icons.menu_book_rounded,
  'audiobook': Icons.headphones_rounded,
  'learn': Icons.school_rounded,
  'language': Icons.translate_rounded,
  'brain': Icons.psychology_rounded,
  'pray': Icons.volunteer_activism_rounded,
  'idea': Icons.lightbulb_rounded,
  'goal': Icons.flag_rounded,
  'water': Icons.water_drop_rounded,
  'eat': Icons.restaurant_rounded,
  'cook': Icons.soup_kitchen_rounded,
  'veggie': Icons.eco_rounded,
  'fruit': Icons.apple_rounded,
  'coffee': Icons.coffee_rounded,
  'alcohol': Icons.wine_bar_rounded,
  'sugar': Icons.cake_rounded,
  'fastfood': Icons.fastfood_rounded,
  'fast': Icons.no_food_rounded,
  'vitamin': Icons.medication_rounded,
  'sleep': Icons.bedtime_rounded,
  'wake': Icons.wb_sunny_rounded,
  'alarm': Icons.alarm_rounded,
  'routine': Icons.checklist_rounded,
  'calendar': Icons.calendar_month_rounded,
  'timer': Icons.timer_rounded,
  'phone': Icons.smartphone_rounded,
  'nophone': Icons.phonelink_erase_rounded,
  'social': Icons.public_rounded,
  'tv': Icons.tv_rounded,
  'game': Icons.sports_esports_rounded,
  'smoke': Icons.smoke_free_rounded,
  'nobad': Icons.block_rounded,
  'swear': Icons.voice_over_off_rounded,
  'nails': Icons.back_hand_rounded,
  'spend': Icons.shopping_cart_rounded,
  'money': Icons.savings_rounded,
  'work': Icons.work_rounded,
  'code': Icons.code_rounded,
  'email': Icons.mail_rounded,
  'laptop': Icons.laptop_mac_rounded,
  'clean': Icons.cleaning_services_rounded,
  'laundry': Icons.local_laundry_service_rounded,
  'bed': Icons.bed_rounded,
  'teeth': Icons.clean_hands_rounded,
  'shower': Icons.shower_rounded,
  'skin': Icons.face_retouching_natural_rounded,
  'plants': Icons.local_florist_rounded,
  'pet': Icons.pets_rounded,
  'family': Icons.family_restroom_rounded,
  'friends': Icons.groups_rounded,
  'call': Icons.call_rounded,
  'chat': Icons.forum_rounded,
  'volunteer': Icons.handshake_rounded,
  'smile': Icons.sentiment_satisfied_alt_rounded,
  'music': Icons.music_note_rounded,
  'piano': Icons.piano_rounded,
  'guitar': Icons.queue_music_rounded,
  'art': Icons.palette_rounded,
  'photo': Icons.photo_camera_rounded,
  'video': Icons.videocam_rounded,
  'craft': Icons.handyman_rounded,
  'outdoors': Icons.park_rounded,
  'travel': Icons.flight_rounded,
  'drive': Icons.directions_car_rounded,
  'star': Icons.star_rounded,
  'bolt': Icons.bolt_rounded,
  'fire': Icons.local_fire_department_rounded,
  'check': Icons.check_circle_rounded,
  'trophy': Icons.emoji_events_rounded,
};

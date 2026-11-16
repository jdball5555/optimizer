import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../util/dispose_safe.dart';
import '../util/fields.dart';

/// The parts of your data the assistant may read, each switched on or off.
enum AiShare {
  calendar('Calendar', 'Your events, trips and free time, any dates it needs'),
  todos('To-dos', 'What’s due, overdue and recently done'),
  journal('Journal', 'Your entries from the last two months'),
  habits('Habits', 'Your habits, streaks and the last two weeks'),
  money('Money', 'Net worth, accounts, this month’s spending, stocks and gas');

  const AiShare(this.label, this.detail);
  final String label;
  final String detail;
}

/// What the assistant may change for you, each off until you turn it on.
enum AiAct {
  calendar('Change your calendar', 'Make, change and delete your own calendars; add, move, edit and delete events on calendars you can edit'),
  todos('Change your to-dos', 'Add, edit, check off and delete to-dos'),
  trips('Change your trips', 'Make, edit and delete trips, and add, change and remove what’s on them');

  const AiAct(this.label, this.detail);
  final String label;
  final String detail;
}

/// One saved line of a chat: what you said, what it answered, or what it did.
typedef AiLine = ({String role, String text});

class AiChat {
  AiChat(this.id, Map<String, dynamic> d)
      : title = '${d['title'] ?? 'Chat'}',
        updated = asDate(d['updatedAt']) ?? DateTime(2000),
        lines = [
          for (final m in (d['messages'] as List? ?? const []))
            if (m is Map) (role: '${m['role'] ?? 'assistant'}', text: '${m['text'] ?? ''}'),
        ];

  final String id;
  final String title;
  final DateTime updated;
  final List<AiLine> lines;
}

/// Your assistant's settings and chats, kept in your own account:
///
///   optimizer/{uid}.ai           what it may read and change
///   optimizer/{uid}/aiChats/{id} your conversations
///
/// The assistant itself is Gemini, run by Optimizer's server (functions/assistant.js):
/// there's no API key to set up.
class AiService extends ChangeNotifier with DisposeSafe {
  AiService(this.uid) {
    _subs = [
      _doc.snapshots().listen((s) {
        final d = s.data() ?? const {};
        final ai = (d['ai'] as Map?) ?? const {};
        final share = (ai['share'] as Map?) ?? const {};
        shared = {for (final s in AiShare.values) if (share[s.name] != false) s};
        final act = (ai['act'] as Map?) ?? const {};
        acts = {for (final a in AiAct.values) if (act[a.name] == true) a};
        confirmChanges = ai['confirmChanges'] != false;
        loaded = true;
        notifyListeners();
      }, onError: (Object e) {
        error = '$e';
        notifyListeners();
      }),
      _doc.collection('aiChats').orderBy('updatedAt', descending: true).limit(50).snapshots().listen((s) {
        chats = [for (final d in s.docs) AiChat(d.id, d.data())];
        notifyListeners();
      }, onError: (_) {}),
    ];
  }

  final String uid;
  late final List<StreamSubscription> _subs;

  bool loaded = false;
  String? error;
  Set<AiShare> shared = AiShare.values.toSet();
  Set<AiAct> acts = {};

  /// Ask before each change it makes (on unless you turn it off).
  bool confirmChanges = true;
  List<AiChat> chats = [];

  DocumentReference<Map<String, dynamic>> get _doc => FirebaseFirestore.instance.collection('optimizer').doc(uid);
  CollectionReference<Map<String, dynamic>> get chatsRef => _doc.collection('aiChats');

  Future<void> setShare(AiShare s, bool on) => _doc.set({
        'ai': {
          'share': {s.name: on},
        },
      }, SetOptions(merge: true));

  Future<void> setAct(AiAct a, bool on) => _doc.set({
        'ai': {
          'act': {a.name: on},
        },
      }, SetOptions(merge: true));

  Future<void> setConfirmChanges(bool on) => _doc.set({
        'ai': {'confirmChanges': on},
      }, SetOptions(merge: true));

  Future<void> deleteChat(AiChat c) => chatsRef.doc(c.id).delete();

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}

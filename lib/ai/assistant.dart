import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../calendar/calendar_service.dart';
import '../trips/trip_store.dart';
import '../util/dispose_safe.dart';
import 'ai_service.dart';
import 'assistant_tools.dart';

enum LineKind { user, reply, action }

/// One line of the chat as shown: what you said, its answer, or something it did.
class AssistantLine {
  AssistantLine(this.kind, this.text, {this.changed = false});
  final LineKind kind;
  final String text;

  /// An action that changed your data (shown with a check).
  final bool changed;

  String get role => switch (kind) { LineKind.user => 'user', LineKind.reply => 'assistant', LineKind.action => 'action' };
}

/// A change waiting for your yes or no (when Settings → Assistant asks first).
class PendingChange {
  PendingChange(this.text);
  final String text;
  final _done = Completer<bool>();
  Future<bool> get answer => _done.future;
  void answerWith(bool yes) {
    if (!_done.isCompleted) _done.complete(yes);
  }
}

/// The built-in assistant's conversation. One for the whole app: the side
/// panel and the Ask page show the same chat.
///
/// Each message goes to Gemini through Optimizer's server (`assistant` in
/// functions/assistant.js). When Gemini wants to look something up or make
/// a change, the tool runs here ([AssistantTools]) and the result goes back,
/// until it has an answer. Everything it changes in one message is a single
/// step in the calendar's undo.
class AssistantController extends ChangeNotifier with DisposeSafe {
  AssistantController({required this.ai, required this.calendar, this.trips, required this.context, this.navigate}) {
    _tools = _newTools();
  }

  final AiService ai;
  final CalendarService calendar;
  final TripStore? trips;

  /// What it's told about you and your data (Settings → Assistant decides what's in it).
  final Future<String> Function() context;
  final void Function(String page)? navigate;

  /// Whether the side panel is open.
  final panelOpen = ValueNotifier<bool>(false);

  final List<AssistantLine> lines = [];
  final List<Map<String, dynamic>> _contents = [];
  late AssistantTools _tools;
  String? chatId;
  bool busy = false;
  String? error;
  PendingChange? pending;
  bool _yesToAll = false;

  /// The undo label of the last message's changes, while undo would still reverse them.
  String? _undoLabel;
  bool get canUndo => _undoLabel != null && calendar.lastChange?.label == _undoLabel;

  static const _maxRounds = 12;

  AssistantTools _newTools() => AssistantTools(ai: ai, calendar: calendar, trips: trips, confirm: _confirm, navigate: navigate);

  Future<bool> _confirm(String change) async {
    if (_yesToAll) return true;
    final p = pending = PendingChange(change);
    notifyListeners();
    final yes = await p.answer;
    if (pending == p) pending = null;
    notifyListeners();
    return yes;
  }

  /// Yes to this change and the rest of this message's.
  void approveAll() {
    _yesToAll = true;
    pending?.answerWith(true);
  }

  void toggle() => panelOpen.value = !panelOpen.value;

  void newChat() {
    if (busy) return;
    lines.clear();
    _contents.clear();
    chatId = null;
    error = null;
    _undoLabel = null;
    _tools = _newTools();
    notifyListeners();
  }

  void openChat(AiChat c) {
    if (busy) return;
    newChat();
    chatId = c.id;
    for (final l in c.lines) {
      final kind = switch (l.role) { 'user' => LineKind.user, 'action' => LineKind.action, _ => LineKind.reply };
      lines.add(AssistantLine(kind, l.text));
      // Gemini gets the words back; what it did shows as a note in its reply.
      if (kind == LineKind.user) {
        _contents.add(_text('user', l.text));
      } else {
        final last = _contents.lastOrNull;
        if (last != null && last['role'] == 'model') {
          (last['parts'] as List).add({'text': kind == LineKind.action ? '[Done earlier: ${l.text}]' : l.text});
        } else {
          _contents.add(_text('model', kind == LineKind.action ? '[Done earlier: ${l.text}]' : l.text));
        }
      }
    }
    notifyListeners();
  }

  static Map<String, dynamic> _text(String role, String text) => {
        'role': role,
        'parts': [
          {'text': text},
        ],
      };

  Future<String> _instructions() async {
    final now = DateTime.now();
    final about = await context();
    return 'You are the assistant built into Optimizer, a personal app for their calendar, to-dos, trips, '
        'journal, habits and money. You can look things up and make changes with your tools, and your goal '
        'is to help them use their time well: plan days, find time for things, untangle clashes, spread work '
        'out before deadlines, and keep the calendar and to-dos tidy.\n\n'
        'It is now ${DateFormat('EEEE, MMMM d, y, h:mm a').format(now)} (${now.timeZoneName}). '
        'All times you read and write are their local time, written YYYY-MM-DDTHH:MM.\n\n'
        'How to work:\n'
        '- Look before you answer: use get_events, find_free_time and get_todos for any dates you need. The '
        'summary below only covers about two weeks and has no ids.\n'
        '- To change or delete something, get its id from get_events or get_todos first.\n'
        '- For a new calendar use create_calendar, then put events on it with its calendar_id. Those calendars '
        'stay in Optimizer and are not synced with Google. Google and Canvas calendars can\'t be created, renamed or deleted.\n'
        '- When asked to plan or schedule, fit things around what is already there, leave short breaks, keep '
        'sensible hours unless told otherwise, and do the work rather than only describing it.\n'
        '- Trips are looked at with get_trips and changed with their own tools, not the event ones. Times on a trip '
        'are the clock at that place. Don\'t make up times, confirmation numbers or flight details: ask for what '
        'they haven\'t said, or leave it out if it can be.\n'
        '- If a request is unclear in a way that matters (which event, which day), ask one short question '
        'instead of guessing. Never delete more than they asked for, and before deleting several things say which.\n'
        '- Deleting a Google event deletes it from Google Calendar too. If it isn\'t clear they want that, ask, or use only_in_optimizer.\n'
        '- After making changes, say briefly what you did, with days and times. They can undo it from the chat.\n'
        '- If a change is skipped, accept it and do not try it again.\n'
        '- Be direct and concise. Use short lists for schedules. Their journal is private: be kind about it.\n'
        '- ${_tools.limits()}\n\n'
        'Here is what you know about them now:\n\n$about';
  }

  /// Sends what you typed, and works through Gemini's tool calls until it answers.
  Future<void> send(String text) async {
    final q = text.trim();
    if (q.isEmpty || busy) return;
    busy = true;
    error = null;
    _yesToAll = false;
    final start = _contents.length;
    lines.add(AssistantLine(LineKind.user, q));
    _contents.add(_text('user', q));
    final firstLine = lines.length - 1;
    notifyListeners();

    final label = 'Assistant: “${q.length > 40 ? '${q.substring(0, 37)}…' : q}”';
    var changed = false;
    try {
      final system = await _instructions();
      await calendar.asOneChange(label, () async {
        for (var round = 0; round < _maxRounds; round++) {
          final content = await _ask(system);
          _contents.add(content);
          final parts = [for (final p in (content['parts'] as List? ?? const [])) if (p is Map) Map<String, dynamic>.from(p)];
          final calls = [for (final p in parts) if (p['functionCall'] is Map) Map<String, dynamic>.from(p['functionCall'] as Map)];
          final said = [
            for (final p in parts)
              if (p['text'] is String && p['thought'] != true) p['text'] as String,
          ].join().trim();
          if (said.isNotEmpty) lines.add(AssistantLine(LineKind.reply, said));
          if (calls.isEmpty) {
            if (said.isEmpty) lines.add(AssistantLine(LineKind.reply, '(No answer.)'));
            return;
          }
          notifyListeners();
          final responses = <Map<String, dynamic>>[];
          for (final call in calls) {
            final name = '${call['name']}';
            final args = call['args'] is Map ? Map<String, dynamic>.from(call['args'] as Map) : <String, dynamic>{};
            final run = await _tools.run(name, args);
            if (run.note != null) lines.add(AssistantLine(LineKind.action, run.note!, changed: run.changed));
            changed = changed || run.changed;
            responses.add({
              'functionResponse': {'name': name, 'response': run.result},
            });
            notifyListeners();
          }
          _contents.add({'role': 'user', 'parts': responses});
        }
        lines.add(AssistantLine(LineKind.reply, 'I stopped after $_maxRounds steps. Tell me if you want me to keep going.'));
      });
    } catch (e) {
      error = _message(e);
      // Gemini didn't finish: what it's told next time is just what was said
      // and done, never a half-finished round of tools.
      _contents.removeRange(start, _contents.length);
      final after = lines.sublist(firstLine + 1);
      if (after.isEmpty) {
        lines.removeLast();
      } else {
        _contents
          ..add(_text('user', q))
          ..add(_text('model', [for (final l in after) l.kind == LineKind.action ? '[Done: ${l.text}]' : l.text].join('\n')));
      }
    } finally {
      pending?.answerWith(false);
      pending = null;
      busy = false;
      _undoLabel = changed ? label : null;
      notifyListeners();
    }
    if (lines.length > firstLine) await _save(q);
  }

  /// Puts back everything the last message changed.
  Future<String?> undo() async {
    if (!canUndo) return null;
    final done = await calendar.undoLast();
    _undoLabel = null;
    lines.add(AssistantLine(LineKind.action, 'Undid those changes'));
    notifyListeners();
    return done;
  }

  Future<Map<String, dynamic>> _ask(String system) async {
    final r = await FirebaseFunctions.instance
        .httpsCallable('assistant', options: HttpsCallableOptions(timeout: const Duration(minutes: 2)))
        .call({'system': system, 'contents': _contents, 'tools': _tools.declarations()});
    // Plain JSON, so it can be sent back exactly as Gemini wrote it.
    final data = jsonDecode(jsonEncode(r.data)) as Map<String, dynamic>;
    final content = data['content'];
    if (content is! Map<String, dynamic>) {
      throw Exception('Gemini didn’t answer that one (${data['blocked'] ?? 'no reason given'}).');
    }
    content['role'] = 'model';
    content['parts'] ??= <dynamic>[];
    return content;
  }

  static String _message(Object e) {
    if (e is FirebaseFunctionsException) {
      return switch (e.code) {
        'not-found' => 'The assistant isn’t set up on the server yet (its function hasn’t been deployed).',
        'unauthenticated' => 'Sign in again to use the assistant.',
        _ => e.message ?? 'The assistant ran into a problem (${e.code}).',
      };
    }
    return '$e'.replaceFirst('Exception: ', '');
  }

  Future<void> _save(String question) async {
    try {
      final ref = chatId == null ? ai.chatsRef.doc() : ai.chatsRef.doc(chatId);
      final now = Timestamp.now();
      await ref.set({
        if (chatId == null) 'title': question.length > 60 ? '${question.substring(0, 57)}…' : question,
        if (chatId == null) 'createdAt': now,
        'updatedAt': now,
        'provider': 'optimizer',
        'messages': [
          for (final l in lines) {'role': l.role, 'text': l.text},
        ],
      }, SetOptions(merge: true));
      chatId = ref.id;
    } catch (_) {
      // Saving the chat is a convenience; the answer is already on screen.
    }
  }

  @override
  void dispose() {
    pending?.answerWith(false);
    panelOpen.dispose();
    super.dispose();
  }
}

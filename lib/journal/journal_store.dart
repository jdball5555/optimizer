import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../config.dart';
import '../util/fields.dart';
import 'journal_crypto.dart';
import '../util/dispose_safe.dart';

String _ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

int countWords(String text) => text.trim().isEmpty ? 0 : text.trim().split(RegExp(r'\s+')).length;

/// Context added under an entry (or under other context) in Axis Journal.
class JournalNote {
  JournalNote(Map data, this.path)
      : header = '${data['header'] ?? ''}',
        body = JournalCrypto.decryptText('${data['content'] ?? ''}'),
        date = asDate(data['appearsAsDate']) ?? asDate(data['timestamp']),
        written = asDate(data['timestamp']),
        children = JournalNote.list(data['addedContext'] ?? data['replies'], path);

  final String header;
  final String body;
  final DateTime? date;
  final DateTime? written;
  final List<JournalNote> children;

  /// Where it sits: its index in the entry's context, then in its parent's, …
  final List<int> path;

  /// How deep it is (1 = right under the entry). Axis Journal allows two.
  int get depth => path.length;

  int get words => countWords(body) + children.fold(0, (n, c) => n + c.words);
  int get count => 1 + children.fold(0, (n, c) => n + c.count);

  static List<JournalNote> list(dynamic raw, [List<int> parent = const []]) => raw is List
      ? [
          for (var i = 0; i < raw.length; i++)
            if (raw[i] is Map) JournalNote(raw[i] as Map, [...parent, i]),
        ]
      : const [];
}

/// A deep copy of Firestore data, so context can be changed and written back
/// whole (Timestamps and the like are kept as they are).
dynamic _copy(dynamic v) => v is Map
    ? {for (final e in v.entries) '${e.key}': _copy(e.value)}
    : v is List
        ? [for (final x in v) _copy(x)]
        : v;

/// An Axis Journal entry. Like the Journal app, it has no title: it's known
/// by its date, with an optional italic header.
class JournalEntry {
  JournalEntry(this.doc)
      : data = doc.data() ?? const {},
        id = doc.id {
    bodyField = firstKey(data, AxisSchema.journalBodyFields) ?? AxisSchema.writeBody;
    dateField = firstKey(data, AxisSchema.dateFields);
  }

  final DocumentSnapshot<Map<String, dynamic>> doc;
  final Map<String, dynamic> data;
  final String id;
  late final String bodyField;
  late final String? dateField;

  String get header => '${data[AxisSchema.writeTitle] ?? ''}'.trim();
  late final String body = JournalCrypto.decryptText('${data[bodyField] ?? ''}');

  /// The start of the entry on one line, short enough to lay out instantly
  /// in a list (laying out a whole long entry per row is what made it lag).
  late final String preview = () {
    final head = body.length > 400 ? body.substring(0, 400) : body;
    return head.replaceAll(RegExp(r'\s+'), ' ').trim();
  }();

  /// Everything search looks at, lowercased once.
  late final String searchText = [body, header, ...people].join('\n').toLowerCase();
  late final DateTime? date = dateField == null ? null : asDate(data[dateField]);
  late final DateTime? written = asDate(data['timestamp']);
  late final List<JournalNote> context = JournalNote.list(data['addedContext'] ?? data['replies']);
  late final List<String> people = [
    for (final p in (data['referencedPeople'] as List? ?? const []))
      if (JournalCrypto.decryptText('$p').trim().isNotEmpty) JournalCrypto.decryptText('$p').trim(),
  ];
  late final int words = countWords(body) + context.fold(0, (n, c) => n + c.words);
  int get contextCount => context.fold(0, (n, c) => n + c.count);
}

/// The Axis Journal entries of one user, live from Firestore. Shared by the
/// Journal page and the dashboard.
class JournalStore extends ChangeNotifier with DisposeSafe {
  JournalStore(this.uid) {
    _sub = _col.where(AxisSchema.journalUserField, isEqualTo: uid).snapshots().listen((s) {
      entries = s.docs.map(JournalEntry.new).toList()
        ..sort((a, b) {
          final byDay = (b.date ?? DateTime(1970)).compareTo(a.date ?? DateTime(1970));
          return byDay != 0 ? byDay : (b.written ?? DateTime(1970)).compareTo(a.written ?? DateTime(1970));
        });
      loaded = true;
      error = null;
      notifyListeners();
    }, onError: (Object e) {
      error = e;
      notifyListeners();
    });
  }

  /// For previews and tests: fixed entries, no Firestore.
  @visibleForTesting
  JournalStore.withEntries(this.uid, this.entries) : loaded = true;

  final String uid;
  StreamSubscription? _sub;

  List<JournalEntry> entries = [];
  bool loaded = false;
  Object? error;

  CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection(AxisSchema.journalCollection);

  JournalEntry? byId(String? id) => entries.where((e) => e.id == id).firstOrNull;

  /// Saves a new entry in the same shape as Axis Journal's JournalEntry.toMap().
  Future<String> create({required String body, String header = '', DateTime? date}) async {
    final d = date ?? DateTime.now();
    final ref = await _col.add({
      AxisSchema.journalUserField: uid,
      if (header.trim().isNotEmpty) AxisSchema.writeTitle: header.trim(),
      AxisSchema.writeBody: JournalCrypto.encryptText(body),
      // When you wrote it, whatever date you've said it appears as.
      'timestamp': Timestamp.now(),
      'date': Timestamp.fromDate(d),
      'appearsAsDate': _ymd(d),
      'addedContext': [],
      'referencedPeople': [],
      'updatedAt': FieldValue.serverTimestamp(),
      'source': 'optimizer',
    });
    return ref.id;
  }

  /// Writes back into the fields this entry already uses, so Axis Journal
  /// keeps reading it the same way.
  Future<void> update(JournalEntry e, {required String body, required String header, required DateTime date}) {
    return _col.doc(e.id).update({
      AxisSchema.writeTitle: header.trim().isEmpty ? FieldValue.delete() : header.trim(),
      e.bodyField: JournalCrypto.encryptText(body),
      if (e.dateField != null && e.data[e.dateField] is Timestamp) e.dateField!: Timestamp.fromDate(date),
      if (e.dateField != null && e.data[e.dateField] is String) e.dateField!: _ymd(date),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> delete(String id) => _col.doc(id).delete();

  /// Who the entry references, encrypted as Axis Journal stores them.
  Future<void> setPeople(JournalEntry e, List<String> people) => _col.doc(e.id).update({
        'referencedPeople': [for (final p in people) JournalCrypto.encryptText(p)],
        'updatedAt': FieldValue.serverTimestamp(),
      });

  /// Everyone referenced anywhere in the journal, by how often.
  Map<String, int> get allPeople {
    final out = <String, int>{};
    final spelling = <String, String>{};
    for (final e in entries) {
      for (final p in e.people) {
        final key = spelling.putIfAbsent(p.toLowerCase(), () => p);
        out[key] = (out[key] ?? 0) + 1;
      }
    }
    return out;
  }

  /// Changes the entry's context tree with [change] and writes it back, in
  /// Axis Journal's shape (addedContext; each item encrypted).
  Future<void> _editContext(JournalEntry e, void Function(List items) change) {
    final items = (_copy(e.data['addedContext'] ?? e.data['replies'] ?? []) as List);
    change(items);
    return _col.doc(e.id).update({'addedContext': items, 'updatedAt': FieldValue.serverTimestamp()});
  }

  /// The list of children at [path] ([] is the entry's own context).
  static List _childrenAt(List items, List<int> path) {
    var list = items;
    for (final i in path) {
      final item = list[i] as Map;
      list = (item['addedContext'] ??= <dynamic>[]) as List;
    }
    return list;
  }

  /// Adds context under the entry ([under] = []) or under a piece of context.
  Future<void> addContext(JournalEntry e, {required List<int> under, required String body, String header = ''}) {
    final now = DateTime.now();
    return _editContext(e, (items) {
      _childrenAt(items, under).add({
        'id': _col.doc().id,
        'timestamp': Timestamp.fromDate(now),
        'date': Timestamp.fromDate(now),
        'appearsAsDate': _ymd(now),
        'content': JournalCrypto.encryptText(body),
        if (header.trim().isNotEmpty) 'header': header.trim(),
        'addedContext': [],
      });
    });
  }

  Future<void> editContext(JournalEntry e, JournalNote n, {required String body, required String header}) {
    return _editContext(e, (items) {
      final item = _childrenAt(items, n.path.sublist(0, n.path.length - 1))[n.path.last] as Map;
      item['content'] = JournalCrypto.encryptText(body);
      if (header.trim().isEmpty) {
        item.remove('header');
      } else {
        item['header'] = header.trim();
      }
    });
  }

  Future<void> deleteContext(JournalEntry e, JournalNote n) =>
      _editContext(e, (items) => _childrenAt(items, n.path.sublist(0, n.path.length - 1)).removeAt(n.path.last));

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

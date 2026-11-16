import 'dart:async';

import 'package:flutter/widgets.dart';

import 'journal_store.dart';

/// Saving an entry as you type, like Axis Journal: shared by the editor on
/// wide screens and the inline one in the phone's journal feed.
mixin EntryAutosave<T extends StatefulWidget> on State<T> {
  JournalStore get store;

  /// The entry being edited; null while writing a new one.
  JournalEntry? get entry;

  /// Called once a new entry has been saved for the first time.
  void onCreated(String id) {}

  /// Called when you've checked it off as done.
  void onFinished() {}

  /// Tells the page this is being written, so its top bar can swap to undo,
  /// redo and the check mark.
  ValueNotifier<EntryAutosave?>? get editingBar;

  /// Being written the whole time it's open, not only while a field has focus.
  bool get alwaysEditing => false;

  /// Opened in order to add or change the header.
  bool get startOnHeader => false;

  late final header = TextEditingController(text: entry?.header ?? '');
  late final body = TextEditingController(text: entry?.body ?? '');
  late DateTime date = entry?.date ?? DateTime.now();

  final headerUndo = UndoHistoryController();
  final bodyUndo = UndoHistoryController();
  final headerFocus = FocusNode();
  final bodyFocus = FocusNode();
  bool _inHeader = false;

  /// The header's line only shows once it has something, or you've asked to add one.
  late bool showHeader = startOnHeader || (entry?.header ?? '').isNotEmpty;

  /// What the undo and redo arrows work on: the field you were last in.
  UndoHistoryController get activeUndo => _inHeader ? headerUndo : bodyUndo;
  late final Listenable undoChanges = Listenable.merge([headerUndo, bodyUndo, headerFocus, bodyFocus]);

  @override
  void initState() {
    super.initState();
    _inHeader = startOnHeader;
    headerFocus.addListener(_focusChanged);
    bodyFocus.addListener(_focusChanged);
    if (alwaysEditing) WidgetsBinding.instance.addPostFrameCallback((_) => _focusChanged());
  }

  void _focusChanged() {
    if (!mounted) return;
    if (headerFocus.hasFocus) _inHeader = true;
    if (bodyFocus.hasFocus) _inHeader = false;
    final bar = editingBar;
    if (bar == null) return;
    if (alwaysEditing || headerFocus.hasFocus || bodyFocus.hasFocus) {
      bar.value = this;
    } else if (bar.value == this) {
      bar.value = null;
    }
  }

  /// Shows the header's line, ready to type in.
  void openHeader() {
    setState(() => showHeader = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) headerFocus.requestFocus();
    });
  }

  /// The check mark: everything's saved, and you're done typing.
  Future<void> finish() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await save();
    // Still there to try again, rather than closing on what wasn't saved.
    if (!mounted || saveError != null) return;
    if (header.text.trim().isEmpty) setState(() => showHeader = false);
    onFinished();
  }

  /// Nothing left to save: the entry's being deleted.
  void discard() {
    _debounce?.cancel();
    dirty = false;
  }

  Timer? _debounce;
  bool saving = false;
  bool dirty = false;
  int _rev = 0; // bumps on every keystroke, so edits made mid-save aren't lost
  String? saveError;
  String? createdId;

  String get saveStatus => saveError != null
      ? 'Couldn’t save'
      : saving
          ? 'Saving…'
          : dirty
              ? 'Editing'
              : (entry == null && createdId == null ? 'New entry' : 'Saved');

  @override
  void dispose() {
    // Runs synchronously up to its first await, so it reads the text before
    // the controllers below are disposed.
    if (dirty) save(closing: true);
    _debounce?.cancel();
    // After this frame's tidying up: nothing can rebuild during it.
    final bar = editingBar;
    if (bar != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (bar.value == this) bar.value = null;
      });
    }
    header.dispose();
    body.dispose();
    headerUndo.dispose();
    bodyUndo.dispose();
    headerFocus.dispose();
    bodyFocus.dispose();
    super.dispose();
  }

  void changed() {
    _rev++;
    setState(() => dirty = true);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 900), save);
  }

  Future<void> save({bool closing = false}) async {
    _debounce?.cancel();
    if (!dirty || (saving && !closing)) return;
    final e = entry ?? store.byId(createdId);
    // A new entry isn't created until there's something in it.
    if (e == null && createdId == null && body.text.trim().isEmpty && header.text.trim().isEmpty) return;
    if (!closing) setState(() => saving = true);
    final rev = _rev;
    try {
      if (e != null) {
        await store.update(e, body: body.text, header: header.text, date: date);
      } else if (createdId == null) {
        createdId = await store.create(body: body.text, header: header.text, date: date);
        if (!closing) onCreated(createdId!);
      }
      dirty = _rev != rev;
      saveError = null;
    } catch (err) {
      saveError = '$err';
    } finally {
      if (mounted) {
        setState(() => saving = false);
        if (dirty) _debounce = Timer(const Duration(milliseconds: 400), save);
      }
    }
  }
}

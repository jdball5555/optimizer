import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../config.dart';
import '../theme.dart';
import '../widgets/calm_scrollbar.dart';
import '../widgets/tiles.dart';
import 'entry_autosave.dart';
import 'habit_store.dart';
import 'habits_view.dart';
import 'journal_feed.dart';
import 'journal_store.dart';

final _grouped = NumberFormat.decimalPattern();

/// The Journal app's own date heading: "Monday, October 27, 2025".
String journalDate(DateTime? d) => d == null ? 'Undated' : DateFormat('EEEE, MMMM d, y').format(d);

/// Reads and writes the same entries as Axis Journal, laid out the same way:
/// no titles, each entry known by its date, with an optional italic header.
class JournalPage extends StatefulWidget {
  const JournalPage({super.key, required this.store, this.habits});

  final JournalStore store;

  /// Axis Journal's habits, on their own tab.
  final HabitStore? habits;

  @override
  State<JournalPage> createState() => _JournalPageState();
}

class _JournalPageState extends State<JournalPage> {
  JournalStore get store => widget.store;

  String? _selectedId; // null + _composing = new entry
  bool _composing = false;
  // Changes only when you open something else, so the editor keeps its focus
  // when a new entry gets its id.
  int _session = 0;
  String _query = '';
  // What's being written: while there is, the top bar has undo, redo and the
  // check mark instead of the tabs. Not disposed: the last editor lets go of it
  // after the page has gone.
  final _editing = ValueNotifier<EntryAutosave?>(null);
  // On a phone, search swaps the journal for the list of matching entries.
  bool _searching = false;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    store.addListener(_changed);
  }

  @override
  void dispose() {
    store.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _open(JournalEntry e) => setState(() {
        if (_selectedId != e.id) _session++;
        _selectedId = e.id;
        _composing = false;
      });

  void _new() => setState(() {
        _session++;
        _selectedId = null;
        _composing = true;
      });

  void _close() => setState(() {
        _session++;
        _selectedId = null;
        _composing = false;
      });

  Future<void> _delete(JournalEntry e) async {
    await store.delete(e.id);
    if (_selectedId == e.id) _close();
  }

  List<MenuAction> _actions(JournalEntry e) => [
        MenuAction(label: 'Open', icon: Icons.open_in_full, onSelected: () => _open(e)),
        MenuAction(label: 'Edit referenced people', icon: Icons.people_alt_outlined, onSelected: () => editReferencedPeople(context, store, e)),
        MenuAction(label: 'Add context', icon: Icons.reply, onSelected: () => editContext(context, store, e, under: const [])),
        MenuAction(
          label: 'Delete entry',
          icon: Icons.delete_outline,
          onSelected: () => _delete(e),
          confirm: (
            'Delete this entry?',
            e.contextCount > 0
                ? '${journalDate(e.date)} and the ${e.contextCount} pieces of context under it will be removed from your Axis Journal everywhere.'
                : '${journalDate(e.date)} will be removed from your Axis Journal everywhere.',
            'Delete',
          ),
        ),
      ];

  bool _showHabits = false;

  @override
  Widget build(BuildContext context) {
    final habits = widget.habits;
    final phone = MediaQuery.sizeOf(context).width < 820;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ValueListenableBuilder<EntryAutosave?>(
        valueListenable: _editing,
        builder: (context, writing, _) {
          if (habits == null && writing == null) return const SizedBox.shrink();
          // One on top of the other, so the page below doesn't jump as they swap.
          return IndexedStack(
            index: writing == null ? 0 : 1,
            sizing: StackFit.passthrough,
            children: [
              if (habits == null)
                const SizedBox.shrink()
              else
                PageTabsHeader<bool>(
                  items: const [(false, 'Journal'), (true, 'Habits')],
                  selected: _showHabits,
                  onSelected: (v) => setState(() => _showHabits = v),
                  actions: [
                    // On a phone the journal is one long page; search opens the list of matches.
                    if (phone && !_showHabits && !_searching)
                      IconButton(tooltip: 'Search entries', icon: const Icon(Icons.search), onPressed: () => setState(() => _searching = true)),
                  ],
                ),
              if (writing == null) const SizedBox.shrink() else _EditBar(editor: writing),
            ],
          );
        },
      ),
      Expanded(
        // Both stay built, so switching back keeps your place and anything typed.
        child: IndexedStack(index: _showHabits ? 1 : 0, children: [_journal(context), if (habits != null) HabitsView(store: habits)]),
      ),
    ]);
  }

  Widget _journal(BuildContext context) {
    if (store.error != null) {
      return _Message(
        icon: Icons.lock_outline,
        text: 'Couldn’t read ${AxisSchema.journalCollection}\n${store.error}\n\n'
            'Check the path in lib/config.dart and your Firestore rules.',
      );
    }
    if (!store.loaded) return const Center(child: CircularProgressIndicator());

    final all = store.entries;
    final q = _query.toLowerCase();
    final entries = q.isEmpty ? all : all.where((e) => e.searchText.contains(q)).toList();
    final editing = _composing || _selectedId != null;
    final selected = store.byId(_selectedId);

    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 820;
      final editor = _Editor(
        key: ValueKey(_session),
        store: store,
        entry: selected,
        editing: _editing,
        onBack: wide ? null : _close,
        onClose: _close,
        onCreated: (id) => setState(() {
          _selectedId = id;
          _composing = false;
        }),
        onDelete: selected == null ? null : () => _delete(selected),
      );

      if (!wide && editing) return Padding(padding: const EdgeInsets.all(12), child: editor);

      final list = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _toolbar(entries.length, all.length),
        const SizedBox(height: 10),
        Expanded(
          child: entries.isEmpty
              ? _Message(icon: Icons.menu_book_outlined, text: q.isEmpty ? 'No entries yet.' : 'Nothing matches “$_query”.')
              : _EntryList(
                  entries: entries,
                  controller: _scroll,
                  selectedId: _selectedId,
                  onOpen: _open,
                  actions: _actions,
                ),
        ),
      ]);

      if (!wide && !_searching) {
        return JournalFeed(store: store, entries: all, editing: _editing);
      }
      if (!wide) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 12, 0),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            IconButton(
              tooltip: 'Back to the journal',
              icon: const Icon(Icons.arrow_back),
              onPressed: () => setState(() {
                _searching = false;
                _query = '';
              }),
            ),
            Expanded(child: Padding(padding: const EdgeInsets.only(top: 4), child: list)),
          ]),
        );
      }
      // Entries down the left; the one you click opens on the right.
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(width: c.maxWidth >= 1200 ? 400 : 340, child: list),
          const SizedBox(width: 12),
          Expanded(
            child: editing
                ? editor
                : Tile(
                    child: Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.menu_book_outlined, size: 40, color: AppColors.secondaryText),
                        const SizedBox(height: 12),
                        const Text('Pick an entry to read it here.', style: TextStyle(color: AppColors.secondaryText)),
                        const SizedBox(height: 16),
                        OutlinedButton.icon(
                          onPressed: _new,
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          label: const Text("Write today's entry"),
                        ),
                      ]),
                    ),
                  ),
          ),
        ]),
      );
    });
  }

  Widget _toolbar(int showing, int total) {
    return Row(children: [
      Expanded(
        child: SizedBox(
          height: 42,
          child: TextField(
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: 'Search entries, headers, people',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(100)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(100),
                borderSide: const BorderSide(color: AppColors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(100),
                borderSide: const BorderSide(color: Color(0x80FFFFFF)),
              ),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
      ),
      const SizedBox(width: 10),
      Text(showing == total ? '${_grouped.format(total)} entries' : '$showing of $total',
          style: const TextStyle(color: AppColors.secondaryText, fontSize: 12)),
      const SizedBox(width: 10),
      FilledButton.icon(
        onPressed: _new,
        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
        icon: const Icon(Icons.edit_outlined, size: 18),
        label: const Text('Write'),
      ),
    ]);
  }
}

/// The entries, newest first, as rows of one fixed height: the list never
/// measures anything while scrolling, and the scrollbar can be dragged
/// straight to any month (a bubble shows which).
class _EntryList extends StatefulWidget {
  const _EntryList({
    required this.entries,
    required this.controller,
    required this.selectedId,
    required this.onOpen,
    required this.actions,
  });

  final List<JournalEntry> entries;
  final ScrollController controller;
  final String? selectedId;
  final void Function(JournalEntry) onOpen;
  final List<MenuAction> Function(JournalEntry) actions;

  static const rowHeight = 96.0;
  static const gap = 6.0;

  @override
  State<_EntryList> createState() => _EntryListState();
}

class _EntryListState extends State<_EntryList> {
  // Kept apart from the list so showing it never rebuilds the rows.
  final _bubble = ValueNotifier<({DateTime date, double fraction})?>(null);
  Timer? _hide;

  @override
  void dispose() {
    _hide?.cancel();
    _bubble.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    if (n is! ScrollUpdateNotification || n.metrics.maxScrollExtent <= 0) return false;
    // Only fast moves (a dragged thumb, a flick) show the month.
    if ((n.scrollDelta ?? 0).abs() < 40 && _bubble.value == null) return false;
    final i = (n.metrics.pixels / (_EntryList.rowHeight + _EntryList.gap)).floor().clamp(0, widget.entries.length - 1);
    final date = widget.entries[i].date;
    if (date != null) {
      _bubble.value = (date: date, fraction: (n.metrics.pixels / n.metrics.maxScrollExtent).clamp(0.0, 1.0));
    }
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 900), () => _bubble.value = null);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: RawScrollbar(
          controller: widget.controller,
          thumbVisibility: true,
          interactive: true,
          thickness: 8,
          minThumbLength: 48,
          radius: const Radius.circular(8),
          thumbColor: const Color(0x55FFFFFF),
          child: withoutAutoScrollbar(
              context,
              ListView.builder(
                controller: widget.controller,
                padding: const EdgeInsets.only(right: 14, bottom: 24),
                itemExtent: _EntryList.rowHeight + _EntryList.gap,
                itemCount: widget.entries.length,
                itemBuilder: (context, i) {
                  final e = widget.entries[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: _EntryList.gap),
                    child: _EntryRow(
                      key: ValueKey(e.id),
                      entry: e,
                      selected: e.id == widget.selectedId,
                      onTap: () => widget.onOpen(e),
                      actions: widget.actions(e),
                    ),
                  );
                },
              )),
        ),
      ),
      Positioned.fill(
        child: IgnorePointer(
          child: ValueListenableBuilder(
            valueListenable: _bubble,
            builder: (context, b, _) => b == null
                ? const SizedBox.shrink()
                : Align(
                    alignment: Alignment(1, -1 + b.fraction * 2),
                    child: Container(
                      margin: const EdgeInsets.only(right: 20),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.primaryText,
                        borderRadius: BorderRadius.circular(100),
                        boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 12)],
                      ),
                      child: Text(DateFormat('MMMM y').format(b.date),
                          style: const TextStyle(color: AppColors.background, fontWeight: FontWeight.w700, fontSize: 13)),
                    ),
                  ),
          ),
        ),
      ),
    ]);
  }
}

/// The people badge from Axis Journal: who an entry references.
class PeopleBadge extends StatelessWidget {
  const PeopleBadge({super.key, required this.people, this.date});

  final List<String> people;
  final DateTime? date;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: people.join(', '),
      child: InkWell(
        borderRadius: BorderRadius.circular(100),
        onTap: () => showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(people.length == 1 ? '1 person referenced' : '${people.length} people referenced'),
            content: SizedBox(
              width: 360,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (date != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(journalDate(date), style: const TextStyle(color: AppColors.secondaryText)),
                  ),
                for (final p in people)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(
                      radius: 16,
                      backgroundColor: AppColors.faint,
                      child: Icon(Icons.person_outline, size: 18, color: AppColors.primaryText),
                    ),
                    title: Text(p),
                  ),
                const SizedBox(height: 4),
                const Text('Edit who’s referenced in Axis Journal.', style: TextStyle(color: AppColors.secondaryText, fontSize: 12)),
              ]),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
          ),
        ),
        child: Container(
          // Axis Journal's badge, in white: a tinted pill with a soft edge.
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0x29FFFFFF),
            borderRadius: BorderRadius.circular(100),
            border: Border.all(color: const Color(0x59FFFFFF)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.people_alt_outlined, size: 13, color: AppColors.primaryText),
            const SizedBox(width: 4),
            Text('${people.length}', style: const TextStyle(color: AppColors.primaryText, fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

/// One entry in the list: its date (and who it mentions), then its header
/// or the start of what was written.
class _EntryRow extends StatelessWidget {
  const _EntryRow({super.key, required this.entry, required this.selected, required this.onTap, required this.actions});

  final JournalEntry entry;
  final bool selected;
  final VoidCallback onTap;
  final List<MenuAction> actions;

  @override
  Widget build(BuildContext context) {
    final preview = entry.preview;
    return HoverMenu(
      top: 6,
      right: 6,
      actions: actions,
      child: Material(
        color: selected ? AppColors.surfaceHigh : AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: selected ? const Color(0x66FFFFFF) : AppColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.only(right: 30),
                child: Row(children: [
                  Flexible(
                    child: Text(journalDate(entry.date),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.primaryText, fontSize: 14, fontWeight: FontWeight.w700)),
                  ),
                  if (entry.people.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    PeopleBadge(people: entry.people, date: entry.date),
                  ],
                ]),
              ),
              const SizedBox(height: 4),
              if (entry.header.isNotEmpty)
                Text(entry.header,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.secondaryText, fontSize: 13, fontStyle: FontStyle.italic, fontWeight: FontWeight.w600)),
              Text(
                preview.isEmpty ? 'Nothing written yet.' : preview,
                maxLines: entry.header.isEmpty ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: preview.isEmpty ? AppColors.secondaryText : const Color(0xBFFFFFFF),
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// While writing: undo and redo at the left, as in Axis Journal, and the check
/// mark at the right, in place of the page's tabs.
class _EditBar extends StatelessWidget {
  const _EditBar({required this.editor});

  final EntryAutosave editor;

  @override
  Widget build(BuildContext context) {
    final end = PageEnd.of(context);
    // No taller than the tabs it stands in for.
    Widget button(String tip, IconData icon, VoidCallback? onPressed) => IconButton(
          tooltip: tip,
          constraints: const BoxConstraints.tightFor(width: 40, height: 34),
          padding: EdgeInsets.zero,
          iconSize: 22,
          icon: Icon(icon),
          onPressed: onPressed,
        );
    // Clicking these isn't clicking away from what you're typing.
    return TextFieldTapRegion(
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, PageSpace.top(context) - 4, 8, 0),
        child: ListenableBuilder(
          listenable: editor.undoChanges,
          builder: (context, _) {
            final undo = editor.activeUndo;
            return ValueListenableBuilder<UndoHistoryValue>(
              valueListenable: undo,
              builder: (context, can, _) => Row(children: [
                button('Undo', Icons.undo, can.canUndo ? undo.undo : null),
                button('Redo', Icons.redo, can.canRedo ? undo.redo : null),
                const Spacer(),
                button('Done', Icons.check, editor.finish),
                if (end != null) end,
              ]),
            );
          },
        ),
      ),
    );
  }
}

/// Writing or reading one entry. Saves itself as you type, like Axis Journal.
/// Hold down the date, or use ⋯, for its header, its date and the rest.
class _Editor extends StatefulWidget {
  const _Editor({
    super.key,
    required this.store,
    required this.entry,
    required this.editing,
    required this.onBack,
    required this.onClose,
    required this.onCreated,
    required this.onDelete,
  });

  final JournalStore store;
  final JournalEntry? entry;
  final ValueNotifier<EntryAutosave?> editing;
  final VoidCallback? onBack;
  final VoidCallback onClose;
  final void Function(String id) onCreated;
  final VoidCallback? onDelete;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> with EntryAutosave<_Editor> {
  @override
  JournalStore get store => widget.store;
  @override
  JournalEntry? get entry => widget.entry;
  @override
  void onCreated(String id) => widget.onCreated(id);
  @override
  ValueNotifier<EntryAutosave?> get editingBar => widget.editing;

  @override
  void onFinished() {
    // A narrow window shows one thing at a time, and a new entry with nothing
    // in it has nothing to stay open for. Otherwise it stays there to read.
    if (widget.onBack != null) {
      widget.onBack!();
    } else if (widget.entry == null && createdId == null) {
      widget.onClose();
    }
  }

  bool _pastConfirmed = false;

  /// Same guard as Axis Journal: past entries ask first.
  bool get _askFirst {
    final e = widget.entry;
    return !_pastConfirmed && e != null && isPastEntry(e);
  }

  Future<bool> _confirmPast() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final ok = await confirmAction(context, title: 'Edit past entry', message: 'Are you sure you want to edit this past entry?', action: 'Edit');
    if (ok && mounted) setState(() => _pastConfirmed = true);
    return ok && mounted;
  }

  Future<void> _tappedPast(FocusNode field) async {
    if (await _confirmPast()) field.requestFocus();
  }

  void _menu() => showEntryMenu(
        context,
        store,
        entry: widget.entry,
        date: date,
        hasHeader: header.text.trim().isNotEmpty,
        onDate: (d) {
          date = d;
          changed();
        },
        onHeader: () async {
          if (!_askFirst || await _confirmPast()) openHeader();
        },
        onDelete: widget.onDelete == null
            ? null
            : () {
                discard();
                widget.onDelete!();
              },
      );

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final words = countWords(body.text);
    final status = saveStatus;
    final ask = _askFirst;
    const plain = InputDecoration(
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      filled: false,
      isDense: true,
      contentPadding: EdgeInsets.zero,
    );

    return Tile(
      padding: const EdgeInsets.fromLTRB(22, 14, 14, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          if (widget.onBack != null) IconButton(tooltip: 'All entries', icon: const Icon(Icons.arrow_back), onPressed: widget.onBack),
          Flexible(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              // Held, as in Axis Journal; with a mouse, a click or right-click does too.
              onTap: _menu,
              onLongPress: _menu,
              onSecondaryTap: _menu,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(journalDate(date),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.primaryText, fontSize: 20, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
          if (entry != null && entry.people.isNotEmpty) ...[
            const SizedBox(width: 8),
            PeopleBadge(people: entry.people, date: entry.date),
          ],
          const Spacer(),
          Text('$words words · $status', style: TextStyle(color: saveError != null ? AppColors.danger : AppColors.secondaryText, fontSize: 12)),
          IconButton(tooltip: 'More', icon: const Icon(Icons.more_horiz), onPressed: _menu),
        ]),
        if (showHeader)
          TextField(
            controller: header,
            focusNode: headerFocus,
            undoController: headerUndo,
            readOnly: ask,
            showCursor: !ask,
            onTap: ask ? () => _tappedPast(headerFocus) : null,
            style: const TextStyle(color: AppColors.secondaryText, fontSize: 17, fontStyle: FontStyle.italic, fontWeight: FontWeight.w600),
            decoration: plain.copyWith(hintText: 'Type header…', hintStyle: const TextStyle(color: Color(0x4DFFFFFF))),
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => changed(),
          ),
        const SizedBox(height: 12),
        Expanded(
          child: TextField(
            controller: body,
            focusNode: bodyFocus,
            undoController: bodyUndo,
            readOnly: ask,
            showCursor: !ask,
            onTap: ask ? () => _tappedPast(bodyFocus) : null,
            autofocus: entry == null,
            expands: true,
            maxLines: null,
            textAlignVertical: TextAlignVertical.top,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(color: Color(0xD9FFFFFF), fontSize: 16, height: 1.65),
            decoration: plain.copyWith(hintText: 'Start writing…', hintStyle: const TextStyle(color: Color(0x4DFFFFFF))),
            onChanged: (_) => changed(),
          ),
        ),
        if (entry != null && entry.context.isNotEmpty) ...[
          const Divider(height: 24),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const StatLabel('Added context · edit it in Axis Journal'),
                const SizedBox(height: 8),
                for (final n in entry.context) _ContextNote(note: n, depth: 0),
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}

class _ContextNote extends StatelessWidget {
  const _ContextNote({required this.note, required this.depth});

  final JournalNote note;
  final int depth;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: depth * 18.0, bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(
          padding: EdgeInsets.only(right: 6, top: 1),
          child: Icon(Icons.subdirectory_arrow_right, size: 16, color: AppColors.secondaryText),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (note.date != null)
              Text(journalDate(note.date), style: const TextStyle(color: AppColors.secondaryText, fontSize: 12, fontWeight: FontWeight.w700)),
            if (note.header.isNotEmpty)
              Text(note.header, style: const TextStyle(color: AppColors.secondaryText, fontSize: 12.5, fontStyle: FontStyle.italic)),
            SelectableText(note.body, style: const TextStyle(color: AppColors.primaryText, fontSize: 14, height: 1.5)),
            for (final c in note.children) _ContextNote(note: c, depth: 1),
          ]),
        ),
      ]),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 40, color: AppColors.secondaryText),
          const SizedBox(height: 12),
          SelectableText(text, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.secondaryText)),
        ]),
      ),
    );
  }
}

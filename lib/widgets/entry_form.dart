import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme.dart';
import 'address_field.dart';
import 'tiles.dart';

/// Any entry's editing page, for the calendar and for trips alike: the form on
/// the left, ending in Save; the map, its places and the people on the right.
/// On a phone they stack, and Save stays in reach at the bottom of the screen.
class EntryForm extends StatelessWidget {
  const EntryForm({
    super.key,
    required this.title,
    required this.onSave,
    required this.saving,
    required this.children,
    this.saveLabel = 'Save',
    this.onDelete,
    this.deleteLabel,
    this.error,
    this.location,
    this.people,
    this.mapAt = 0,
    this.unsaved = false,
  });

  final String title;
  final VoidCallback onSave;
  final bool saving;
  final String saveLabel;
  final List<Widget> children;
  final VoidCallback? onDelete;
  final String? deleteLabel;
  final String? error;

  /// The address, or a drive's addresses, for under the map.
  final Widget? location;

  /// Who can see it, for under that.
  final Widget? people;

  /// Where among [children] the map goes when it isn't beside them.
  final int mapAt;

  /// Something's been changed: leaving asks first.
  final bool unsaved;

  /// Below this, Save stays at the bottom of the screen.
  static const _phone = 720.0;

  Widget get _saveButton => FilledButton(
        onPressed: saving ? null : onSave,
        style: FilledButton.styleFrom(minimumSize: const Size(148, 46)),
        child: saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Text(saveLabel),
      );

  Widget get _deleteButton => TextButton.icon(
        style: TextButton.styleFrom(foregroundColor: AppColors.danger),
        onPressed: saving ? null : onDelete,
        icon: const Icon(Icons.delete_outline, size: 18),
        label: Text(deleteLabel ?? 'Delete'),
      );

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final phone = width < _phone, beside = width >= FormWithMap.beside;
    final page = Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: 'Back', icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.maybePop(context)),
        title: Text(title),
      ),
      bottomNavigationBar: !phone
          ? null
          : SafeArea(
              child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 10), child: _saveButton),
            ),
      body: FormWithMap(
        location: location,
        // Beside the form, they go under the place. With less room, after the
        // form, so what you came to change isn't pushed off the screen.
        people: beside ? people : null,
        builder: (context, below) => ListView(padding: EdgeInsets.fromLTRB(phone ? 16 : 24, 8, phone ? 16 : 24, 32), children: [
          ...children.take(mapAt),
          if (below != null) below,
          ...children.skip(mapAt),
          if (!beside && people != null) ...[
            const SizedBox(height: 20),
            people!,
          ],
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(error!, style: const TextStyle(color: AppColors.danger)),
          ],
          const SizedBox(height: 18),
          if (phone)
            if (onDelete != null) Align(alignment: Alignment.centerLeft, child: _deleteButton) else const SizedBox.shrink()
          else
            Row(children: [
              _saveButton,
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => Navigator.maybePop(context),
                style: TextButton.styleFrom(foregroundColor: AppColors.secondaryText),
                child: const Text('Cancel'),
              ),
              const Spacer(),
              if (onDelete != null) _deleteButton,
            ]),
        ]),
      ),
    );
    return PopScope(
      canPop: !unsaved,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await confirmAction(context,
            title: 'Discard your changes?', message: 'You haven’t saved them, so they’ll be lost.', action: 'Discard', cancel: 'Keep editing');
        if (leave && context.mounted) Navigator.pop(context);
      },
      child: page,
    );
  }
}

/// An entry's name, with its type or calendar beside it. Stacked on a phone.
class EntryTitleRow extends StatelessWidget {
  const EntryTitleRow({super.key, required this.title, required this.side, this.sideIsLabel = false});

  final Widget title;
  final Widget side;

  /// [side] is just a few words, which fit beside the name even on a phone.
  final bool sideIsLabel;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        if (sideIsLabel) return Row(children: [Expanded(child: title), const SizedBox(width: 14), side, const SizedBox(width: 4)]);
        return c.maxWidth < 460
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [title, const SizedBox(height: 12), side])
            : Row(children: [Expanded(child: title), const SizedBox(width: 12), SizedBox(width: c.maxWidth < 620 ? 180 : 230, child: side)]);
      });
}

/// When something happens, like a Google Calendar entry: all on one row, with
/// one time zone. Without [showEnd], just the start.
class TimeRange extends StatelessWidget {
  const TimeRange({
    super.key,
    required this.start,
    required this.end,
    required this.onStartDate,
    required this.onStartTime,
    required this.onEndDate,
    required this.onEndTime,
    this.allDay = false,
    this.showEnd = true,
    this.startLabel,
    this.endLabel,
    this.zone,
  });

  final DateTime start;
  final DateTime end;
  final VoidCallback onStartDate;
  final VoidCallback onStartTime;
  final VoidCallback onEndDate;
  final VoidCallback onEndTime;
  final bool allDay;
  final bool showEnd;

  /// To say what each end is, like Check in and Check out.
  final String? startLabel;
  final String? endLabel;

  /// Which time zone these are in: right after the last time.
  final Widget? zone;

  static final _time = DateFormat.jm();

  /// Below this, the end goes on a row of its own.
  static const _oneRow = 760.0;

  /// Below this, buttons tighten up and a date leaves off this year.
  static const _compact = 460.0;

  Widget _label(String s) => Text(s, style: const TextStyle(color: AppColors.secondaryText, fontSize: 13));

  Widget _button(VoidCallback onPressed, String text, bool small) => OutlinedButton(
        onPressed: onPressed,
        style: small ? OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 13)) : null,
        child: Text(text),
      );

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final small = c.maxWidth < _compact;
        // No year on a phone, unless it isn't this year.
        final date = small && start.year == DateTime.now().year ? DateFormat('EEE, MMM d') : DateFormat('EEE, MMM d, y');
        final first = [
          if (startLabel != null) _label(startLabel!),
          _button(onStartDate, date.format(start), small),
          if (!allDay) _button(onStartTime, _time.format(start), small),
        ];
        final second = [
          if (showEnd) ...[
            _label(endLabel ?? 'to'),
            // With a label on each end, both read date then time. Otherwise
            // it's like Google Calendar's: 9 AM to 10 AM, then the end's date.
            if (endLabel != null) _button(onEndDate, date.format(end), small),
            if (!allDay) _button(onEndTime, _time.format(end), small),
            if (endLabel == null) _button(onEndDate, date.format(end), small),
          ],
          if (zone != null) zone!,
        ];
        Widget row(List<Widget> children) =>
            Wrap(spacing: small ? 6 : 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: children);
        if (c.maxWidth >= _oneRow) return row([...first, ...second]);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (showEnd) ...[row(first), const SizedBox(height: 8), row(second)] else row([...first, ...second]),
        ]);
      });
}

/// A small checkbox and its label, for the row under the times.
class TimeOption extends StatelessWidget {
  const TimeOption({super.key, required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.only(right: 10),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Checkbox(value: value, onChanged: (v) => onChanged(v ?? false), visualDensity: VisualDensity.compact),
            Text(label, style: const TextStyle(fontSize: 13.5)),
          ]),
        ),
      );
}

/// An entry's details when reading it, for the calendar and for trips alike:
/// the map on the right with its place and the people under it. On a phone the
/// map comes first, with the details below.
class EntryDetailsLayout extends StatelessWidget {
  const EntryDetailsLayout({super.key, required this.location, required this.details, this.people});

  final String location;
  final Widget details;
  final Widget? people;

  @override
  Widget build(BuildContext context) {
    final hasPlace = location.isNotEmpty;
    if (!hasPlace && people == null) return ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: details);
    final side = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (hasPlace) ...[
        PlaceMap(to: location, height: 200),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(padding: EdgeInsets.only(top: 1), child: Icon(Icons.place_outlined, size: 18, color: AppColors.secondaryText)),
          const SizedBox(width: 6),
          Expanded(child: SelectableText(location)),
        ]),
      ],
      if (people != null) ...[
        if (hasPlace) const SizedBox(height: 16),
        people!,
      ],
    ]);
    final width = MediaQuery.sizeOf(context).width;
    if (width >= 760) {
      return SizedBox(
        width: width >= 1000 ? 800 : 660,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: details),
          const SizedBox(width: 24),
          SizedBox(width: width >= 1000 ? 320 : 260, child: side),
        ]),
      );
    }
    return SizedBox(
      width: width - 128 > 420 ? 420 : width - 128,
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [side, const SizedBox(height: 12), details]),
    );
  }
}

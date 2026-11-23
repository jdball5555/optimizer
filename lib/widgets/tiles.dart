import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Building blocks shared by the Journal and Net worth pages, after the
/// stat cards in Axis Journal and Asset Track — in black and white only.

/// Where every page's title sits, and how far its page starts below it. All
/// the pages use these, so their titles line up as you move between them.
class PageSpace {
  static bool _roomy(BuildContext c) => MediaQuery.sizeOf(c).width >= 720;

  /// From the top of the page to its title. (A phone's app also has the status bar above.)
  static double top(BuildContext c) => _roomy(c) ? 32 : 18;

  /// From the title to where the page starts.
  static double gap(BuildContext c) => _roomy(c) ? 28 : 20;
}

/// What goes last in every page's top row: room for the assistant's arrow,
/// which floats in the corner over it. There's none on a page outside the app.
class PageEnd extends InheritedWidget {
  const PageEnd({super.key, required this.end, required super.child});

  final Widget? end;

  static Widget? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PageEnd>()?.end;

  @override
  bool updateShouldNotify(PageEnd old) => !identical(old.end, end);
}

/// On a small screen, how a page's ☰ opens the side bar over the app;
/// none on the website, where the side bar is always there.
class PageMenu extends InheritedWidget {
  const PageMenu({super.key, required this.open, required super.child});

  final VoidCallback? open;

  static VoidCallback? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PageMenu>()?.open;

  @override
  bool updateShouldNotify(PageMenu old) => !identical(old.open, open);
}

/// What goes first in every page's top row on a small screen: the ☰, its
/// lines lined up with the page's left edge, as tall as the title. Nothing
/// where there's no [PageMenu].
class PageMenuButton extends StatelessWidget {
  const PageMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    final open = PageMenu.of(context);
    if (open == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Transform.translate(
        offset: const Offset(-6, 0),
        child: IconButton(
          tooltip: 'Menu',
          constraints: const BoxConstraints.tightFor(width: 36, height: 34),
          padding: EdgeInsets.zero,
          // Just its box: the padded tap target would push the title over.
          style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          icon: const Icon(Icons.menu),
          onPressed: open,
        ),
      ),
    );
  }
}

/// A page's title.
TextStyle pageTitleStyle(BuildContext c) => TextStyle(
      color: AppColors.primaryText,
      fontSize: MediaQuery.sizeOf(c).width >= 720 ? 32 : 28,
      fontWeight: FontWeight.w800,
      height: 1.1,
      letterSpacing: -0.8,
    );

/// A page's title, with whatever actions go beside it.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.actions = const []});

  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final end = PageEnd.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageMenuButton(),
        Expanded(child: Text(title, style: pageTitleStyle(context))),
        for (final a in actions) ...[const SizedBox(width: 8), a],
        // These titles are in a column down the middle: on a wide enough
        // window the corner's already clear of it, and the room would only
        // push their buttons out of line with what's below.
        if (end != null && MediaQuery.sizeOf(context).width < 1130) ...[const SizedBox(width: 8), end],
      ],
    );
  }
}

/// Section title with a leading icon, like the headers on the Journal home page.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.icon, required this.title, this.subtitle, this.trailing});

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(color: AppColors.faint, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: AppColors.primaryText, size: 16),
          ),
          const SizedBox(width: 10),
          Text(title, style: const TextStyle(color: AppColors.primaryText, fontSize: 18, fontWeight: FontWeight.w700)),
          if (subtitle != null) ...[
            const SizedBox(width: 10),
            Expanded(
              child:
                  Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.secondaryText, fontSize: 13)),
            ),
          ] else
            const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// A rounded panel on the blue-gray surface.
class Tile extends StatelessWidget {
  const Tile({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.onTap, this.raised = false});

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final bool raised;

  @override
  Widget build(BuildContext context) {
    final box = Ink(
      decoration: tileDecoration(raised: raised),
      child: Padding(padding: padding, child: child),
    );
    return Material(
      type: MaterialType.transparency,
      child: onTap == null ? box : InkWell(borderRadius: BorderRadius.circular(18), onTap: onTap, child: box),
    );
  }
}

/// Quiet label above or below a number.
class StatLabel extends StatelessWidget {
  const StatLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppColors.secondaryText, fontSize: 12, fontWeight: FontWeight.w500),
      );
}

/// Rounded chip with an icon, for streaks and the like.
class Pill extends StatelessWidget {
  const Pill({super.key, required this.text, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: AppColors.faint, borderRadius: BorderRadius.circular(100)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 14, color: AppColors.primaryText), const SizedBox(width: 6)],
        Text(text, style: const TextStyle(color: AppColors.primaryText, fontSize: 12, fontWeight: FontWeight.w500)),
      ]),
    );
  }
}

/// The small chart at the foot of a [StatTile].
sealed class TileChart {
  const TileChart();
}

class TileBars extends TileChart {
  const TileBars(this.values);
  final List<num> values;
}

class TileLine extends TileChart {
  const TileLine(this.values);
  final List<num> values;
}

class TileDots extends TileChart {
  const TileDots(this.days);
  final List<bool> days;
}

class TileMeter extends TileChart {
  const TileMeter(this.fraction);
  final double fraction;
}

/// A fixed-height tile: label, headline value, a note and a small chart, so
/// a grid of them lines up.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.unit,
    this.note,
    this.chart,
    this.onTap,
  });

  static const height = 156.0;

  final IconData icon;
  final String label;
  final String value;
  final String? unit;
  final String? note;
  final TileChart? chart;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Tile(
        onTap: onTap,
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(icon, size: 15, color: AppColors.secondaryText),
              const SizedBox(width: 6),
              Expanded(child: StatLabel(label)),
              if (onTap != null) const Icon(Icons.chevron_right, size: 16, color: AppColors.secondaryText),
            ]),
            const SizedBox(height: 10),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text.rich(
                TextSpan(text: value, children: [
                  if (unit != null)
                    TextSpan(
                      text: ' $unit',
                      style: const TextStyle(color: AppColors.secondaryText, fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                ]),
                maxLines: 1,
                style: const TextStyle(
                  color: AppColors.primaryText,
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                  letterSpacing: -0.3,
                ),
              ),
            ),
            if (note != null && note!.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(note!,
                  maxLines: chart == null ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.secondaryText, fontSize: 12)),
            ],
            const SizedBox(height: 8),
            Expanded(
              child: chart == null ? const SizedBox.shrink() : Align(alignment: Alignment.bottomCenter, child: _ChartView(chart!)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lays tiles out in as many columns as fit (at least [minTileWidth] wide each).
class TileGrid extends StatelessWidget {
  const TileGrid({super.key, required this.tiles, this.minTileWidth = 200, this.maxColumns = 4});

  final List<Widget> tiles;
  final double minTileWidth;
  final int maxColumns;

  @override
  Widget build(BuildContext context) {
    const gap = 12.0;
    return LayoutBuilder(builder: (context, c) {
      final cols = ((c.maxWidth + gap) / (minTileWidth + gap)).floor().clamp(1, maxColumns);
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final t in tiles) SizedBox(width: w, child: t)],
      );
    });
  }
}

class _ChartView extends StatelessWidget {
  const _ChartView(this.chart);

  final TileChart chart;

  @override
  Widget build(BuildContext context) {
    return switch (chart) {
      TileBars(:final values) => SizedBox(height: 34, width: double.infinity, child: CustomPaint(painter: _BarsPainter(values))),
      TileLine(:final values) => SizedBox(height: 34, width: double.infinity, child: CustomPaint(painter: _LinePainter(values))),
      TileDots(:final days) => SizedBox(height: 12, width: double.infinity, child: CustomPaint(painter: _DotsPainter(days))),
      TileMeter(:final fraction) => ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: fraction.clamp(0.0, 1.0),
            minHeight: 8,
            backgroundColor: AppColors.faint,
            color: AppColors.primaryText,
          ),
        ),
    };
  }
}

// The latest bar or dot is white; the rest are dimmed.
const _dim = Color(0x59FFFFFF);

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.values);

  final List<num> values;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final hi = values.fold<num>(0, math.max).toDouble();
    const gap = 3.0;
    final w = (size.width - gap * (values.length - 1)) / values.length;
    for (var i = 0; i < values.length; i++) {
      final h = hi <= 0 ? 0.0 : values[i] / hi * size.height;
      final r = Rect.fromLTWH(i * (w + gap), size.height - math.max(2.0, h), w, math.max(2.0, h));
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(2)),
          Paint()..color = i == values.length - 1 ? AppColors.primaryText : (values[i] > 0 ? _dim : AppColors.faint));
    }
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) => old.values != values;
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.values);

  final List<num> values;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    // Via doubles: reduce(math.min) throws on a List<double> typed as List<num>.
    final lo = values.map((v) => v.toDouble()).reduce(math.min);
    var hi = values.map((v) => v.toDouble()).reduce(math.max);
    if (hi == lo) hi = lo + 1;
    Offset at(int i) => Offset(
          i / (values.length - 1) * size.width,
          size.height - 2 - (values[i] - lo) / (hi - lo) * (size.height - 4),
        );
    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < values.length; i++) {
      path.lineTo(at(i).dx, at(i).dy);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = _dim
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round);
    canvas.drawCircle(at(values.length - 1), 3, Paint()..color = AppColors.primaryText);
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) => old.values != values;
}

class _DotsPainter extends CustomPainter {
  _DotsPainter(this.days);

  final List<bool> days;

  @override
  void paint(Canvas canvas, Size size) {
    if (days.isEmpty) return;
    final step = size.width / days.length;
    final r = math.min(size.height / 2, step / 2 - 1.5);
    for (var i = 0; i < days.length; i++) {
      canvas.drawCircle(
        Offset(step * i + step / 2, size.height / 2),
        r,
        Paint()..color = days[i] ? (i == days.length - 1 ? AppColors.primaryText : _dim) : AppColors.faint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DotsPainter old) => old.days != days;
}

/// One item in a [HoverMenu].
class MenuAction {
  const MenuAction({required this.label, required this.icon, required this.onSelected, this.confirm});

  final String label;
  final IconData icon;
  final VoidCallback onSelected;

  /// Destructive actions ask first: (title, message, button label).
  final (String, String, String)? confirm;
}

/// Asks before something that can't be undone. Resolves true only on yes.
Future<bool> confirmAction(BuildContext context,
    {required String title, required String message, String action = 'Delete', String cancel = 'Cancel'}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message, style: const TextStyle(color: AppColors.secondaryText)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(cancel)),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Wraps [child] with a ⋯ button that only appears while the pointer is over
/// it (or after a long press on touch screens), so nothing destructive sits
/// one click away.
class HoverMenu extends StatefulWidget {
  const HoverMenu({super.key, required this.child, required this.actions, this.top = 6, this.right = 6, this.bare = false});

  final Widget child;
  final List<MenuAction> actions;
  final double top;
  final double right;

  /// Just the dots, level with the middle of a row, with nothing around them.
  final bool bare;

  @override
  State<HoverMenu> createState() => _HoverMenuState();
}

class _HoverMenuState extends State<HoverMenu> {
  bool _hover = false;
  bool _open = false;
  final _button = GlobalKey<PopupMenuButtonState<int>>();

  Future<void> _run(MenuAction a) async {
    final c = a.confirm;
    if (c != null && !await confirmAction(context, title: c.$1, message: c.$2, action: c.$3)) return;
    a.onSelected();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _hover || _open;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onLongPress: () => _button.currentState?.showButtonMenu(),
        child: Stack(children: [
          widget.child,
          Positioned(
            top: widget.bare ? 0 : widget.top,
            bottom: widget.bare ? 0 : null,
            right: widget.right,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: IgnorePointer(
                ignoring: !visible,
                child: Material(
                  color: widget.bare ? Colors.transparent : AppColors.surfaceHigh,
                  shape: widget.bare ? null : const CircleBorder(side: BorderSide(color: AppColors.border)),
                  child: PopupMenuButton<int>(
                    key: _button,
                    tooltip: 'More',
                    iconSize: widget.bare ? null : 18,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 160),
                    icon: widget.bare ? null : const Icon(Icons.more_horiz, color: AppColors.primaryText),
                    onOpened: () => setState(() => _open = true),
                    onCanceled: () => setState(() => _open = false),
                    onSelected: (i) {
                      setState(() => _open = false);
                      _run(widget.actions[i]);
                    },
                    itemBuilder: (_) => [
                      for (var i = 0; i < widget.actions.length; i++)
                        PopupMenuItem(
                          value: i,
                          child: Row(children: [
                            Icon(widget.actions[i].icon,
                                size: 18, color: widget.actions[i].confirm != null ? AppColors.danger : AppColors.primaryText),
                            const SizedBox(width: 10),
                            Text(widget.actions[i].label,
                                style: TextStyle(color: widget.actions[i].confirm != null ? AppColors.danger : AppColors.primaryText)),
                          ]),
                        ),
                    ],
                    child: !widget.bare
                        ? null
                        : const SizedBox(
                            width: 28,
                            child: Center(child: Icon(Icons.more_horiz, size: 18, color: AppColors.primaryText)),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// A row of pill buttons, one selected — the app's own tab/segment control.
class PillTabs<T> extends StatelessWidget {
  const PillTabs({super.key, required this.items, required this.selected, required this.onSelected, this.dense = false});

  final List<(T, String)> items;
  final T selected;
  final ValueChanged<T> onSelected;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final (value, label) in items)
          GestureDetector(
            onTap: () => onSelected(value),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: EdgeInsets.symmetric(horizontal: dense ? 10 : 14, vertical: dense ? 5 : 7),
                decoration: BoxDecoration(
                  color: value == selected ? AppColors.primaryText : Colors.transparent,
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text(label,
                    style: TextStyle(
                      color: value == selected ? AppColors.background : AppColors.secondaryText,
                      fontSize: dense ? 12 : 13,
                      fontWeight: FontWeight.w600,
                    )),
              ),
            ),
          ),
      ]),
    );
  }
}

/// A bare sparkline, for places other than a [StatTile].
class TileLineChart extends StatelessWidget {
  const TileLineChart({super.key, required this.values});

  final List<num> values;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.infinite, painter: _LinePainter(values));
}

/// The top of a page that has views of its own (Journal · Habits, Overview ·
/// Spending · …): the views as large words, the chosen one bright, with the
/// page's buttons on the same line at the right.
const _tabPad = 4.0;

class PageTabsHeader<T> extends StatelessWidget {
  const PageTabsHeader({super.key, required this.items, required this.selected, required this.onSelected, this.actions = const []});

  final List<(T, String)> items;
  final T selected;
  final ValueChanged<T> onSelected;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final end = PageEnd.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, PageSpace.top(context) - _tabPad, 8, PageSpace.gap(context) - _tabPad * 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(padding: EdgeInsets.only(top: _tabPad), child: PageMenuButton()),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final (value, label) in items)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelected(value),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 18, top: _tabPad, bottom: _tabPad),
                      // A plain Text style merges with the app's font; an animated
                      // default style would replace it.
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.4,
                          color: value == selected ? AppColors.primaryText : const Color(0x59FFFFFF),
                        ),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ),
        ...actions,
        if (end != null) end,
      ]),
    );
  }
}

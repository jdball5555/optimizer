import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_version.dart';
import '../theme.dart';
import '../widgets/calm_scrollbar.dart';
import '../widgets/logo.dart';

/// What's inside a bubble when the bar is folded: the bar less its 1 edge, the
/// bubble's 10 margins and its own 1 border. Things in a bubble are placed by
/// this, so they sit dead center of it when folded and don't move when open.
const _foldedInside = SideNav.collapsedWidth - 1 - 20 - 2;

/// One page in the side bar.
typedef SideNavItem = ({IconData icon, IconData selected, String label});

/// The website's side bar, laid out like Axis Team's: the logo with
/// "Optimizer" beside it, the pages, your account, and at the bottom the
/// version and an arrow, one big button that folds it down to just icons (the
/// words fade out). Softer than Team's: every page sits in a rounded bubble that lights
/// up under the mouse.
class SideNav extends StatefulWidget {
  const SideNav({super.key, required this.items, required this.selected, required this.onSelected, required this.account});

  final List<SideNavItem> items;
  final int selected;
  final ValueChanged<int> onSelected;

  /// Your picture and name, given whether the bar is open.
  final Widget Function(bool expanded) account;

  static const expandedWidth = 232.0;
  static const collapsedWidth = 72.0;

  @override
  State<SideNav> createState() => _SideNavState();
}

class _SideNavState extends State<SideNav> {
  static const _key = 'optimizer.sideNavExpanded';
  bool _expanded = true;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      final v = p.getBool(_key);
      if (v != null && mounted) setState(() => _expanded = v);
    }, onError: (_) {});
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    SharedPreferences.getInstance().then((p) => p.setBool(_key, _expanded), onError: (_) => false);
  }

  /// Lays [child] out at the open width always, so nothing reflows while the
  /// bar folds; the bar just shows less of it.
  Widget _fixed(Widget child) => _NoBar(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: SizedBox(width: SideNav.expandedWidth, child: child),
      );

  Widget _fade(Widget child) => AnimatedOpacity(duration: const Duration(milliseconds: 200), opacity: _expanded ? 1 : 0, child: child);

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      width: _expanded ? SideNav.expandedWidth : SideNav.collapsedWidth,
      decoration: const BoxDecoration(
        color: AppColors.background,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) => _NoBar(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight),
                child: IntrinsicHeight(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const SizedBox(height: 20),
                    // The logo always, over the icons when folded; "Optimizer" fades.
                    _fixed(Padding(
                      padding: const EdgeInsets.fromLTRB((SideNav.collapsedWidth - 1 - 32) / 2, 4, 12, 4),
                      child: Row(children: [
                        const OptimizerLogo(size: 32),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _fade(const Text(
                            'Optimizer',
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.fade,
                            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 21, letterSpacing: 0.2, height: 1.1),
                          )),
                        ),
                      ]),
                    )),
                    const SizedBox(height: 18),
                    for (var i = 0; i < widget.items.length; i++)
                      _NavBubble(
                        item: widget.items[i],
                        selected: i == widget.selected,
                        expanded: _expanded,
                        onTap: () => widget.onSelected(i),
                      ),
                    const Spacer(),
                    widget.account(_expanded),
                    const SizedBox(height: 8),
                  ]),
                ),
              ),
            ),
          ),
        ),
        // The version and the fold arrow: one button, the whole rectangle.
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: _Bubbly(
            onTap: _toggle,
            tooltip: _expanded ? 'Collapse' : 'Expand',
            child: SizedBox(
              height: 44,
              width: double.infinity,
              child: Stack(children: [
                Positioned(
                  left: 16,
                  top: 0,
                  bottom: 0,
                  child: Center(
                      child: _fade(const Text('v$appVersion', softWrap: false, style: TextStyle(color: AppColors.secondaryText, fontSize: 12)))),
                ),
                // Centered in the bubble when folded.
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: (_foldedInside - 24) / 2),
                    child: Icon(_expanded ? Icons.keyboard_arrow_left : Icons.keyboard_arrow_right, size: 24, color: AppColors.secondaryText),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

/// A page in the bar: a rounded bubble, softly lit under the mouse and
/// filled when it's the page you're on. Folded, just the icon (its name in a
/// tooltip).
class _NavBubble extends StatelessWidget {
  const _NavBubble({required this.item, required this.selected, required this.expanded, required this.onTap});

  final SideNavItem item;
  final bool selected;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final row = SizedBox(
      height: 44,
      child: _NoBar(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: SizedBox(
          width: SideNav.expandedWidth - 20,
          child: Row(children: [
            const SizedBox(width: (_foldedInside - 20) / 2),
            Icon(selected ? item.selected : item.icon, size: 20, color: selected ? AppColors.primaryText : AppColors.secondaryText),
            const SizedBox(width: 14),
            Expanded(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: expanded ? 1 : 0,
                child: Text(
                  item.label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                  style: TextStyle(
                    color: selected ? AppColors.primaryText : const Color(0xD9FFFFFF),
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    fontSize: 14.5,
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: _Bubbly(
        onTap: onTap,
        selected: selected,
        tooltip: expanded ? null : item.label,
        child: row,
      ),
    );
  }
}

/// A rounded, friendly hit area: a soft bubble appears under the mouse, and
/// stays filled when [selected].
class _Bubbly extends StatefulWidget {
  const _Bubbly({required this.onTap, required this.child, this.selected = false, this.tooltip});

  /// Null when something around it handles the tap (a menu button).
  final VoidCallback? onTap;
  final Widget child;
  final bool selected;
  final String? tooltip;

  @override
  State<_Bubbly> createState() => _BubblyState();
}

class _BubblyState extends State<_Bubbly> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final lit = widget.selected || _hover;
    Widget body = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: widget.selected ? const Color(0x1FFFFFFF) : (_hover ? const Color(0x12FFFFFF) : Colors.transparent),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: lit ? const Color(0x1AFFFFFF) : Colors.transparent),
      ),
      child: widget.child,
    );
    if (widget.tooltip != null) body = Tooltip(message: widget.tooltip!, waitDuration: const Duration(milliseconds: 400), child: body);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: widget.onTap == null ? body : GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.onTap, child: body),
    );
  }
}

/// Your account at the bottom of the bar: picture always, name when open.
/// Its menu has Settings and Sign out.
class SideNavAccount extends StatelessWidget {
  const SideNavAccount(
      {super.key, required this.name, required this.email, required this.expanded, required this.onSettings, required this.onSignOut});

  final String name;
  final String email;
  final bool expanded;
  final VoidCallback onSettings;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final label = name.isEmpty ? 'Axis user' : name;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: PopupMenuButton<String>(
        tooltip: label,
        position: PopupMenuPosition.over,
        onSelected: (v) => v == 'settings' ? onSettings() : onSignOut(),
        itemBuilder: (_) => [
          PopupMenuItem(enabled: false, child: Text(email.isEmpty ? label : email)),
          const PopupMenuItem(
            value: 'settings',
            child: Row(children: [Icon(Icons.settings_outlined, size: 18), SizedBox(width: 10), Text('Settings')]),
          ),
          const PopupMenuItem(value: 'out', child: Text('Sign out')),
        ],
        child: _Bubbly(
          onTap: null,
          child: SizedBox(
            height: 48,
            child: _NoBar(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: SizedBox(
                width: SideNav.expandedWidth - 20,
                child: Row(children: [
                  const SizedBox(width: (_foldedInside - 32) / 2),
                  CircleAvatar(radius: 16, child: Text(label.characters.first.toUpperCase())),
                  const SizedBox(width: 12),
                  Expanded(
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 200),
                      opacity: expanded ? 1 : 0,
                      child:
                          Text(label, maxLines: 1, softWrap: false, overflow: TextOverflow.fade, style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A scroll view with no scrollbar: the bar's rows are laid out at full
/// width and clipped while it's folded, and a scrollbar would show under them.
class _NoBar extends StatelessWidget {
  const _NoBar({this.scrollDirection = Axis.vertical, this.physics, required this.child});

  final Axis scrollDirection;
  final ScrollPhysics? physics;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      withoutAutoScrollbar(context, SingleChildScrollView(scrollDirection: scrollDirection, physics: physics, child: child));
}

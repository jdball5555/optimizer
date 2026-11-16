import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Optimizer's scrollbar: thin, in the gap beside the tiles, and there while
/// you scroll. It can be grabbed and dragged, but a pointer just passing over
/// it doesn't bring it up: only resting on it for a moment does.
class CalmScrollbar extends RawScrollbar {
  const CalmScrollbar({super.key, required super.child, super.controller})
      : super(
          thickness: 6,
          radius: const Radius.circular(3),
          crossAxisMargin: 3,
          interactive: true,
          thumbColor: const Color(0x73FFFFFF),
          fadeDuration: const Duration(milliseconds: 250),
          timeToFade: const Duration(milliseconds: 800),
        );

  @override
  RawScrollbarState<CalmScrollbar> createState() => _CalmScrollbarState();
}

class _CalmScrollbarState extends RawScrollbarState<CalmScrollbar> {
  static const _rest = Duration(milliseconds: 600);
  Timer? _waiting;
  PointerHoverEvent? _last;

  @override
  void handleHover(PointerHoverEvent event) {
    if (isPointerOverScrollbar(event.position, event.kind, forHover: true)) {
      // Over the bar: show it only once the pointer has stayed a moment.
      _last = event;
      _waiting ??= Timer(_rest, () {
        if (mounted && _last != null) super.handleHover(_last!);
      });
      return;
    }
    _waiting?.cancel();
    _waiting = null;
    super.handleHover(event);
  }

  @override
  void handleHoverExit(PointerExitEvent event) {
    _waiting?.cancel();
    _waiting = null;
    super.handleHoverExit(event);
  }

  @override
  void dispose() {
    _waiting?.cancel();
    super.dispose();
  }
}

/// [child]'s lists without the automatic scrollbar: for a list that draws
/// its own (or shouldn't have one), so there's never a second on top.
Widget withoutAutoScrollbar(BuildContext context, Widget child) =>
    ScrollConfiguration(behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false), child: child);

/// Puts [CalmScrollbar] on every scrolling list on a desktop or laptop
/// (phones show their own while you scroll).
class CalmScrollBehavior extends MaterialScrollBehavior {
  const CalmScrollBehavior();

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    switch (getPlatform(context)) {
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return CalmScrollbar(controller: details.controller, child: child);
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.iOS:
        return child;
    }
  }
}

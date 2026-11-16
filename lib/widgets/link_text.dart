import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';

final _linkPattern = RegExp(r'''(?:https?://|www\.)[^\s<>"']+''', caseSensitive: false);

/// Where a link in some text really ends: not on the period after it.
String _trimmed(String link) => link.replaceFirst(RegExp(r'[.,;:!?)\]}]+$'), '');

/// Every link in [text], in order.
List<String> findLinks(String text) => [for (final m in _linkPattern.allMatches(text)) _trimmed(m.group(0)!)];

/// What to open for a link as it's written: "www.a.com" is https://www.a.com.
Uri? linkUri(String link) => Uri.tryParse(link.toLowerCase().startsWith('www.') ? 'https://$link' : link);

Future<void> openLink(String link) async {
  final uri = linkUri(link);
  if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// A link to show without the clutter: "booking.com/hotel…".
String shortLink(String link, {int length = 44}) {
  final s = link.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '').replaceFirst(RegExp(r'^www\.', caseSensitive: false), '');
  return s.length <= length ? s : '${s.substring(0, length - 1)}…';
}

/// [text] split into plain pieces and links, in order.
List<({String text, bool link})> _pieces(String text) {
  final out = <({String text, bool link})>[];
  var at = 0;
  for (final m in _linkPattern.allMatches(text)) {
    final link = _trimmed(m.group(0)!);
    if (m.start > at) out.add((text: text.substring(at, m.start), link: false));
    out.add((text: link, link: true));
    at = m.start + link.length;
  }
  if (at < text.length) out.add((text: text.substring(at), link: false));
  return out;
}

const _linkStyle = TextStyle(color: Energy.ice, decoration: TextDecoration.underline, decorationColor: Energy.ice);

/// Text whose links can be clicked.
class LinkText extends StatefulWidget {
  const LinkText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  State<LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<LinkText> {
  final _taps = <TapGestureRecognizer>[];

  void _clear() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    return SelectableText.rich(
      TextSpan(style: widget.style, children: [
        for (final p in _pieces(widget.text))
          if (p.link)
            TextSpan(
              text: p.text,
              style: _linkStyle,
              mouseCursor: SystemMouseCursors.click,
              recognizer: (TapGestureRecognizer()..onTap = () => openLink(p.text)).also(_taps.add),
            )
          else
            TextSpan(text: p.text),
      ]),
    );
  }
}

extension on TapGestureRecognizer {
  TapGestureRecognizer also(void Function(TapGestureRecognizer) f) {
    f(this);
    return this;
  }
}

/// Shows links as links, as you type or paste them.
class LinkingController extends TextEditingController {
  LinkingController({super.text});

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    // Mid-word on a phone's keyboard, leave it to look as it normally would.
    if (withComposing && value.isComposingRangeValid) return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    return TextSpan(style: style, children: [
      for (final p in _pieces(text)) TextSpan(text: p.text, style: p.link ? _linkStyle : null),
    ]);
  }
}

/// A notes box. A link pasted in shows as one, with a button under the box to open it.
class NotesField extends StatelessWidget {
  const NotesField({super.key, required this.controller, this.label = 'Notes', this.minLines = 3});

  final TextEditingController controller;
  final String label;
  final int minLines;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        TextField(
          controller: controller,
          minLines: minLines,
          maxLines: null,
          textCapitalization: TextCapitalization.sentences,
          // Multi-line boxes match the browser's copy of them (web/index.html).
          style: const TextStyle(height: 1.65),
          decoration: InputDecoration(labelText: label, alignLabelWithHint: true),
        ),
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final links = findLinks(controller.text).toSet();
            if (links.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(spacing: 4, runSpacing: 2, children: [
                for (final l in links)
                  TextButton.icon(
                    onPressed: () => openLink(l),
                    icon: const Icon(Icons.open_in_new, size: 14),
                    label: Text(shortLink(l), style: const TextStyle(fontSize: 12.5)),
                    style: TextButton.styleFrom(foregroundColor: Energy.ice, visualDensity: VisualDensity.compact),
                  ),
              ]),
            );
          },
        ),
      ]);
}

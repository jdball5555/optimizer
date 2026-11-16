import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../theme.dart';

Widget mapFrame(String url) => _MapFrame(key: ValueKey(url), url: url);

class _MapFrame extends StatefulWidget {
  const _MapFrame({super.key, required this.url});

  final String url;

  @override
  State<_MapFrame> createState() => _MapFrameState();
}

class _MapFrameState extends State<_MapFrame> {
  // There are no web views under `flutter test`.
  static final _testing = Platform.environment.containsKey('FLUTTER_TEST');

  late final WebViewController? _controller = _testing
      ? null
      : (WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(NavigationDelegate(onNavigationRequest: (r) {
          // The map stays here; its links ("View larger map") go to Google Maps.
          final inMap = r.url.startsWith('https://www.google.com/maps/embed') || r.url.contains('output=embed');
          if (inMap || !r.isMainFrame) return NavigationDecision.navigate;
          launchUrl(Uri.parse(r.url), mode: LaunchMode.externalApplication);
          return NavigationDecision.prevent;
        }))
        ..loadRequest(Uri.parse(widget.url)));

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null) return const ColoredBox(color: AppColors.surfaceHigh);
    return WebViewWidget(
      controller: c,
      // So dragging moves the map, not the page around it.
      gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)},
    );
  }
}

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

Widget mapFrame(String url) => HtmlElementView.fromTagName(
      key: ValueKey(url),
      tagName: 'iframe',
      onElementCreated: (e) {
        final f = e as web.HTMLIFrameElement;
        f.src = url;
        f.title = 'Map';
        f.style
          ..border = '0'
          ..width = '100%'
          ..height = '100%';
      },
    );

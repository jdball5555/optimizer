// Renders Optimizer's logo into the app and browser icon PNGs:
//   ICON_OUT=/some/folder flutter test test/tool/make_icons_test.dart
// Skipped in a normal `flutter test`.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optimizer/widgets/logo.dart';

final out = Platform.environment['ICON_OUT'] ?? '';

Future<void> render(String name, {required double logo, double radius = 0, bool transparent = false}) async {
  const size = 1024.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final bg = Paint()..color = const Color(0xFF000000);
  if (transparent) {
    // Android's adaptive icon foreground: the background is a color layer.
  } else if (radius == 0) {
    canvas.drawRect(const Rect.fromLTWH(0, 0, size, size), bg);
  } else {
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, size, size), Radius.circular(radius)), bg);
  }
  final l = size * logo;
  canvas.translate((size - l) / 2, (size - l) / 2);
  OptimizerLogoPainter(Colors.white).paint(canvas, Size(l, l));
  final image = await recorder.endRecording().toImage(size.toInt(), size.toInt());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File('$out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  test(skip: out.isEmpty, 'icons', () async {
    await render('icon', logo: 0.78); // app icon and web icons
    await render('icon_maskable', logo: 0.6); // Android/web maskable: logo inside the safe zone
    await render('favicon', logo: 0.86, radius: 230); // browser tab
    await render('foreground', logo: 0.5, transparent: true); // Android adaptive icon, inside its safe zone
  });
}

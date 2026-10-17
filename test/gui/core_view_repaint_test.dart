import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/core_view.dart';
import 'package:fnesemu/gui/direction_pad.dart';
import 'package:fnesemu/gui/ticker_image.dart';
import 'package:fnesemu_core/app_api.dart';

ui.Image _image() {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(1, 1);
  picture.dispose();
  return image;
}

void main() {
  testWidgets('a new frame does not repaint the touch controls',
      (tester) async {
    final controller = CoreController((_) {}, (_) {}, (_) {}, Sram());
    final container = ImageContainer(
        decoder: (pixels, width, height, callback) => callback(_image()));
    addTearDown(container.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CoreView(controller: controller, container: container))));
    container.push(Uint32List(1), 1, 1, 256, displayHeight: 240);
    await tester.pump();

    var padPaints = 0, imagePaints = 0;
    debugProfilePaintsEnabled = true;
    debugOnProfilePaint = (object) {
      if (object is! RenderCustomPaint) return;
      if (object.painter is DirectionPadPainter) padPaints++;
      if (object.painter != null && object.painter is! DirectionPadPainter) {
        imagePaints++;
      }
    };
    for (var i = 0; i < 3; i++) {
      container.push(Uint32List(1), 1, 1, 256, displayHeight: 240);
      await tester.pump();
    }
    debugProfilePaintsEnabled = false;
    debugOnProfilePaint = null;
    expect(imagePaints, 3);
    expect(padPaints, 0);
  });
}

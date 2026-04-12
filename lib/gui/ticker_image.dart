import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'config.dart';

class ImageContainer {
  static final config = Config();

  ui.Image? image;

  ImageContainer();

  final displayWidthNotifier = ValueNotifier<int>(config.imageWidth);
  final imageNotifier = ValueNotifier<ui.Image?>(null);

  int displayHeight = config.imageHeight;

  void push(Uint8List buffer, int width, int height, int displayWidth) {
    displayWidthNotifier.value = displayWidth;

    buffer.isNotEmpty
        ? ui.decodeImageFromPixels(
            buffer, width, height, ui.PixelFormat.rgba8888, (image) {
            this.image = image;
            imageNotifier.value = image;
          })
        : null;
  }
}

Widget imageListener(
        {required ValueNotifier<ui.Image?> notifier,
        required double width,
        required double height}) =>
    ValueListenableBuilder(
        valueListenable: notifier,
        builder: (context, value, child) => CustomPaint(
              size: Size(width, height),
              painter: _ImagePainter(value),
            ));

class _ImagePainter extends CustomPainter {
  final ui.Image? image;

  _ImagePainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    // paint image to canvas
    final paint = Paint();

    if (image == null) {
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
          Paint()..color = Colors.black);
      return;
    }

    final srcRect =
        Rect.fromLTWH(0, 0, image!.width.toDouble(), image!.height.toDouble());
    final dstRect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(image!, srcRect, dstRect, paint);
  }

  @override
  bool shouldRepaint(covariant _ImagePainter oldDelegate) {
    // repaint only if image is changed
    return oldDelegate.image != image;
  }
}

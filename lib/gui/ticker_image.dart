import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'config.dart';
import 'pixels/host_pixels_io.dart'
    if (dart.library.js_interop) 'pixels/host_pixels_web.dart';

typedef PixelDecoder = void Function(Uint8List pixels, int width, int height,
    ui.PixelFormat format, ui.ImageDecoderCallback callback);

class ImageContainer {
  static final config = Config();

  ui.Image? image;

  ImageContainer({PixelDecoder? decoder})
      : _decoder = decoder ?? ui.decodeImageFromPixels;

  final PixelDecoder _decoder;
  bool _disposed = false;
  int _generation = 0;
  int _displayedGeneration = 0;
  final _retiredImages = <ui.Image>{};
  bool _retirementScheduled = false;

  final displayWidthNotifier = ValueNotifier<int>(config.imageWidth);
  final displayHeightNotifier = ValueNotifier<int>(config.imageHeight);
  final imageNotifier = ValueNotifier<ui.Image?>(null);

  void push(Uint8List buffer, int width, int height, int displayWidth,
      {int? displayHeight}) {
    if (_disposed || buffer.isEmpty) return;

    final generation = ++_generation;
    _decoder(hostPixels(buffer), width, height, ui.PixelFormat.rgba8888,
        (next) {
      // An asynchronous decode may finish after a newer frame or disposal.
      if (_disposed || generation < _displayedGeneration) {
        next.dispose();
        return;
      }
      _displayedGeneration = generation;
      final previous = image;
      image = next;
      displayWidthNotifier.value = displayWidth;
      displayHeightNotifier.value = displayHeight ?? height;
      imageNotifier.value = next;
      if (previous != null) _retire(previous);
    });
  }

  void _retire(ui.Image previous) {
    _retiredImages.add(previous);
    if (_retirementScheduled) return;
    _retirementScheduled = true;
    // The existing painter can still reference the old image until repaint.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _retirementScheduled = false;
      _disposeRetiredImages();
    });
  }

  void _disposeRetiredImages() {
    for (final retired in _retiredImages) {
      retired.dispose();
    }
    _retiredImages.clear();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    image?.dispose();
    image = null;
    _disposeRetiredImages();
    imageNotifier.dispose();
    displayWidthNotifier.dispose();
    displayHeightNotifier.dispose();
  }
}

Widget imageListener(
        {required ValueNotifier<ui.Image?> notifier,
        required double width,
        required double height}) =>
    // A new frame repaints only this layer. Rebuilding a widget here would
    // relayout the enclosing LayoutBuilder and repaint the overlaid controls.
    RepaintBoundary(
        child: CustomPaint(
      size: Size(width, height),
      painter: _ImagePainter(notifier),
    ));

class _ImagePainter extends CustomPainter {
  final ValueListenable<ui.Image?> notifier;

  _ImagePainter(this.notifier) : super(repaint: notifier);

  @override
  void paint(Canvas canvas, Size size) {
    final image = notifier.value;
    if (image == null) {
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
          Paint()..color = Colors.black);
      return;
    }

    final srcRect =
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final dstRect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(image, srcRect, dstRect, Paint());
  }

  @override
  bool shouldRepaint(covariant _ImagePainter oldDelegate) =>
      oldDelegate.notifier != notifier;
}

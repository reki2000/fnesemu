import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

class ImageContainer {
  ui.Image? image;

  ImageContainer();

  void push(Uint8List buffer, int width, int height) =>
      ui.decodeImageFromPixels(buffer, width, height, ui.PixelFormat.rgba8888,
          (image) => this.image = image);
}

class TickerImage extends StatefulWidget {
  final double width;
  final double height;
  final ImageContainer container;

  const TickerImage({
    super.key,
    required this.width,
    required this.height,
    required this.container,
  });

  @override
  State<TickerImage> createState() => _TickerImageState();
}

class _TickerImageState extends State<TickerImage>
    with SingleTickerProviderStateMixin {
  ui.Image? _currentImage;
  late Ticker _ticker;

  @override
  void initState() {
    super.initState();

    // vsyncに同期するTickerを作成
    _ticker = createTicker(_onTick);
    _ticker.start();
  }

  // called every frame from Ticker
  void _onTick(Duration elapsed) {
    if (widget.container.image != null) {
      setState(() {
        _currentImage = widget.container.image;
        widget.container.image = null;
      });
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_currentImage == null) {
      // placeholder
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: Container(color: Colors.black),
      );
    }

    return CustomPaint(
      size: Size(widget.width, widget.height),
      painter: _ImagePainter(_currentImage!),
    );
  }
}

class _ImagePainter extends CustomPainter {
  final ui.Image image;

  _ImagePainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    // paint image to canvas
    final paint = Paint();
    final srcRect =
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final dstRect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(image, srcRect, dstRect, paint);
  }

  @override
  bool shouldRepaint(covariant _ImagePainter oldDelegate) {
    // repaint only if image is changed
    return oldDelegate.image != image;
  }
}

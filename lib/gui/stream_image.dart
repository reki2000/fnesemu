import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

class StreamImageWidget extends StatefulWidget {
  final Stream<ui.Image> imageStream;
  final double width;
  final double height;

  const StreamImageWidget({
    super.key,
    required this.imageStream,
    required this.width,
    required this.height,
  });

  @override
  State<StreamImageWidget> createState() => _StreamImageWidgetState();
}

class _StreamImageWidgetState extends State<StreamImageWidget>
    with SingleTickerProviderStateMixin {
  ui.Image? _currentImage;
  ui.Image? _nextImage;
  late StreamSubscription<ui.Image> _subscription;
  late Ticker _ticker;

  @override
  void initState() {
    super.initState();

    // vsyncに同期するTickerを作成
    _ticker = createTicker(_onTick);
    _ticker.start();

    // 画像ストリームを購読
    _subscription = widget.imageStream.listen((ui.Image image) {
      // 新しい画像を受け取ったら、_nextImageに格納
      _nextImage = image;
    });
  }

  void _onTick(Duration elapsed) {
    // vsyncに同期して呼ばれる
    if (_nextImage != null) {
      setState(() {
        // 新しい画像を表示用にセットし、_nextImageをクリア
        _currentImage = _nextImage;
        _nextImage = null;
      });
    }
  }

  @override
  void dispose() {
    // 資源を解放
    _ticker.dispose();
    _subscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_currentImage == null) {
      // 初期状態や画像がまだない場合のプレースホルダー
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
    // 画像をキャンバスに描画
    final paint = Paint();
    final srcRect =
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final dstRect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(image, srcRect, dstRect, paint);
  }

  @override
  bool shouldRepaint(covariant _ImagePainter oldDelegate) {
    // 画像が更新されたときに再描画
    return oldDelegate.image != image;
  }
}

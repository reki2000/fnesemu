// Dart imports:
// Flutter imports:
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/debugger.dart';
import '../../core/types.dart';
import '../../styles.dart';

_imageBufferRenderer(ImageBuffer buf, {useMouseFollow = false}) {
  if (buf.buffer.isEmpty) {
    return const SizedBox();
  }

  final completer = Completer<ui.Image>();

  ui.decodeImageFromPixels(buf.buffer, buf.width, buf.height,
      ui.PixelFormat.rgba8888, (image) => completer.complete(image));

  final rectStream = StreamController<(int, int, String)>.broadcast();

  final imageWidget = FutureBuilder(
    future: completer.future,
    builder: (context, image) => RawImage(image: image.data),
  );

  if (!useMouseFollow) {
    return imageWidget;
  }

  return MouseRegion(
      onHover: (event) {
        final x = (event.localPosition.dx).floor();
        final y = (event.localPosition.dy).floor();
        rectStream.add((x ~/ 8 * 8, y ~/ 8 * 8, "[${x ~/ 8},${y ~/ 8}]"));
      },
      child: Stack(children: [
        imageWidget,
        StreamBuilder(
            stream: rectStream.stream,
            builder: (context, snapshot) => (!snapshot.hasData)
                ? Container()
                : CustomPaint(
                    size: Size(buf.width.toDouble(), buf.height.toDouble()),
                    painter: RectanglePainter(snapshot.data!.$1.toDouble(),
                        snapshot.data!.$2.toDouble(), 8, 8, snapshot.data!.$3),
                  )),
      ]));
}

class RectanglePainter extends CustomPainter {
  final double x;
  final double y;
  final double width;
  final double height;
  final String text;

  RectanglePainter(this.x, this.y, this.width, this.height, this.text);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final rect = Rect.fromLTWH(x, y, width, height);
    canvas.drawRect(rect, paint);

    final textSpan = TextSpan(
      text: text,
      style: const TextStyle(
          color: Colors.red, fontSize: 12, fontWeight: FontWeight.bold),
    );

    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    )..layout(
        minWidth: 0,
        maxWidth: size.width,
      );

    textPainter.paint(canvas, Offset(x + 10, y));
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) =>
      oldDelegate is RectanglePainter && oldDelegate.text != text;
}

class DebugVdc extends StatefulWidget {
  final Debugger debugger;
  final double width;

  const DebugVdc({super.key, required this.debugger, this.width = 640});

  @override
  State<DebugVdc> createState() => _DebugVdc();
}

class _DebugVdc extends State<DebugVdc> {
  int _paletteNo = 0;
  bool _useGrayscale = true;

  static const _paletteNoMask = 0x1f;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  int get paletteNo => _paletteNo;
  set paletteNo(int value) =>
      setState(() => _paletteNo = value & _paletteNoMask);

  @override
  Widget build(BuildContext context) {
    final dbg = widget.debugger;
    final spriteInfo = dbg.spriteInfo();
    final spriteInfos = List.generate(
        4,
        (i) => spriteInfo.sublist(
            i * spriteInfo.length ~/ 4, (i + 1) * spriteInfo.length ~/ 4));

    final colorTable = Column(children: [
      Row(children: [
        Switch(
            value: _useGrayscale,
            onChanged: (v) => setState(() => _useGrayscale = v)),
        IconButton(
            icon: const Icon(Icons.arrow_upward), onPressed: () => paletteNo--),
        IconButton(
            icon: const Icon(Icons.arrow_downward),
            onPressed: () => paletteNo++),
        Text("$_paletteNo", style: debugStyle),
      ]),
      _imageBufferRenderer(dbg.renderColorTable(_paletteNo)),
    ]);

    return Container(
        width: widget.width,
        alignment: Alignment.center,
        margin: const EdgeInsets.all(10.0),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              colorTable,
              _imageBufferRenderer(dbg.renderVram(_useGrayscale, _paletteNo)),
              ...spriteInfos.map((e) => Text(e.join("\n"), style: debugStyle)),
            ]),
            _imageBufferRenderer(dbg.renderBg()),
          ]),
        ));
  }
}

// Dart imports:
// Flutter imports:
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/debugger.dart';
import '../../core/types.dart';
import '../../styles.dart';

_imageBufferRenderer(ImageBuffer buf) {
  if (buf.buffer.isEmpty) {
    return const SizedBox();
  }

  final completer = Completer<ui.Image>();

  ui.decodeImageFromPixels(buf.buffer, buf.width, buf.height,
      ui.PixelFormat.rgba8888, (image) => completer.complete(image));

  return FutureBuilder(
    future: completer.future,
    builder: (context, image) => RawImage(image: image.data),
  );
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

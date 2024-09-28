// Dart imports:
// Flutter imports:
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/debugger.dart';
import '../../core/types.dart';
import '../../styles.dart';

_imageBufferRenderer(ImageBuffer buf) {
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

  const DebugVdc({super.key, required this.debugger});

  @override
  State<DebugVdc> createState() => _DebugVdc();
}

class _DebugVdc extends State<DebugVdc> {
  int _paletteNo = 0;
  bool _useSecond = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  List<int> _colorTable(bool second) {
    final colorTable = List<int>.from(widget.debugger.dumpColorTable());
    if (second) {
      colorTable[0] = 0x1ff;
    }
    return colorTable;
  }

  @override
  Widget build(BuildContext context) {
    final spriteInfo = widget.debugger.spriteInfo();
    return Container(
      alignment: Alignment.center,
      margin: const EdgeInsets.all(10.0),
      child: Column(children: [
        Row(children: [
          Text(spriteInfo.sublist(0, spriteInfo.length ~/ 2).join("\n"),
              style: debugStyle),
          Text(spriteInfo.sublist(spriteInfo.length ~/ 2).join("\n"),
              style: debugStyle),
          Row(children: [
            Column(children: [
              Row(children: [
                Switch(
                    value: _useSecond,
                    onChanged: (onoff) => setState(() => _useSecond = onoff)),
                IconButton(
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: () => setState(() {
                          _paletteNo = (_paletteNo - 1) & 0x1f;
                        })),
                IconButton(
                    icon: const Icon(Icons.arrow_downward),
                    onPressed: () => setState(() {
                          _paletteNo = (_paletteNo + 1) & 0x1f;
                        })),
                Text("$_paletteNo", style: debugStyle),
              ]),
              _imageBufferRenderer(
                  widget.debugger.renderColorTable(_paletteNo)),
            ]),
            _imageBufferRenderer(
                widget.debugger.renderVram(_useSecond, _paletteNo)),
          ]),
        ]),
        _imageBufferRenderer(widget.debugger.renderBg()),
      ]),
    );
  }
}

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
  bool _useSecond = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spriteInfo = widget.debugger.spriteInfo();
    final spriteInfos = List.generate(
        4,
        (i) => spriteInfo.sublist(
            i * spriteInfo.length ~/ 4, (i + 1) * spriteInfo.length ~/ 4 - 1));

    return Container(
        width: widget.width,
        alignment: Alignment.center,
        margin: const EdgeInsets.all(10.0),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(children: [
            Row(children: [
              ...spriteInfos.map((e) => Text(e.join("\n"), style: debugStyle)),
              Row(children: [
                Column(children: [
                  Row(children: [
                    Switch(
                        value: _useSecond,
                        onChanged: (onoff) =>
                            setState(() => _useSecond = onoff)),
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
        ));
  }
}

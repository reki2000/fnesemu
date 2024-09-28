import 'dart:async';
import 'dart:typed_data';

import 'package:fnesemu/core/pad_button.dart';
import 'package:fnesemu/core/types.dart';
import 'package:fnesemu/util.dart';

import '../core.dart';

class Nes implements Core {
  @override
  ExecResult exec() {
    return ExecResult(0, false, false);
  }

  @override
  int get audioSampleRate => 800000;

  @override
  int get clocks => 0;

  @override
  int get clocksInScanline => 4000000 ~/ 60 ~/ 242;

  @override
  List<int> get colorTable => throw UnimplementedError();

  @override
  Pair<String, int> disasm(int addr) {
    return Pair("", 1);
  }

  @override
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    return "";
  }

  @override
  ImageBuffer imageBuffer() {
    return ImageBuffer(0, 0, Uint8List(0));
  }

  @override
  void padDown(int controllerId, PadButton k) {}

  @override
  void padUp(int controllerId, PadButton k) {}

  @override
  List<PadButton> get buttons => [
        PadButton.left,
        PadButton.right,
        PadButton.up,
        PadButton.down,
        PadButton("Select"),
        PadButton("Start"),
        PadButton("A"),
        PadButton("B"),
      ];

  @override
  int get programCounter => 0;

  @override
  int read(int addr) {
    return 0;
  }

  @override
  ImageBuffer renderBg() {
    return ImageBuffer(0, 0, Uint8List(0));
  }

  @override
  void reset() {}

  @override
  int get scanlinesInFrame => 242;

  @override
  setAudioStream(StreamSink<Float32List>? stream) {}

  @override
  void setRom(Uint8List body) {}

  @override
  List<int> get spriteTable => List.empty();

  @override
  int get systemClockHz => 4000000;

  @override
  String get tracingState => "";

  @override
  List<int> get vram => List.empty();
}

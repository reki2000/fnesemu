import 'dart:typed_data';

import 'core.dart';
import 'pad_button.dart';
import 'types.dart';

class EmptyCore extends Core {
  int _clocks = 0;

  @override
  int get systemClockHz => 1000000;

  @override
  int get scanlinesInFrame => 240;

  @override
  int get clocksInScanline => systemClockHz ~/ 60 ~/ scanlinesInFrame;

  @override
  List<CpuInfo> get cpuInfos => [const CpuInfo(0, "", 16)];

  @override
  void reset() => throw "ROM not loaded";

  @override
  void setRom(Uint8List body) {}

  @override
  ExecResult exec(bool step) => ExecResult(_clocks++, true, true);

  @override
  ImageBuffer imageBuffer() => ImageBuffer.empty();

  @override
  onAudio(void Function(AudioBuffer p1) onAudio) {}

  @override
  List<PadButton> get buttons => [];

  @override
  void padDown(int controllerId, PadButton k) {}

  @override
  void padUp(int controllerId, PadButton k) {}

  @override
  int programCounter(int cpuNo) => 0;

  @override
  int stackPointer(int cpuNo) => 0;

  @override
  (String, int) disasm(int cpuNo, int addr) => ("", 0);

  @override
  TraceLog trace(int cpuNo) => TraceLog(0, 0, "", "", List.empty());

  @override
  String dump(
          {bool showZeroPage = false,
          bool showSpriteVram = false,
          bool showStack = false,
          bool showApu = false}) =>
      "";

  @override
  int read(int cpuNo, int addr) => 0;

  @override
  ImageBuffer renderBg() => ImageBuffer.empty();

  @override
  ImageBuffer renderColorTable(int paletteNo) => ImageBuffer.empty();

  @override
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) =>
      ImageBuffer.empty();

  @override
  List<String> spriteInfo() => [];

  @override
  List<int> get vram => [];
}

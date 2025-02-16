import 'dart:typed_data';

import '../util/util.dart';
import 'core.dart';
import 'pad_button.dart';
import 'types.dart';

class EmptyCore extends Core {
  @override
  List<PadButton> get buttons => [];

  @override
  int get clocksInScanline => 0;

  @override
  List<CpuInfo> get cpuInfos => [const CpuInfo(0, "", 16)];

  @override
  Pair<String, int> disasm(int cpuNo, int addr) => const Pair("", 0);

  @override
  String dump(
          {bool showZeroPage = false,
          bool showSpriteVram = false,
          bool showStack = false,
          bool showApu = false}) =>
      "";

  @override
  ExecResult exec(bool step) => ExecResult(1, true, true);

  @override
  ImageBuffer imageBuffer() => ImageBuffer.empty();

  @override
  onAudio(void Function(AudioBuffer p1) onAudio) {}

  @override
  void padDown(int controllerId, PadButton k) {}

  @override
  void padUp(int controllerId, PadButton k) {}

  @override
  int programCounter(int cpuNo) => 0;

  @override
  int stackPointer(int cpuNo) => 0;

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
  void reset() => throw "ROM not loaded";

  @override
  int get scanlinesInFrame => 0;

  @override
  void setRom(Uint8List body) {}

  @override
  List<String> spriteInfo() => [];

  @override
  int get systemClockHz => 0;

  @override
  TraceLog trace(int cpuNo) => TraceLog(0, 0, "", "");

  @override
  List<int> get vram => [];
}

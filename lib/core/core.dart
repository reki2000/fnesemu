// data class to conver the result of 'exec'
import 'dart:typed_data';

import '../util/util.dart';
import 'pad_button.dart';
import 'types.dart';

// abstract class to be implemented by Emulator classes
abstract class Core {
  int get systemClockHz;

  int get scanlinesInFrame;
  int get clocksInScanline;

  List<CpuInfo> get cpuInfos;

  /// exec 1 cpu instruction and render image/audio if it passed enough cycles
  /// returns current elapsed CPU cycles(clocks) and bool - false when unimplemented instruction is found
  ExecResult exec(bool step);

  /// returns screen image buffer
  ImageBuffer imageBuffer();

  // receives callback to push rendered audio buffer
  void onAudio(void Function(AudioBuffer) onAudio);

  /// handles reset button events
  void reset();

  /// handles pad down/up events
  void padDown(int controllerId, PadButton k);
  void padUp(int controllerId, PadButton k);

  /// returns list of buttons
  List<PadButton> get buttons;

  // loads an rom file.
  // throws exception if the mapper type of the rom file is not supported.
  void setRom(Uint8List body);

  /// debug: returns the emulator's internal status report
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false});

  // debug: returns dis-assembled instruction in Pair<String nmemonic, int nextAddr>
  Pair<String, int> disasm(int cpuNo, int addr);

  // debug: returns PC register
  int programCounter(int cpuNo);

  // debug: returns SP register
  int stackPointer(int cpuNo);

  // debug: returns tracing CPU state - disassembed next instruction and current registers
  String tracingState(int cpuNo);

  // debug: dump vram
  List<int> get vram;

  // debug: read mem
  int read(int cpuNo, int addr);

  // debug: dump vram
  ImageBuffer renderBg();
  List<String> spriteInfo();
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo);
  ImageBuffer renderColorTable(int paletteNo);
}

class EmptyCore extends Core {
  @override
  List<PadButton> get buttons => [];

  @override
  int get clocksInScanline => 0;

  @override
  List<CpuInfo> get cpuInfos => [];

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
  ExecResult exec(bool step) => ExecResult(0, true, true);

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
  String tracingState(int cpuNo) => "";

  @override
  List<int> get vram => [];
}

// data class to conver the result of 'exec'
import 'dart:async';
import 'dart:typed_data';

import '../util.dart';
import 'pad_button.dart';
import 'types.dart';

class ExecResult {
  final int cycles;
  final bool stopped;
  final bool scanlineRendered;
  ExecResult(this.cycles, this.stopped, this.scanlineRendered);
}

// abstract class to be implemented by Pce class
abstract class Core {
  int get systemClockHz;

  int get scanlinesInFrame;
  int get clocksInScanline;

  int get clocks;

  /// exec 1 cpu instruction and render PPU / APU if enough cycles passed
  /// returns current CPU cycle and bool - false when unimplemented instruction is found
  ExecResult exec();

  /// returns screen buffer as hSize x vSize argb
  ImageBuffer imageBuffer();

  setAudioStream(StreamSink<Float32List>? stream);

  int get audioSampleRate;

  /// handles reset button events
  void reset();

  /// handles pad down/up events
  void padDown(int controllerId, PadButton k);
  void padUp(int controllerId, PadButton k);

  List<PadButton> get buttons;

  // loads an .pce format rom file.
  // throws exception if the mapper type of the rom file is not supported.
  void setRom(Uint8List body);

  /// debug: returns the emulator's internal status report
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false});

  // debug: returns dis-assembled 6502 instruction in [String nmemonic, int nextAddr]
  Pair<String, int> disasm(int addr);

  // debug: returns PC register
  int get programCounter;

  // debug: set debug logging
  String get tracingState;

  // debug: dump vram
  List<int> get vram;

  // debug: dump color table
  List<int> get colorTable;

  // debug: dump sprite table
  List<int> get spriteTable;

  // debug: read mem
  int read(int addr);

  // debug: dump vram
  ImageBuffer renderBg();
}

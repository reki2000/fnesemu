// Dart imports:
import 'dart:typed_data';

// Project imports:
import '../../util/util.dart';
import '../core.dart';
import '../pad_button.dart';
import '../types.dart';
import 'bus_m68.dart';
import 'bus_z80.dart';
import 'cpu_m68.dart';
import 'rom.dart';
import 'z80/z80.dart';

/// main class for NES emulation. integrates cpu/ppu/apu/bus/pad control
class Md implements Core {
  late final M68 cpu68k;
  late final Z80 cpuZ80;

  late final BusZ80 busZ80;
  late final BusM68 busM68;

  static const systemClockHz_ = 21477270; // 21.47727MHz

  @override
  int get systemClockHz => systemClockHz_;

  @override
  int get scanlinesInFrame => 263;

  @override
  int get clocksInScanline => systemClockHz ~/ 59.97 ~/ scanlinesInFrame;

  Md() {
    busM68 = BusM68();
    cpu68k = M68(busM68);

    busZ80 = BusZ80();
    cpuZ80 = Z80(busZ80);
  }

  int _clocks = 0;

  /// exec 1 cpu instruction and render PPU / APU if enough cycles passed
  /// returns current CPU cycle and bool - false when unimplemented instruction is found
  @override
  ExecResult exec() {
    while (_clocks < cpu68k.clocks) {
      cpu68k.exec();
    }

    while (_clocks < cpuZ80.clocks) {
      cpuZ80.exec();
    }

    _clocks += 20;

    return ExecResult(_clocks, true, false);
  }

  /// returns screen buffer as hSize x vSize argb
  @override
  ImageBuffer imageBuffer() {
    return ImageBuffer(0, 0, Uint8List(0));
  }

  void Function(AudioBuffer) _onAudio = (_) {};

  @override
  onAudio(void Function(AudioBuffer) onAudio) {
    _onAudio = onAudio;
  }

  /// handles reset button events
  @override
  void reset() {
    busM68.onReset();
  }

  /// handles pad down/up events
  @override
  void padDown(int controllerId, PadButton k) =>
      busM68.pad.keyDown(controllerId, k);
  @override
  void padUp(int controllerId, PadButton k) =>
      busM68.pad.keyUp(controllerId, k);

  @override
  List<PadButton> get buttons => busM68.pad.buttons;

  // ROM CRC
  String crc = "";

  // loads an .pce format rom file.
  // throws exception if the mapper type of the rom file is not supported.
  @override
  void setRom(Uint8List body) {
    final rom = Rom();
    rom.load(body);

    reset();
  }

  /// debug: returns the emulator's internal status report
  @override
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    // final cpuDump = cpu.dump(showRegs: true);
    // final dump = "$cpuDump\n"
    //     "${cpu.dump(showIRQVector: true, showStack: showStack, showZeroPage: showZeroPage)}"
    //     "${showApu ? psg.dump() : ""}"
    //     "${bus.vdc.dump()}";
    return "";
    // return '${fps.toStringAsFixed(2)}fps';
  }

  // debug: returns dis-assembled 6502 instruction in [String nmemonic, int nextAddr]
  @override
  Pair<String, int> disasm(int addr) => const Pair("", 0);

  // debug: returns PC register
  @override
  int get programCounter => 0;

  // debug: set debug logging
  @override
  String get tracingState => "";

  // debug: dump vram
  @override
  List<int> get vram => List.empty();

  // debug: read mem
  @override
  int read(int addr) => 0;

  // debug: render BG
  @override
  ImageBuffer renderBg() => ImageBuffer.empty();

  @override
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) =>
      ImageBuffer.empty();

  @override
  ImageBuffer renderColorTable(int paletteNo) => ImageBuffer.empty();

  @override
  List<String> spriteInfo() => List.empty();
}

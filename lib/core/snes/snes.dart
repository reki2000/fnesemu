// Dart imports:
import 'dart:typed_data';

// Project imports:
import 'package:fnesemu/util/int.dart';

import '../core.dart';
import '../disc.dart';
import '../pad_button.dart';
import '../sram.dart';
import '../types.dart';
import 'component/bus.dart';
import 'component/cpu.dart';
import 'component/cpu_debug.dart';
import 'component/pad.dart';
import 'component/ppu.dart';
import 'rom/snes_file.dart';

/// main class for SNES emulation.
///
/// milestone 2 scope: 65816 CPU + bus (WRAM/ROM/SRAM) + a minimal MMIO/NMI
/// stub run end-to-end so CPU test ROMs can be traced. the PPU only produces
/// a fixed blank frame (no BG/sprite/Mode7 rendering yet) and SPC700/DSP
/// audio is not wired up.
class Snes implements Core {
  Snes() {
    bus = Bus();
    cpu = Cpu(bus);
    ppu = Ppu();
    bus.ppu = ppu;
  }

  late final Bus bus;
  late final Cpu cpu;
  late final Ppu ppu;

  // approximate NTSC SNES master clock / cpu clock (fast-rom not modeled yet)
  static const masterClock = 21477270;
  static const cpuClock = masterClock ~/ 6; // ~3.58MHz slow-rom

  static const scanlinesInFrame_ = 262;
  static const cpuCyclesInScanline = cpuClock ~/ 60 ~/ scanlinesInFrame_;

  @override
  int get systemClockHz => cpuClock;

  @override
  int get scanlinesInFrame => scanlinesInFrame_;

  @override
  int get clocksInScanline => cpuCyclesInScanline;

  @override
  List<CpuInfo> get cpuInfos => [CpuInfo.ofR3000(0, "65816")];

  int _scanline = 0;
  int _nextScanlineCycle = 0;

  void Function(AudioBuffer) _onAudio = (_) {};

  /// exec 1 cpu instruction, advance the scanline counter / vblank when
  /// enough cycles have passed.
  @override
  ExecResult exec(bool _) {
    if (!cpu.exec()) {
      return ExecResult(cpu.cycle, true, false);
    }

    bool rendered = false;
    if (cpu.cycle >= _nextScanlineCycle) {
      ppu.execScanline(_scanline);
      _scanline++;
      _nextScanlineCycle += cpuCyclesInScanline;
      rendered = true;

      if (_scanline == 225) {
        bus.enterVBlank();
      } else if (_scanline >= scanlinesInFrame_) {
        _scanline = 0;
        bus.leaveVBlank();
      }
    }

    return ExecResult(cpu.cycle, false, rendered);
  }

  /// returns screen buffer as 256x224 argb (currently a fixed placeholder)
  @override
  ImageBuffer imageBuffer() =>
      ImageBuffer(Ppu.width, Ppu.height, ppu.buffer.buffer.asUint8List());

  @override
  onAudio(void Function(AudioBuffer) onAudio) {
    _onAudio = onAudio;
  }

  @override
  void reset() {
    _scanline = 0;
    _nextScanlineCycle = cpuCyclesInScanline;
    ppu.reset();
    bus.onReset();
  }

  @override
  void padDown(int id, PadButton k) => bus.pad.keyDown(id, k);
  @override
  void padUp(int id, PadButton k) => bus.pad.keyUp(id, k);

  @override
  List<PadButton> get buttons => SnesPad.buttons;

  @override
  void setDisc(Disc disc) {} // cartridge-only; no disc support

  @override
  void setSram(Sram sram) {
    _sram = sram;
  }

  String crc = "";
  Sram _sram = Sram();

  // loads an .sfc/.smc rom image. throws if the header looks invalid.
  @override
  void setRom(Uint8List body) {
    final file = SnesFile()..load(body);
    crc = file.crc;
    bus.setRom(file);

    if (file.hasBattery && file.sramSize > 0) {
      _sram.init(crc, bus.sram);
      bus.sramRead = _sram.read8;
      bus.sramWrite = _sram.write8;
    }

    reset();
  }

  // ---------------------------------------------------------------- debug
  @override
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    return cpu.dump(showStack: showStack);
  }

  @override
  (String, int) disasm(int cpuNo, int addr) => cpu.dumpDisasm(addr);

  @override
  int programCounter(int cpuNo) => cpu.regs.pbr.shl16 | cpu.regs.pc;

  @override
  int stackPointer(int cpuNo) => cpu.regs.s;

  @override
  TraceLog trace(int cpuNo) => cpu.trace();

  @override
  List<int> get vram => const [];

  @override
  int read(int cpuNo, int addr) => bus.read(addr);

  @override
  ImageBuffer renderBg() => ImageBuffer.empty();

  @override
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) =>
      ImageBuffer.empty();

  @override
  ImageBuffer renderColorTable(int paletteNo) => ImageBuffer.empty();

  @override
  List<String> spriteInfo() => const [];
}

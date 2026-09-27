// Dart imports:
import 'dart:typed_data';

// Project imports:
import 'package:fnesemu/util/int.dart';

import '../core.dart';
import '../disc.dart';
import '../pad_button.dart';
import '../sram.dart';
import '../types.dart';
import 'component/apu.dart';
import 'component/bus.dart';
import 'component/cpu.dart';
import 'component/cpu_debug.dart';
import 'component/dma.dart';
import 'component/pad.dart';
import 'component/ppu.dart';
import 'component/ppu_render.dart';
import 'rom/snes_file.dart';

/// main class for SNES emulation.
///
/// 65816 CPU + bus (WRAM/ROM/SRAM) + DMA/HDMA + PPU (BG modes 0-4/7, OBJ,
/// windows, color math, mosaic) + SPC700/DSP audio (BRR, ADSR, noise,
/// simplified echo). Mode 5/6 hi-res is a documented approximation - see
/// ppu.dart/dsp.dart class docs for exact gaps (Gaussian interpolation,
/// FIR filter, EXTBG, direct color, vertical mosaic).
class Snes implements Core {
  Snes() {
    bus = Bus();
    cpu = Cpu(bus);
    ppu = Ppu();
    dma = Dma(bus);
    apu = Apu();
    bus.ppu = ppu;
    bus.dma = dma;
    bus.apu = apu;
    bus.inHBlank = () =>
        _nextScanlineCycle - cpu.cycle <= _cpuCyclesInHBlank;
  }

  late final Bus bus;
  late final Cpu cpu;
  late final Ppu ppu;
  late final Dma dma;
  late final Apu apu;

  // approximate NTSC SNES master clock / cpu clock (fast-rom not modeled yet)
  static const masterClock = 21477270;
  static const cpuClock = masterClock ~/ 6; // ~3.58MHz slow-rom

  static const scanlinesInFrame_ = 262;
  static const cpuCyclesInScanline = cpuClock ~/ 60 ~/ scanlinesInFrame_;

  // hblank covers roughly the last 67 of the 341 dots of a scanline
  static const _cpuCyclesInHBlank = cpuCyclesInScanline * 67 ~/ 341;

  @override
  int get systemClockHz => cpuClock;

  @override
  int get scanlinesInFrame => scanlinesInFrame_;

  @override
  int get clocksInScanline => cpuCyclesInScanline;

  @override
  List<CpuInfo> get cpuInfos => [CpuInfo.ofM68(0, "65816")];

  int _scanline = 0;
  int _nextScanlineCycle = 0;
  int _lastApuCycle = 0;
  int _nextAudioFlushCycle = 0;

  void Function(AudioBuffer) _onAudio = (_) {};

  /// exec 1 cpu instruction, advance the scanline counter / vblank when
  /// enough cycles have passed.
  @override
  ExecResult exec(bool _) {
    if (!cpu.exec()) {
      return ExecResult(cpu.cycle, true, false);
    }

    apu.exec(cpu.cycle - _lastApuCycle, cpuClock);
    _lastApuCycle = cpu.cycle;
    if (cpu.cycle >= _nextAudioFlushCycle) {
      _nextAudioFlushCycle += cpuCyclesInScanline * 16;
      final buf = apu.flush();
      if (buf.isNotEmpty) {
        _onAudio(AudioBuffer(Apu.dspSampleHz, 2, buf));
      }
    }

    bool rendered = false;
    if (cpu.cycle >= _nextScanlineCycle) {
      if (_scanline == 0) dma.hdmaInit();
      ppu.renderScanline(_scanline);
      // HDMA runs in this line's hblank, so it affects the following line
      if (_scanline <= Ppu.height) dma.hdmaScanline();
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

  /// returns screen buffer as 256x224 rgba (modes 0/1/3 + sprites render;
  /// other modes show backdrop only - see Ppu's class doc)
  @override
  ImageBuffer imageBuffer() => ImageBuffer(
      ppu.width, Ppu.height, ppu.buffer.buffer.asUint8List(),
      displayWidth_: Ppu.widthNormal);

  @override
  onAudio(void Function(AudioBuffer) onAudio) {
    _onAudio = onAudio;
  }

  @override
  void reset() {
    _scanline = 0;
    _nextScanlineCycle = cpuCyclesInScanline;
    _lastApuCycle = 0;
    _nextAudioFlushCycle = 0;
    ppu.reset();
    dma.reset();
    apu.reset();
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

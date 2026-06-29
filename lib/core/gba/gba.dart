// Dart imports:
import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import '../core.dart';
import '../disc.dart';
import '../pad_button.dart';
import '../sram.dart';
import '../types.dart';
import 'arm7tdmi/arm7.dart';
import 'arm7tdmi/arm_disasm.dart';
import 'bus.dart';
import 'irq.dart';
import 'ppu.dart';

/// Game Boy Advance core.
///
/// Stage 1: integrates ARM7TDMI + memory bus into the Core abstraction and
/// produces a (blank) 240x160 frame. CPU decode, PPU and APU are added in
/// later stages.
class Gba implements Core {
  late final Bus bus;
  late final Arm7 cpu;
  late final Ppu ppu;

  static const screenWidth = 240;
  static const screenHeight = 160;

  // GBA system clock 16.78MHz
  static const _clockHz = 16 * 1024 * 1024; // 16777216
  static const _cyclesPerScanline = 1232;
  static const _scanlines = 228; // 160 visible + 68 vblank

  Gba() {
    bus = Bus();
    cpu = Arm7(bus);
    ppu = Ppu(bus);
  }

  @override
  int get systemClockHz => _clockHz;

  @override
  int get scanlinesInFrame => _scanlines;

  @override
  int get clocksInScanline => _cyclesPerScanline;

  @override
  List<CpuInfo> get cpuInfos => [const CpuInfo(0, "ARM7TDMI", 32, traceDiffs: 17)];

  int _clocks = 0;
  int _nextScanClock = 0;
  int _scanline = 0;

  static const _visibleLines = 160;

  @override
  ExecResult exec(bool step) {
    final result = ExecResult(0, false, false);

    final int consumed;
    if (bus.halted && !bus.irq.anyPending) {
      // CPU is halted: fast-forward to the next scanline so the timing IRQs
      // (VBlank/HBlank/VCount/Timer) have a chance to fire and wake it.
      consumed = (_nextScanClock - _clocks).clamp(1, _cyclesPerScanline);
    } else {
      bus.halted = false;
      consumed = cpu.step();
    }

    _clocks += consumed;
    bus.timers.tick(consumed);

    while (_clocks >= _nextScanClock) {
      _nextScanClock += _cyclesPerScanline;
      _endScanline();
      result.scanlineRendered = true;
    }

    if (bus.irq.pending) cpu.irq();

    result.elapsedClocks = _clocks;
    return result;
  }

  // advance the display by one scanline, updating DISPSTAT flags and firing the
  // HBlank/VBlank/VCount interrupts and DMA triggers.
  void _endScanline() {
    final line = _scanline;

    // HBlank for the line that just finished.
    bus.hblank = true;
    if (bus.hblankIrqEnabled) bus.irq.raise(IrqBit.hblank);
    if (line < _visibleLines) {
      _renderScanline(line);
      bus.dma.onHBlank();
    }

    // advance to the next line.
    _scanline++;
    if (_scanline >= _scanlines) _scanline = 0;
    bus.vcount = _scanline;
    bus.hblank = false;

    // VBlank flag covers lines 160..226 (not the last line).
    bus.vblank = _scanline >= _visibleLines && _scanline < _scanlines - 1;
    if (_scanline == _visibleLines) {
      if (bus.vblankIrqEnabled) bus.irq.raise(IrqBit.vblank);
      bus.dma.onVBlank();
    }

    // VCount match.
    if (_scanline == bus.vcountSetting && bus.vcountIrqEnabled) {
      bus.irq.raise(IrqBit.vcount);
    }

    _renderAudio();
  }

  // accumulate APU samples and push a stereo buffer once it fills up.
  final _audio = Float32List(2048 * 2); // interleaved L,R
  int _audioIndex = 0;

  void _renderAudio() {
    final samples = _clocks * bus.apu.sampleHz ~/ _clockHz - bus.apu.elapsedSamples;
    if (samples <= 0) return;

    if (_audioIndex + samples * 2 >= _audio.length) {
      _onAudio(AudioBuffer(bus.apu.sampleHz, 2, _audio.sublist(0, _audioIndex)));
      _audioIndex = 0;
    }

    final rendered = bus.apu.render(samples);
    for (int i = 0; i < rendered.length; i++) {
      _audio[_audioIndex++] = rendered[i];
    }
  }

  void _renderScanline(int line) => ppu.renderLine(line);

  @override
  ImageBuffer imageBuffer() => ppu.imageBuffer;

  void Function(AudioBuffer) _onAudio = (_) {};

  @override
  void onAudio(void Function(AudioBuffer) onAudio) => _onAudio = onAudio;

  @override
  void setDisc(Disc disc) {}

  @override
  void setSram(Sram sram) {}

  @override
  void reset() {
    bus.onReset();
    ppu.reset();
    // With a real BIOS, boot from the reset vector; otherwise HLE the boot so
    // the cartridge entry runs directly.
    if (bus.biosLoaded) {
      cpu.reset();
    } else {
      cpu.resetHle();
    }
    _clocks = 0;
    _nextScanClock = _cyclesPerScanline;
    _scanline = 0;
  }

  @override
  void padDown(int controllerId, PadButton k) => bus.pad.keyDown(controllerId, k);
  @override
  void padUp(int controllerId, PadButton k) => bus.pad.keyUp(controllerId, k);

  @override
  List<PadButton> get buttons => bus.pad.buttons;

  @override
  void setRom(Uint8List body) {
    bus.cart.load(body);
    reset();
  }

  @override
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    return "${cpu.dump()}\ntitle:${bus.cart.title} code:${bus.cart.gameCode}\n"
        "clk:$_clocks line:$_scanline vcnt:${bus.vcount} "
        "ie:${bus.irq.ie.x4} if:${bus.irq.if_.x4} ime:${bus.irq.ime} "
        "halt:${bus.halted}";
  }

  @override
  (String, int) disasm(int cpuNo, int addr) {
    final thumb = cpu.regs.thumb;
    if (thumb) {
      final op = bus.read16(addr & ~1);
      return ("${addr.x8}: ${op.x4}      ${Arm7Disasm.thumb(op, addr)}", addr + 2);
    }
    final op = bus.read32(addr & ~3);
    return ("${addr.x8}: ${op.x8}  ${Arm7Disasm.arm(op, addr)}", addr + 4);
  }

  @override
  int programCounter(int cpuNo) => cpu.regs.pc;

  @override
  int stackPointer(int cpuNo) => cpu.regs.r[13];

  @override
  TraceLog trace(int cpuNo) => TraceLog(
        cpu.regs.pc,
        cpu.cycles,
        disasm(0, cpu.regs.pc).$1.padRight(32),
        cpu.dump().replaceAll("\n", " "),
        [...cpu.regs.r, cpu.regs.cpsr],
      );

  @override
  List<int> get vram => bus.vram;

  @override
  int read(int cpuNo, int addr) => bus.read8(addr);

  @override
  ImageBuffer renderBg() => ImageBuffer.empty();

  @override
  ImageBuffer renderColorTable(int paletteNo) => ppu.renderColorTable();

  @override
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) =>
      ImageBuffer.empty();

  @override
  List<String> spriteInfo() => [];
}

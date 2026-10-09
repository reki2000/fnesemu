import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import '../cdrom_drive.dart';
import '../core.dart';
import '../pad_button.dart';
import '../sram.dart';
import '../types.dart';
import 'arm7tdmi/arm7.dart';
import 'arm7tdmi/arm_disasm.dart';
import 'bus.dart';
import 'irq.dart';
import 'ppu.dart';

/// gba core.
///
/// Stage 1: integrates ARM7TDMI + memory bus into the Core abstraction and
/// produces a (blank) 240x160 frame. CPU decode, PPU and APU are added in
/// later stages.
class Gba implements Core, FrameRunner {
  late final Bus bus;
  late final Arm7 cpu;
  late final Ppu ppu;

  static const screenWidth = 240;
  static const screenHeight = 160;

  // GBA system clock 16.78MHz
  static const _clockHz = 16 * 1024 * 1024; // 16777216
  static const _cyclesPerScanline = 1232;
  static const _hblankStart = 960; // cycles into the line where HBlank begins
  static const _scanlines = 228; // 160 visible + 68 vblank

  Gba() {
    bus = Bus();
    cpu = Arm7(bus);
    ppu = Ppu(bus);
  }

  /// when the BIOS is set, reset() boots from the BIOS reset vector instead
  /// of the HLE boot.
  @override
  void setBiosFiles(List<Uint8List> files) {
    if (files.isNotEmpty) {
      bus.loadBios(files.first);
    }
  }

  @override
  int get systemClockHz => _clockHz;

  @override
  int get scanlinesInFrame => _scanlines;

  @override
  int get clocksInScanline => _cyclesPerScanline;

  @override
  List<CpuInfo> get cpuInfos =>
      [const CpuInfo(0, "ARM7TDMI", 32, traceDiffs: 17)];

  int _clocks = 0;
  int _nextEventClock = 0; // next HBlank start or line end
  bool _inHblank = false;
  int _scanline = 0;

  static const _visibleLines = 160;

  @override
  ExecResult exec(bool step) {
    // Advancing also updates _rendered; capture the result after that update.
    final elapsedClocks = _advanceClocks();
    return ExecResult(elapsedClocks, false, _rendered);
  }

  bool _rendered = false;

  @override
  ExecResult runFrame(int scanlines) {
    var rendered = false;
    while (scanlines > 0) {
      _advanceClocks();
      rendered = _rendered;
      if (rendered) scanlines--;
    }
    return ExecResult(_clocks, false, rendered);
  }

  @pragma('vm:prefer-inline')
  int _advanceClocks() {
    _rendered = false;

    final int consumed;
    if (bus.halted && !bus.irq.anyPending) {
      // CPU is halted: fast-forward to the next display event so the timing
      // IRQs (VBlank/HBlank/VCount/Timer) have a chance to fire and wake it.
      consumed = (_nextEventClock - _clocks).clamp(1, _cyclesPerScanline);
    } else {
      bus.halted = false;
      consumed = cpu.step();
    }

    _clocks += consumed;
    bus.timers.tick(consumed);

    while (_clocks >= _nextEventClock) {
      if (!_inHblank) {
        _inHblank = true;
        _nextEventClock += _cyclesPerScanline - _hblankStart;
        _startHblank();
      } else {
        _inHblank = false;
        _nextEventClock += _hblankStart;
        _endScanline();
        _rendered = true;
      }
    }

    if (bus.irq.pending) cpu.irq();

    return _clocks;
  }

  // HBlank of the current line: DISPSTAT flag, interrupt, render and DMA.
  // The flag stays set until the line ends so that it can be polled.
  void _startHblank() {
    final line = _scanline;
    bus.hblank = true;
    if (bus.hblankIrqEnabled) bus.irq.raise(IrqBit.hblank);
    if (line < _visibleLines) {
      _renderScanline(line);
      bus.dma.onHBlank();
    }
  }

  // advance the display to the next scanline, updating DISPSTAT flags and
  // firing the VBlank/VCount interrupts and DMA triggers.
  void _endScanline() {
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
    final samples =
        _clocks * bus.apu.sampleHz ~/ _clockHz - bus.apu.elapsedSamples;
    if (samples <= 0) return;

    if (_audioIndex + samples * 2 >= _audio.length) {
      _onAudio(
          AudioBuffer(bus.apu.sampleHz, 2, _audio.sublist(0, _audioIndex)));
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

  Sram _sram = Sram();

  @override
  void setCdromDrive(CdromDrive drive) {}

  @override
  void setSram(Sram sram) => _sram = sram;

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
    _nextEventClock = _hblankStart;
    _inHblank = false;
    _scanline = 0;
  }

  @override
  void padDown(int controllerId, PadButton k) =>
      bus.pad.keyDown(controllerId, k);
  @override
  void padUp(int controllerId, PadButton k) => bus.pad.keyUp(controllerId, k);

  @override
  List<PadButton> get buttons => bus.pad.buttons;

  @override
  void setRom(Uint8List body) {
    bus.cart.load(body);
    bus.cart.initBackup(_sram);
    reset();
  }

  @override
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    return "${cpu.dump()}\ntitle:${bus.cart.title} code:${bus.cart.gameCode} "
        "save:${bus.cart.backup.type.name}\n"
        "clk:$_clocks line:$_scanline vcnt:${bus.vcount} "
        "ie:${bus.irq.ie.x4} if:${bus.irq.if_.x4} ime:${bus.irq.ime} "
        "halt:${bus.halted}";
  }

  @override
  (String, int) disasm(int cpuNo, int addr) {
    final thumb = cpu.regs.thumb;
    if (thumb) {
      final aligned = addr & ~1;
      final op = bus.read16(aligned);
      if (op & 0xf800 == 0xf000) {
        final next = bus.read16(aligned + 2);
        if (next & 0xf800 == 0xf800) {
          return (
            '${addr.x8}: ${op.x4} ${next.x4}  ${Arm7Disasm.thumb(op, aligned, nextHalfword: next)}',
            4
          );
        }
      } else if (op & 0xf800 == 0xf800) {
        final previous = bus.read16(aligned - 2);
        if (previous & 0xf800 == 0xf000) {
          return (
            '${addr.x8}: ${op.x4}      ${Arm7Disasm.thumb(previous, aligned - 2, nextHalfword: op)}',
            2
          );
        }
      }
      return ("${addr.x8}: ${op.x4}      ${Arm7Disasm.thumb(op, addr)}", 2);
    }
    final op = bus.read32(addr & ~3);
    return ("${addr.x8}: ${op.x8}  ${Arm7Disasm.arm(op, addr)}", 4);
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
      ppu.renderVram(useSecondBgColor, paletteNo);

  @override
  List<String> spriteInfo() => ppu.spriteInfo();
}

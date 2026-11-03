import 'dart:typed_data';

import '../../cdrom_drive.dart';
import '../../core.dart';
import '../../pad_button.dart';
import '../../sram.dart';
import '../../types.dart';
import '../../util/int.dart';
import '../../util/state.dart';
import '../../video_debug.dart';
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
class Snes extends Core {
  @override
  bool get hasPatternTables => true;

  @override
  List<DebugVideoLayer> get videoLayers => ppu.debugVideoLayers;
  @override
  List<DebugPatternTable> get patternTables => ppu.debugPatternTables;

  Snes() {
    bus = Bus(padPort);
    cpu = Cpu(bus);
    ppu = Ppu();
    dma = Dma(bus);
    apu = Apu();
    bus.ppu = ppu;
    bus.dma = dma;
    bus.apu = apu;
    bus.inHBlank = () => _nextScanlineCycle - cpu.cycle <= _cpuCyclesInHBlank;
    ppu.beam = () {
      final inLine = cpuCyclesInScanline - (_nextScanlineCycle - cpu.cycle);
      final dot = (inLine.clamp(0, cpuCyclesInScanline - 1) * 341) ~/
          cpuCyclesInScanline;
      return dot.shl16 | _scanline;
    };
  }

  late final Bus bus;
  late final Cpu cpu;
  late final Ppu ppu;
  late final Dma dma;
  late final Apu apu;

  // Nominal NTSC master clock. The CPU currently uses fixed six-clock cycles.
  static const masterClock = 21477270;
  static const cpuClock = masterClock ~/ 6; // Fixed CPU scheduling unit; memory wait states are not modeled.

  static const scanlinesInFrame_ = 262;
  static const cpuCyclesInScanline = cpuClock ~/ 60 ~/ scanlinesInFrame_;

  // hblank covers roughly the last 67 of the 341 dots of a scanline
  static const _cpuCyclesInHBlank = cpuCyclesInScanline * 67 ~/ 341;

  @override
  int get clocksPerFrame => clocksInScanline * scanlinesInFrame;

  @override
  int get systemClockHz => masterClock;

  @override
  int get scanlinesInFrame => scanlinesInFrame_;

  @override
  int get clocksInScanline => cpuCyclesInScanline * 6;

  @override
  List<CpuInfo> get cpuInfos => [CpuInfo.ofM68(0, "65816")];

  int _scanline = 0;
  int _frames = 0;
  int _nextScanlineCycle = 0;
  int _lastApuCycle = 0;
  int _nextAudioFlushCycle = 0;
  bool _timerFiredThisLine = false;

  void Function(AudioBuffer) _onAudio = (_) {};

  static const _stepContinues = 0;
  static const _stepRenderedLine = 1;
  static const _stepStopped = 2;

  /// exec 1 cpu instruction, advance the scanline counter / vblank when
  /// enough cycles have passed.
  @override
  ExecResult exec(bool _) {
    final status = _advance();
    return ExecResult(
        cpu.cycle * 6, status == _stepStopped, status == _stepRenderedLine);
  }

  @override
  ExecResult runFrame(int scanlines) {
    var rendered = false;
    while (scanlines > 0) {
      final status = _advance();
      if (status == _stepStopped) return ExecResult(cpu.cycle * 6, true, false);
      rendered = status == _stepRenderedLine;
      if (rendered) scanlines--;
    }
    return ExecResult(cpu.cycle * 6, false, rendered);
  }

  // Returns one of the _step* codes without allocating an instruction result.
  @pragma('vm:prefer-inline')
  int _advance() {
    if (!cpu.exec()) return _stepStopped;
    bus.sa1?.run(cpu.cycle);
    bus.superFx?.run(cpu.cycle);

    apu.exec(cpu.cycle - _lastApuCycle, cpuClock);
    _lastApuCycle = cpu.cycle;
    if (!_timerFiredThisLine &&
        bus.timerReached(_scanline, _nextScanlineCycle - cpuCyclesInScanline,
            cpu.cycle, cpuCyclesInScanline)) {
      _timerFiredThisLine = true;
    }
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
      if (_scanline <= ppu.displayLines) dma.hdmaScanline();
      _scanline++;
      _timerFiredThisLine = false;
      _nextScanlineCycle += cpuCyclesInScanline;
      rendered = true;

      if (_scanline == ppu.displayLines + 1) {
        ppu.onVBlank();
        bus.enterVBlank();
      } else if (_scanline >= scanlinesInFrame_) {
        _scanline = 0;
        ppu.oddField = !ppu.oddField;
        bus.leaveVBlank();
        if (++_frames % 60 == 0) bus.spc7110?.tickSecond();
      }
    }

    return rendered ? _stepRenderedLine : _stepContinues;
  }

  /// returns screen buffer as 256x224 rgba (modes 0/1/3 + sprites render;
  /// other modes show backdrop only - see Ppu's class doc)
  @override
  ImageBuffer imageBuffer() => ImageBuffer(ppu.width, ppu.outputHeight, ppu.buffer,
      displayWidth_: Ppu.widthNormal, displayHeight: ppu.displayLines);

  @override
  void onAudio(void Function(AudioBuffer) onAudio) {
    _onAudio = onAudio;
  }

  @override
  void reset() {
    _scanline = 0;
    _nextScanlineCycle = cpuCyclesInScanline;
    _lastApuCycle = 0;
    _nextAudioFlushCycle = 0;
    _timerFiredThisLine = false;
    ppu.reset();
    dma.reset();
    apu.reset();
    bus.onReset();
  }

  @override
  List<PadButton> get buttons => SnesPad.buttons;

  @override
  void setCdromDrive(CdromDrive drive) {}

  @override
  void setBiosFiles(List<Uint8List> files) {}

  @override
  void dispose() {}

  static const _stateVersion = 1;

  @override
  Uint8List saveState() {
    final w = StateWriter('snes', _stateVersion, stateMediaHash(crc.codeUnits));
    w.section('snes');
    w.ints([_scanline, _frames, _nextScanlineCycle, _lastApuCycle, _nextAudioFlushCycle]);
    w.boolean(_timerFiredThisLine);
    cpu.saveState(w);
    bus.saveState(w);
    ppu.saveState(w);
    apu.saveState(w);
    w.section('snes-chips');
    w.boolean(bus.sdd1 != null);
    w.boolean(bus.sa1 != null);
    w.boolean(bus.superFx != null);
    w.boolean(bus.dsp1 != null);
    w.boolean(bus.cx4 != null);
    w.boolean(bus.spc7110 != null);
    bus.sdd1?.saveState(w);
    bus.sa1?.saveState(w);
    bus.superFx?.saveState(w);
    bus.dsp1?.saveState(w);
    bus.cx4?.saveState(w);
    bus.spc7110?.saveState(w);
    return w.take();
  }

  /// The header and media are validated before any component is applied, and the cartridge chip set must match before the chip sections are read; a failure after that leaves a partially restored core, so reset it before running again.
  @override
  void loadState(Uint8List state) {
    final s = StateReader(state, 'snes', _stateVersion, stateMediaHash(crc.codeUnits));
    s.section('snes');
    final v = s.ints();
    if (v.length != 5) throw const StateMismatch('snes state layout');
    final timerFired = s.boolean();
    cpu.loadState(s);
    bus.loadState(s);
    ppu.loadState(s);
    apu.loadState(s);
    s.section('snes-chips');
    final chips = [
      s.boolean(), s.boolean(), s.boolean(), s.boolean(), s.boolean(),
      s.boolean(),
    ];
    if (chips[0] != (bus.sdd1 != null) ||
        chips[1] != (bus.sa1 != null) ||
        chips[2] != (bus.superFx != null) ||
        chips[3] != (bus.dsp1 != null) ||
        chips[4] != (bus.cx4 != null) ||
        chips[5] != (bus.spc7110 != null)) {
      throw const StateMismatch('snes cartridge chips differ');
    }
    bus.sdd1?.loadState(s);
    bus.sa1?.loadState(s);
    bus.superFx?.loadState(s);
    bus.dsp1?.loadState(s);
    bus.cx4?.loadState(s);
    bus.spc7110?.loadState(s);
    s.end();
    _scanline = v[0];
    _frames = v[1];
    _nextScanlineCycle = v[2];
    _lastApuCycle = v[3];
    _nextAudioFlushCycle = v[4];
    _timerFiredThisLine = timerFired;
  }

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
  TraceLog trace(int cpuNo) => cpu.trace(clock: cpu.cycle * 6);

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

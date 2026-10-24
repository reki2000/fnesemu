import 'dart:typed_data';

import '../../cdrom_drive.dart';
import '../../core.dart';
import '../../pad_button.dart';
import '../../sram.dart';
import '../../trace_flow.dart';
import '../../types.dart';
import '../../util/crc32.dart';
import '../../util/disasm.dart';
import '../../util/int.dart';
import '../../video_debug.dart';
import 'apu.dart';
import 'bus.dart';
import 'cartridge.dart';
import 'cpu.dart';
import 'disasm.dart';
import 'ppu.dart';
import 'video_debug.dart';

/// main class of the gb core. integrates cpu/ppu/apu/timer/cartridge
class Gb extends Core {
  @override
  bool get hasPatternTables => true;

  @override
  List<DebugVideoLayer> get videoLayers => ppu.debugVideoLayers;
  @override
  List<DebugPatternTable> get patternTables => ppu.debugPatternTables;

  final bus = Bus();

  Cpu get cpu => bus.cpu;
  Ppu get ppu => bus.ppu;
  Apu get apu => bus.apu;

  static const clockHz = 4194304;

  @override
  int get systemClockHz => clockHz;

  @override
  int get scanlinesInFrame => Ppu.linesInFrame;

  @override
  int get clocksInScanline => Ppu.clocksInLine;

  @override
  get cpuInfos => [const CpuInfo(0, "SM83", 16)];

  // scanline boundary in system clocks, which stay at 4.19MHz in GBC double speed
  int _nextScanlineClocks = 0;

  Sram? _sram;

  // ROM CRC
  String crc = "";

  static const _stepContinues = 0;
  static const _stepRenderedLine = 1;
  static const _stepStopped = 2;

  /// exec 1 cpu instruction and render image/audio if enough cycles passed
  @override
  ExecResult exec(bool step) {
    final status = _advance();
    return ExecResult(
        bus.clocks, status == _stepStopped, status == _stepRenderedLine);
  }

  @override
  ExecResult runFrame(int scanlines) {
    var rendered = false;
    while (scanlines > 0) {
      final status = _advance();
      if (status == _stepStopped) return ExecResult(bus.clocks, true, false);
      rendered = status == _stepRenderedLine;
      if (rendered) scanlines--;
    }
    return ExecResult(bus.clocks, false, rendered);
  }

  // Returns one of the _step* codes without allocating an instruction result.
  @pragma('vm:prefer-inline')
  int _advance() {
    if (!cpu.exec()) return _stepStopped;

    var rendered = false;
    if (bus.dotClocks >= _nextScanlineClocks) {
      _nextScanlineClocks += Ppu.clocksInLine;
      rendered = true;
    }

    if (apu.bufferFull) {
      _onAudio(AudioBuffer(Apu.sampleRate, 2, apu.takeBuffer()));
    }

    return rendered ? _stepRenderedLine : _stepContinues;
  }

  @override
  ImageBuffer imageBuffer() => ppu.imageBuffer;

  void Function(AudioBuffer) _onAudio = (_) {};

  @override
  void onAudio(void Function(AudioBuffer) onAudio) {
    _onAudio = onAudio;
  }

  @override
  void setCdromDrive(CdromDrive drive) {}

  @override
  void setBiosFiles(List<Uint8List> files) {}

  @override
  void dispose() {}

  @override
  void setSram(Sram sram) {
    _sram = sram;
  }

  @override
  void reset() {
    bus.reset();
    _nextScanlineClocks = Ppu.clocksInLine;
  }

  @override
  void padDown(int controllerId, PadButton k) =>
      bus.pad.keyDown(controllerId, k);

  @override
  void padUp(int controllerId, PadButton k) => bus.pad.keyUp(controllerId, k);

  @override
  List<PadButton> get buttons => bus.pad.buttons;

  /// loads a rom image. throws when the cartridge type is not supported.
  /// GBC-flagged images run in GBC mode, others in DMG mode.
  @override
  void setRom(Uint8List body) {
    final cart = Cartridge.of(body);

    crc = crc32Hex(body);
    cart.attachRam(_sram, "gb-$crc");

    bus.cart = cart;
    bus.gbc = cart.header.gbc;
    reset();
  }

  /// debug: returns the emulator's internal status report
  @override
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    final (asm, _) = disasm(0, cpu.pc);
    final stack = showStack
        ? "\n${List.generate(16, (i) => bus.read((cpu.sp + i).mask16).x2).join(" ")}"
        : "";
    final hram = showZeroPage
        ? "\n${List.generate(8, (row) => List.generate(16, (i) => bus.read(0xff80 + row * 16 + i).x2).join(" ")).join("\n")}"
        : "";

    return "$asm\n${cpu.dump()}$stack$hram\n"
        "ie:${bus.ie.x2} if:${bus.intFlag.x2} "
        "div:${bus.timer.counter.shr8.x2} tima:${bus.timer.tima.x2} "
        "tma:${bus.timer.tma.x2} tac:${bus.timer.tac.x2} "
        "clk:${bus.clocks.format3}\n"
        "${ppu.dump()}\n"
        "${bus.cart.dump()} ${bus.cart.header}\n"
        "${showApu ? apu.dump() : ""}";
  }

  // debug: returns dis-assembled instruction in (String mnemonic, int nextAddr)
  @override
  (String, int) disasm(int cpuNo, int addr) {
    final (inst, len) = Disasm.disasm(bus.read, addr);
    final bytes =
        List.generate(len, (i) => bus.read((addr + i).mask16).x2).join(' ');
    return (
      formatDisasm(addr.x4, bytes, inst, codeWidth: 8),
      (addr + len).mask16
    );
  }

  @override
  int programCounter(int cpuNo) => cpu.pc;

  @override
  int stackPointer(int cpuNo) => cpu.sp;

  @override
  TraceLog trace(int cpuNo) => TraceLog(
      cpu.pc,
      bus.clocks,
      disasm(0, cpu.pc).$1.padRight(36),
      cpu.dump(),
      [cpu.af, cpu.bc, cpu.de, cpu.hl, cpu.sp],
      frame: ppu.frames,
      scanline: ppu.ly,
      flow: traceZ80Flow(bus.read(cpu.pc), cpu.pc, cpu.af & 255,
          gb: true,
          operand: bus.read((cpu.pc + 1) & 0xffff) |
              bus.read((cpu.pc + 2) & 0xffff) << 8));

  // debug: bank 0 only
  @override
  List<int> get vram => ppu.vram.sublist(0, Ppu.vramBankSize);

  @override
  int read(int cpuNo, int addr) => bus.read(addr.mask16);

  @override
  ImageBuffer renderBg() => ppu.renderBg();

  @override
  List<String> spriteInfo() => ppu.spriteInfo();

  @override
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) =>
      ppu.renderVram(paletteNo);

  @override
  ImageBuffer renderColorTable(int paletteNo) => ppu.renderColorTable();
}

import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:fnesemu/util/int.dart';

import '../core.dart';
import '../disc.dart';
import '../pad_button.dart';
import '../sram.dart';
import '../types.dart';
import 'apu.dart';
import 'bus.dart';
import 'cartridge.dart';
import 'cpu.dart';
import 'disasm.dart';
import 'ppu.dart';

/// main class of the gb core. integrates cpu/ppu/apu/timer/cartridge
class Gb implements Core {
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
  get cpuInfos => [const CpuInfo(0, "SM83", 16, traceDiffs: 2)];

  int _nextScanlineClocks = 0;

  Sram? _sram;

  // ROM CRC
  String crc = "";

  /// exec 1 cpu instruction and render image/audio if enough cycles passed
  @override
  ExecResult exec(bool step) {
    if (!cpu.exec()) {
      return ExecResult(bus.clocks, true, false);
    }

    var rendered = false;
    if (bus.clocks >= _nextScanlineClocks) {
      _nextScanlineClocks += Ppu.clocksInLine;
      rendered = true;
    }

    if (apu.bufferFull) {
      _onAudio(AudioBuffer(Apu.sampleRate, 2, apu.takeBuffer()));
    }

    return ExecResult(bus.clocks, false, rendered);
  }

  @override
  ImageBuffer imageBuffer() => ppu.imageBuffer;

  void Function(AudioBuffer) _onAudio = (_) {};

  @override
  void onAudio(void Function(AudioBuffer) onAudio) {
    _onAudio = onAudio;
  }

  @override
  void setDisc(Disc disc) {}

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
  @override
  void setRom(Uint8List body) {
    final cart = Cartridge.of(body);
    if (cart.header.gbcOnly) {
      throw Exception("GBC-only cartridges are not supported");
    }

    crc = (Crc32()..add(body.toList())).close().map((v) => v.x2).join();
    cart.attachRam(_sram, "gb-$crc");

    bus.cart = cart;
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
        ? "\n${List.generate(16, (i) => bus.read((cpu.sp + i) & 0xffff).x2).join(" ")}"
        : "";
    final hram = showZeroPage
        ? "\n${List.generate(8, (row) => List.generate(16, (i) => bus.read(0xff80 + row * 16 + i).x2).join(" ")).join("\n")}"
        : "";

    return "$asm\n${cpu.dump()}$stack$hram\n"
        "ie:${bus.ie.x2} if:${bus.intFlag.x2} "
        "div:${(bus.timer.counter >> 8).x2} tima:${bus.timer.tima.x2} "
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
    final bytes = List.generate(
        3, (i) => i < len ? bus.read((addr + i) & 0xffff).x2 : "  ").join(" ");
    return ("${addr.x4}: $bytes  $inst", (addr + len) & 0xffff);
  }

  @override
  int programCounter(int cpuNo) => cpu.pc;

  @override
  int stackPointer(int cpuNo) => cpu.sp;

  @override
  TraceLog trace(int cpuNo) => TraceLog(cpu.pc, bus.clocks,
      disasm(0, cpu.pc).$1.padRight(36), cpu.dump(),
      [cpu.af, cpu.bc, cpu.de, cpu.hl, cpu.sp],
      frame: ppu.frames, scanline: ppu.ly);

  @override
  List<int> get vram => ppu.vram;

  @override
  int read(int cpuNo, int addr) => bus.read(addr & 0xffff);

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

import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';
import 'package:fnesemu/util/util.dart';

import '../../util/debug.dart';
import '../core.dart';
import '../pad_button.dart';
import '../types.dart';
import 'r3000/r3000.dart';
import 'r3000/r3000_disasm.dart';
import 'bus.dart';
import 'gpu.dart';

class Ps extends Core {
  final Bus bus;
  late final R3000 cpu;
  late final Gpu gpu;

  int initAddress = 0xbfc00000;

  Ps() : bus = Bus() {
    cpu = R3000(bus);
    gpu = Gpu(bus);
    bus.gpu = gpu;
    bus.cpu = cpu;
  }

  static const _systemClockHz = 33868800; // 33.8688MHz

  @override
  int get systemClockHz => _systemClockHz;

  @override
  int get clocksInScanline => _systemClockHz ~/ 60 ~/ Gpu.scanlinesInFrame;

  @override
  int get scanlinesInFrame => Gpu.scanlinesInFrame;

  @override
  List<CpuInfo> get cpuInfos => [CpuInfo.ofR3000(0, "R3000")];

  @override
  void setRom(Uint8List body) {
    if (body.getUInt32BE(0) == 0x50532d58 &&
        body.getUInt32BE(4) == 0x20455845) {
      cpu.exe = body;
      debugLog("loaded PS-EXE");
      return;
    }

    bus.rom.setAll(0, body);
  }

  int nextScanlineClock = 0;
  int nextDmaClock = 0;

  @override
  ExecResult exec(bool step) {
    cpu.step();

    if (cpu.clocks > nextScanlineClock) {
      nextScanlineClock += clocksInScanline;
      gpu.renderScanline();
      return ExecResult(cpu.clocks, false, true);
    }

    if (cpu.clocks > nextDmaClock) {
      nextDmaClock += 1000;
      bus.execDma(1000);
    }

    return ExecResult(cpu.clocks, false, false);
  }

  @override
  void reset() {
    cpu.reset();
    cpu.pc = initAddress;
    cpu.nextPc = initAddress.inc4.mask32;

    nextScanlineClock = 0;
  }

  @override
  ImageBuffer imageBuffer() => gpu.imageBuffer;

  @override
  onAudio(void Function(AudioBuffer p1) onAudio) {}

  @override
  List<PadButton> get buttons => [];

  @override
  void padDown(int controllerId, PadButton k) {}

  @override
  void padUp(int controllerId, PadButton k) {}

  @override
  int programCounter(int _) => cpu.pc;

  @override
  int stackPointer(int _) => cpu.r[29];

  @override
  (String, int) disasm(int _, int addr) {
    addr = addr.mask32 & ~0x03;
    final inst32 = bus.read32(addr);
    return ("${addr.hex32}: ${inst32.hex32} ${DisasmR3000.disasm(inst32)}", 4);
  }

  @override
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    final asm = disasm(0, cpu.pc).$1;
    final regs = cpu.dump();
    final gpuStat = gpu.dump();
    final dma = range(0, 7).map((ch) => "$ch:${bus.dma[ch].dump()}").join("\n");
    return "$asm\n$regs cy:${cpu.clocks}\n\n$dma\n\n$gpuStat";
  }

  @override
  TraceLog trace(int cpuNo) => TraceLog(
      cpu.pc,
      cpu.clocks,
      disasm(0, cpu.pc).$1.padRight(44),
      cpu.dump().replaceAll("\n", " "),
      [for (int i = 0; i < 32; i++) cpu.r[i]]);

  @override
  int read(int _, int addr) => bus.read8(addr);

  @override
  ImageBuffer renderBg() => ImageBuffer.empty();

  @override
  ImageBuffer renderColorTable(int paletteNo) => ImageBuffer.empty();

  @override
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) =>
      ImageBuffer.empty();

  @override
  List<String> spriteInfo() => [];

  @override
  List<int> get vram => [];
}

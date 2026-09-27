import 'dart:math' as math;
import 'dart:typed_data';

import '../../util/debug.dart';
import '../core.dart';
import '../disc.dart';
import '../pad_button.dart';
import '../sram.dart';
import '../types.dart';
import 'bus.dart';
import 'cpu.dart';
import 'rom.dart';

/// Direct-boot experimental N64 core for small integer-only homebrew.
class N64 extends Core {
  final bus = N64Bus();
  late final cpu = Vr4300(bus);
  N64Rom? _rom;
  int _nextLine = 0, _frame = 0;

  @override
  int get systemClockHz => 93750000;
  @override
  int get scanlinesInFrame => 262;
  @override
  int get clocksInScanline => systemClockHz ~/ 60 ~/ scanlinesInFrame;
  @override
  List<CpuInfo> get cpuInfos => [const CpuInfo(0, 'VR4300', 32, traceDiffs: 4)];

  @override
  void setRom(Uint8List body) {
    final rom = N64Rom(body);
    _rom = rom;
    bus.rom = rom.bytes;
  }

  @override
  void reset() {
    final rom = _rom;
    if (rom == null) throw StateError('N64 ROM not loaded');
    bus.reset();
    // Deliberately bypass IPL/CIC. Only the first MiB of the payload is copied.
    final destination = rom.entryPoint & 0x1fffffff;
    final length = math.min(
      0x100000,
      math.min(rom.bytes.length - 0x1000, bus.ram.length - destination),
    );
    bus.ram.setRange(destination, destination + length, rom.bytes, 0x1000);
    cpu.reset(rom.entryPoint);
    _nextLine = clocksInScanline;
    _frame = 0;
    debugStatus.clock = debugStatus.frame = debugStatus.scanline = 0;
    debugStatus.pc = cpu.pc;
  }

  @override
  ExecResult exec(bool step) {
    cpu.step();
    var line = false;
    if (cpu.clocks >= _nextLine) {
      _nextLine += clocksInScanline;
      bus.scanline++;
      if (bus.scanline == scanlinesInFrame) {
        bus.scanline = 0;
        _frame++;
      }
      line = true;
    }
    debugStatus.clock = cpu.clocks;
    debugStatus.frame = _frame;
    debugStatus.scanline = bus.scanline;
    debugStatus.pc = cpu.pc;
    return ExecResult(cpu.clocks, cpu.stopReason != null, line);
  }

  @override
  ImageBuffer imageBuffer() => bus.image();
  @override
  void onAudio(void Function(AudioBuffer) onAudio) {}
  @override
  void setDisc(Disc disc) {}
  @override
  void setSram(Sram sram) {}
  // Controller SI/PIF protocol is not implemented yet.
  @override
  List<PadButton> get buttons => [];
  @override
  void padDown(int controllerId, PadButton k) {}
  @override
  void padUp(int controllerId, PadButton k) {}
  @override
  int programCounter(int cpuNo) => cpu.pc;
  @override
  int stackPointer(int cpuNo) => cpu.address(cpu.r[29]);
  @override
  (String, int) disasm(int cpuNo, int addr) => (
    '${addr.toRadixString(16).padLeft(8, '0')}: .word 0x${bus.read(addr, 4).toRadixString(16).padLeft(8, '0')}',
    4,
  );
  @override
  TraceLog trace(int cpuNo) => TraceLog(
    cpu.pc,
    cpu.clocks,
    disasm(cpuNo, cpu.pc).$1,
    dump(),
    [cpu.pc, ...cpu.r.map(cpu.address)],
    frame: _frame,
    scanline: bus.scanline,
  );
  @override
  String dump({
    bool showZeroPage = false,
    bool showSpriteVram = false,
    bool showStack = false,
    bool showApu = false,
  }) =>
      'N64 ${_rom?.title ?? ''} (experimental direct boot)\n'
      'PC:${cpu.pc.toRadixString(16)} cycles:${cpu.clocks}\n'
      '${List.generate(32, (i) => 'r$i:${cpu.r[i].toUnsigned(64).toRadixString(16).padLeft(16, '0')}').join(' ')}\n'
      '${cpu.stopReason ?? ''}';
  @override
  int read(int cpuNo, int addr) => bus.read8(addr);
  @override
  List<int> get vram => bus.ram;
  @override
  ImageBuffer renderBg() => imageBuffer();
  @override
  List<String> spriteInfo() => [];
  @override
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) => imageBuffer();
  @override
  ImageBuffer renderColorTable(int paletteNo) => ImageBuffer.empty();
}

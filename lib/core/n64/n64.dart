import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import '../../util/debug.dart';
import '../core.dart';
import '../disc.dart';
import '../pad_button.dart';
import '../sram.dart';
import '../types.dart';
import 'bus.dart';
import 'cpu.dart';
import 'rom.dart';
import 'graphics.dart';
import 'audio.dart';

/// Independent N64 core with a VR4300 interpreter and GBI/audio task HLE.
class N64 extends Core {
  final bus = N64Bus();
  late final cpu = Vr4300(bus);
  late final graphics = N64Graphics(bus);
  late final audio = N64Audio(bus);
  N64() {
    bus.onDp = (start, end) => graphics.commands(start, end);
    bus.onTask = () {
      final task = ByteData.sublistView(bus.sp, 0xfc0);
      final type = task.getUint32(0);
      if (type == 1) {
        graphics.task(task.getUint32(48) & 0x7fffff, task.getUint32(52),
            task.getUint32(24) & 0x7fffff, task.getUint32(28));
      } else if (type == 2) {
        audio.task(task.getUint32(48) & 0x7fffff, task.getUint32(52),
            newer: _rom?.bytes[0x3f] == 3);
      } else {
        throw UnsupportedError('RSP task type $type');
      }
    };
  }
  N64Rom? _rom;
  int _nextLine = 0, _frame = 0;
  final _result = ExecResult(0, false, false);

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
    bus.sram?.init(
        'n64_${rom.bytes.sublist(0x10, 0x18).map((v) => v.x2).join()}',
        Uint8List(512)..fillRange(0, 512, 255));
  }

  @override
  void reset() {
    final rom = _rom;
    if (rom == null) throw StateError('N64 ROM not loaded');
    bus.reset();
    graphics.reset();
    audio.reset();
    // Deliberately bypass IPL/CIC. Only the first MiB of the payload is copied.
    final destination = rom.entryPoint & 0x1fffffff;
    final length = math.min(
      0x100000,
      math.min(rom.bytes.length - 0x1000, bus.ram.length - destination),
    );
    bus.ram.setRange(destination, destination + length, rom.bytes, 0x1000);
    cpu.reset(rom.entryPoint);
    bus.ramWrite(0x318, 0x800000, 4);
    bus.ramWrite(0x300, 1, 4); // osTvType: NTSC
    bus.ramWrite(0x304, 0, 4); // osRomType: cartridge
    bus.ramWrite(0x308, 0xb0000000, 4); // osRomBase
    bus.ramWrite(0x30c, 0, 4); // osResetType
    bus.ramWrite(0x310, 0x3f, 4); // CIC seed
    cpu.r[20] = BigInt.one;
    cpu.r[22] = BigInt.from(0x3f);

    _nextLine = clocksInScanline;
    _frame = 0;
    debugStatus.clock = debugStatus.frame = debugStatus.scanline = 0;
    debugStatus.pc = cpu.pc;
  }

  @override
  ExecResult exec(bool step) {
    final before = cpu.clocks;
    if (!step && cpu.idleLoop) {
      cpu.idle(_nextLine - cpu.clocks);
    } else {
      cpu.step();
    }
    bus.tick(cpu.clocks - before);
    var line = false;
    if (cpu.clocks >= _nextLine) {
      _nextLine += clocksInScanline;
      bus.scanline++;
      if (bus.scanline == scanlinesInFrame) {
        bus.scanline = 0;
        _frame++;
      }
      if (bus.scanline * 2 == bus.vi[3].mask10) bus.interrupt(8);
      line = true;
    }
    debugStatus.clock = cpu.clocks;
    debugStatus.frame = _frame;
    debugStatus.scanline = bus.scanline;
    debugStatus.pc = cpu.pc;
    _result.elapsedClocks = cpu.clocks;
    _result.stopped = cpu.stopReason != null;
    _result.scanlineRendered = line;
    return _result;
  }

  @override
  ImageBuffer imageBuffer() => bus.image();
  @override
  void onAudio(void Function(AudioBuffer) onAudio) {
    bus.onAudio = onAudio;
  }

  @override
  void setDisc(Disc disc) {}
  @override
  void setSram(Sram sram) {
    bus.sram = sram;
  }

  // Arrow buttons drive the analog stick; the remaining buttons use PIF bits.
  @override
  List<PadButton> get buttons => [
        PadButton.up,
        PadButton.down,
        PadButton.left,
        PadButton.right,
        const PadButton('Z'),
        const PadButton('start'),
        const PadButton('B'),
        const PadButton('A'),
        const PadButton('C-down'),
        const PadButton('L'),
        const PadButton('C-left'),
        const PadButton('R'),
        const PadButton('C-up'),
        const PadButton('C-right')
      ];
  @override
  void padDown(int controllerId, PadButton k) => bus.pad(controllerId, k, true);
  @override
  void padUp(int controllerId, PadButton k) => bus.pad(controllerId, k, false);
  @override
  int programCounter(int cpuNo) => cpu.pc;
  @override
  int stackPointer(int cpuNo) => cpu.address(cpu.r[29]);
  @override
  (String, int) disasm(int cpuNo, int addr) => (
        '${addr.x8}: .word 0x${bus.read(addr, 4).x8}',
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
      'N64 ${_rom?.title ?? ''} (Dart / task HLE)\n'
      'PC:${cpu.pc.hex} cycles:${cpu.clocks}\n'
      '${List.generate(32, (i) => 'r$i:${cpu.r[i].toUnsigned(64).toRadixString(16).padLeft(16, '0')}').join(' ')}\n'
      'RSP graphics:${graphics.tasks} triangles:${graphics.triangles} audio:${audio.tasks}\n'
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

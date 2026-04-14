import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu/core/ps/gpu/gpu_debug.dart';
import 'package:fnesemu/core/ps/serial.dart';
import 'package:fnesemu/core/ps/timer.dart';
import 'package:fnesemu/util/int.dart';
import 'package:fnesemu/util/uint8list.dart';
import 'package:fnesemu/util/util.dart' show range;

import '../../util/debug.dart';
import '../core.dart';
import '../disc.dart';
import '../pad_button.dart';
import '../sram.dart';
import '../types.dart';
import 'bus.dart';
import 'cdrom.dart';
import 'dma.dart';
import 'gpu/gpu.dart';
import 'interrupt.dart';
import 'mdec.dart';
import 'memory_card.dart';
import 'pad.dart';
import 'r3000/disasm.dart';
import 'r3000/r3000.dart';
import 'spu/spu.dart';

const _fastboot = bool.fromEnvironment("FASTBOOT", defaultValue: false);
const _memcardFile = String.fromEnvironment("MEMCARD", defaultValue: "");

class Ps extends Core {
  final Bus bus;
  late final R3000 cpu;
  late final Gpu gpu;
  late final Pad pad;
  late final MemoryCard memoryCard;
  late final MemoryCard memoryCard2;
  late final Serial serial;
  late final Spu spu;
  late final TimerController timer;
  late final Cdrom cdrom;
  late final Mdec mdec;
  late final Dma dma;

  bool fastBoot = _fastboot;

  Ps() : bus = Bus() {
    cpu = R3000(bus);
    gpu = Gpu(bus);
    pad = Pad();
    memoryCard = MemoryCard();

    memoryCard2 = MemoryCard();
    if (_memcardFile.isNotEmpty) {
      debugLog("loaded memory card from $_memcardFile");
      final memcard2Image = File(_memcardFile).readAsBytesSync();
      memoryCard2.setRw((addr) => memcard2Image[addr],
          (addr, value) => memcard2Image[addr] = value);
    }

    serial = Serial(
      bus,
      pad,
      memoryCard,
      memoryCard2,
    );
    spu = Spu(bus);
    timer = TimerController(bus);
    cdrom = Cdrom(bus);
    mdec = Mdec();
    dma = Dma(bus);

    bus.interrupt = InterruptController()..cpu = cpu;
    bus.dma = dma;
    bus.gpu = gpu;
    bus.cpu = cpu;
    bus.serial = serial;
    bus.spu = spu;
    bus.timer = timer;
    bus.cdrom = cdrom;
    bus.mdec = mdec;
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
    if (body.getUint32BE(0) == 0x50532d58 &&
        body.getUint32BE(4) == 0x20455845) {
      cpu.exe = body;
      debugLog("loaded PS-EXE");
      return;
    }

    bus.rom.setAll(0, body);

    if (fastBoot) {
      const fastBootSequence = [
        // turn display on by writing 0x0300 to GPU I/O: 1f801814 with using only register t2
        0x3c0a1f80, // lui  t2, 0x1f80
        0x354a1814, // ori  t2, t2, 0x1814
        0x340b0300, // ori  t3, zero, 0x0300
        0xad4b0000, // sw   t3, 0(t2)
        0x03e00008, // jr   ra
        0x00000000, // nop
      ];
      int patchAddr = 0x18000;
      for (int b32 in fastBootSequence) {
        bus.rom.setUint32LE(patchAddr, b32);
        patchAddr += 4;
      }
    }

    cdrom.closeShell();

    _sram.init("psx_mem1", MemoryCard.blankImage);
    memoryCard.setRw(_sram.read8, _sram.write8);
  }

  int nextScanlineClock = 0;
  int nextTimerClock = 0;
  bool _waitFinishLine = false;
  int nextDmaClock = 0;
  int nextSpuClock = 0;
  int nextSerialClock = 0;
  int nextCdromClock = 0;

  late Sram _sram;

  void Function(AudioBuffer) _onAudio = (_) {};
  final audioBuffer = Float32List(1000 * 2);
  int audioBufferIndex = 0;

  @override
  ExecResult exec(bool step) {
    cpu.step();

    if (cpu.clocks > nextTimerClock) {
      nextTimerClock += 100;
      bus.timer.clock(100);
    }

    if (cpu.clocks > nextScanlineClock) {
      bus.timer.endHBlank();
      nextScanlineClock += clocksInScanline;
      gpu.renderScanline();
      _waitFinishLine = true;
      return ExecResult(cpu.clocks, false, true);
    }

    if (_waitFinishLine && cpu.clocks >= nextScanlineClock - 200) {
      bus.timer.startHBlank();
      _waitFinishLine = false;
    }

    if (cpu.clocks > nextDmaClock) {
      nextDmaClock += 24;
      bus.dma.exec(24);
    }

    if (cpu.clocks > nextSpuClock) {
      nextSpuClock += 768; // master clock 33.8688MHz / 44100Hz
      final (l, r) = spu.render();
      audioBuffer[audioBufferIndex + 0] = l;
      audioBuffer[audioBufferIndex + 1] = r;
      audioBufferIndex += 2;
      if (audioBufferIndex >= audioBuffer.length) {
        _onAudio(AudioBuffer(44100, 2, audioBuffer));
        audioBufferIndex = 0;
      }
    }

    if (cpu.clocks > nextSerialClock) {
      nextSerialClock += 100;
      bus.serial.exec(100);
    }

    if (cpu.clocks > nextCdromClock) {
      nextCdromClock += 200;
      bus.cdrom.exec(200);
    }

    debugStatus.clock = cpu.clocks;
    debugStatus.frame = gpu.frame;
    debugStatus.scanline = gpu.scanline;
    debugStatus.pc = cpu.pc;

    return ExecResult(cpu.clocks, false, false);
  }

  @override
  void reset() {
    cpu.reset();

    nextScanlineClock = 0;
    nextTimerClock = 0;
    nextDmaClock = 0;
    nextSpuClock = 0;
    nextSerialClock = 0;
    nextCdromClock = 0;
    _waitFinishLine = false;
    audioBuffer.fillRange(0, audioBuffer.length, 0);

    gpu.reset();
    spu.reset();
    pad.reset();
    memoryCard.reset();
    serial.reset();
    cdrom.reset();
    timer.reset();
    bus.reset();

    debugStatus.clock = 0;
    debugStatus.frame = 0;
    debugStatus.scanline = 0;
    debugStatus.pc = cpu.pc;
  }

  @override
  ImageBuffer imageBuffer() => gpu.imageBuffer;

  @override
  onAudio(void Function(AudioBuffer p1) f) => _onAudio = f;

  @override
  void setDisc(Disc disc) {
    debugLog("set disc ${disc.isEmpty ? "empty" : "with data"}");
    disc.isEmpty ? bus.cdrom.openShell() : bus.cdrom.closeShell();
    bus.cdrom.readDisc = disc.read;
  }

  @override
  void setSram(Sram sram) => _sram = sram;

  @override
  List<PadButton> get buttons => pad.buttons;

  @override
  void padDown(int id, PadButton k) => pad.keyDown(id, k);

  @override
  void padUp(int id, PadButton k) => pad.keyUp(id, k);

  @override
  int programCounter(int _) => cpu.pc;

  @override
  int stackPointer(int _) => cpu.r[29];

  @override
  (String, int) disasm(int _, int addr) {
    addr = addr.mask32 & ~0x03;
    final inst32 = bus.read32(addr);
    return (
      "${addr.hex32}: ${inst32.hex32} ${DisasmR3000.disasm(inst32, pc: addr, regs: cpu.r)}",
      4
    );
  }

  @override
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    return "${disasm(0, cpu.pc).$1}\n${cpu.dump()} cy:${cpu.clocks}\n"
        "${range(0, 7).map((ch) => bus.dma.channels[ch].dump()).join("\n")}\n"
        "${timer.timers.map((t) => t.dump()).join(" ")}\n"
        "${bus.interrupt.dump()}\n"
        "${gpu.dump()}\n"
        "${spu.dump()}\n"
        "${serial.dump()}\n"
        "cdrom: ${cdrom.dump()}\n"
        "mdec: ${mdec.dump()}";
  }

  @override
  TraceLog trace(int cpuNo) => TraceLog(
      cpu.pc,
      cpu.clocks,
      disasm(0, cpu.pc).$1.padRight(46),
      cpu.dump().replaceAll("\n", " "),
      [for (int i = 0; i < 32; i++) cpu.r[i]],
      frame: gpu.frame,
      scanline: gpu.scanline);

  @override
  int read(int _, int addr) => (addr >> 28 == 0x07)
      ? bus.spu.ram[addr & 0x7ffff]
      : bus.read32(addr & 0x1fffff);

  @override
  ImageBuffer renderBg() => gpu.renderBg();

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

// Dart imports:
import 'dart:async';
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
import 'apu.dart';
import 'apu_debug.dart';
import 'bus.dart';
import 'cpu.dart';
import 'cpu_debug.dart';
import 'joypad.dart';
import 'mapper/mapper.dart';
import 'ppu.dart';
import 'ppu_debug.dart';
import 'rom/nes_file.dart';

/// main class for NES emulation. integrates cpu/ppu/apu/bus/pad control
class Nes {
  late final Ppu ppu;
  late final Apu apu;
  late final Cpu cpu;
  late final Bus bus;

  static const cpuClock = 1789773;
  static const apuClock = cpuClock ~/ 2;

  static const cpuCyclesInScanline = 114;
  static const scanlinesInFrame = 262;

  Nes() {
    bus = Bus();
    cpu = Cpu(bus);
    ppu = Ppu(bus);
    apu = Apu(bus);
  }

  int nextPpuCycle = 0;
  int nextApuCycle = 0;

  /// exec 1 cpu instruction and render PPU / APU is enough cycles passed
  void exec() async {
    cpu.exec();
    if (cpu.cycle >= nextPpuCycle) {
      ppu.exec();
      nextPpuCycle += cpuCyclesInScanline;
    }
    if (cpu.cycle >= nextApuCycle) {
      apu.exec();
      nextApuCycle += scanlinesInFrame * cpuCyclesInScanline;
    }
  }

  /// returns screen buffer as 250x240xargb
  Uint8List ppuBuffer() {
    return ppu.buffer;
  }

  // returns audio buffer as float32 with (1.78M/2) Hz * 1/60 samples
  Float32List apuBuffer() {
    return apu.buffer;
  }

  /// handles reset button events
  void reset() {
    nextPpuCycle = cpuCyclesInScanline;
    nextApuCycle = scanlinesInFrame * cpuCyclesInScanline;
    stop();
    bus.onReset();
  }

  /// handles pad down/up events
  void padDown(PadButton k) => bus.joypad.keyDown(k);
  void padUp(PadButton k) => bus.joypad.keyUp(k);

  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    final cpuDump = cpu.dump(showRegs: true);
    final dump = "${cpuDump.substring(0, 48)}\n"
        "${cpuDump.substring(48)}\n"
        "${cpu.dump(showIRQVector: true, showStack: showStack, showZeroPage: showZeroPage)}"
        "${ppu.dump(showSpriteVram: showSpriteVram)}"
        "${showApu ? apu.dump() : ""}"
        "${bus.mapper.dump()}";
    return dump;
    // return '${fps.toStringAsFixed(2)}fps';
  }

  // loads an iNES format rom file.
  // throws exception if the mapper typ of the rom file is not supported.
  void setRom(Uint8List body) {
    stop();

    final nesFile = NesFile();
    nesFile.load(body);

    switch (nesFile.mapper) {
      case 0:
        bus.mapper = MapperNROM();
        break;
      case 1:
        bus.mapper = MapperMMC1();
        break;
      case 2:
        bus.mapper = MapperUxROM();
        break;
      case 3:
        bus.mapper = MapperCNROM();
        break;
      case 4:
        bus.mapper = MapperMMC3();
        break;
      case 75:
        bus.mapper = MapperVrc1();
        break;
      case 21:
        bus.mapper = MapperVrc4a4c();
        break;
      case 23:
        bus.mapper = MapperVrc4f4e();
        break;
      case 25:
        bus.mapper = MapperVrc4b4d();
        break;
      default:
        throw Exception("unimplemented mapper:${nesFile.mapper}!");
    }

    bus.mapper.setRom(nesFile.character, nesFile.program);
    bus.mirrorVertical(nesFile.mirrorVertical);
    bus.mapper.mirrorVertical = bus.mirrorVertical;

    bus.mapper.holdIrq = (hold) => hold ? bus.holdIrq() : bus.releaseIrq();

    bus.onReset();
  }

  // below will be deprecated

  int breakpoint = 0;
  bool forceBreak = false;
  bool enableDebugLog = false;

  void execStep() async {
    cpu.exec();
    if (enableDebugLog) {
      cpu.debugLog();
    }
    renderVideo(ppu.buffer);
    renderAudio(apu.buffer);
  }

  void execLine() async {
    final cycle = cpu.cycle;
    while (cpu.cycle - cycle < 114) {
      if (cpu.regs.PC == breakpoint) {
        stop();
        renderVideo(ppu.buffer);
        return;
      }
      if (!cpu.exec()) {
        forceBreak = true;
      }
      if (enableDebugLog) {
        cpu.debugLog();
      }
    }
    ppu.exec();
    renderVideo(ppu.buffer);
    renderAudio(apu.buffer);
  }

  void execFrame() async {
    final cycle = cpu.cycle;
    for (int j = 0; j < 262; j++) {
      while (cpu.cycle - cycle < 114 * (j + 1)) {
        if (cpu.regs.PC == breakpoint || forceBreak) {
          stop();
          renderVideo(ppu.buffer);
          forceBreak = false;
          return;
        }
        if (!cpu.exec()) {
          forceBreak = true;
        }
        if (enableDebugLog) {
          cpu.debugLog();
        }
      }
      ppu.exec();
    }
    apu.exec();
    renderVideo(ppu.buffer);
    renderAudio(apu.buffer);
  }

  Future<void> Function(Uint8List) renderVideo = ((_) async {});
  Future<void> Function(Float32List) renderAudio = ((_) async {});

  Timer? _timer;
  double fps = 0.0;

  void run() async {
    final startAt = DateTime.now();
    var frames = 0;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (fps <= 60.0) {
        execFrame();
        frames++;
      }
      fps = frames /
          (DateTime.now().difference(startAt).inMilliseconds.toDouble() /
              1000.0);
    });
  }

  void stop() async {
    _timer?.cancel();
  }

  void keyDown(PadButton k) => bus.joypad.keyDown(k);
  void keyUp(PadButton k) => bus.joypad.keyUp(k);
}

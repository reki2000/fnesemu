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

class Nes {
  late final Ppu ppu;
  late final Apu apu;
  late final Cpu cpu;
  late final Bus bus;

  int breakpoint = 0;
  bool forceBreak = false;
  bool enableDebugLog = false;

  Nes() {
    ppu = Ppu();
    apu = Apu();
    cpu = Cpu();
    bus = Bus(cpu, ppu, apu);
  }

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

  void setRom(Uint8List body) {
    stop();
    final nesFile = NesFile()..load(body);

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
      default:
        log("unimplemented mapper:${nesFile.mapper}!");
        return;
    }

    bus.mapper.loadProgramRom(nesFile.program);
    bus.mapper.loadCharRom(nesFile.character);

    bus.mirrorVertical(nesFile.mirrorVertical);
    bus.mapper.mirrorVertical = bus.mirrorVertical;

    bus.mapper.holdIrq = (hold) => hold ? bus.holdIrq() : bus.releaseIrq();

    bus.onReset();
  }

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
    _timer = Timer.periodic(const Duration(milliseconds: 17), (timer) {
      execFrame();
      frames++;
      fps = frames /
          (DateTime.now().difference(startAt).inMilliseconds.toDouble() /
              1000.0);
    });
  }

  void stop() async {
    _timer?.cancel();
  }

  void reset() {
    stop();
    cpu.reset();
  }

  void keyDown(PadButton k) => bus.joypad.keyDown(k);
  void keyUp(PadButton k) => bus.joypad.keyUp(k);
}

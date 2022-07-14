// Dart imports:
import 'dart:async';
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
import '../rom/nes_file.dart';
import 'apu.dart';
import 'apu_debug.dart';
import 'bus.dart';
import 'cpu.dart';
import 'cpu_debug.dart';
import 'mapper/mapper.dart';
import 'mapper/mapper1.dart';
import 'ppu.dart';
import 'ppu_debug.dart';

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
        "${showApu ? apu.dump() : ""}";
    return dump;
    // return '${fps.toStringAsFixed(2)}fps';
  }

  void setRom(Uint8List body) {
    stop();
    final nesFile = NesFile()..load(body);

    switch (nesFile.mapper) {
      case 0:
        bus.mapper = Mapper0();
        break;
      case 1:
        bus.mapper = Mapper1();
        break;
      case 2:
        bus.mapper = Mapper2();
        break;
      case 3:
        bus.mapper = Mapper3();
        break;
      case 4:
        bus.mapper = Mapper4();
        break;
      default:
        log("unimplemented mapper:${nesFile.mapper}!");
        return;
    }

    bus.mapper.loadProgramRom(nesFile.program);
    bus.mapper.loadCharRom(nesFile.character);
    bus.mapper.init();

    bus.mirrorVertical = nesFile.mirrorVertical;

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
    // await _mPlayer.resume();
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
    // await _mPlayer.stop();
  }

  void reset() {
    stop();
    cpu.reset();
  }
}

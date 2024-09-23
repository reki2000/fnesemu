// Dart imports:
import 'dart:async';
import 'dart:typed_data';

import '../../util.dart';
// Project imports:
import '../types.dart';
import 'component/bus.dart';
import 'component/cpu.dart';
import 'component/cpu_debug.dart';
import 'component/cpu_disasm.dart';
import 'component/pic.dart';
import 'component/psg.dart';
import 'component/psg_debug.dart';
import 'component/timer.dart';
import 'component/vdc.dart';
import 'component/vdc_render.dart';
import 'mapper/rom.dart';
import 'pad_button.dart';
import 'rom/pce_file.dart';
import 'storage.dart';

export 'pad_button.dart';

// data class to conver the result of 'exec'
class ExecResult {
  final int cycles;
  final bool stopped;
  final bool scanlineRendered;
  ExecResult(this.cycles, this.stopped, this.scanlineRendered);
}

/// main class for NES emulation. integrates cpu/ppu/apu/bus/pad control
class Pce {
  late final Vdc vdc;
  late final Psg psg;
  late final Cpu2 cpu;
  late final Bus bus;
  late final Timer timer;
  late final Pic pic;

  final storage = Storage.of();

  static const systemClock = 21477270;

  static const clocksInScanline = systemClock ~/ 59.97 ~/ scanlinesInFrame;
  static const scanlinesInFrame = 263;

  Pce() {
    bus = Bus();
    cpu = Cpu2(bus);
    vdc = Vdc(bus);
    psg = Psg(bus);
    timer = Timer(bus);
    pic = Pic(bus);
  }

  int nextVdcClocks = 0;
  int prevPsgClocks = 0;

  /// exec 1 cpu instruction and render PPU / APU if enough cycles passed
  /// returns current CPU cycle and bool - false when unimplemented instruction is found
  ExecResult exec() {
    final cpuOk = cpu.exec();

    bus.timer.exec(cpu.clock);

    if (!cpuOk) {
      return ExecResult(cpu.cycles, false, false);
    }

    bool rendered = false;

    while (cpu.clocks >= nextVdcClocks) {
      vdc.exec();
      nextVdcClocks += clocksInScanline;
      // print(
      //     "cpu.clocks:${cpu.clocks} cpu.cycles:${cpu.cycles} nextVdcClocks: $nextVdcClocks");
      rendered = true;
    }

    while (cpu.clocks >= prevPsgClocks + clocksInScanline) {
      final elapsed = (cpu.clocks - prevPsgClocks) ~/ 6 * 6;
      prevPsgClocks += elapsed;
      audioStream?.add(psg.exec(elapsed));
    }

    return ExecResult(cpu.cycles, true, rendered);
  }

  /// returns screen buffer as hSize x vSize argb
  ImageBuffer imageBuffer() {
    return ImageBuffer(
        vdc.hSize, vdc.vSize, VdcRenderer.buffer.buffer.asUint8List());
  }

  StreamSink<Float32List>? audioStream;

  static const audioSampleRate = Psg.audioSamplingRate;

  /// handles reset button events
  void reset() {
    nextVdcClocks = clocksInScanline;
    prevPsgClocks = clocksInScanline;
    bus.onReset();
  }

  /// handles pad down/up events
  void padDown(PadButton k) => bus.joypad.keyDown(k);
  void padUp(PadButton k) => bus.joypad.keyUp(k);

  // ROM CRC
  String crc = "";

  // loads an .pce format rom file.
  // throws exception if the mapper type of the rom file is not supported.
  void setRom(Uint8List body) {
    final file = PceFile();
    file.load(body);
    crc = file.crc;

    bus.rom = Rom(file.banks);

    reset();
  }

  /// debug: returns the emulator's internal status report
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    final cpuDump = cpu.dump(showRegs: true);
    final dump = "$cpuDump\n"
        "${cpu.dump(showIRQVector: true, showStack: showStack, showZeroPage: showZeroPage)}"
        "${showApu ? psg.dump() : ""}"
        "${bus.vdc.dump()}";
    return dump;
    // return '${fps.toStringAsFixed(2)}fps';
  }

  // debug: returns dis-assembled 6502 instruction in [String nmemonic, int nextAddr]
  Pair<String, int> disasm(int addr) => Pair(
      cpu.dumpDisasm(addr, toAddrOffset: 1), Disasm.nextPC(cpu.read(addr)));

  // debug: returns PC register
  int get pc => cpu.regs.pc;

  // debug: set debug logging
  String get state => "${cpu.trace()} ${vdc.dump()}";

  // debug: dump vram
  List<int> dumpVram() => vdc.vram.toList(growable: false);

  // debug: read mem
  int read(int addr) => bus.cpu.read(addr);

  // debug: dump color table
  List<int> dumpColorTable() => vdc.colorTable;
}
